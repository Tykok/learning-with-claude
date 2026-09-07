# Coach mode — the dev writes the code, Claude challenges it

Date: 2026-09-07
Status: approved design, not yet implemented

## Goal

Learner today runs one way round: Claude writes the code, then quizzes the dev on it. That
keeps the dev informed, but it still leaves them a passenger — the code that lands is Claude's
code, and the dev's job is to answer questions about it afterwards.

Coach mode inverts the loop. **The dev writes the code.** Claude stops implementing, watches
the working tree from the outside, and comes back at chosen intervals with a challenge, a
handful of findings and a couple of leads — never with a patch. The dev may hand Claude a
named slice of the work ("you do the repositories, I do the service"), and only that slice.

The measure of success is not "did Claude produce good code" but "did the dev write it, defend
it, and level up on it".

## Locked decisions

| # | Decision |
|---|----------|
| 1 | Coach is a **subcommand family of the existing `learner` skill**, not a separate skill: it shares the config layers, the five levels, `memory.md` and `recap.md`. One learner record, two regimes. |
| 2 | No Claude Code hook fires when the *dev* saves a file in their editor — hooks only observe Claude's own tool calls. Coach therefore **polls the working tree** from a shipped shell script armed once per session as a persistent `Monitor`. This is not a preference; it is the only mechanism that can see the dev's edits. |
| 3 | Default cadence is a **pomodoro**, not a change threshold: work block (silent) → one notification → challenge window. A threshold cadence stays available via `coachCadence: "threshold"`. Rationale: a threshold interrupts mid-thought and makes token cost unbounded; a pomodoro interrupts at a boundary the dev picked and costs exactly one turn per cycle. |
| 4 | Work block starts at **25 min and grows 5 min per completed cycle, capped at 45**; the challenge window is a **fixed 8 min**. The work block grows, not the challenge window — the dev needs *less* scaffolding as they warm up, and a challenge window that grows would invert the actor/spectator relationship this whole mode exists to fix. |
| 5 | **One notification per cycle, never two.** The script emits at the end of the work block and stays silent at the end of the challenge window: the challenge ends naturally when the dev answers and goes back to coding. A "back to work" line would cost a full turn per cycle for no information. |
| 6 | The first work block starts **when the watcher is armed** (`coach on`, or the `SessionStart` nudge) — no extra `coach start` ceremony. |
| 7 | Out-of-scope writes are **denied**, not warned about: a `PreToolUse` hook on `Write\|Edit\|NotebookEdit` refuses any path outside the delegated globs. A skill instruction alone cannot hold over fifty turns, and drift back into implementing is precisely the failure this mode must not have. |
| 8 | Idle cut-off is **two consecutive empty work blocks** — relative to the dev's own cadence, so it adapts if they move to 50-minute blocks. The watcher emits one line and **exits**; nothing keeps running. |
| 9 | The **level drives two axes, not one**: what the challenge attacks *and* the register it is written in. Findings and leads are calibrated on the same axis as the questions — the same bug is phrased differently at `J` and at `S`. |
| 10 | The watcher's own lines are **English machine triggers**, consistent with the existing `🎓 Learner (level: …)` trigger. What the dev reads is Claude's rendering of them, which follows the skill's existing "mirror the dev" rule. There is still no language setting. |
| 11 | Delegation is **session-scoped** (a file in `TMPDIR`, not `learner.local.json`): who does which slice is a per-task decision, and it should not silently carry over into next week's session. |
| 12 | The built-in exclusion floor and `untrackGlobs` matching, today inline in `learner-record-edit.sh`, move into `learner-config.sh` as one shared `learner_excluded` helper. Coach needs the same list; two copies would drift. |

## 1. Dispatch — additions to `skills/learner/SKILL.md`

| Subcommand | Mode | Read |
|------------|------|------|
| `coach on` / `coach off` | Flip `coach` in the project config layer | this file, § Config |
| `coach delegate <glob> …` | Add write scopes for this session; `coach delegate none` clears | `references/coach.md` |
| `coach review [base-ref]` | Run one review immediately, off-cadence | `references/coach.md` |

`coach` with no further token behaves as `coach on`. `learner status` gains one line — coach on/off,
the cycle number, and the delegated globs — rather than growing a `coach status` of its own.

`coach review` runs the §4 protocol against the current candidate set and **advances the
baseline** on the way out, exactly as an emission does (§2.2). Otherwise the watcher would
re-serve the same material at the end of the running work block, and the dev would be
challenged twice on one diff.

The existing subcommands (`quiz`, `status`, `improve`, `export`, `update`, `config`) are unchanged
and serve both regimes.

## 2. The watcher — `hooks/coach-watch.sh`

A long-running script, **not** a hook. Armed once per session via the `Monitor` tool with
`persistent: true`. Its stdout is the event stream: one line per notification.

It sources `learner-config.sh` for config resolution and exits immediately (status 0) if `jq`
is missing, there is no git repo, learner is not active here, or `coach` is false — so an
accidental arming in the wrong repo is a no-op rather than a nuisance.

It needs the session id, which a hook receives on stdin but a `Monitor` command does not. It is
therefore invoked as `sh coach-watch.sh <session-id>`, with the id substituted by whoever arms
it — `learner-onboard.sh` reads it from its own stdin payload (§6), and the skill has it in
context for a manual `coach on`.

A second, test-only flag: `sh coach-watch.sh <session-id> --once` runs exactly one cycle with no
sleep and returns, instead of looping. Every watcher test below drives it this way, so the test
suite stays a few seconds long and never sleeps a real work block.

### 2.1 Candidate files — what counts as "the dev's work"

At the end of each work block, the candidate set is built in four steps:

1. **Everything touched in the working tree.** `git diff --name-only HEAD` (covers staged and
   unstaged), plus `git ls-files -o --exclude-standard` (untracked — a file the dev just
   created is the primary case), plus `git diff --name-only <baseline-HEAD> HEAD` where
   `<baseline-HEAD>` is the commit recorded when the baseline was last advanced. That third
   term matters: without it, a dev who commits at the end of a block would empty their own
   candidate set and get an "idle" cut-off for the block they just worked hardest in. In a repo
   with no commits yet, `git diff HEAD` fails and only the untracked term applies, which is the
   correct answer there.
2. **Minus the exclusion floor and `untrackGlobs`**, via the shared `learner_excluded` helper
   (decision #12) — same `node_modules` / `*.lock` / `dist` / generated-file floor the quiz
   already applies, and the same user globs.
3. **Minus every path Claude wrote this session**, read from the existing
   `$TMPDIR/claude-learner-<sid>.session` log. The coach does not review Claude's own output:
   what Claude writes goes to the `learner` quiz, what the dev writes goes to the coach. This
   split is the whole point of the mode, and it comes for free from a file that already exists.
4. **Minus binaries**, detected with `grep -Iq . <file>` — the trigger metric is a line count,
   and a line count over a PNG is noise.

### 2.2 The trigger metric — lines changed *since the last review*

Measuring against `HEAD` would recount the same lines every cycle: a file the dev revisits in
three consecutive blocks would look like three times the work. So the watcher keeps a content
baseline per candidate file:

```
$TMPDIR/claude-learner-<sid>.coach-base/
  .head                 # HEAD sha when the baseline was taken
  .manifest             # "<key> <repo-relative path>" per line
  <key>                 # a copy of that file's content at baseline time
```

`<key>` is `git hash-object --stdin` of the repo-relative path — 40 hex characters, so any path
becomes a safe filename. Per file:

- baseline exists → `diff -u <base> <cur> | grep -c '^[+-][^+-]'`
- no baseline (new file) → its current line count
- baseline exists, file gone → the baseline's line count

Advancing the baseline means: copy every current candidate's content over its key, drop
manifest entries that are no longer candidates, rewrite `.head`. It happens **at emission
time**, immediately after the line is printed — not after the review finishes. A review that
Claude never runs must not re-fire the same material 45 seconds later.

`.head` and the content copies live in `TMPDIR` and are removed by `learner-cleanup.sh` at
`SessionEnd` (§6).

Clean separation, stated once because it governs the whole design: **the baseline decides
*when* to speak; the `HEAD` diff decides *what* the review says.** The watcher never chooses
the content of a review.

### 2.3 Pomodoro cadence (default)

```
cycle = 1
empty = 0
loop:
  work = min(coachWorkMinutes + coachWorkGrowthMinutes * (cycle - 1), coachWorkMaxMinutes)
  sleep work minutes
  material = candidate files (§2.1) with a non-zero line delta (§2.2)
  if material is empty:
      empty = empty + 1
      if empty >= coachIdleCycles:  emit the idle line; exit 0
      continue                      # cycle does NOT advance
  empty = 0
  emit the coach line
  advance the baseline
  sleep coachChallengeMinutes
  cycle = cycle + 1
```

An empty block does not advance `cycle`: the work block grows as a reward for actually writing
code, not for leaving the editor open. The challenge window is only slept through when a
challenge was actually issued.

Note that the pomodoro cadence needs **no polling at all** — it sleeps the block and measures
once at the end. `coachPollSeconds` exists only for the threshold cadence.

The emitted line:

```
🧑‍🏫 Coach (level: S, cycle: 3, files: 2, lines: 62) — Service.kt Mapper.kt
Invoke the `learner` skill, follow references/coach.md. One challenge, then wait for the dev's answer.
```

Same shape and same contract as the existing quiz trigger: parameters and a pointer to the
protocol, never the protocol itself. File list capped at 20 paths.

The idle line, emitted once, immediately before exiting:

```
🧑‍🏫 Coach — no tracked changes for 2 work blocks; the watcher has stopped.
Ask the dev whether they want to continue the coaching session. If they do, re-arm the watcher.
```

### 2.4 Threshold cadence (`coachCadence: "threshold"`)

Same candidate set and same metric, different clock: poll every `coachPollSeconds`, and emit
when **any** of `coachLines` (lines since last review), `coachFiles` (files with a non-zero
delta) or `coachEveryMinutes` (elapsed since last review, `0` = off) is reached, gated by
`coachCooldownMinutes` so two reviews can never land back to back. `coachIdleCycles` is read as
idle *periods* of one work-block-equivalent (`coachWorkMinutes`) in this cadence.

## 3. The gate — `hooks/coach-gate.sh` (`PreToolUse` on `Write|Edit|NotebookEdit`)

No-op (exit 0, no output) unless `jq` is present, learner is active here, **and** `coach` is
true. A dev who never turns coach on never notices this hook exists.

Given `tool_input.file_path`, the write is **allowed** when any of:

- the path is outside the repo root — Claude's own config, the scratchpad, another project.
  Coach mode is about the code the dev is learning to write, in this repo. Resolved the same
  way `learner-record-edit.sh` already resolves it, so a repo reached through a symlink is not
  mistaken for "outside".
- the repo-relative path matches a line in `$TMPDIR/claude-learner-<sid>.coach-scope` — the
  delegated slice.
- `learner_excluded` says the path is floor or `untrackGlobs` material — docs, JSON, lock
  files. Those are not the learning target, and blocking Claude from writing a README would be
  friction with no pedagogical payoff.

Otherwise it **denies**, with a reason that redirects rather than just refusing:

```
🧑‍🏫 Coach mode — src/main/kotlin/Service.kt is not delegated to you.
Describe the approach and name the file and the lead; do not write it. If this slice really is
yours, the dev can delegate it: learner coach delegate 'src/**/repository/**'
```

Scope globs are matched with `case`, in which `*` crosses `/`. So `src/**/repository/**` and
`src/*/repository/*` behave identically — documented rather than worked around, since the
permissive reading is the one a dev writing that glob intends.

**Deny payload — verified against the hooks reference**, not assumed. A gate that silently
fails open is worse than no gate, because the dev would believe they were protected.

```json
{"hookSpecificOutput": {"hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": "…"}}
```

Confirmed with it: exit `0` alongside that JSON; `permissionDecision` is one of
`allow`/`deny`/`ask`/`defer`; exit 0 with no stdout is the correct "allow, unchanged" no-op;
`Write`, `Edit` **and** `NotebookEdit` all carry the path as `.tool_input.file_path`; and a
matcher made only of names and `|` is matched exactly, so `Write|Edit|NotebookEdit` hits those
three and `Edit` alone would *not* also match `NotebookEdit`.

## 4. The review protocol — `skills/learner/references/coach.md`

A new reference, read on a coach trigger the way `references/hook-quiz.md` is read on a quiz
trigger. It reads `references/data.md` once for the data-file rules rather than restating them.

On a trigger:

1. Read `memory.md`. Open weak spots bias where to look in the diff — the same spaced-repetition
   pull the quiz already has.
2. `git diff HEAD -- <the named files>`, and read the files where the diff is not enough.
3. Produce, calibrated on the level (§4.1):
   - **exactly one challenge** — a socratic question about a real decision visible in the diff,
     then stop and wait for the dev's answer.
   - **zero to three findings** — bug, edge case, duplication, each anchored `file:line`. No fix
     is applied and none is written out.
   - **zero to two leads** — a direction, never code.
4. Never write to a source file. Never offer to apply a finding. If the dev asks for the patch,
   that is a delegation request: point them at `learner coach delegate`.
5. When the dev answers, update `memory.md` and `recap.md` exactly as § After every answer of
   `data.md` prescribes — same `✅ ok` / `⚠️ revisit` / `⏭️ skip` verdicts, `Style` column set to
   `coach`. One learner record across both regimes (decision #1).

Volume ceiling, deliberately: one challenge and a short findings list. A wall of text would put
the dev back in the passenger seat by other means.

### 4.1 Level drives depth *and* register

| Level | What the challenge attacks | Register |
|-------|---------------------------|----------|
| `D` | What this block is for, what this construct is called | Name and explain each technical term before using it |
| `J` | What the function does, where the code lives | Everyday vocabulary, a concrete example over an abstraction |
| `C` | Why this split, edge cases, error handling | Standard jargon assumed, the basics are not re-explained |
| `S` | Trade-offs, rejected alternatives, perf and coupling | Dense, allusive, no unrequested explanation |
| `E` | Invariants, failure modes, what breaks at scale | Context assumed, a discussion between equals |

The register column applies to **findings and leads too**, not only to questions. At `J`: "this
crashes when the list is empty, line 42". At `S`: "the empty path is uncovered and it propagates
into the mapper". Same defect, two registers. Calibrating the question while leaving the
feedback at a fixed register is the failure mode this table exists to prevent.

## 5. Config — new keys

Appended to the table in § Config of `SKILL.md`, and to `learner.json.example`.

| Key | Values | Default | Effect |
|-----|--------|---------|--------|
| `coach` | bool | `false` | Coach regime: the dev writes, Claude challenges |
| `coachCadence` | `pomodoro`/`threshold` | `pomodoro` | Which clock drives reviews |
| `coachWorkMinutes` | int ≥ 1 | `25` | First work block |
| `coachWorkGrowthMinutes` | int ≥ 0 | `5` | Added to the work block per completed cycle |
| `coachWorkMaxMinutes` | int ≥ 1 | `45` | Work-block ceiling |
| `coachChallengeMinutes` | int ≥ 0 | `8` | Challenge window, fixed |
| `coachIdleCycles` | int ≥ 1 | `2` | Empty work blocks before the watcher stops |
| `coachPollSeconds` | int ≥ 5 | `45` | Poll interval — `threshold` cadence only |
| `coachLines` | int ≥ 1 | `40` | Lines since last review that trigger one — `threshold` only |
| `coachFiles` | int ≥ 1 | `3` | Changed files that trigger one — `threshold` only |
| `coachEveryMinutes` | int ≥ 0 | `0` | Elapsed-time trigger, `0` = off — `threshold` only |
| `coachCooldownMinutes` | int ≥ 0 | `5` | Floor between two reviews — `threshold` only |

Only `coach` needs setting; every other key has a default that implements decisions #3–#8.
`coachWorkMaxMinutes` below `coachWorkMinutes` clamps to `coachWorkMinutes` rather than being
rejected — the intent of that pair is unambiguous.

Validation follows the existing rule in § Config: reject an invalid value and re-ask rather
than writing it. `coach` boolean, `coachCadence` one of the two words, the rest integers at or
above their stated floor.

## 6. Arming, and what has to change elsewhere

**`hooks/learner-onboard.sh`** (already a `SessionStart` hook) gains one branch: when learner
is active and `coach` is true, and the payload's `source` is `startup` or `resume`, its
`additionalContext` tells Claude to arm the watcher —
`Monitor` with `command: sh <hooks-dir>/coach-watch.sh <session-id>`, `persistent: true`,
description `coach: the dev's changes`. The hook knows its own directory via `$(dirname "$0")`,
which is how every other hook in this repo already resolves its neighbours, so this works
identically for a plugin install and a traditional one. The dev types nothing at session start
(decision #6).

The `source` check is not decoration. `SessionStart` also fires on `clear`, `compact` and
`fork`; arming on a mid-session context compaction would start a **second** watcher against the
same session id, and the dev would receive every review twice on two drifting cadences.

**`hooks/learner-cleanup.sh`** also removes `claude-learner-<sid>.coach-scope` and the
`claude-learner-<sid>.coach-base/` directory.

**`hooks/learner-record-edit.sh`** switches its inline floor and `untrackGlobs` loop for the
shared `learner_excluded` helper (decision #12). Behaviour-preserving; the existing tests for
those exclusions must still pass unchanged, which is how we know it is.

**`hooks/hooks.json`** and **`hooks/settings.snippet.json`** both wire `coach-gate.sh` as a
`PreToolUse` hook with matcher `Write|Edit|NotebookEdit` — the plugin path and the
curl/clone/brew/apt path are two consumers of the same scripts and neither may be forgotten.
`coach-watch.sh` is wired in **neither**: it is not a hook.

## 7. Interaction with the existing quiz

Nothing about the quiz side changes, and the two regimes compose rather than collide:

- Coach on, Claude writes inside a delegated glob → `learner-record-edit.sh` logs it → the
  `Stop` hook quizzes the dev on it, as today. Claude quizzes what Claude wrote; coach
  challenges what the dev wrote. Same `memory.md`, same `recap.md`.
- Coach never writes to a source file, so the `// LEARNER-TODO` guardrail and the `fill`
  exercise flow need no hardening.
- Coach off is the current product, byte for byte.

## Known limitations

1. **No hook sees the dev's editor saves.** Every alternative to polling was ruled out by this,
   not chosen against. It is the reason coach depends on `Monitor`.
2. **Coach is interactive-session-only.** `Monitor` does not exist in `claude -p`, in a
   subagent, or in a cloud session, so the watcher cannot be armed there. The *gate* still
   works in all of them — it is an ordinary hook — so a non-interactive session with `coach`
   true gets the write refusal without the reviews. Documented rather than papered over.
3. **A file both Claude and the dev touched in one session is attributed to Claude** and skipped
   by the coach (§2.1 step 3). Per-hunk authorship is not available to a shell script; the
   conservative direction is the right one, since reviewing Claude's own code as if it were the
   dev's would produce a challenge the dev cannot answer.
4. **`*` crosses `/` in scope globs** (§3), because `case` is the matcher.
5. **Binary files never contribute to the trigger metric** (§2.1 step 4).
6. **A `Monitor` that floods is stopped automatically by the harness.** At one event per ~33
   minutes the pomodoro cadence cannot flood; an aggressively configured `threshold` cadence
   could, which is what `coachCooldownMinutes` is for.
7. **The watcher does not survive the session.** `SessionEnd` is the end of the cadence; the
   next session re-arms at cycle 1. Growing work blocks reset with it.

## Files touched

| Path | Change |
|------|--------|
| `hooks/coach-watch.sh` | new — the watcher (§2) |
| `hooks/coach-gate.sh` | new — the `PreToolUse` gate (§3) |
| `hooks/learner-config.sh` | new shared `learner_excluded` helper; coach config defaults |
| `hooks/learner-onboard.sh` | arm the watcher when `coach` is true (§6) |
| `hooks/learner-cleanup.sh` | remove the coach scratch files (§6) |
| `hooks/learner-record-edit.sh` | use `learner_excluded` instead of its inline copy (§6) |
| `hooks/hooks.json` | wire `coach-gate.sh` as `PreToolUse` |
| `hooks/settings.snippet.json` | same wiring for the non-plugin install path |
| `skills/learner/SKILL.md` | coach subcommands, coach config keys, register column |
| `skills/learner/references/coach.md` | new — the review protocol (§4) |
| `learner.json.example` | the new keys with their defaults |
| `test.sh` | the tests below |
| `README.md`, `docs/usage.html`, `docs/config.html` | a coach section on each |

## Tests

Added to `test.sh`, in its existing plain-`sh` style against the isolated `WORK` repo — no
framework, no network.

**Gate (`coach-gate.sh`)**

- `coach` false → no output, exit 0, whatever the path.
- learner inactive (no level / `enabled: false` / `disabledPaths`) → no output even with `coach` true.
- coach on, no scope file → a repo source path is denied.
- coach on, scope `src/**/repository/**` → a matching path allowed, a sibling service path denied.
- a path outside the repo root → allowed.
- an `untrackGlobs` path (`*.md`) → allowed.
- the deny payload is valid JSON and carries the documented deny field.

**Watcher (`coach-watch.sh`)** — driven with tiny block values so a test runs in seconds, and
with a `--once` flag that runs a single cycle and returns instead of looping.

- no baseline, one new untracked file of 10 lines → emits, `lines: 10`.
- baseline taken, file unchanged → empty cycle, no output.
- baseline taken, 3 lines appended → emits `lines: 3`, not the file's full length. *(This is the
  test that would catch a regression to measuring against `HEAD`.)*
- a file the dev changed **and committed** since the baseline still counts (§2.1 step 1, third term).
- a path present in `<sid>.session` is excluded even when changed.
- a `node_modules` path and an `untrackGlobs` path are excluded.
- a binary file is excluded.
- `coachIdleCycles` consecutive empty cycles → the idle line is emitted exactly once and the
  script exits 0.
- work-block growth: cycle 1 = 25, cycle 2 = 30, capped at `coachWorkMaxMinutes`; an empty cycle
  does not advance it.
- `coachWorkMaxMinutes` below `coachWorkMinutes` clamps rather than erroring.

**Config**

- each new key merges through defaults → global → project, like the existing keys.
- an invalid `coachCadence` and a zero `coachWorkMinutes` are rejected.

**Regression**

- the existing exclusion tests pass unchanged after `learner-record-edit.sh` moves to
  `learner_excluded` (§6).

## Out of scope

- Enforcing the cadence in non-interactive sessions (limitation #2). No mechanism exists.
- Watching more than one repo from a single session.
- Reviewing edits the dev makes outside the repo root.
- Per-hunk authorship attribution (limitation #3).
- Any change to `quiz`, `improve`, `export` or `update` beyond the `Style: coach` value.
- A visual or TUI pomodoro timer. The notification is the timer.

## Traceability

| Decision | Section |
|----------|---------|
| #1 subcommand of `learner` | §1, §4 step 5, §7 |
| #2 polling via `Monitor` | §2, §6, limitations #1–#2 |
| #3 pomodoro default | §2.3, §2.4, §5 |
| #4 growing work block, fixed challenge | §2.3, §5 |
| #5 one notification per cycle | §2.3 |
| #6 starts on arming | §6 |
| #7 deny, not warn | §3 |
| #8 two empty blocks, then exit | §2.3, §5 |
| #9 level drives depth and register | §4.1 |
| #10 English triggers, mirrored replies | §2.3 |
| #11 session-scoped delegation | §1, §3, §6 |
| #12 one shared exclusion helper | §2.1, §6, tests |
