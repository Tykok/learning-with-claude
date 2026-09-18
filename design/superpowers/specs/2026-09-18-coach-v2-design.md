# Coach v2 — one cadence, several learning channels

Supersedes the cadence and protocol halves of
`design/superpowers/specs/2026-09-07-coach-mode-design.md`. The gate
(`hooks/coach-gate.sh`) and the candidate/delta machinery of the watcher are unchanged and are
not restated here; read that spec first for them.

## Goal

Coach v1 shipped two cadences and a five-key pomodoro clock, and in real use produced **zero
reviews**. It also spoke in one register only: it interrogated. v2 does three things.

1. **One cadence, driven by the dev's own rhythm.** The pomodoro clock and the threshold clock
   both go. A review fires when the dev *pauses*, not when a timer expires.
2. **Several learning channels, not just the challenge.** A review may confirm a good decision,
   may teach a third-party library the dev is actually using, and always ends with the coach
   explaining rather than only asking.
3. **The review itself feeds the record.** A defect the coach spots now lands in `To improve`
   even when no question was asked about it. In v1 it evaporated with the screen.

Underneath all three: give the dev more ways in, and make them think.

## Why v1 produced nothing

Diagnosed on `main` at `442549e`, by probing `coach-watch.sh --once` in a throwaway repo (the
measurement machinery itself works: it emitted `files: 1, lines: 7` correctly).

1. **The pomodoro block sleeps 25 minutes before the first measurement.** A test session shorter
   than that gets nothing, and nothing says why.
2. **A file Claude wrote once is excluded for the whole session.** `coach_candidates` skips any
   path in `<sid>.session`, which `learner-record-edit.sh` appends to and never clears. Ask
   Claude one question about the file you are working on and it leaves your candidate set
   permanently. If that empties the set, the idle counter runs out and the watcher **exits for
   good**.
3. **Nothing verifies the watcher was armed.** `learner-onboard.sh` emits `additionalContext`
   asking Claude to call `Monitor`. If Claude does not, coach mode is silently dead.

All three are fixed here (§4).

## Locked decisions

| Decision | Chosen |
|---|---|
| Cadence | A single one: a pause in the dev's typing |
| Pomodoro | Removed, with its five keys and `learner_coach_work_minutes` |
| Threshold cadence | Removed as a *mode*; its poll/cooldown keys survive with new meanings |
| Question count | Scales with the size of the dev's changes: 1 / 2 / 3 |
| Library questions | Only when the diff actually uses a third-party method worth asking about. **No fallback question** when it does not |
| Detection of the library | Claude, reading the diff. The watcher is unchanged |
| Teaching ceiling | Free explanation + a generic snippet ≈ 6 lines. Never the dev's identifiers, never a pasteable patch of their file |
| Confirmations | Written into the record only through the `Mastered` promotion, not as `Session history` rows |
| Findings | Feed `To improve` in `recap.md`; they do **not** write to `memory.md` |
| `libs.md` | New file, carries the spaced repetition on libraries |
| "Sujets creusés" section | Cut |

---

## 1. Cadence — the pause in the typing

`coachCadence` disappears with both of its modes. `coach-watch.sh` keeps its candidate
selection, its per-file baseline and `coach_advance` exactly as they are, and replaces the
cadence layer.

### 1.1 The measurement

At each poll the watcher computes `coach_material()` as today, and derives three values from it:

- `L` — total delta, summed over files (`coach_delta`, added **and** removed lines).
- `N` — number of files with a non-zero delta.
- `FP` — a **fingerprint** of the candidate files' own content: each path from `coach_material`,
  `cat`-ed in order, through `cksum`. Empty material has no fingerprint.

The fingerprint, not `L`, is what detects activity. A dev who deletes three lines and writes
three others leaves `L` unchanged while very much still working; comparing totals would read
that as a pause.

Hashing the files' content rather than `coach_material`'s `<delta>\t<path>` summary is load
bearing, and the reason is easy to miss: **before a baseline exists for a file**,
`coach_delta`'s no-baseline branch returns the file's whole-file line *count*. An in-place edit
— same number of lines, different bytes — therefore leaves that summary byte-identical from one
poll to the next, and a summary-based fingerprint would call an actively typing dev paused. This
was caught by the cadence test that asserts an edit with an unchanged line total still counts as
activity.

### 1.2 The state machine

Per-session state, all under `${TMPDIR:-/tmp}`, all removed by `learner-cleanup.sh`:

| File | Holds |
|---|---|
| `claude-learner-<sid>.coach-fp` | the previous poll's fingerprint |
| `claude-learner-<sid>.coach-quiet` | consecutive polls with an unchanged fingerprint |
| `claude-learner-<sid>.coach-idle` | consecutive polls with zero material |
| `claude-learner-<sid>.coach-pending` | epoch seconds when the current pending material first appeared |
| `claude-learner-<sid>.coach-last` | epoch seconds of the last emission (already exists) |

`claude-learner-<sid>.coach-empty` is replaced by `.coach-idle` and must be dropped from
`learner-cleanup.sh`'s list along with the addition of the four new names.

One poll, in order:

```
M  = coach_material()
L  = sum of deltas        N = file count        FP = cksum of M
now = epoch seconds

# --- no material at all -------------------------------------------------
if L == 0:
    idle  += 1
    quiet  = 0
    clear .coach-pending and .coach-fp
    if idle * coachPollSeconds >= coachIdleMinutes * 60:
        emit the idle line; remove .coach-idle; return 1      # stop
    return 2                                                  # keep going

# --- material present ---------------------------------------------------
idle = 0
if .coach-pending is unset:  .coach-pending = now

if FP != previous FP:
    quiet = 0 ;  previous FP = FP        # the dev is typing
else:
    quiet += 1                           # the dev has stopped

elapsed = (now - .coach-last) / 60       # minutes since the last review
waited  = (now - .coach-pending) / 60    # minutes this material has been pending
if .coach-last is 0:  elapsed = coachCooldownMinutes + coachMaxWaitMinutes + 1

fire = 0
if L >= coachMinLines and quiet >= coachQuietPolls:      fire = 1   # the pause
if coachMaxWaitMinutes > 0 and L >= coachMinLines
   and waited >= coachMaxWaitMinutes:                    fire = 1   # the guard
if elapsed < coachCooldownMinutes:                       fire = 0   # the floor

if fire == 0:  return 2

emit the trigger line
coach_candidates | coach_advance
.coach-last = now ;  quiet = 0 ;  clear .coach-pending
CYCLE += 1
return 0
```

Four properties this ordering buys, each of which a naive rewrite loses:

- **The cooldown never resets `quiet`.** A pause that arrives inside the cooldown window fires at
  the first poll after it expires, instead of requiring the dev to pause a second time.
- **Material below `coachMinLines` is not idle.** The dev is writing; they are simply below the
  floor. `idle` stays at 0 and the watcher does not cut itself off under someone who is working.
- **The guard also respects the floor.** `coachMaxWaitMinutes` exists for the dev in continuous
  flow, not to force a review of four lines.
- **`quiet` is only reset by an emission or by real activity**, never by a blocked fire.

The three-way return contract (`0` emitted / `1` stop / `2` keep going) and the `--once`,
`--print-material`, `--advance`, `--cycle` flags are unchanged. All state lives in files, so the
tests can still drive several cycles as separate `--once` processes.

### 1.3 The loop

```sh
while :; do
  CFG=$(learner_config)                       # unchanged: picks up `coach off` mid-session
  learner_coach_active "$CFG" "$ROOT" || exit 0
  coach_load_cadence
  sleep "$POLL"
  coach_cycle
  case $? in 1) exit 0 ;; *) ;; esac
done
```

The post-emission `sleep $((CHALLENGE * 60))` goes: the cooldown is now the only floor between
two reviews. `CYCLE` is incremented inside `coach_cycle` (it was incremented by the loop) and
still appears in the trigger line as the session's review counter — it no longer drives
anything.

### 1.4 The trigger line

Unchanged in shape; only the idle line's wording changes.

```
🧑‍🏫 Coach (level: C, cycle: 3, files: 2, lines: 62) — Service.kt Mapper.kt
Invoke the `learner` skill and follow references/coach.md. One challenge, then wait for the dev's answer.
```

```
🧑‍🏫 Coach — no tracked changes for 45 minutes; the watcher has stopped.
Ask the dev whether they want to continue the coaching session. If they do, re-arm the watcher.
```

`files` and `lines` are what the protocol's ladder (§2.1) reads, so they must keep their current
meaning: `lines` is the delta since the last review, not the size of the branch diff.

### 1.5 Config

Six keys, from ten.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `coachPollSeconds` | int ≥ 5 | `30` | Measurement interval |
| `coachQuietPolls` | int ≥ 1 | `1` | Consecutive unchanged polls before a review fires |
| `coachMinLines` | int ≥ 1 | `10` | Floor: fewer changed lines than this never triggers a review |
| `coachCooldownMinutes` | int ≥ 0 | `3` | Floor between two reviews |
| `coachMaxWaitMinutes` | int ≥ 0 | `15` | Emit even without a pause once material has waited this long; `0` disables |
| `coachIdleMinutes` | int ≥ 1 | `45` | Zero material for this long → the watcher stops |

`coach` (bool, `false`) is untouched.

**Removed:** `coachCadence`, `coachWorkMinutes`, `coachWorkGrowthMinutes`, `coachWorkMaxMinutes`,
`coachChallengeMinutes`, `coachIdleCycles`, `coachLines`, `coachFiles`, `coachEveryMinutes`.
`learner_coach_work_minutes` is deleted from `learner-config.sh`, with its tests.

**Migration.** A config still carrying a removed key does not fail: `learner_config` merges
defaults with the user's layers and unknown keys simply pass through unread. The `learner` skill's
config validation gains one rule — on a `learner config` invocation, name the obsolete keys once
and say they are ignored. Do not rewrite the user's file for them.

---

## 2. The review protocol

`skills/coach/references/coach.md`, § *On a trigger*, is rewritten. § *Resolving `<session-id>`*,
§ *The regime*, § *`learner coach delegate`*, § *`learner coach review`* and the level register
table are unchanged.

### 2.1 The ladder — how much a review contains

Read `files` and `lines` from the trigger line.

| Size | `lines` | `files` | Questions | Findings |
|---|---|---|---|---|
| Small | < 40 | 1 | **1** — the challenge | 0-2 |
| Medium | 40-120 | 2-3 | up to **2** — challenge + library *if there is material* | 0-3 |
| Large | > 120 | ≥ 4 | up to **3** — challenge + library + one on the split/structure | 0-3 |

**The two criteria are read independently and the higher tier wins.** 300 lines in one file is
large, not small; six files of five lines each is large too. Reading `files` alone would let a
single-file rewrite be treated as a trivial diff — the most common shape of real work.

A ceiling, never a quota. Two questions are allowed on a medium diff; one is right when the diff
offers nothing worth a second.

**Asking order.** One or two questions are asked together, in the same message. **Three are asked
one at a time**: state that there are three, ask the first, wait for the answer, then the next.
Three questions in one message is an interrogation, and it is how a dev learns to answer the
first well and the other two badly.

### 2.2 The blocks

In this order.

| Block | Count | Rule |
|---|---|---|
| **Confirmation** | 0-1 | One line. A genuinely good decision *visible in the diff*, named precisely — a split, a name, a guard clause. Nothing true to say → say nothing. An empty compliment devalues every block after it. |
| **Challenge** | 1, always | A question about a real decision in the diff. The socle of the review; unchanged from v1. |
| **Library question** | 0-1 | Only when the diff puts a third-party method in play that is worth asking about: cost parameters, a known pitfall, a non-obvious contract, a default that bites. A trivial use, or no library at all → **no question, and no fallback**. |
| **Structure question** | 0-1, large diffs only | The split across the files in the trigger: what belongs where, what leaked. |
| **Findings** | 0-3 | Anchored `path/file.kt:42`. State the defect, not the fix. Unchanged. |
| **Leads** | 0-2 | Broadened: also the **next steps of the feature under way** — what remains to handle, not how to write it. |

Then **stop and wait**.

### 2.3 Finding the library

Claude's job, from the diff — the watcher is not involved and needs no per-language regex. Look
for, in order of strength: a dependency added to a manifest (`package.json`, `go.mod`,
`Cargo.toml`, `build.gradle`, `pyproject.toml`, `composer.json`); an import added in a changed
file; a third-party call newly used in the diff even though its import already existed. That last
case is the reason this is not a shell grep.

Read `libs.md` (§3.3) **before** choosing: prefer a library with no row, and when every candidate
already has one, pick an angle that is not in the `angle covered` column.

### 2.4 Teaching, after the answer

New, and the point of v2: whatever the dev answers, the coach then **explains**. The concept, the
pitfall, the parameters that matter, what the default does. This is not an evaluation — the dev
is meant to leave knowing something they did not know.

The ceiling:

- **Allowed** — free prose, and a **short generic snippet** (≈ 6 lines) illustrating the API in
  the abstract.
- **Forbidden** — a snippet using the dev's own class, function or file names; any block long
  enough to paste back into the file under review. On *their* code the rule is unchanged: the
  defect and its location, never the correction.

`coach-gate.sh` enforces the write; this paragraph enforces the rest.

### 2.5 Level

The register table (D/J/C/S/E) is unchanged and applies to **all** blocks — confirmation, both
questions, findings, leads and the teaching paragraph alike. Calibrating the question while
leaving everything else at a fixed register is the failure the table exists to prevent.

---

## 3. The record

Paths as in `skills/learner/references/data.md`: `$CFG/learner/`, with
`CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`.

### 3.1 Findings feed `To improve`

The substantive change. In v1 only the dev's *answers* wrote anything; a defect the coach found
but did not question vanished with the screen.

Each finding is rolled into an existing broad theme of `recap.md` § `To improve`, under its
domain — "a missing exception at a critical point" belongs under `Code › Error and exception
handling`, it does not become a line of its own. Create a theme only when no existing one fits.
The section stays a handful of themes per domain; it must not grow one entry per review.

### 3.2 `memory.md` does not move for a finding

`memory.md` is the **only** file read to pick a question. A weak spot is added there exactly as
today: when the dev answers wrong or hesitates. A finding they were never questioned on must not
land in it — it would make the coach and the quiz ask about something the dev has never been
given a chance on.

### 3.3 `libs.md` — new

`$CFG/learner/libs.md`, created on first use:

```markdown
# Libraries covered

| Library | Seen | Angle covered | Verdict |
|---------|------|---------------|---------|
| argon2 | 2026-09-18 | cost parameters (t, m) | ⚠️ revisit |
| zod | 2026-09-18 | refine vs superRefine | ✅ ok |
```

One row per (library, angle) pair, not per library: revisiting `argon2` three weeks later from
the salt-storage angle adds a row, it does not overwrite one. Read before choosing a library
question (§2.3), written after the answer.

### 3.4 `Session history` and confirmations

`recap.md` § `Session history` gains one `Style` value, `coach-lib`, next to the existing `coach`.
Verdicts are unchanged: `✅ ok`, `⚠️ revisit`, `⏭️ skip`.

A confirmation writes a row too, with the `Style` value `coach-ack` and the verdict `✅ ok`; its
`Note` names the reflex ("business logic kept out of the controller"). The same reflex confirmed
**twice, on two different diffs** — two `coach-ack` rows carrying the same theme — promotes that
theme into `recap.md` § `Mastered`.

*Deviation from the brainstorm, flagged.* The agreed answer there was "a confirmation writes
nothing", because the count was going to live in a `Compréhension du code` map that was then cut
from the design. With the map gone there is nowhere else to count from, and an uncountable
"twice" rule is not implementable. A row costs one line and no new verdict symbol. The
alternative is to drop the `Mastered` promotion and leave confirmations purely spoken — say so
and §3.4 shrinks to nothing.

### 3.5 Carrying `libs.md`

`skills/sync/references/sync.md` enumerates the record's files: `libs.md` joins `memory.md`,
`recap.md` and the global `learner.json` in what push and pull carry, and `docs/safety.html`'s
consent list names it.

`export` is **not** touched: it builds Notion rows from `recap.md`'s themes only, and a library
ledger is not a theme. Exporting it would be a second, unrelated data model in the same
database.

---

## 4. The three v1 defects

### 4.1 A file Claude touched is excluded for one window, not forever

`learner-record-edit.sh` appends one absolute physical path per line to
`claude-learner-<sid>.session` and never clears it (the quiz's synthesis question reads the whole
file, so it must stay append-only and complete). `coach_candidates` currently skips any path
present anywhere in it.

Fix: skip only what Claude wrote **since the last baseline advance**.

- `coach_advance` records the current length of `.session` into `<basedir>/.sessionmark`
  (`grep -c '' "$SESSION"`, `0` when the file is absent). It lives in the baseline directory
  rather than in a `TMPDIR` file of its own so that it advances with the baseline it belongs to,
  and so that `learner-cleanup.sh`'s existing `rm -rf` of that directory already removes it.
- `coach_candidates` reads the mark and tests membership against the **tail** only:
  `tail -n +$((MARK + 1)) "$SESSION"`, then `grep -qxF`.

The file is append-only, so a line count is a valid cursor. A file Claude writes again in a later
window is excluded again for that window — which is correct, and which the old behaviour got
right only by accident of never expiring.

### 4.2 The watcher's arming is verified

- `coach-watch.sh` creates `claude-learner-<sid>.coach-armed` once, immediately after
  `learner_coach_active` passes and before entering the loop. Not in `--once` /
  `--print-material` / `--advance` mode.
- New hook `hooks/coach-armed-check.sh`, wired on `UserPromptSubmit` beside `pilot-nudge.sh`
  (and in `settings.snippet.json` for the non-plugin install). It exits 0 silently unless: the
  coach regime is active, `.coach-armed` is absent, and a one-shot marker
  `claude-learner-<sid>.coach-armwarn` is absent. In that case it writes the marker and emits one
  line of `additionalContext`:

  > 🧑‍🏫 Coach mode is on but the change watcher is not armed. Arm it with the `Monitor` tool:
  > `sh "<hooks-dir>/coach-watch.sh" "<sid>"` — or tell the dev, in one line, that coach mode is
  > inert in this session.

  The marker makes it fire at most once per session. The escape clause covers the sessions where
  `Monitor` does not exist at all (`claude -p`, subagents, cloud) — v1 limitation #2 stands, but
  it stops being silent.
- `learner-cleanup.sh` removes both new files.

### 4.3 Idle is redefined

v1 counted empty *cycles*, which the removal of the work block leaves meaningless, and which the
new cadence inverts: an unchanged poll is now the *trigger condition*, not evidence of
abandonment. Idle is now "zero material for `coachIdleMinutes`" (§1.2), which only a dev who has
genuinely stopped touching the repo can reach.

---

## 5. Files touched

| Path | Change |
|---|---|
| `plugins/learner/hooks/coach-watch.sh` | the cadence layer rewritten (§1), the `.session` window fix (§4.1), the armed marker (§4.2) |
| `plugins/learner/hooks/coach-armed-check.sh` | new (§4.2) |
| `plugins/learner/hooks/learner-config.sh` | the six keys in `LEARNER_DEFAULTS`, `learner_coach_work_minutes` deleted |
| `plugins/learner/hooks/learner-cleanup.sh` | the new scratch files in, `.coach-empty` out |
| `plugins/learner/hooks/hooks.json` | `coach-armed-check.sh` on `UserPromptSubmit` |
| `plugins/learner/hooks/settings.snippet.json` | same wiring |
| `plugins/learner/skills/coach/references/coach.md` | § *On a trigger* rewritten: the ladder, the blocks, the library, the teaching ceiling (§2) |
| `plugins/learner/skills/learner/SKILL.md` | the config table, the removed keys, the coach trigger paragraph |
| `plugins/learner/skills/learner/references/data.md` | `libs.md`, the findings rule, the `coach-lib` style, the confirmation rule (§3) |
| `plugins/learner/skills/sync/references/sync.md` | `libs.md` in the carried set |
| `plugins/learner/skills/status/SKILL.md` | the coach status line loses the cadence wording and reports whether the watcher is armed, read from `.coach-armed` |
| `learner.json.example` | the six keys |
| `README.md`, `docs/usage.html`, `docs/config.html`, `docs/safety.html` | the coach section, the key table, the consent list |
| `test.sh` | §6 |

`design/superpowers/specs/2026-09-07-coach-mode-design.md` is left in place and gains a one-line
header pointing here.

## 6. Tests

Added to `test.sh`, in its existing plain-`sh` style against the isolated `WORK` repo. **The
suite runs under `bash`, not `sh`** — line 3533 uses a process substitution. Baseline at
`442549e`: 941 passing, 0 failing.

**Cadence (`coach-watch.sh`, driven with `--once` across successive processes)**

- material present, fingerprint changed → no emission, `quiet` reset to 0.
- material present, fingerprint unchanged, `quiet` reaches `coachQuietPolls` → emits.
- the same, but `L` below `coachMinLines` → no emission, and `idle` stays 0 (the regression that
  would cut a dev off mid-work).
- deleting three lines and adding three others between two polls → the fingerprint changes even
  though `L` is equal → counted as activity, not as a pause.
- a fire blocked by `coachCooldownMinutes` → no emission, and `quiet` is **not** reset, so the
  next poll after the cooldown emits.
- `coachMaxWaitMinutes` reached with the fingerprint still changing every poll → emits anyway.
- `coachMaxWaitMinutes: 0` → no guard, the pause is the only path.
- zero material for `coachIdleMinutes` worth of polls → the idle line once, exit 0.
- material reappearing before the idle limit resets the idle counter.
- an emission advances the baseline, so the next cycle measures from it (the v1 test, kept).

**`.session` window (§4.1)**

- Claude writes `A.kt`, a review fires, then the dev changes `A.kt` → `A.kt` **is** material in
  the next cycle. *(The v1 bug. This test is the reason for the whole section.)*
- Claude writes `A.kt` and no review has fired since → `A.kt` is still excluded.
- `.session` absent → mark 0, nothing excluded.

**Arming (§4.2)**

- `coach-armed-check.sh` with the coach off → no output, exit 0.
- coach on, no `.coach-armed` → one `additionalContext` line, valid JSON, and the warn marker is
  written.
- called twice → the second is silent.
- `.coach-armed` present → silent.
- `coach-watch.sh --once` does **not** create `.coach-armed`.

**Config**

- the six keys merge through defaults → global → project.
- a config still carrying `coachCadence` / `coachWorkMinutes` does not fail and the removed keys
  have no effect.
- `coachMaxWaitMinutes: 0` and `coachCooldownMinutes: 0` are accepted; `coachQuietPolls: 0`,
  `coachMinLines: 0` and a `coachPollSeconds` below its floor fall back to their **defaults**
  (1, 10 and 30), which is what `learner_int RAW FALLBACK FLOOR` does with an out-of-range value
  — it returns FALLBACK, not FLOOR.
- `learner_coach_work_minutes` is gone (its tests deleted, not skipped).

**Docs**

- the key table in `README.md`, `docs/config.html` and `SKILL.md` names exactly the six keys and
  none of the removed ones (the repo already tests doc/consent coverage this way).
- `docs/safety.html`'s consent list names `libs.md`.

## 7. Out of scope

- Per-hunk authorship. §4.1 narrows the window; it does not split a file between two authors.
- Arming the watcher in `claude -p`, subagents or cloud sessions. `Monitor` does not exist there;
  §4.2 only makes the silence audible.
- Watching more than one repo from one session.
- Any change to `quiz`, `improve` or `pilot` beyond the `coach-lib` style value and `libs.md`
  being carried.
- The `// LEARNER-TODO` false positive in `hooks/learner-quiz.sh` (its scan matches the marker
  inside markdown prose and backticks). Real, separate, tracked elsewhere.

## 8. Traceability

| Decision | Section |
|---|---|
| Pomodoro removed | §1, §1.5 |
| Pause-driven cadence | §1.2 |
| Question count follows the diff's size | §2.1 |
| Confirmations | §2.2, §3.4 |
| Library questions, only when there is material | §2.2, §2.3 |
| Library detected by Claude, not the shell | §2.3 |
| Teaching, with a generic-snippet ceiling | §2.4 |
| Findings become improvement areas | §3.1 |
| Everything traceable (`libs.md`) | §3.3 |
| The three v1 defects | §4 |
