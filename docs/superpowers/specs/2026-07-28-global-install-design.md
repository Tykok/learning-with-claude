# Claude Learner — global install redesign

Date: 2026-07-28
Status: approved design, not yet implemented

## Goal

Learner is currently installed **per project**: hooks and skill are copied into
`<repo>/.claude/`, and every repo carries its own config and progress files. This redesign
makes it a **single user-level install** that works in every repo, with per-project
overrides, English-first content, and a much smaller console footprint.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | Install is user-level (`$CLAUDE_CONFIG_DIR`), never per repo. |
| 2 | Two config layers: global defaults, project override wins key by key. |
| 3 | Content is English; questions are asked in whatever language the dev writes in. |
| 4 | `trackGlobs` → `untrackGlobs`, additive on top of a non-removable built-in floor. |
| 5 | Levels become letters: `D` / `J` / `C` / `S` / `E`. |
| 6 | `language` param removed. |
| 7 | Progress data is global, tagged by repo. |
| 8 | Hooks emit a 2-line trigger; the protocol lives in the skill. |
| 9 | `install.sh` does the onboarding (level, synthesis, blanks) and verifies Claude Code exists. |
| 10 | `recapEvery` → `synthesisFrequency` (keywords); `trouBlanks` → `blanksPerExercise`; `trou` → `fill`. |

No migration path. The current layout shipped as beta on a single repo; `uninstall.sh
--project <repo>` cleans it, then `install.sh` starts fresh.

## 1. Layout

Everything resolves from `CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` — never a hardcoded
`~/.claude`.

```
$CFG/skills/learner/SKILL.md          # user-level skill, available in every repo
$CFG/skills/learner/references/*.md   # protocol details, loaded on demand
$CFG/hooks/learner-*.sh               # hooks
$CFG/settings.json                    # hook wiring (idempotent merge)
$CFG/learner.json                     # global config, written by install.sh
$CFG/learner/memory.md                # working memory: open weak spots
$CFG/learner/recap.md                 # readable dashboard
```

The installer writes **nothing** into any repo. No hook copies, no `.gitignore` edits.

## 2. Config resolution

Two user-facing layers sit on top of baked-in defaults. Sources are merged left to right,
later wins **key by key**:

| Order | Source | Notes |
|-------|--------|-------|
| 1 | baked-in defaults | inside `learner-config.sh` |
| 2 | `$CFG/learner.json` | the dev's defaults, all repos |
| 3 | `<repo>/.claude/learner.local.json` | optional, gitignored, partial |

Implemented in `learner-config.sh`, sourced by the other hooks:

```sh
learner_config() {
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  proj="${CLAUDE_PROJECT_DIR:-.}/.claude/learner.local.json"
  jq -s '.[0] * .[1] * .[2]' \
    <(printf '%s' "$LEARNER_DEFAULTS") \
    <(cat "$cfg/learner.json" 2>/dev/null || echo '{}') \
    <(cat "$proj" 2>/dev/null || echo '{}')
}
```

- `jq`'s `*` deep-merges objects and **replaces** arrays and scalars. A project
  `untrackGlobs` therefore replaces the global list rather than appending — predictable, and
  the built-in floor still applies.
- `*` does not use `//`, so `"enabled": false` survives the merge (the current code has a
  comment about this exact jq pitfall; keep it).
- POSIX `sh` has no process substitution. Use temp files or `jq --argjson` with command
  substitution instead; the snippet above is illustrative, not literal.

### Activation predicate

`learner-record-edit.sh` and the quiz path of `learner-quiz.sh` run only when **all** hold:

1. `jq` is on `PATH`;
2. the cwd is inside a git repo (`git rev-parse --show-toplevel` succeeds);
3. the merged config has a non-empty `level`;
4. merged `enabled` is not `false`;
5. the repo's real path is not prefixed by any entry of `disabledPaths` (entries are
   tilde-expanded and compared as path prefixes, so a parent directory disables every repo
   under it).

The `LEARNER-TODO` guardrail in `learner-quiz.sh` is **exempt**: it runs unconditionally,
even with `enabled: false` and even with no config, so a crashed fill-in exercise can never
leave source broken.

Three ways to turn it off:

- everywhere → `"enabled": false` in `$CFG/learner.json`;
- one repo you own → `{"enabled": false}` in its `.claude/learner.local.json` (`learner off`
  writes it);
- a repo you don't own → add its path to `disabledPaths` globally, writing nothing into it.

## 3. Config schema

```json
{
  "level": "S",
  "enabled": true,
  "questionStyles": "auto",
  "synthesisFrequency": "normal",
  "blanksPerExercise": 2,
  "untrackGlobs": [],
  "disabledPaths": []
}
```

| Key | Values | Default | Effect |
|-----|--------|---------|--------|
| `level` | `D`/`J`/`C`/`S`/`E` | — **required** | Question difficulty |
| `enabled` | bool | `true` | Master switch for the automatic quiz |
| `questionStyles` | `"auto"` or subset of `code`/`architecture`/`fill` | `"auto"` | Allowed formats |
| `synthesisFrequency` | `off`/`rare`/`normal`/`often` | `normal` | How often a synthesis question replaces a granular one |
| `blanksPerExercise` | int ≥ 1 | `2` | `// LEARNER-TODO` holes in a `fill` exercise |
| `untrackGlobs` | array of globs | `[]` | Extra paths to exclude from quiz material |
| `disabledPaths` | array of path prefixes | `[]` | Repos where learner stays silent |

Removed: `language`, `trackGlobs`, `recapEvery`, `trouBlanks`.

### Levels

Canonical value is the letter. Matching is case-insensitive and accepts the full word as an
alias (`senior` → `S`).

| Letter | Name | What the question targets |
|--------|------|---------------------------|
| `D` | Discovering | syntax, what a block is for, basic vocabulary |
| `J` | Junior | what the function does, where the code lives |
| `C` | Competent | why this split, edge cases, error handling |
| `S` | Senior | trade-offs, rejected alternatives, perf/coupling impact |
| `E` | Expert | invariants, failure modes, what breaks at scale |

The table lives in `SKILL.md` (both quiz modes need it) and is the single source of truth
for how difficulty is modulated.

### `synthesisFrequency`

Keyword → every N questions: `off` = never, `rare` = 8, `normal` = 4, `often` = 2.

Behaviour change: the old `recapEvery` default was 3, `normal` is 4. Intentional.

### Question styles

`code` = what a changed function does. `architecture` (alias `archi`) = which module / layer
it lives in and why. `fill` = interactive fill-in exercise in the real source file.

### Exclusion floor

Always excluded, not removable via config:

```
node_modules/  build/  dist/  out/  target/  vendor/  .git/  .gradle/
__pycache__/  .venv/  coverage/  __snapshots__/
*.lock  *-lock.json  *.min.*  *.generated.*  *.snap
```

`untrackGlobs` adds to this floor. Inverting the model (exclude-list instead of
include-list) means every edited file is quiz material by default, so the floor is what
keeps a 8000-line `package-lock.json` from becoming a question.

## 4. Hooks

Today the quiz protocol exists twice: ~40 lines of French prompt inside `learner-quiz.sh`
(the `REASON` variable) and again in `SKILL.md`. The Stop hook's block `reason` is rendered
in the console, which is the noise the user wants gone — and the duplication is a
maintenance trap.

After: the hook emits a **trigger**, the skill owns the **protocol**.

```sh
REASON="🎓 Learner (level: $LEVEL) — files touched since last question: $FILES
Invoke the \`learner\` skill and follow references/hook-quiz.md (mode: granular, styles: $STYLES, blanks: $BLANKS). Ask ONE question, then wait for the answer."
```

The synthesis variant swaps `mode: granular` for `mode: synthesis` and lists the
session-wide file set. Both stay under 4 lines.

| Hook | Event | Job | Console output |
|------|-------|-----|----------------|
| `learner-config.sh` | *sourced* | merge the three config layers, emit JSON | — |
| `learner-onboard.sh` | SessionStart | check `jq` and that a config with a level exists | one line, only when broken |
| `learner-record-edit.sh` | PostToolUse `Write\|Edit` | activation predicate, then append the path to the session scratch file | none |
| `learner-quiz.sh` | Stop | `LEARNER-TODO` guardrail, else short block trigger | ~2 lines |
| `learner-cleanup.sh` | SessionEnd | remove `$TMPDIR` scratch files | none |

`learner-onboard.sh` shrinks a lot: `install.sh` now does the onboarding, so the hook only
reports a broken state (`jq` missing, or config without a level) instead of driving a
conversational setup.

Scratch files stay per session in `$TMPDIR` (`claude-learner-<sid>.{edits,session,count}`),
unchanged.

## 5. Skill file layout

```
skills/learner/
  SKILL.md                  # dispatch table, level table, config params
  references/hook-quiz.md   # protocol for the hook-triggered quiz
  references/quiz.md        # on-demand quiz over the branch diff
  references/improve.md     # coaching loop to mastery
  references/data.md        # memory.md / recap.md formats + write rules
```

`SKILL.md` is currently 258 lines and would grow by absorbing the hook protocol. Splitting
it keeps the always-loaded part small and lets each mode pull only what it needs.

`data.md` is shared by `hook-quiz.md`, `quiz.md` and `improve.md`, replacing the
triplicated description of the two learning files.

Subcommands: `config` (incl. `config project`, and the `off` / `on` shortcuts), `quiz`,
`status`, `improve`, `help`.

`learner off` writes `{"enabled": false}` into the current repo's
`.claude/learner.local.json` and adds that path to the repo's `.gitignore` if absent.
`learner on` removes the key. This is the only code that writes into a repo, and it only
runs when the dev asks for it.

The skill description is English, but keeps its French trigger phrases
(`interroge-moi`, `quiz sur la branche`, …) — consistent with mirroring the dev's language.

## 6. Data files

Both files move to `$CFG/learner/` and become global, tagged by repo.

`memory.md` — working memory, the **only** file that drives question selection:

```
- [Code][my-api] cache invalidation — seen: 2026-07-28
```

`recap.md` — dashboard, written but never read to pick a question:

- `To improve` / `Mastered`, grouped by domain, phrased as **broad competency themes** (no
  repo tag: a cross-repo view is the point).
- `Session history` gains a repo column: `| Date | Repo | Domain | Style | Verdict | Note |`

Repo tag is `basename "$(git rev-parse --show-toplevel)"`. Two repos with the same basename
collide in the tag; accepted, it is a reading label, not a key.

`status` and `improve` become cross-project as a result: "level up on error handling" holds
across every repo the dev works in.

## 7. install.sh / uninstall.sh

```bash
./install.sh                                          # interactive: 3 questions
./install.sh --level S --synthesis normal --blanks 2   # non-interactive
./install.sh --dry-run                                 # print what would be written
```

Preflight, in order:

1. **Claude Code present** — `command -v claude`, or `$CFG` exists. Otherwise **abort** with
   the install link. Installing without Claude Code does nothing useful.
2. **`jq`** — missing does not abort, but warns loudly: every hook is inert until `jq` is
   installed.
3. `$CFG/settings.json` unreadable or invalid JSON → abort **before** touching it.
   Otherwise back up to `settings.json.bak`, then merge idempotently (dedupe hook entries
   whose command contains `learner-`).
4. Onboarding: three prompts (level, synthesis frequency, blanks), Enter accepts the
   default. No TTY and no flags → use defaults, but `level` is required, so abort if it was
   not passed.

Hook commands are written with `$CFG` resolved at install time, so a non-default
`CLAUDE_CONFIG_DIR` is honoured.

```bash
./uninstall.sh                    # skill + hooks + settings blocks; keeps progress data
./uninstall.sh --purge            # also removes $CFG/learner.json and $CFG/learner/
./uninstall.sh --project <repo>   # clean a repo that still has the old per-project layout
```

`--project` keeps the existing, already-tested per-repo cleanup so the beta repo can be
cleared. A stray `.claude/learner.local.json` in some other repo is not enumerable — the
uninstaller says so plainly rather than implying a full sweep.

## 8. Tests

`test.sh` runs against a sandboxed config dir (`CLAUDE_CONFIG_DIR=$tmp/claude`) plus a
throwaway git repo. Cases:

- config merge: project override wins key by key; arrays replace, not append
- `"enabled": false` honoured at global level, at project level, and via `disabledPaths`
- no-op outside a git repo
- exclusion floor applies; `untrackGlobs` adds to it
- `LEARNER-TODO` guardrail fires even when `enabled` is `false` and when no config exists
- **Stop-hook `reason` size** — assert it stays under a line budget and contains no protocol
  prose; this is the regression test that keeps the console quiet
- install is idempotent; aborts when Claude Code is absent; aborts on invalid
  `settings.json`; `--dry-run` writes nothing
- `install.sh --level s` and `--level senior` both normalise to `S`

CI keeps running `test.sh` and `shellcheck --severity=warning` on every push and PR.

## 9. Docs

`README.md` is rewritten around the global install: one install command, the three ways to
disable, the new config table, the letter levels, and the fact that nothing is written into
repos. `learner.local.json.example` becomes `learner.json.example` with the new schema.

## Out of scope

- A third, committed config layer (`.claude/learner.json` as a team rule). YAGNI; the merge
  chain accepts one more source later without breaking anything.
- Disambiguating repos that share a basename in the data tag.
- Any migration of old configs or old per-project installs beyond `--project` cleanup.

## Traceability

| Request | Section |
|---------|---------|
| 1. install at Claude Code level | 1, 7 |
| 2. disable globally or per project | 2 |
| 3. English by default | 3, 5 (translation of skill + hooks) |
| 4. `untrackGlobs` instead of `trackGlobs` | 3 |
| 5. letter levels | 3 |
| 6. drop `language` | 3 |
| 7. global config, project override wins | 2 |
| 8. no skill text in the console | 4, 5, 8 |
| 9. smoother install with onboarding | 7 |
| 10. rename `recapEvery` / `trouBlanks` | 3 |
| Claude Code presence check | 7 |
