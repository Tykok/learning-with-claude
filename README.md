# Claude Learning Mode

[![CI](https://github.com/Tykok/learning-with-claude/actions/workflows/ci.yml/badge.svg)](https://github.com/Tykok/learning-with-claude/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Claude Code](https://img.shields.io/badge/Claude%20Code-hooks%20%2B%20skill-8A63D2)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25?logo=gnu-bash&logoColor=white)

Turn Claude Code into a **learning loop**. While it writes code with you, it periodically
stops to quiz you on what was just built, at your level, and keeps a per-developer record of
your weak spots and progress. Stack-agnostic. One install, active in every git repo you open
with Claude Code — no per-repo setup.

## What it does

- **`SessionStart`** — reports a broken install (missing `jq`, no valid `level` configured)
  through hidden context; a healthy install says nothing.
- **`PostToolUse`** (`Write`/`Edit`) — records every file edited this session, so the `Stop`
  hook has something to quiz on.
- **`Stop`** — blocks once and asks Claude, via the `learner` skill, to pose **one** question
  about the code just written (or, periodically, a **synthesis** question about how the whole
  session's work fits together). The same hook carries a guardrail: it re-blocks
  unconditionally, even with the quiz disabled, while any `// LEARNER-TODO` marker survives
  anywhere in the repo, so a crashed fill-in exercise can never leave the tree broken.
- **`learner` skill**, invoked on demand or by the `Stop` hook trigger: `quiz` (Q&A over the
  current branch diff), `status` (read-only: level + what to improve), `improve` (coach one
  weak spot to mastery), `config` (view/edit settings, including `off`/`on` for this repo).

The only thing in the whole system that writes into a repository is the skill's
`learner off` / `learner on` / `learner config project …` — and only when you ask for it.
Everything else, the installer included, lives entirely under your Claude Code config
directory.

## Three question styles

- `code` — what a specific changed function does.
- `architecture` (alias `archi`) — which module/directory/layer the code lives in, and why.
- `fill` — Claude blanks part of a real function's body with `// LEARNER-TODO: <hint>`
  comments, you write the missing code back **in the file**, Claude restores the correct
  version and validates it.

The `fill` style carries a guardrail, not just a convention: the `Stop` hook blocks
unconditionally — even with the quiz otherwise disabled — while any `// LEARNER-TODO` marker
survives anywhere in the repo. A session that ends mid-exercise (crash, closed terminal,
`/clear`) can never leave source code broken; the next `Stop` keeps blocking until the marker
is gone.

## Requirements

- **`jq`** on `PATH`. Required to install (the hook-wiring merge needs it) and required by
  every hook at run time — without it they are inert, and `SessionStart` says so.
- **POSIX `sh`** — macOS, Linux, WSL. Native Windows without a `sh` is not supported.
- **Claude Code** installed (`claude` on `PATH`, or an existing config directory).

## Install

```bash
./install.sh                                          # interactive prompt for level/synthesis/blanks
./install.sh --level S --synthesis normal --blanks 2  # non-interactive, one shot
./install.sh --dry-run                                # print what would happen, write nothing
./install.sh --yes                                    # never prompt; defaults for anything unset
```

- `--level D|J|C|S|E` — your level: the letter, or the full word from the table below, in any
  case.
- `--synthesis off|rare|normal|often` — how often a synthesis question replaces a granular one.
- `--blanks N` — holes left in a `fill` exercise (integer ≥ 1).
- `--dry-run` — print what would be written; write nothing.
- `--yes` (`-y`) — never prompt; fill in anything not passed with its default.

The installer is idempotent: re-running re-copies the hooks and the skill and re-merges the
hook wiring into `settings.json` without duplicating entries, and it never overwrites an
existing config. **It writes nothing into any repository** — every path it touches sits under
`$CLAUDE_CONFIG_DIR` (default `~/.claude`), and every hook command it wires into
`settings.json` carries the literal `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, so moving your
config directory later needs no reinstall.

## Levels

The canonical value is the letter; the full name is accepted too, in any case.

| Letter | Name | What a question targets |
|--------|------|-------------------------|
| `D` | Discovering | syntax, what a block is for, basic vocabulary |
| `J` | Junior | what the function does, where the code lives |
| `C` | Competent | why this split, edge cases, error handling |
| `S` | Senior | trade-offs, rejected alternatives, perf and coupling impact |
| `E` | Expert | invariants, failure modes, what breaks at scale |

## Turning it off

Three ways, depending on scope:

1. **Everywhere** — set `"enabled": false` in the global config, or run
   `learner config enabled=false`.
2. **One repo you own** — say `learner off` in that repo; it writes
   `<repo>/.claude/learner.local.json` (gitignoring it if needed). `learner on` reverses it.
3. **One repo you don't own** (nothing should be committed to it) — add its path to
   `disabledPaths` in the global config, e.g. `learner config disabledPaths='["/path/to/repo"]'`.
   This writes nothing into that repo. Matching is a path-prefix check: disabling `/a/b`
   silences `/a/b/c` but not a sibling like `/a/bee`.

## Settings

Two layers, later wins **key by key** — arrays are replaced wholesale, never merged:

1. `$CLAUDE_CONFIG_DIR/learner.json` (default `~/.claude/learner.json`) — your defaults for
   every repo. Written by the installer, edited by `learner config …`.
2. `<repo>/.claude/learner.local.json` — optional, gitignored, partial override for one repo.
   Written by `learner off` / `on` / `config project …`.

| Key | Values | Default | Effect |
|-----|--------|---------|--------|
| `level` | `D`/`J`/`C`/`S`/`E` | — required | Question difficulty |
| `enabled` | bool | `true` | Master switch for the automatic quiz |
| `questionStyles` | `"auto"` or subset of `code`/`architecture`/`fill` | `"auto"` | Allowed formats |
| `synthesisFrequency` | `off`/`rare`/`normal`/`often` | `normal` | Synthesis question every 0/8/4/2 questions |
| `blanksPerExercise` | int ≥ 1 | `2` | `// LEARNER-TODO` holes in a `fill` exercise |
| `untrackGlobs` | array of globs | `[]` | Extra paths excluded from quiz material |
| `disabledPaths` | array of path prefixes | `[]` | Repos where learner stays silent |

See `learner.json.example`.

File tracking is an **exclusion list**, not an include list: every file Claude edits counts as
quiz material, minus a built-in, non-configurable floor —

- directories anywhere in the path: `node_modules/`, `build/`, `dist/`, `out/`, `target/`,
  `vendor/`, `.git/`, `.gradle/`, `__pycache__/`, `.venv/`, `coverage/`, `__snapshots__/`
- file suffixes: `*.lock`, `*-lock.*`, `*.min.*`, `*.generated.*`, `*.snap`

— minus your own `untrackGlobs` on top of that floor. Globs are matched with shell pattern
matching and split on whitespace internally, so **a glob containing a space is not supported**.

## Files installed

Everything lives under `$CLAUDE_CONFIG_DIR` (default `~/.claude`, written `$CFG` below):

| Path | Role |
|------|------|
| `$CFG/skills/learner/SKILL.md` | The `learner` skill: dispatch, levels, config |
| `$CFG/skills/learner/references/*.md` | Skill protocol — `quiz.md`, `hook-quiz.md`, `improve.md`, `data.md` |
| `$CFG/hooks/learner-config.sh` | Shared config resolution — sourced by the other hooks, never invoked directly |
| `$CFG/hooks/learner-onboard.sh` | `SessionStart` — reports a broken install |
| `$CFG/hooks/learner-record-edit.sh` | `PostToolUse` — records edited files |
| `$CFG/hooks/learner-quiz.sh` | `Stop` — quiz trigger + `LEARNER-TODO` guardrail |
| `$CFG/hooks/learner-cleanup.sh` | `SessionEnd` — deletes this session's scratch files |
| `$CFG/settings.json` | Hook wiring, merged in (a `.bak` is kept alongside it) |
| `$CFG/learner.json` | Your global config |
| `$CFG/learner/memory.md` | Working memory — open weak spots, drives question selection |
| `$CFG/learner/recap.md` | Readable dashboard — to-improve / mastered / session history |

Five hook files ship; four are wired into `settings.json`. `learner-config.sh` is sourced by
the other four, never invoked directly by Claude Code.

## Uninstall

```bash
./uninstall.sh                            # removes hooks, skill, hook wiring; keeps your data
./uninstall.sh --purge                    # also deletes learner.json and learner/ (memory + recap)
./uninstall.sh --project /path/to/repo    # clean up a repo left over from the per-project beta
```

`--project` reverses the old per-repo install (hooks, skill, `.claude/settings.json` entries
and `.gitignore` lines) inside one specific repo — for anyone who installed an earlier,
per-project version of learner and wants it fully gone. Per-repo overrides
(`.claude/learner.local.json`) are not centrally enumerable, so a plain `./uninstall.sh`
cannot remove them for you: delete them by hand, or use `--project <repo>` for a legacy
per-project install.

## Development

```bash
./test.sh                                                     # hook + installer + skill tests
shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh test.sh
```

The `hooks/*.sh` glob covers all five shipped hook files, including `learner-config.sh`. CI
(`.github/workflows/ci.yml`) runs both on every push and PR.

## License

[MIT](./LICENSE) © Tykok
