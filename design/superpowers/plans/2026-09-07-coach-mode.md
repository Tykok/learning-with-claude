# Coach mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Invert the learner loop — the dev writes the code, and Claude becomes a periodic
challenger that watches the working tree, asks one socratic question per cycle, and is denied
write access outside the slice the dev explicitly delegated.

**Architecture:** Two new POSIX `sh` scripts beside the existing six. `hooks/coach-gate.sh` is a
`PreToolUse` hook that denies `Write`/`Edit`/`NotebookEdit` outside the delegated globs.
`hooks/coach-watch.sh` is **not** a hook — it is a long-running script armed once per session as
a persistent `Monitor`, whose stdout lines become conversation notifications. No Claude Code
hook fires when the dev saves a file in their editor, so polling the git working tree is the
only mechanism that can observe the dev's own edits. Both scripts source the existing
`hooks/learner-config.sh`, which grows the coach config keys and one shared exclusion helper
lifted out of `learner-record-edit.sh`.

**Tech Stack:** POSIX `sh` (no bash-isms — these scripts run under `sh` on macOS and Debian),
`jq` for all JSON, `git` for the working-tree diff and for `hash-object` as a path hasher,
`diff`/`grep`/`awk` for the line metric. Tests are plain `sh` assertions in the existing
`test.sh`, no framework, no network.

**Spec:** `design/superpowers/specs/2026-09-07-coach-mode-design.md`

## Global Constraints

- Spec: `design/superpowers/specs/2026-09-07-coach-mode-design.md` — every task implements one or more of its numbered sections. Its "Locked decisions" table is binding; do not re-litigate a decision during implementation.
- **POSIX `sh` only.** No `[[`, no arrays, no `local`, no `$'...'`, no process substitution, no `comm` on process substitutions. Prefix function-local variables with `_` and a function-specific tag, matching the existing style in `hooks/learner-config.sh`.
- Every new script starts with `#!/bin/sh` and `# SPDX-License-Identifier: GPL-3.0-or-later`, matching all six existing hooks.
- Every hook exits **0** on every path that is not a deliberate block. A learner hook must never fail a tool call or a session because `jq` is missing, the repo has no commits, or a config file is malformed.
- `coach` defaults to `false`. A dev who never turns coach on must observe **zero** behaviour change: no output, no extra work, no new prompts.
- The exclusion floor (`node_modules`, `*.lock`, `dist`, …) and `untrackGlobs` matching live in **exactly one** place after Task 1: `learner_excluded` in `hooks/learner-config.sh`. No second copy anywhere.
- The watcher's emitted lines are **English machine triggers**, matching the existing `🎓 Learner (level: …)` trigger. The skill renders them to the dev in the dev's own language (the skill's existing "mirror the dev" rule). There is no language setting and this plan does not add one.
- Levels are the five existing letters `D`/`J`/`C`/`S`/`E`, resolved with the existing `learner_level` helper. Coach adds no sixth level.
- Both `hooks/hooks.json` (plugin install) and `hooks/settings.snippet.json` (curl/clone/brew/apt install) must be updated together whenever hook wiring changes. Forgetting one ships a half-working feature to half the users.
- `coach-watch.sh` is wired in **neither** JSON file. It is not a hook.
- `test.sh` must stay fast (seconds) and offline. The watcher is always driven with `--once` in tests; no test ever sleeps a real work block.
- Run `./test.sh` before every commit. Run `shellcheck hooks/*.sh` if available (CI runs it — see `.github/workflows/ci.yml`).

---

### Task 1: One shared exclusion helper

Lift the built-in exclusion floor and the `untrackGlobs` loop out of
`hooks/learner-record-edit.sh` into `hooks/learner-config.sh` as `learner_excluded`, and make
`learner-record-edit.sh` call it. Behaviour-preserving: the existing exclusion tests must pass
untouched, which is how we know the lift was faithful. The coach watcher (Task 4) needs the
same list, and two copies would drift apart within a release.

**Files:**
- Modify: `hooks/learner-config.sh` — add `learner_excluded`, and document it in the header comment block
- Modify: `hooks/learner-record-edit.sh` — replace its inline floor + glob loop with one call
- Modify: `test.sh` — add direct tests for `learner_excluded`

**Interfaces:**
- Consumes: nothing new. `learner_config` already exists and returns merged config as one-line JSON.
- Produces: `learner_excluded PATH CFG` — returns **0 (true) when PATH should be skipped**, 1 when it is material. `PATH` is an absolute path. `CFG` is the merged config JSON string. Tasks 4 and 3 both call it.

- [ ] **Step 1: Write the failing tests**

Append to `test.sh`, immediately after the existing `--- config resolution ---` block:

```sh
# --- learner_excluded -------------------------------------------------------
echo '{"level":"C","untrackGlobs":["*.md","*.json"]}' > "$GCFG"
rm -f "$PCFG"
XCFG=$(cfgsh 'learner_config')

excl() { cfgsh "learner_excluded '$1' '$XCFG'"; }

excl "$WORK/proj/src/Main.kt"            && ko "plain source is material"            || ok "plain source is material"
excl "$WORK/proj/node_modules/x/i.js"    && ok "node_modules is excluded"             || ko "node_modules is excluded"
excl "$WORK/proj/build/gen/A.kt"         && ok "build/ is excluded"                   || ko "build/ is excluded"
excl "$WORK/proj/target/out.jar"         && ok "target/ is excluded"                  || ko "target/ is excluded"
excl "$WORK/proj/.git/COMMIT_EDITMSG"    && ok ".git/ is excluded"                    || ko ".git/ is excluded"
excl "$WORK/proj/pnpm-lock.yaml"         && ok "*-lock.* is excluded"                 || ko "*-lock.* is excluded"
excl "$WORK/proj/yarn.lock"              && ok "*.lock is excluded"                   || ko "*.lock is excluded"
excl "$WORK/proj/app.min.js"             && ok "*.min.* is excluded"                  || ko "*.min.* is excluded"
excl "$WORK/proj/api.generated.ts"       && ok "*.generated.* is excluded"            || ko "*.generated.* is excluded"
excl "$WORK/proj/README.md"              && ok "untrackGlobs *.md is excluded"        || ko "untrackGlobs *.md is excluded"
excl "$WORK/proj/pkg.json"               && ok "untrackGlobs *.json is excluded"      || ko "untrackGlobs *.json is excluded"

# An empty untrackGlobs must not accidentally exclude everything.
echo '{"level":"C"}' > "$GCFG"
XCFG=$(cfgsh 'learner_config')
excl "$WORK/proj/src/Main.kt" && ko "no globs: source still material" || ok "no globs: source still material"

# The helper must not leave `set -f` on in the caller's shell, or every later
# glob expansion in that shell silently stops working.
out=$(cfgsh "learner_excluded '$WORK/proj/src/Main.kt' '$XCFG'; case \"\$-\" in *f*) echo LEAKED ;; *) echo CLEAN ;; esac")
[ "$out" = "CLEAN" ] && ok "learner_excluded restores globbing" || ko "learner_excluded restores globbing"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -E 'FAIL|learner_excluded'`
Expected: every new assertion FAILs — `learner_excluded` is not defined yet, so `cfgsh` exits
non-zero, which the `&&`/`||` pairs read as "not excluded". The `is excluded` lines therefore
report FAIL and the two `is material` lines pass by accident. That accidental pass is fine; the
`is excluded` failures are the real signal.

- [ ] **Step 3: Add `learner_excluded` to `hooks/learner-config.sh`**

Add to the header comment block, after the `learner_synthesis_n WORD` line:

```sh
#   learner_excluded PATH CFG       true when PATH is never quiz/coach material
```

Then add the function itself, immediately after `learner_synthesis_n`:

```sh
# learner_excluded PATH CFG — true (0) when PATH must never become quiz or coach
# material. Two layers:
#
#   1. A built-in floor, deliberately NOT overridable through config: without it
#      every package-lock.json and generated file would become quiz material.
#   2. The user's `untrackGlobs` on top of that floor.
#
# PATH is absolute. Globs are whitespace-separated, so a glob containing a space
# is not supported (documented in README).
learner_excluded() {
  _lxp="$1"
  _lxcfg="$2"

  case "$_lxp" in
    */node_modules/*|*/build/*|*/dist/*|*/out/*|*/target/*|*/vendor/*) return 0 ;;
    */.git/*|*/.gradle/*|*/__pycache__/*|*/.venv/*|*/coverage/*|*/__snapshots__/*) return 0 ;;
  esac
  case "$_lxp" in
    *.lock|*-lock.*|*.min.*|*.generated.*|*.snap) return 0 ;;
  esac

  # `set -f` is a shell-wide option and this is a sourced function, so the
  # caller's globbing state has to be restored on every exit path — including
  # the match. A hook that silently disabled globbing for the rest of its own
  # run would be a very hard bug to find.
  case "$-" in *f*) _lxf=1 ;; *) _lxf=0 ;; esac
  _lxhit=1
  set -f
  # shellcheck disable=SC2046,SC2086  # intentional word splitting on the glob list
  for _lxo in $(printf '%s' "$_lxcfg" | jq -r '(.untrackGlobs // [])[]' 2>/dev/null); do
    [ -n "$_lxo" ] || continue
    # shellcheck disable=SC2254  # $_lxo is a glob pattern on purpose
    case "$_lxp" in $_lxo) _lxhit=0; break ;; esac
  done
  [ "$_lxf" = 1 ] || set +f
  return "$_lxhit"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh`
Expected: every new `learner_excluded` assertion reports `ok`, and the pre-existing test count
is unchanged (no regressions).

- [ ] **Step 5: Make `learner-record-edit.sh` use the helper**

In `hooks/learner-record-edit.sh`, delete the two `case "$FP" in` floor blocks and the whole
`GLOBS=` / `set -f` / `for g in $GLOBS` / `set +f` section — everything between the
`# Built-in floor` comment and the blank line before `# Pending edits since the last quiz`.
Replace all of it with:

```sh
# Exclusions live in learner-config.sh so the coach watcher applies the exact
# same list (see learner_excluded).
learner_excluded "$FP" "$CFG" && exit 0
```

- [ ] **Step 6: Run the full suite to verify the lift was faithful**

Run: `./test.sh`
Expected: PASS, with the **pre-existing** `record-edit` exclusion assertions still passing
unchanged. Those tests were written against the inline copy; their passing against the helper
is the proof the lift preserved behaviour. If any of them now fails, the helper diverges from
the code it replaced — fix the helper, do not touch the test.

- [ ] **Step 7: Run shellcheck**

Run: `shellcheck hooks/learner-config.sh hooks/learner-record-edit.sh`
Expected: clean, or only the warnings suppressed by the inline `# shellcheck disable` comments.
If `shellcheck` is not installed, skip — CI runs it.

- [ ] **Step 8: Commit**

```bash
git add hooks/learner-config.sh hooks/learner-record-edit.sh test.sh
git commit -m "refactor(hooks): move the exclusion floor into learner_excluded

The coach watcher needs the same node_modules/*.lock/dist floor and the same
untrackGlobs matching that learner-record-edit.sh applies. Two copies of that
list would drift within a release, so it moves into learner-config.sh beside
the other shared helpers.

Behaviour-preserving: the pre-existing record-edit exclusion tests pass
unchanged against the helper, which is what makes the lift verifiable rather
than merely plausible.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Coach config keys and cadence arithmetic

Add the twelve `coach*` keys to the config defaults, plus the two helpers that turn them into
decisions: is coach on here, and how long is work block N. Doing the arithmetic in
`learner-config.sh` rather than inside the watcher keeps it directly testable without running a
cadence loop.

**Files:**
- Modify: `hooks/learner-config.sh` — extend `LEARNER_DEFAULTS`, add `learner_coach_active` and `learner_coach_work_minutes`
- Modify: `learner.json.example` — the new keys with their defaults
- Modify: `test.sh` — merge-through-layers and arithmetic tests

**Interfaces:**
- Consumes: `learner_config`, `learner_active` (both existing, unchanged).
- Produces:
  - `learner_coach_active CFG ROOT` — returns 0 when `learner_active CFG ROOT` **and** `.coach == true`. Tasks 3, 4 and 6 all gate on this.
  - `learner_coach_work_minutes CYCLE CFG` — prints the work-block length in minutes for a 1-based cycle number. Task 5 calls it.

- [ ] **Step 1: Write the failing tests**

Append to `test.sh` after the `learner_excluded` block from Task 1:

```sh
# --- coach config -----------------------------------------------------------
echo '{"level":"C"}' > "$GCFG"
rm -f "$PCFG"
out=$(cfgsh 'learner_config')
{ [ "$(echo "$out" | jq -r .coach)" = "false" ] \
  && [ "$(echo "$out" | jq -r .coachCadence)" = "pomodoro" ] \
  && [ "$(echo "$out" | jq -r .coachWorkMinutes)" = "25" ] \
  && [ "$(echo "$out" | jq -r .coachWorkGrowthMinutes)" = "5" ] \
  && [ "$(echo "$out" | jq -r .coachWorkMaxMinutes)" = "45" ] \
  && [ "$(echo "$out" | jq -r .coachChallengeMinutes)" = "8" ] \
  && [ "$(echo "$out" | jq -r .coachIdleCycles)" = "2" ]; } \
  && ok "coach defaults are present" || ko "coach defaults are present"

# `coach` is a boolean, so it must survive the `*` merge (which `//` would break).
echo '{"level":"C","coach":true}' > "$GCFG"
echo '{"coach":false}' > "$PCFG"
out=$(cfgsh 'learner_config')
[ "$(echo "$out" | jq -r .coach)" = "false" ] \
  && ok "project layer can turn coach off" || ko "project layer can turn coach off"

echo '{"level":"C","coach":false}' > "$GCFG"
echo '{"coach":true,"coachWorkMinutes":10}' > "$PCFG"
out=$(cfgsh 'learner_config')
{ [ "$(echo "$out" | jq -r .coach)" = "true" ] \
  && [ "$(echo "$out" | jq -r .coachWorkMinutes)" = "10" ]; } \
  && ok "project layer can turn coach on and retune it" \
  || ko "project layer can turn coach on and retune it"

# --- learner_coach_active ---------------------------------------------------
echo '{"level":"C","coach":true}' > "$GCFG"
rm -f "$PCFG"
cfgsh 'learner_coach_active "$(learner_config)" "$(learner_repo_root)"' \
  && ok "coach active with level + coach:true" || ko "coach active with level + coach:true"

echo '{"level":"C","coach":false}' > "$GCFG"
cfgsh 'learner_coach_active "$(learner_config)" "$(learner_repo_root)"' \
  && ko "coach inactive when coach:false" || ok "coach inactive when coach:false"

echo '{"coach":true}' > "$GCFG"
cfgsh 'learner_coach_active "$(learner_config)" "$(learner_repo_root)"' \
  && ko "coach inactive without a level" || ok "coach inactive without a level"

echo '{"level":"C","coach":true,"enabled":false}' > "$GCFG"
cfgsh 'learner_coach_active "$(learner_config)" "$(learner_repo_root)"' \
  && ko "coach inactive when learner is disabled" || ok "coach inactive when learner is disabled"

# --- learner_coach_work_minutes --------------------------------------------
echo '{"level":"C","coach":true}' > "$GCFG"
WCFG=$(cfgsh 'learner_config')
wm() { cfgsh "learner_coach_work_minutes $1 '$WCFG'"; }
[ "$(wm 1)" = "25" ] && ok "work block cycle 1 = 25" || ko "work block cycle 1 = 25"
[ "$(wm 2)" = "30" ] && ok "work block cycle 2 = 30" || ko "work block cycle 2 = 30"
[ "$(wm 5)" = "45" ] && ok "work block cycle 5 = 45 (capped)" || ko "work block cycle 5 = 45 (capped)"
[ "$(wm 99)" = "45" ] && ok "work block stays at the cap" || ko "work block stays at the cap"

echo '{"level":"C","coach":true,"coachWorkGrowthMinutes":0}' > "$GCFG"
WCFG=$(cfgsh 'learner_config')
[ "$(wm 7)" = "25" ] && ok "growth 0 keeps a fixed work block" || ko "growth 0 keeps a fixed work block"

# max below min is unambiguous in intent: clamp, do not reject.
echo '{"level":"C","coach":true,"coachWorkMinutes":30,"coachWorkMaxMinutes":10}' > "$GCFG"
WCFG=$(cfgsh 'learner_config')
[ "$(wm 1)" = "30" ] && ok "coachWorkMaxMinutes below min clamps to min" \
  || ko "coachWorkMaxMinutes below min clamps to min"

# A garbage value must fall back to the default rather than produce an empty
# sleep interval, which would spin the watcher at 100% CPU.
echo '{"level":"C","coach":true,"coachWorkMinutes":"soon"}' > "$GCFG"
WCFG=$(cfgsh 'learner_config')
[ "$(wm 1)" = "25" ] && ok "non-numeric coachWorkMinutes falls back to 25" \
  || ko "non-numeric coachWorkMinutes falls back to 25"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep FAIL`
Expected: the coach-defaults assertion FAILs (`jq -r .coach` prints `null`), both
`learner_coach_active` and `learner_coach_work_minutes` assertions FAIL (functions not defined).

- [ ] **Step 3: Extend `LEARNER_DEFAULTS` in `hooks/learner-config.sh`**

Replace the single-line `LEARNER_DEFAULTS=` assignment with:

```sh
LEARNER_DEFAULTS='{"enabled":true,"questionStyles":"auto","synthesisFrequency":"normal","blanksPerExercise":2,"untrackGlobs":[],"disabledPaths":[],"coach":false,"coachCadence":"pomodoro","coachWorkMinutes":25,"coachWorkGrowthMinutes":5,"coachWorkMaxMinutes":45,"coachChallengeMinutes":8,"coachIdleCycles":2,"coachPollSeconds":45,"coachLines":40,"coachFiles":3,"coachEveryMinutes":0,"coachCooldownMinutes":5}'
```

- [ ] **Step 4: Add the two coach helpers**

Add to the header comment block, after the `learner_active CFG ROOT` line:

```sh
#   learner_coach_active CFG ROOT   true when the coach regime is on here
#   learner_coach_work_minutes N CFG  length in minutes of work block N (1-based)
```

Then add the functions at the end of the file, after `learner_active`:

```sh
# learner_int RAW FALLBACK FLOOR — a positive integer from config, or FALLBACK
# when RAW is absent, empty, non-numeric or below FLOOR. Every cadence value goes
# through this: a malformed config must never yield an empty or zero sleep
# interval, which would spin the watcher at 100% CPU instead of waiting.
learner_int() {
  _lir="${1:-}"; _lif="$2"; _lil="${3:-1}"
  case "$_lir" in ''|null|*[!0-9]*) printf '%s' "$_lif"; return 0 ;; esac
  [ "$_lir" -lt "$_lil" ] && { printf '%s' "$_lif"; return 0; }
  printf '%s' "$_lir"
}

# The coach regime is the learner regime plus one switch: everything that
# silences the quiz (no level, enabled:false, disabledPaths) silences the coach
# too, so a dev who switched learner off in a repo does not get coached in it.
learner_coach_active() {
  _lcacfg="$1"
  _lcaroot="$2"
  learner_active "$_lcacfg" "$_lcaroot" || return 1
  [ "$(printf '%s' "$_lcacfg" | jq -r '.coach')" = "true" ] || return 1
  return 0
}

# learner_coach_work_minutes N CFG — the work block grows by
# coachWorkGrowthMinutes per completed cycle, capped at coachWorkMaxMinutes.
# A cap below the base is unambiguous in intent, so it clamps to the base rather
# than being rejected.
learner_coach_work_minutes() {
  _lcwn="${1:-1}"
  _lcwcfg="$2"
  case "$_lcwn" in ''|*[!0-9]*) _lcwn=1 ;; esac
  [ "$_lcwn" -lt 1 ] && _lcwn=1
  _lcwbase=$(learner_int "$(printf '%s' "$_lcwcfg" | jq -r '.coachWorkMinutes // empty')" 25 1)
  _lcwgrow=$(learner_int "$(printf '%s' "$_lcwcfg" | jq -r '.coachWorkGrowthMinutes // empty')" 5 0)
  _lcwmax=$(learner_int "$(printf '%s' "$_lcwcfg" | jq -r '.coachWorkMaxMinutes // empty')" 45 1)
  _lcwv=$((_lcwbase + _lcwgrow * (_lcwn - 1)))
  [ "$_lcwv" -gt "$_lcwmax" ] && _lcwv=$_lcwmax
  [ "$_lcwv" -lt "$_lcwbase" ] && _lcwv=$_lcwbase
  printf '%s' "$_lcwv"
}
```

Note on `learner_int` and a growth of `0`: the floor argument is `0` for
`coachWorkGrowthMinutes` so a legitimate `0` (a fixed-length work block) is kept, while it is
`1` for the two length values so a `0` there falls back rather than producing a zero sleep.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./test.sh`
Expected: PASS, including `growth 0 keeps a fixed work block` and
`non-numeric coachWorkMinutes falls back to 25`.

- [ ] **Step 6: Update `learner.json.example`**

Replace the whole file with:

```json
{
  "level": "C",
  "enabled": true,
  "questionStyles": "auto",
  "synthesisFrequency": "normal",
  "blanksPerExercise": 2,
  "untrackGlobs": ["*.md", "*.json"],
  "disabledPaths": [],

  "coach": false,
  "coachCadence": "pomodoro",
  "coachWorkMinutes": 25,
  "coachWorkGrowthMinutes": 5,
  "coachWorkMaxMinutes": 45,
  "coachChallengeMinutes": 8,
  "coachIdleCycles": 2,

  "coachPollSeconds": 45,
  "coachLines": 40,
  "coachFiles": 3,
  "coachEveryMinutes": 0,
  "coachCooldownMinutes": 5
}
```

The blank lines group the three blocks: learner keys, pomodoro cadence, threshold cadence. JSON
allows them and they carry the same information the spec's config table does.

- [ ] **Step 7: Verify the example file is valid JSON**

Run: `jq -e . learner.json.example >/dev/null && echo OK`
Expected: `OK`

- [ ] **Step 8: Run shellcheck and commit**

Run: `shellcheck hooks/learner-config.sh`

```bash
git add hooks/learner-config.sh learner.json.example test.sh
git commit -m "feat(config): add the coach keys and the cadence arithmetic

Twelve coach* keys with defaults that implement the spec's pomodoro cadence,
plus the two helpers that turn them into decisions: learner_coach_active
(learner_active AND coach:true, so everything that silences the quiz silences
the coach) and learner_coach_work_minutes (25, +5 per cycle, capped at 45).

Every cadence value is read through learner_int, which falls back to the
default on anything non-numeric: a malformed config must not produce a zero
sleep interval, which would spin the watcher at 100% CPU rather than wait.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The gate — deny writes outside the delegated slice

A `PreToolUse` hook on `Write|Edit|NotebookEdit` that refuses any path the dev has not delegated
to Claude. This is the part that makes coach mode hold: a skill instruction alone will not
survive fifty turns, and drift back into implementing is the one failure this mode cannot have.

**Files:**
- Create: `hooks/coach-gate.sh`
- Modify: `test.sh` — the allow/deny matrix

**Interfaces:**
- Consumes: `learner_config`, `learner_repo_root`, `learner_coach_active` (Task 2), `learner_excluded` (Task 1).
- Produces: the delegation scope file contract, which Task 7's skill instructions write and Task 6's cleanup removes — `$TMPDIR/claude-learner-<sid>.coach-scope`, one repo-relative glob per line.

- [ ] **Step 1: Write the failing tests**

Append to `test.sh`:

```sh
# --- coach gate -------------------------------------------------------------
GATE="$ROOT/hooks/coach-gate.sh"
scope() { echo "$TMPDIR/claude-learner-$1.coach-scope"; }

# $1 = session id, $2 = file path, $3 = tool name (default Edit)
gate() {
  printf '{"session_id":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' \
    "$1" "${3:-Edit}" "$2" | sh "$GATE"
}
denied() { printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }

SID_G=gate1
rm -f "$(scope "$SID_G")"

# Coach off: the gate must be completely silent, whatever the path.
echo '{"level":"C","coach":false}' > "$GCFG"
rm -f "$PCFG"
[ -z "$(gate "$SID_G" "$WORK/proj/src/Service.kt")" ] \
  && ok "gate silent when coach is off" || ko "gate silent when coach is off"

# Learner inactive beats coach:true — same five conditions as the quiz.
echo '{"coach":true}' > "$GCFG"
[ -z "$(gate "$SID_G" "$WORK/proj/src/Service.kt")" ] \
  && ok "gate silent without a level" || ko "gate silent without a level"
echo '{"level":"C","coach":true,"enabled":false}' > "$GCFG"
[ -z "$(gate "$SID_G" "$WORK/proj/src/Service.kt")" ] \
  && ok "gate silent when learner is disabled" || ko "gate silent when learner is disabled"

# Coach on, nothing delegated: repo source is denied.
echo '{"level":"C","coach":true,"untrackGlobs":["*.md"]}' > "$GCFG"
mkdir -p "$WORK/proj/src/main/repository" "$WORK/proj/src/main/service"
out=$(gate "$SID_G" "$WORK/proj/src/main/service/Service.kt")
denied "$out" && ok "undelegated repo source is denied" || ko "undelegated repo source is denied"

# The deny payload must be valid JSON and must name the file and the escape hatch,
# or Claude gets a refusal it cannot act on and the dev never learns how to delegate.
{ printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'Service.kt' \
  && printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'coach delegate'; } \
  && ok "deny payload is valid JSON naming the file and the escape hatch" \
  || ko "deny payload is valid JSON naming the file and the escape hatch"

# All three write tools are gated.
for tool in Write Edit NotebookEdit; do
  out=$(gate "$SID_G" "$WORK/proj/src/main/service/Service.kt" "$tool")
  denied "$out" && ok "$tool is gated" || ko "$tool is gated"
done

# The suggested glob must never be a bare `**` — that would invite the dev to
# delegate the entire repo, which is the opposite of what coach mode is for.
out=$(gate "$SID_G" "$WORK/proj/TopLevel.kt")
sug=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' \
        | sed -n "s/.*coach delegate '\([^']*\)'.*/\1/p")
[ "$sug" = "TopLevel.kt" ] && ok "a top-level file suggests itself, not a bare **" \
  || ko "a top-level file suggests itself, not a bare ** (got '$sug')"
out=$(gate "$SID_G" "$WORK/proj/src/main/service/Service.kt")
sug=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' \
        | sed -n "s/.*coach delegate '\([^']*\)'.*/\1/p")
[ "$sug" = "src/main/service/**" ] && ok "a nested file suggests its directory glob" \
  || ko "a nested file suggests its directory glob (got '$sug')"

# Delegation: the matching path is allowed, its sibling is still denied.
printf 'src/**/repository/**\n' > "$(scope "$SID_G")"
[ -z "$(gate "$SID_G" "$WORK/proj/src/main/repository/UserRepo.kt")" ] \
  && ok "delegated glob is allowed" || ko "delegated glob is allowed"
out=$(gate "$SID_G" "$WORK/proj/src/main/service/Service.kt")
denied "$out" && ok "sibling of a delegated glob is still denied" \
  || ko "sibling of a delegated glob is still denied"

# Several globs, one per line.
printf 'src/**/repository/**\nsrc/**/mapper/**\n' > "$(scope "$SID_G")"
mkdir -p "$WORK/proj/src/main/mapper"
[ -z "$(gate "$SID_G" "$WORK/proj/src/main/mapper/UserMapper.kt")" ] \
  && ok "second delegated glob is allowed" || ko "second delegated glob is allowed"
rm -f "$(scope "$SID_G")"

# Outside the repo: Claude's own config and the scratchpad are never coach material.
[ -z "$(gate "$SID_G" "$WORK/cfg/learner.json")" ] \
  && ok "path outside the repo is allowed" || ko "path outside the repo is allowed"

# untrackGlobs material is allowed: blocking a README write is friction with no
# pedagogical payoff.
[ -z "$(gate "$SID_G" "$WORK/proj/README.md")" ] \
  && ok "untrackGlobs path is allowed" || ko "untrackGlobs path is allowed"
[ -z "$(gate "$SID_G" "$WORK/proj/node_modules/x/i.js")" ] \
  && ok "floor path is allowed" || ko "floor path is allowed"

# Degenerate payloads must never block a tool call.
[ -z "$(printf '{}' | sh "$GATE")" ] && ok "empty payload is a no-op" || ko "empty payload is a no-op"
[ -z "$(gate "$SID_G" "")" ] && ok "missing file_path is a no-op" || ko "missing file_path is a no-op"
[ -z "$(printf 'not json' | sh "$GATE")" ] && ok "non-JSON payload is a no-op" || ko "non-JSON payload is a no-op"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep FAIL`
Expected: every gate assertion FAILs — `hooks/coach-gate.sh` does not exist, so `sh "$GATE"`
prints nothing to stdout. The `is allowed` and `no-op` assertions pass by accident (no output is
what they expect); the `denied` and `is gated` assertions are the real signal.

- [ ] **Step 3: Write `hooks/coach-gate.sh`**

```sh
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# PreToolUse Write|Edit|NotebookEdit: in the coach regime, the dev writes the
# code. Claude may only write inside the slice the dev explicitly delegated
# (`learner coach delegate <glob>`), and is denied everywhere else in the repo.
#
# This exists because a skill instruction cannot hold over fifty turns. Drifting
# back into implementing is the one failure coach mode must not have, so the
# refusal is a hook, not a paragraph.
#
# Silent no-op unless the coach regime is active here. Every non-deny path exits
# 0 with no output: a learner hook must never fail a tool call because jq is
# missing or a config file is malformed.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

CFG=$(learner_config)
ROOT=$(learner_repo_root)
learner_coach_active "$CFG" "$ROOT" || exit 0

DATA=$(cat)
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""' 2>/dev/null)
# Verified against the hooks reference: Write, Edit and NotebookEdit all pass the
# path as .tool_input.file_path. The notebook_path fallback costs one jq
# alternative and covers the day that stops being true.
FP=$(printf '%s' "$DATA" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
[ -n "$SID" ] || exit 0
[ -n "$FP" ] || exit 0

# Outside the repo is always allowed: Claude's own config, the scratchpad,
# another project. Coach mode is about the code the dev is learning to write
# here. ROOT is physical (git rev-parse --show-toplevel) while file_path is
# whatever path the session used, so a repo reached through a symlink has to be
# resolved before it can be called "outside" — the same slow path
# learner-record-edit.sh already takes, and only when the cheap match fails.
case "$FP" in
  "$ROOT"/*) ;;
  *)
    _rd=$(cd "${FP%/*}" 2>/dev/null && pwd -P) || _rd=''
    case "${_rd:-/dev/null}/" in
      "$ROOT"/*) ;;
      *) exit 0 ;;
    esac ;;
esac

# Docs, JSON, lock files, generated output: not the learning target. Blocking a
# README write would be friction with no pedagogical payoff.
learner_excluded "$FP" "$CFG" && exit 0

REL=${FP#"$ROOT"/}
SCOPE="${TMPDIR:-/tmp}/claude-learner-${SID}.coach-scope"

# Delegated globs, one per line. Matched with `case`, in which `*` crosses `/` —
# so `src/**/repository/**` and `src/*/repository/*` behave identically. That
# permissive reading is what a dev writing such a glob intends.
if [ -f "$SCOPE" ]; then
  while IFS= read -r _g; do
    [ -n "$_g" ] || continue
    case "$_g" in \#*) continue ;; esac
    # shellcheck disable=SC2254  # $_g is a glob pattern on purpose
    case "$REL" in $_g) exit 0 ;; esac
  done < "$SCOPE"
fi

# The suggested glob must never widen to the whole repo. `sed 's:[^/]*$:**:'` on a
# top-level file like `Foo.kt` yields the bare glob `**`, which would invite the
# dev to delegate the entire repository — the exact opposite of the point. Only a
# path with a directory component gets a directory glob; anything else suggests
# itself.
case "$REL" in
  */*) SUGGEST=$(printf '%s' "$REL" | sed 's:[^/]*$:**:') ;;
  *)   SUGGEST="$REL" ;;
esac

REASON="🧑‍🏫 Coach mode — $REL is not delegated to you.
The dev writes this code. Describe the approach, name the file and the lead, and point at the
lines you would change — do not write them. If this slice really is yours, the dev can delegate
it: learner coach delegate '$SUGGEST'"

jq -n --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
```

The `sed` turns `src/main/service/Service.kt` into `src/main/service/**` — a delegation glob
the dev can copy verbatim instead of composing one from scratch. That is the difference between
an escape hatch a dev uses and one they read past. The `case` guard around it is not
decoration: without it a top-level file yields the bare glob `**`, and the hook would be
suggesting that the dev hand Claude the whole repository.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh`
Expected: PASS, all gate assertions included.

- [ ] **Step 5: Verify the deny actually blocks, in a real session**

Read-only tests prove the payload's shape, not that Claude Code honours it. Do this once, by
hand:

```bash
# From a scratch repo with the plugin loaded:
#   claude --plugin-dir /path/to/claude-learner-mode
# then, in that session:
#   learner config level=C
#   learner coach on
#   ask Claude to edit a source file it has not been delegated
```
Expected: the tool call is refused and Claude reports the coach reason instead of writing.
Record the observed behaviour in the task report. If the payload shape is wrong the call will
succeed silently — which is exactly the fail-open outcome this step exists to rule out, and why
a passing `test.sh` is not sufficient evidence here.

- [ ] **Step 6: Run shellcheck and commit**

Run: `shellcheck hooks/coach-gate.sh`

```bash
git add hooks/coach-gate.sh test.sh
git commit -m "feat(coach): deny writes outside the delegated slice

A PreToolUse hook on Write|Edit|NotebookEdit. In the coach regime Claude may
only write inside the globs the dev delegated for this session; everywhere else
in the repo it is refused, with a reason that redirects it to describing the
lead and hands the dev a copy-pasteable delegate glob.

Paths outside the repo, and anything learner_excluded already skips (docs,
JSON, lock files), stay allowed: blocking a README write would be friction with
no pedagogical payoff.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The watcher's eye — candidate files and the line metric

The measurement half of `coach-watch.sh`, driven by `--once` so it is testable without a clock:
build the candidate set, compute each file's line delta **since the last review**, print the
material. No loop, no sleep, no cadence yet.

**Files:**
- Create: `hooks/coach-watch.sh`
- Modify: `test.sh` — the metric tests

**Interfaces:**
- Consumes: `learner_config`, `learner_repo_root`, `learner_coach_active` (Task 2), `learner_excluded` (Task 1), and the existing `$TMPDIR/claude-learner-<sid>.session` log written by `learner-record-edit.sh`.
- Produces:
  - CLI: `sh coach-watch.sh <session-id> [--once]`. Task 5 adds the loop; Task 6 arms it.
  - Baseline layout `$TMPDIR/claude-learner-<sid>.coach-base/` with `.head`, `.manifest` and one content copy per key. Task 6's cleanup removes it.
  - Internal functions Task 5 calls: `coach_material` (prints `<delta>\t<rel>` lines) and `coach_advance` (reads rel paths on stdin, rewrites the baseline).

- [ ] **Step 1: Write the failing tests**

Append to `test.sh`:

```sh
# --- coach watcher: candidates and metric -----------------------------------
WATCH="$ROOT/hooks/coach-watch.sh"
basedir() { echo "$TMPDIR/claude-learner-$1.coach-base"; }
sess() { echo "$TMPDIR/claude-learner-$1.session"; }

# A dedicated repo so the watcher tests cannot disturb the record-edit ones.
CREPO="$WORK/crepo"
mkdir -p "$CREPO/.claude"
git -C "$CREPO" init -q
git -C "$CREPO" config user.email t@t.t
git -C "$CREPO" config user.name t
CREPO="$(cd "$CREPO" && pwd -P)"

lines() { i=1; while [ "$i" -le "$1" ]; do echo "line $i"; i=$((i + 1)); done; }

# $1 = session id — one measurement cycle, material on stdout as "<delta>\t<rel>"
material() { CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$1" --once --print-material; }

echo '{"level":"C","coach":true,"untrackGlobs":["*.md"]}' > "$GCFG"
rm -f "$PCFG"
SID_W=watch1
rm -rf "$(basedir "$SID_W")"; rm -f "$(sess "$SID_W")"

# No baseline yet: a new untracked file counts every one of its lines.
mkdir -p "$CREPO/src"
lines 10 > "$CREPO/src/Service.kt"
out=$(material "$SID_W")
[ "$(printf '%s' "$out" | awk -F'\t' '$2=="src/Service.kt"{print $1}')" = "10" ] \
  && ok "new untracked file counts all its lines" || ko "new untracked file counts all its lines"

# Advance the baseline, change nothing: an empty cycle.
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_W" --once --advance >/dev/null
out=$(material "$SID_W")
[ -z "$out" ] && ok "unchanged file after baseline is an empty cycle" \
  || ko "unchanged file after baseline is an empty cycle"

# Three lines appended must count as 3, not as the file's full 13. This is the
# assertion that catches a regression to measuring against HEAD.
lines 3 | sed 's/^/extra /' >> "$CREPO/src/Service.kt"
out=$(material "$SID_W")
[ "$(printf '%s' "$out" | awk -F'\t' '$2=="src/Service.kt"{print $1}')" = "3" ] \
  && ok "delta is measured since the last review, not since HEAD" \
  || ko "delta is measured since the last review, not since HEAD"

# Work the dev committed since the baseline still counts. Without the
# <baseline-HEAD>..HEAD term the candidate set would be empty here and the dev
# would be cut off for idleness right after their most productive block.
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_W" --once --advance >/dev/null
lines 4 | sed 's/^/committed /' >> "$CREPO/src/Service.kt"
git -C "$CREPO" add -A >/dev/null 2>&1
git -C "$CREPO" commit -q -m "dev commits mid-block"
out=$(material "$SID_W")
[ "$(printf '%s' "$out" | awk -F'\t' '$2=="src/Service.kt"{print $1}')" = "4" ] \
  && ok "work committed since the baseline still counts" \
  || ko "work committed since the baseline still counts"

# Claude's own writes are the quiz's material, not the coach's.
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_W" --once --advance >/dev/null
mkdir -p "$CREPO/src/repository"
lines 20 > "$CREPO/src/repository/UserRepo.kt"
echo "$CREPO/src/repository/UserRepo.kt" > "$(sess "$SID_W")"
out=$(material "$SID_W")
[ -z "$(printf '%s' "$out" | awk -F'\t' '$2=="src/repository/UserRepo.kt"{print $1}')" ] \
  && ok "a path Claude wrote this session is excluded" \
  || ko "a path Claude wrote this session is excluded"
rm -f "$(sess "$SID_W")"

# Exclusions come from the shared helper, so both layers must apply.
mkdir -p "$CREPO/node_modules/x"
lines 50 > "$CREPO/node_modules/x/index.js"
lines 30 > "$CREPO/NOTES.md"
out=$(material "$SID_W")
[ -z "$(printf '%s' "$out" | awk -F'\t' '$2 ~ /node_modules/{print $1}')" ] \
  && ok "node_modules is excluded from the metric" || ko "node_modules is excluded from the metric"
[ -z "$(printf '%s' "$out" | awk -F'\t' '$2=="NOTES.md"{print $1}')" ] \
  && ok "untrackGlobs is excluded from the metric" || ko "untrackGlobs is excluded from the metric"
rm -rf "$CREPO/node_modules" "$CREPO/NOTES.md"

# A line count over a PNG is noise.
printf 'PNG\000\001\002binary\000data' > "$CREPO/src/logo.png"
out=$(material "$SID_W")
[ -z "$(printf '%s' "$out" | awk -F'\t' '$2=="src/logo.png"{print $1}')" ] \
  && ok "binary file is excluded from the metric" || ko "binary file is excluded from the metric"
rm -f "$CREPO/src/logo.png"

# An emptied file is a real 10-line change, not a binary and not nothing.
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_W" --once --advance >/dev/null
lines 10 > "$CREPO/src/Empty.kt"
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_W" --once --advance >/dev/null
: > "$CREPO/src/Empty.kt"
out=$(material "$SID_W")
[ "$(printf '%s' "$out" | awk -F'\t' '$2=="src/Empty.kt"{print $1}')" = "10" ] \
  && ok "emptying a file counts its deleted lines" || ko "emptying a file counts its deleted lines"
rm -f "$CREPO/src/Empty.kt"

# coach_delta must print exactly one number. `grep -c` prints "0" and exits 1 on
# no matches, so a naive `|| printf '0'` would yield "00" here.
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_W" --once --advance >/dev/null
lines 6 > "$CREPO/src/Single.kt"
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_W" --once --advance >/dev/null
printf 'x' >> "$CREPO/src/Single.kt"
out=$(material "$SID_W")
d=$(printf '%s' "$out" | awk -F'\t' '$2=="src/Single.kt"{print $1}')
case "$d" in
  [0-9]) ok "delta is a single normalised integer" ;;
  *) ko "delta is a single normalised integer (got '$d')" ;;
esac
rm -f "$CREPO/src/Single.kt"

# The watcher must be as silent as the gate when the regime is off.
echo '{"level":"C","coach":false}' > "$GCFG"
out=$(material "$SID_W")
[ -z "$out" ] && ok "watcher silent when coach is off" || ko "watcher silent when coach is off"
echo '{"level":"C","coach":true,"untrackGlobs":["*.md"]}' > "$GCFG"

# A repo with no commits at all: the untracked term alone must still work.
NREPO="$WORK/nrepo"; mkdir -p "$NREPO"; git -C "$NREPO" init -q
NREPO="$(cd "$NREPO" && pwd -P)"
lines 7 > "$NREPO/fresh.kt"
out=$(CLAUDE_PROJECT_DIR="$NREPO" sh "$WATCH" watch-fresh --once --print-material)
[ "$(printf '%s' "$out" | awk -F'\t' '$2=="fresh.kt"{print $1}')" = "7" ] \
  && ok "repo with no commits still measures untracked files" \
  || ko "repo with no commits still measures untracked files"
rm -rf "$(basedir watch-fresh)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep FAIL`
Expected: every watcher assertion that expects a number FAILs — the script does not exist yet.

- [ ] **Step 3: Write `hooks/coach-watch.sh` (measurement half)**

```sh
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The coach watcher. NOT a hook — a long-running script armed once per session
# as a persistent Monitor, whose stdout lines become conversation
# notifications.
#
# Why polling: no Claude Code hook fires when the *dev* saves a file in their
# editor — hooks observe Claude's own tool calls only. Polling the git working
# tree is the only mechanism that can see the dev's edits, which is what coach
# mode is entirely about.
#
# Usage: sh coach-watch.sh <session-id> [--once] [--print-material] [--advance]
#   --once             run a single cycle without sleeping, then return (tests)
#   --print-material   print "<delta>\t<rel>" per changed file instead of a
#                      trigger line (tests)
#   --advance          advance the baseline and return, emitting nothing (tests)
#
# The session id is an argument, not stdin: a hook receives it in its payload
# but a Monitor command does not, so whoever arms the watcher substitutes it.

. "$(dirname "$0")/learner-config.sh"

SID="${1:-}"
[ -n "$SID" ] || exit 0
shift

ONCE=0; PRINT_MATERIAL=0; ADVANCE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1 ;;
    --print-material) PRINT_MATERIAL=1; ONCE=1 ;;
    --advance) ADVANCE_ONLY=1; ONCE=1 ;;
    *) ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

CFG=$(learner_config)
ROOT=$(learner_repo_root)
learner_coach_active "$CFG" "$ROOT" || exit 0

TMPD="${TMPDIR:-/tmp}"
SESSION="$TMPD/claude-learner-${SID}.session"
BASEDIR="$TMPD/claude-learner-${SID}.coach-base"

# --- baseline ---------------------------------------------------------------
# The baseline is a content copy per candidate file, plus the HEAD it was taken
# at. Measuring against HEAD instead would recount the same lines every cycle:
# a file the dev revisits in three consecutive blocks would look like three
# times the work.
#
# <key> is `git hash-object --stdin` of the repo-relative path — 40 hex
# characters, so any path becomes a safe filename.
coach_key() { printf '%s' "$1" | git hash-object --stdin; }

coach_baseline_head() { cat "$BASEDIR/.head" 2>/dev/null || printf ''; }

# Everything the dev touched, minus everything that is not theirs to be
# challenged on.
coach_candidates() {
  _cbh=$(coach_baseline_head)
  {
    git -C "$ROOT" diff --name-only HEAD 2>/dev/null
    git -C "$ROOT" ls-files -o --exclude-standard 2>/dev/null
    # Work the dev committed since the baseline. Without this term a dev who
    # commits at the end of a block empties their own candidate set and gets an
    # idle cut-off for the block they just worked hardest in.
    [ -n "$_cbh" ] && git -C "$ROOT" diff --name-only "$_cbh" HEAD 2>/dev/null
  } | sort -u | while IFS= read -r _cr; do
    [ -n "$_cr" ] || continue
    _ca="$ROOT/$_cr"
    learner_excluded "$_ca" "$CFG" && continue
    # What Claude wrote goes to the learner quiz; what the dev wrote goes to the
    # coach. Per-hunk authorship is not available to a shell script, so a file
    # both touched is attributed to Claude — reviewing Claude's own code as if
    # it were the dev's would produce a challenge the dev cannot answer.
    if [ -f "$SESSION" ] && grep -qxF "$_ca" "$SESSION" 2>/dev/null; then
      continue
    fi
    # A line count over a PNG is noise. Non-empty and no text line = binary; an
    # emptied file is a real change and must survive this test.
    if [ -s "$_ca" ] && ! grep -Iq . "$_ca" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$_cr"
  done
}

# Lines changed since the baseline, for one repo-relative path.
coach_delta() {
  _cdr="$1"
  _cda="$ROOT/$_cdr"
  _cdb="$BASEDIR/$(coach_key "$_cdr")"
  # `grep -c` prints its count AND exits 1 when that count is zero, so a
  # `grep -c … || printf '0'` would emit "00". Arithmetic reads "00" as zero, so
  # such a bug would survive review and only mislead whoever debugs the trigger
  # later. Capture once, normalise once, print once.
  if [ -f "$_cdb" ] && [ -f "$_cda" ]; then
    # `[^+-]|$` so an added or removed *blank* line still counts, while diff's
    # own `---`/`+++` headers (second character is - or +) do not.
    _cdn=$(diff -u "$_cdb" "$_cda" 2>/dev/null | grep -Ec '^[+-]([^+-]|$)')
  elif [ -f "$_cda" ]; then
    _cdn=$(grep -c '' "$_cda" 2>/dev/null)
  elif [ -f "$_cdb" ]; then
    _cdn=$(grep -c '' "$_cdb" 2>/dev/null)
  else
    _cdn=0
  fi
  case "$_cdn" in ''|*[!0-9]*) _cdn=0 ;; esac
  printf '%s' "$_cdn"
}

# "<delta>\t<rel>" per file with a non-zero delta.
coach_material() {
  coach_candidates | while IFS= read -r _cmr; do
    [ -n "$_cmr" ] || continue
    _cmd=$(coach_delta "$_cmr")
    case "$_cmd" in ''|*[!0-9]*) _cmd=0 ;; esac
    [ "$_cmd" -gt 0 ] && printf '%s\t%s\n' "$_cmd" "$_cmr"
  done
}

# Rewrite the baseline from the repo-relative paths on stdin. Called at emission
# time, immediately after a line is printed — never after the review finishes: a
# review Claude never runs must not re-fire the same material one cycle later.
coach_advance() {
  mkdir -p "$BASEDIR" 2>/dev/null || return 0
  _canew="$BASEDIR/.manifest.new"
  : > "$_canew"
  while IFS= read -r _car; do
    [ -n "$_car" ] || continue
    _cak=$(coach_key "$_car")
    if [ -f "$ROOT/$_car" ]; then
      cp "$ROOT/$_car" "$BASEDIR/$_cak" 2>/dev/null || continue
    else
      rm -f "$BASEDIR/$_cak"
    fi
    printf '%s %s\n' "$_cak" "$_car" >> "$_canew"
  done
  # Drop content copies for files that are no longer candidates, so the baseline
  # directory tracks the working set instead of growing all session.
  if [ -f "$BASEDIR/.manifest" ]; then
    while read -r _cao _caorel; do
      [ -n "$_cao" ] || continue
      grep -q "^$_cao " "$_canew" 2>/dev/null || rm -f "$BASEDIR/$_cao"
    done < "$BASEDIR/.manifest"
  fi
  mv "$_canew" "$BASEDIR/.manifest" 2>/dev/null
  git -C "$ROOT" rev-parse HEAD > "$BASEDIR/.head" 2>/dev/null || : > "$BASEDIR/.head"
}

if [ "$ADVANCE_ONLY" = 1 ]; then
  coach_candidates | coach_advance
  exit 0
fi

if [ "$PRINT_MATERIAL" = 1 ]; then
  coach_material
  exit 0
fi

# Task 5 replaces this with the cadence loop.
exit 0
```

**Note for the implementer:** run `sh -n hooks/coach-watch.sh` before any test. A `do`/`done`
or `in`/`;` slip inside one of these `while read` loops is the easiest mistake to make in this
file and the hardest to read out of a test failure.

- [ ] **Step 4: Syntax-check, then run the tests**

Run: `sh -n hooks/coach-watch.sh && ./test.sh`
Expected: `sh -n` silent, then PASS on every watcher assertion — in particular
`delta is measured since the last review, not since HEAD` and
`work committed since the baseline still counts`.

- [ ] **Step 5: Run shellcheck and commit**

Run: `shellcheck hooks/coach-watch.sh`

```bash
git add hooks/coach-watch.sh test.sh
git commit -m "feat(coach): measure the dev's changes since the last review

The measurement half of the watcher. The candidate set is everything the dev
touched in the working tree — including work they committed since the baseline,
without which a dev who commits at the end of a block would empty their own
candidate set and be cut off for idleness — minus the shared exclusion floor,
minus every path Claude wrote this session, minus binaries.

The metric is lines changed since the last review, computed against a per-file
content baseline rather than against HEAD. Measuring against HEAD would recount
the same lines every cycle, so a file revisited in three blocks would look like
three times the work.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: The watcher's clock — pomodoro cadence, growth, idle exit

Wrap Task 4's measurement in the two cadences and emit the trigger lines. One notification per
cycle, work blocks that grow only when the dev actually wrote code, and a watcher that stops
itself after two empty blocks rather than pinging an empty room forever.

**Files:**
- Modify: `hooks/coach-watch.sh` — replace the `exit 0` stub with the loop
- Modify: `test.sh` — cadence, idle and emission tests

**Interfaces:**
- Consumes: `coach_material`, `coach_advance`, `coach_candidates` (Task 4), `learner_coach_work_minutes`, `learner_int` (Task 2), `learner_level` (existing).
- Produces: the two trigger-line formats Task 7's `references/coach.md` is written against:
  - `🧑‍🏫 Coach (level: <L>, cycle: <N>, files: <F>, lines: <D>) — <paths>` followed by the protocol pointer line.
  - `🧑‍🏫 Coach — no tracked changes for <N> work blocks; the watcher has stopped.` followed by the resume-question line.

- [ ] **Step 1: Write the failing tests**

Append to `test.sh`:

```sh
# --- coach watcher: cadence and emission ------------------------------------
# --once runs one cycle with no sleep, so the whole cadence is testable in
# milliseconds. `--cycle N` injects the cycle number a real loop would hold.
cycle_out() { CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$1" --once --cycle "$2"; }

echo '{"level":"S","coach":true,"untrackGlobs":["*.md"]}' > "$GCFG"
rm -f "$PCFG"
SID_C=watch2
rm -rf "$(basedir "$SID_C")"; rm -f "$(sess "$SID_C")"
rm -f "$CREPO/src/Service.kt"
git -C "$CREPO" add -A >/dev/null 2>&1; git -C "$CREPO" commit -q -m clean 2>/dev/null

mkdir -p "$CREPO/src"
lines 12 > "$CREPO/src/A.kt"
lines 8  > "$CREPO/src/B.kt"
out=$(cycle_out "$SID_C" 3)

printf '%s' "$out" | grep -q '^🧑‍🏫 Coach (level: S, cycle: 3, files: 2, lines: 20)' \
  && ok "trigger line carries level, cycle, files and lines" \
  || ko "trigger line carries level, cycle, files and lines"
printf '%s' "$out" | grep -q 'src/A.kt' && printf '%s' "$out" | grep -q 'src/B.kt' \
  && ok "trigger line names the changed files" || ko "trigger line names the changed files"
printf '%s' "$out" | grep -q 'references/coach.md' \
  && ok "trigger line points at the protocol, not at the protocol's content" \
  || ko "trigger line points at the protocol, not at the protocol's content"
[ "$(printf '%s\n' "$out" | grep -c '🧑‍🏫')" = "1" ] \
  && ok "one emission per cycle, never two" || ko "one emission per cycle, never two"

# Emitting advances the baseline, so the very next cycle is empty. Otherwise the
# dev gets challenged twice on one diff.
out=$(cycle_out "$SID_C" 4)
[ -z "$out" ] && ok "emission advances the baseline" || ko "emission advances the baseline"

# Idle: coachIdleCycles empty cycles in a row, then one line and exit 0.
echo '{"level":"S","coach":true,"coachIdleCycles":2}' > "$GCFG"
SID_I=watch3
rm -rf "$(basedir "$SID_I")"
out1=$(cycle_out "$SID_I" 1)   # empty 1 of 2
[ -z "$out1" ] && ok "first empty cycle says nothing" || ko "first empty cycle says nothing"
out2=$(cycle_out "$SID_I" 1)   # empty 2 of 2 -> idle
printf '%s' "$out2" | grep -q 'the watcher has stopped' \
  && ok "idle line is emitted after coachIdleCycles empty cycles" \
  || ko "idle line is emitted after coachIdleCycles empty cycles"
printf '%s' "$out2" | grep -qi 'continue' \
  && ok "idle line asks about continuing the session" || ko "idle line asks about continuing the session"
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_I" --once --cycle 1 >/dev/null 2>&1
[ "$?" = "0" ] && ok "watcher exits 0 on idle" || ko "watcher exits 0 on idle"

# A cycle with material resets the empty counter: two empty blocks must be
# *consecutive* to stop the watcher.
SID_R=watch4
rm -rf "$(basedir "$SID_R")"
cycle_out "$SID_R" 1 >/dev/null                       # empty 1
lines 5 > "$CREPO/src/C.kt"
cycle_out "$SID_R" 1 >/dev/null                       # material -> reset
out=$(cycle_out "$SID_R" 1)                           # empty 1 again, not 2
[ -z "$out" ] && ok "material resets the empty-cycle counter" \
  || ko "material resets the empty-cycle counter"
rm -f "$CREPO/src/C.kt"

# The threshold cadence fires on the OR of its three triggers.
echo '{"level":"C","coach":true,"coachCadence":"threshold","coachLines":10,"coachFiles":99,"coachCooldownMinutes":0}' > "$GCFG"
SID_T=watch5
rm -rf "$(basedir "$SID_T")"
lines 25 > "$CREPO/src/D.kt"
out=$(cycle_out "$SID_T" 1)
printf '%s' "$out" | grep -q '🧑‍🏫 Coach (' \
  && ok "threshold cadence fires on coachLines" || ko "threshold cadence fires on coachLines"

echo '{"level":"C","coach":true,"coachCadence":"threshold","coachLines":9999,"coachFiles":1,"coachCooldownMinutes":0}' > "$GCFG"
rm -rf "$(basedir "$SID_T")"
out=$(cycle_out "$SID_T" 1)
printf '%s' "$out" | grep -q '🧑‍🏫 Coach (' \
  && ok "threshold cadence fires on coachFiles" || ko "threshold cadence fires on coachFiles"

# Under both thresholds and inside the cooldown: silence.
echo '{"level":"C","coach":true,"coachCadence":"threshold","coachLines":9999,"coachFiles":99,"coachCooldownMinutes":0}' > "$GCFG"
rm -rf "$(basedir "$SID_T")"
out=$(cycle_out "$SID_T" 1)
[ -z "$out" ] && ok "threshold cadence is silent below every trigger" \
  || ko "threshold cadence is silent below every trigger"
rm -f "$CREPO/src/D.kt"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep FAIL`
Expected: every cadence assertion FAILs — the script still ends at the `exit 0` stub and emits
nothing. `first empty cycle says nothing` passes by accident.

- [ ] **Step 3: Add `--cycle N` to the argument parser**

In the argument loop near the top of the file, add a case so tests can inject the cycle number
a real loop would hold, and initialise `CYCLE=1` beside `ONCE=0` so the variable always exists:

```sh
    --cycle) shift; CYCLE="${1:-1}"; case "$CYCLE" in ''|*[!0-9]*) CYCLE=1 ;; esac ;;
```

- [ ] **Step 4: Replace the stub in `hooks/coach-watch.sh` with the cadence loop**

Delete the two trailing lines (`# Task 5 replaces this with the cadence loop.` and its
`exit 0`) and append:

```sh
# --- cadence ----------------------------------------------------------------
LEVEL=$(learner_level "$(printf '%s' "$CFG" | jq -r '.level // empty')")
CADENCE=$(printf '%s' "$CFG" | jq -r '.coachCadence // "pomodoro"')
case "$CADENCE" in threshold) ;; *) CADENCE=pomodoro ;; esac

IDLE_MAX=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachIdleCycles // empty')" 2 1)
CHALLENGE=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachChallengeMinutes // empty')" 8 0)
POLL=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachPollSeconds // empty')" 45 5)
THR_LINES=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachLines // empty')" 40 1)
THR_FILES=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachFiles // empty')" 3 1)
THR_EVERY=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachEveryMinutes // empty')" 0 0)
COOLDOWN=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachCooldownMinutes // empty')" 5 0)

# The empty-cycle counter has to survive `--once`, which is a fresh process per
# cycle in tests and the only way the idle path is testable at all.
EMPTYF="$TMPD/claude-learner-${SID}.coach-empty"
LASTF="$TMPD/claude-learner-${SID}.coach-last"

coach_read_int() { _cri=$(cat "$1" 2>/dev/null); case "$_cri" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$_cri" ;; esac; }

# One measurement + decision + emission. Returns 0 to keep going, 1 to stop
# (idle cut-off). CYCLE is read from the environment so --once can inject it.
coach_cycle() {
  _ccm=$(coach_material)

  if [ -z "$_ccm" ]; then
    _cce=$(coach_read_int "$EMPTYF" 0)
    _cce=$((_cce + 1))
    printf '%s' "$_cce" > "$EMPTYF"
    if [ "$_cce" -ge "$IDLE_MAX" ]; then
      # One line, then stop. The watcher costs nothing while it waits, but every
      # notification opens a turn — so an abandoned session must not keep
      # producing them.
      printf '%s\n' "🧑‍🏫 Coach — no tracked changes for $IDLE_MAX work blocks; the watcher has stopped.
Ask the dev whether they want to continue the coaching session. If they do, re-arm the watcher."
      rm -f "$EMPTYF"
      return 1
    fi
    return 0
  fi

  _ccn=$(printf '%s\n' "$_ccm" | grep -c '')
  _ccl=$(printf '%s\n' "$_ccm" | awk -F'\t' '{s += $1} END {print s + 0}')
  _ccnow=$(date +%s)
  _cclast=$(coach_read_int "$LASTF" 0)
  _ccelapsed=$(( (_ccnow - _cclast) / 60 ))
  [ "$_cclast" = 0 ] && _ccelapsed=$((COOLDOWN + THR_EVERY + 1))

  if [ "$CADENCE" = threshold ]; then
    [ "$_ccelapsed" -lt "$COOLDOWN" ] && return 0
    _ccfire=0
    [ "$_ccl" -ge "$THR_LINES" ] && _ccfire=1
    [ "$_ccn" -ge "$THR_FILES" ] && _ccfire=1
    [ "$THR_EVERY" -gt 0 ] && [ "$_ccelapsed" -ge "$THR_EVERY" ] && _ccfire=1
    [ "$_ccfire" = 1 ] || return 0
  fi

  _ccfiles=$(printf '%s\n' "$_ccm" | cut -f2 | head -n 20 | tr '\n' ' ')

  # Same contract as the quiz trigger: parameters and a pointer to the protocol,
  # never the protocol itself. Rendered in the console, so it stays one screen.
  printf '%s\n' "🧑‍🏫 Coach (level: $LEVEL, cycle: ${CYCLE:-1}, files: $_ccn, lines: $_ccl) — $_ccfiles
Invoke the \`learner\` skill and follow references/coach.md. One challenge, then wait for the dev's answer."

  coach_candidates | coach_advance
  printf '%s' "$_ccnow" > "$LASTF"
  rm -f "$EMPTYF"
  return 0
}

if [ "$ONCE" = 1 ]; then
  coach_cycle
  exit 0
fi

# The real loop. Pomodoro sleeps the whole work block and measures once at the
# end — no polling at all; coachPollSeconds exists only for the threshold
# cadence. An empty block does NOT advance CYCLE: the work block grows as a
# reward for writing code, not for leaving the editor open.
CYCLE=1
rm -f "$EMPTYF" "$LASTF"
while :; do
  if [ "$CADENCE" = threshold ]; then
    sleep "$POLL"
  else
    sleep $(( $(learner_coach_work_minutes "$CYCLE" "$CFG") * 60 ))
  fi

  coach_cycle || exit 0

  # coach_cycle removes the counter file when it emits and writes it when the
  # cycle was empty, so "did this cycle emit" is exactly "is the counter gone".
  # On an emission: sleep the challenge window and grow the work block. The
  # script stays silent at the end of that window — the challenge ends when the
  # dev answers and goes back to coding, and a "back to work" line would cost a
  # full turn per cycle for no information.
  if [ ! -f "$EMPTYF" ]; then
    [ "$CADENCE" = pomodoro ] && [ "$CHALLENGE" -gt 0 ] && sleep $((CHALLENGE * 60))
    CYCLE=$((CYCLE + 1))
  fi
done
```

- [ ] **Step 5: Syntax-check and run the tests**

Run: `sh -n hooks/coach-watch.sh && ./test.sh`
Expected: PASS on every cadence assertion, including
`one emission per cycle, never two`, `material resets the empty-cycle counter` and the three
threshold cases.

- [ ] **Step 6: Verify the real loop sleeps and fires, once, by hand**

`--once` proves the decision logic, not the clock. Run the loop for real with a one-minute block:

```bash
cd /tmp && rm -rf coachtest && mkdir coachtest && cd coachtest && git init -q
mkdir -p .claude
printf '{"level":"C","coach":true,"coachWorkMinutes":1,"coachWorkGrowthMinutes":0,"coachChallengeMinutes":0}' \
  > "$CLAUDE_CONFIG_DIR/learner.json"   # back this file up first if it is your real one
CLAUDE_PROJECT_DIR=/tmp/coachtest sh /path/to/hooks/coach-watch.sh manualtest &
sleep 5; seq 1 30 > src.txt; sleep 70
```
Expected: exactly one `🧑‍🏫 Coach (level: C, cycle: 1, files: 1, lines: 30)` block appears about
60 seconds in, and nothing further until the next block. Then `kill %1`, restore your real
`learner.json`, and record what you observed in the task report.

- [ ] **Step 7: Run shellcheck and commit**

Run: `shellcheck hooks/coach-watch.sh`

```bash
git add hooks/coach-watch.sh test.sh
git commit -m "feat(coach): pomodoro cadence, growing work blocks, idle cut-off

One notification per cycle: the watcher emits at the end of the work block and
stays silent at the end of the challenge window, because the challenge ends
when the dev answers and goes back to coding. A back-to-work line would cost a
full turn per cycle for no information.

The work block grows 5 min per cycle to a 45 min cap, but only for cycles that
produced material — growth rewards writing code, not leaving the editor open.
After two consecutive empty blocks the watcher emits one line and exits, since
it costs nothing while waiting but every notification opens a turn.

The threshold cadence fires on the OR of coachLines/coachFiles/coachEveryMinutes
gated by coachCooldownMinutes, for devs who want change-driven rather than
time-driven reviews.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Arming, cleanup, and hook wiring

Make coach mode start and stop on its own: `SessionStart` tells Claude to arm the watcher when
`coach` is true, `SessionEnd` removes the coach scratch files, and the gate is wired into both
install paths.

**Files:**
- Modify: `hooks/learner-onboard.sh` — the arming branch
- Modify: `hooks/learner-cleanup.sh` — remove the coach scratch files
- Modify: `hooks/hooks.json` — wire `coach-gate.sh` as `PreToolUse`
- Modify: `hooks/settings.snippet.json` — the same wiring for the non-plugin install
- Modify: `test.sh` — arming, cleanup and wiring tests

**Interfaces:**
- Consumes: `learner_coach_active` (Task 2), `hooks/coach-gate.sh` (Task 3), `hooks/coach-watch.sh` (Tasks 4–5).
- Produces: the `additionalContext` arming instruction Task 7's skill relies on, and the guarantee that `.coach-base/`, `.coach-scope`, `.coach-empty` and `.coach-last` never outlive a session.

- [ ] **Step 1: Write the failing tests**

Append to `test.sh`:

```sh
# --- coach arming and cleanup ----------------------------------------------
onboard() { printf '{"session_id":"%s"}' "$1" | sh "$ONB"; }

echo '{"level":"C","coach":true}' > "$GCFG"
rm -f "$PCFG"
out=$(onboard arm1)
{ printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1 \
  && printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'Monitor' \
  && printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'coach-watch.sh' \
  && printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'arm1'; } \
  && ok "onboard arms the watcher when coach is on" || ko "onboard arms the watcher when coach is on"

echo '{"level":"C","coach":false}' > "$GCFG"
[ -z "$(onboard arm2)" ] && ok "onboard says nothing when coach is off" \
  || ko "onboard says nothing when coach is off"

# A context compaction must not arm a second watcher on the same session: the dev
# would get every review twice, on two drifting cadences.
echo '{"level":"C","coach":true}' > "$GCFG"
onboard_src() { printf '{"session_id":"%s","source":"%s"}' "$1" "$2" | sh "$ONB"; }
[ -n "$(onboard_src arm4 startup)" ] && ok "startup arms the watcher" || ko "startup arms the watcher"
[ -n "$(onboard_src arm4 resume)" ] && ok "resume arms the watcher" || ko "resume arms the watcher"
[ -z "$(onboard_src arm4 compact)" ] && ok "compact does not re-arm the watcher" \
  || ko "compact does not re-arm the watcher"
[ -z "$(onboard_src arm4 clear)" ] && ok "clear does not re-arm the watcher" \
  || ko "clear does not re-arm the watcher"

# A missing level already produces the existing "no valid level" nudge; coach
# must not replace or duplicate it.
echo '{"coach":true}' > "$GCFG"
out=$(onboard arm3)
printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'learner config level=' \
  && ok "a missing level still wins over the coach nudge" \
  || ko "a missing level still wins over the coach nudge"

# Cleanup must take the coach scratch files with the rest.
SID_X=clean-coach
mkdir -p "$TMPDIR/claude-learner-${SID_X}.coach-base"
touch "$TMPDIR/claude-learner-${SID_X}.coach-base/.head" \
      "$TMPDIR/claude-learner-${SID_X}.coach-scope" \
      "$TMPDIR/claude-learner-${SID_X}.coach-empty" \
      "$TMPDIR/claude-learner-${SID_X}.coach-last" \
      "$TMPDIR/claude-learner-${SID_X}.edits"
printf '{"session_id":"%s"}' "$SID_X" | sh "$CLEAN"
{ [ ! -d "$TMPDIR/claude-learner-${SID_X}.coach-base" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.coach-scope" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.coach-empty" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.coach-last" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.edits" ]; } \
  && ok "cleanup removes the coach scratch files" || ko "cleanup removes the coach scratch files"

# Both install paths must be wired, or half the users get half the feature.
{ jq -e '.hooks.PreToolUse[] | select(.matcher == "Write|Edit|NotebookEdit")
         | .hooks[0].command | contains("coach-gate.sh")' "$ROOT/hooks/hooks.json" >/dev/null 2>&1; } \
  && ok "hooks.json wires coach-gate.sh" || ko "hooks.json wires coach-gate.sh"
{ jq -e '.hooks.PreToolUse[] | select(.matcher == "Write|Edit|NotebookEdit")
         | .hooks[0].command | contains("coach-gate.sh")' "$ROOT/hooks/settings.snippet.json" >/dev/null 2>&1; } \
  && ok "settings.snippet.json wires coach-gate.sh" || ko "settings.snippet.json wires coach-gate.sh"

# coach-watch.sh is not a hook and must never be wired as one.
grep -q 'coach-watch' "$ROOT/hooks/hooks.json" \
  && ko "coach-watch.sh is not wired as a hook" || ok "coach-watch.sh is not wired as a hook"
grep -q 'coach-watch' "$ROOT/hooks/settings.snippet.json" \
  && ko "coach-watch.sh is not wired in the snippet either" \
  || ok "coach-watch.sh is not wired in the snippet either"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep FAIL`
Expected: the arming, cleanup and both wiring assertions FAIL. The two `is not wired` assertions
already pass, which is correct — they are regression guards, not new behaviour.

- [ ] **Step 3: Add the arming branch to `hooks/learner-onboard.sh`**

Replace the tail of the file — everything from `CFG=$(learner_config)` to the end — with:

```sh
CFG=$(learner_config)
LEVEL=$(learner_level "$(printf '%s' "$CFG" | jq -r '.level // empty')")
if [ -z "$LEVEL" ]; then
  CTX="Learner is installed but has no valid level, so it will never ask a question. Tell the user, in one line, to run \`learner config level=<D|J|C|S|E>\`, then continue with their request."
  jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
  exit 0
fi

# Coach mode needs a long-running watcher, and nothing in the hook system can
# start one: no hook fires when the *dev* saves a file, so the watcher has to
# poll, and polling means a process that outlives this hook. The one thing this
# hook can do is tell Claude to arm it — which costs the dev no ceremony at
# session start.
learner_coach_active "$CFG" "$ROOT" || exit 0

DATA=$(cat 2>/dev/null)
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$SID" ] || exit 0

# SessionStart fires on `startup`, `resume`, `clear`, `compact` and `fork`. Only
# `startup` and `resume` may arm: a context compaction mid-session would
# otherwise arm a *second* watcher on the same session id, and the dev would get
# every review twice, on two drifting cadences.
SOURCE=$(printf '%s' "$DATA" | jq -r '.source // "startup"' 2>/dev/null)
case "$SOURCE" in startup|resume) ;; *) exit 0 ;; esac

WATCH="$(dirname "$0")/coach-watch.sh"
CTX="Coach mode is on in this repo: the dev writes the code, you challenge it.
Arm the change watcher now, before anything else, with the Monitor tool:
  command: sh \"$WATCH\" \"$SID\"
  description: coach: the dev's changes
  persistent: true
Then read the \`learner\` skill's references/coach.md so you know the review protocol before the
first notification arrives. Do not implement anything the dev has not delegated with
\`learner coach delegate\` — a PreToolUse hook will refuse it anyway. Then continue with the
dev's request."
jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
```

Note that the original file did not read stdin at all; it does now, for the session id.

- [ ] **Step 4: Extend `hooks/learner-cleanup.sh`**

Replace the `rm -f` command with:

```sh
rm -f "$DIR/claude-learner-${SID}.edits" \
      "$DIR/claude-learner-${SID}.session" \
      "$DIR/claude-learner-${SID}.count" \
      "$DIR/claude-learner-${SID}.guard" \
      "$DIR/claude-learner-${SID}.coach-scope" \
      "$DIR/claude-learner-${SID}.coach-empty" \
      "$DIR/claude-learner-${SID}.coach-last"
rm -rf "$DIR/claude-learner-${SID}.coach-base"
```

- [ ] **Step 5: Wire the gate into `hooks/hooks.json`**

Add a `PreToolUse` block between `SessionStart` and `PostToolUse`:

```json
    "PreToolUse": [
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/coach-gate.sh\"", "timeout": 10 }
        ]
      }
    ],
```

- [ ] **Step 6: Wire the gate into `hooks/settings.snippet.json`**

Add the same block, with the traditional-install path:

```json
    "PreToolUse": [
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/coach-gate.sh\"",
            "timeout": 10
          }
        ]
      }
    ],
```

- [ ] **Step 7: Verify both JSON files and run the tests**

Run: `jq -e . hooks/hooks.json >/dev/null && jq -e . hooks/settings.snippet.json >/dev/null && ./test.sh`
Expected: both `jq` checks silent, then PASS.

- [ ] **Step 8: Check `install.sh` copies the new scripts**

Run: `grep -n 'hooks/' install.sh | head -30`
Expected: `install.sh` copies the whole `hooks/` directory (a glob or a loop), in which case the
two new scripts come along for free and nothing needs changing. If instead it lists hook files
one by one, add `coach-gate.sh` and `coach-watch.sh` to that list and note the change in the
task report — a traditional install that ships the wiring but not the script would fire a hook
against a missing file on every single write.

- [ ] **Step 9: Run shellcheck and commit**

Run: `shellcheck hooks/learner-onboard.sh hooks/learner-cleanup.sh`

```bash
git add hooks/learner-onboard.sh hooks/learner-cleanup.sh hooks/hooks.json hooks/settings.snippet.json test.sh
git commit -m "feat(coach): arm the watcher at session start, wire the gate

Nothing in the hook system can start a long-running watcher, so SessionStart
does the one thing it can: tell Claude to arm it with Monitor, passing the
session id the watcher cannot otherwise get. The dev types nothing.

SessionEnd takes the coach baseline directory and scratch files with the rest,
and the gate is wired into both hooks.json and settings.snippet.json — the
plugin path and the curl/clone/brew/apt path are two consumers of the same
scripts and neither may be forgotten. coach-watch.sh is deliberately wired in
neither: it is not a hook.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: The skill side — dispatch, the review protocol, and the register axis

Everything Claude actually reads. Without this task the hooks fire into a void: the trigger line
points at `references/coach.md`, and that file does not exist yet.

**Files:**
- Create: `skills/learner/references/coach.md`
- Modify: `skills/learner/SKILL.md` — dispatch rows, the register column, the coach config keys, the status line, the frontmatter description
- Modify: `test.sh` — documentation guards

**Interfaces:**
- Consumes: the two trigger-line formats (Task 5), the scope-file contract (Task 3), the config keys (Task 2).
- Produces: nothing other tasks consume. This is the last behavioural task.

- [ ] **Step 1: Write the failing tests**

Documentation is testable where it carries a contract. Append to `test.sh`:

```sh
# --- coach documentation ----------------------------------------------------
SK="$ROOT/skills/learner/SKILL.md"
CO="$ROOT/skills/learner/references/coach.md"

[ -f "$CO" ] && ok "references/coach.md exists" || ko "references/coach.md exists"

# Every config key the code reads must be documented, or a dev cannot discover it.
for k in coach coachCadence coachWorkMinutes coachWorkGrowthMinutes coachWorkMaxMinutes \
         coachChallengeMinutes coachIdleCycles coachPollSeconds coachLines coachFiles \
         coachEveryMinutes coachCooldownMinutes; do
  grep -q "\`$k\`" "$SK" && ok "SKILL.md documents $k" || ko "SKILL.md documents $k"
done

# The dispatch table must route every subcommand the skill claims to accept.
for c in "coach on" "coach off" "coach delegate" "coach review"; do
  grep -q "$c" "$SK" && ok "SKILL.md dispatches \`$c\`" || ko "SKILL.md dispatches \`$c\`"
done

# The protocol reference must be reachable from the trigger line's pointer.
grep -q 'references/coach.md' "$SK" && ok "SKILL.md points at references/coach.md" \
  || ko "SKILL.md points at references/coach.md"

# The protocol must state its own ceiling and its own prohibition, since those
# are the two things that keep the dev in the driver's seat.
grep -qi 'one challenge' "$CO" && ok "coach.md states the one-challenge ceiling" \
  || ko "coach.md states the one-challenge ceiling"
grep -qi 'never write' "$CO" && ok "coach.md forbids writing to source" \
  || ko "coach.md forbids writing to source"
grep -q 'references/data.md' "$CO" && ok "coach.md defers to data.md for the data rules" \
  || ko "coach.md defers to data.md for the data rules"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep FAIL`
Expected: `references/coach.md exists` FAILs, all twelve config-key assertions FAIL, all four
dispatch assertions FAIL.

- [ ] **Step 3: Write `skills/learner/references/coach.md`**

```markdown
# Coach mode — the dev writes, you challenge

Read on a `🧑‍🏫 Coach (…)` trigger, and on `learner coach review`. Read
`references/data.md` once for the data-file rules; do not restate them here.

**Language: mirror the dev**, exactly as everywhere else in this skill. The trigger line is an
English machine parameter list — it is not what the dev reads.

## The regime

The dev writes the code. You do not implement, and a `PreToolUse` hook enforces that: a
`Write`/`Edit` outside the globs the dev delegated is refused. That refusal is the design
working, not an obstacle to route around. If you believe a slice should be yours, say so and
name the glob — the dev runs `learner coach delegate '<glob>'`.

## On a trigger

The trigger carries `level`, `cycle`, `files` and `lines`. Then:

1. **Read `memory.md`** (path in `references/data.md`). Open weak spots decide where to look
   first — the same spaced-repetition pull the quiz has. A dev with `Error and exception
   handling` open should be looked at for error paths before anything else.
2. **Read the diff.** `git diff HEAD -- <the files named in the trigger>`, and read the files
   themselves where the diff alone is not enough to judge.
3. **Produce exactly three things**, in this order and calibrated per § Level below:
   - **One challenge.** A question about a real decision visible in the diff — a split, a name,
     an error path, a data structure. Then **stop and wait for the dev's answer.** Not two
     questions. Not a question with three sub-questions.
   - **Zero to three findings.** A bug, an edge case, a duplication. Each anchored
     `path/file.kt:42`. State the defect, not the fix.
   - **Zero to two leads.** A direction worth exploring. Name the concept or the place to look;
     never write the code.
4. **Never write to a source file.** Not the fix, not a sketch, not "here is what I would do"
   in a code block long enough to paste. If the dev asks for the patch, that is a delegation
   request: point them at `learner coach delegate`.
5. **When the dev answers**, update `memory.md` and `recap.md` exactly as § After every answer
   of `references/data.md` prescribes: `✅ ok` / `⚠️ revisit` / `⏭️ skip`, and `coach` in the
   `Style` column.

The ceiling — one challenge, a short findings list — is deliberate. A wall of text puts the dev
back in the passenger seat by other means.

## Level: depth *and* register

The level decides two things, and they are easy to conflate. **What** the challenge attacks, and
**how** everything is phrased — the challenge, the findings and the leads alike.

| Level | What the challenge attacks | Register |
|-------|---------------------------|----------|
| `D` | What this block is for, what this construct is called | Name and explain each technical term before using it |
| `J` | What the function does, where the code lives | Everyday vocabulary, a concrete example over an abstraction |
| `C` | Why this split, edge cases, error handling | Standard jargon assumed, the basics are not re-explained |
| `S` | Trade-offs, rejected alternatives, perf and coupling | Dense, allusive, no unrequested explanation |
| `E` | Invariants, failure modes, what breaks at scale | Context assumed, a discussion between equals |

The same defect, at two levels:

- `J` — "`UserService.kt:42` — this crashes when the list is empty. What should happen instead?"
- `S` — "`UserService.kt:42` — the empty path is uncovered and it propagates into the mapper."

Calibrating the question while leaving the feedback at a fixed register is the failure this
table exists to prevent.

## On the idle line

`🧑‍🏫 Coach — no tracked changes for N work blocks; the watcher has stopped.` means the watcher
has already exited. Ask the dev, in one line, whether they want to continue the coaching
session. If they do, arm it again with the `Monitor` tool exactly as the `SessionStart` context
described. If they do not, say nothing further about it.

## `learner coach delegate <glob> …`

Write one glob per line to `$TMPDIR/claude-learner-<session-id>.coach-scope`, appending to what
is there. `coach delegate none` removes the file. Report back which globs are now in force.

Globs are matched with shell `case`, in which `*` crosses `/` — so `src/**/repository/**` and
`src/*/repository/*` behave identically. Say so if the dev writes a glob whose precision they
seem to be relying on.

Delegation is session-scoped by design: who does which slice is a per-task decision, and it
should not silently carry over into next week's session.

## `learner coach review [base-ref]`

Run the § On a trigger protocol immediately, off-cadence, against the current material. Get the
material and advance the baseline in one step:

```bash
sh <hooks-dir>/coach-watch.sh "<session-id>" --once --print-material
sh <hooks-dir>/coach-watch.sh "<session-id>" --once --advance
```

Advancing matters: without it the running work block would serve the same material again and
the dev would be challenged twice on one diff.
```

- [ ] **Step 4: Update `skills/learner/SKILL.md`**

Four edits.

**(a)** In the frontmatter `description`, after `"improve" (coach one weak spot to mastery)`,
insert:

```
"coach" (coach mode: the dev writes the code, you challenge it — "coach on"/"off", "coach delegate <glob>", "coach review"),
```

and add these to the trigger list: `"learner coach"`, `"coach on"`, `"coach off"`,
`"coach delegate"`, `"coach review"`, `"mode coach"`, `"passe en mode coach"`,
`"délègue-moi"`, `"challenge-moi"`.

**(b)** In the § Dispatch table, after the `improve` row:

```markdown
| `coach on` / `coach off` | Turn the coach regime on/off in this repo | `references/coach.md` |
| `coach delegate <glob> …` | Let Claude write inside those globs this session; `none` clears | `references/coach.md` |
| `coach review [base-ref]` | Run one review now, off-cadence | `references/coach.md` |
```

And after the "Invoked by the Stop hook" paragraph, add:

```markdown
**Invoked by the coach watcher.** A `Monitor` armed at session start blocks with
`🧑‍🏫 Coach (level: S, cycle: 3, files: 2, lines: 62) — Service.kt Mapper.kt`. When you see it,
read `references/coach.md` and follow it with those values. As with the quiz trigger, the line is
parameters, not the protocol.
```

**(c)** In § Levels, add a third column so the register axis lives beside the depth axis:

```markdown
| Letter | Name | What a question targets | Register (coach) |
|--------|------|-------------------------|------------------|
| `D` | Discovering | syntax, what a block is for, basic vocabulary | name and explain each term before using it |
| `J` | Junior | what the function does, where the code lives | everyday vocabulary, a concrete example over an abstraction |
| `C` | Competent | why this split, edge cases, error handling | standard jargon assumed, basics not re-explained |
| `S` | Senior | trade-offs, rejected alternatives, perf and coupling impact | dense, allusive, no unrequested explanation |
| `E` | Expert | invariants, failure modes, what breaks at scale | context assumed, a discussion between equals |
```

**(d)** In § Config, append to the key table:

```markdown
| `coach` | bool | `false` | Coach regime: the dev writes, Claude challenges |
| `coachCadence` | `pomodoro`/`threshold` | `pomodoro` | Which clock drives reviews |
| `coachWorkMinutes` | int ≥ 1 | `25` | First work block, in minutes |
| `coachWorkGrowthMinutes` | int ≥ 0 | `5` | Added to the work block per completed cycle |
| `coachWorkMaxMinutes` | int ≥ 1 | `45` | Work-block ceiling |
| `coachChallengeMinutes` | int ≥ 0 | `8` | Challenge window, fixed |
| `coachIdleCycles` | int ≥ 1 | `2` | Empty work blocks before the watcher stops |
| `coachPollSeconds` | int ≥ 5 | `45` | Poll interval — `threshold` cadence only |
| `coachLines` | int ≥ 1 | `40` | Lines since last review that trigger one — `threshold` only |
| `coachFiles` | int ≥ 1 | `3` | Changed files that trigger one — `threshold` only |
| `coachEveryMinutes` | int ≥ 0 | `0` | Elapsed-time trigger, `0` = off — `threshold` only |
| `coachCooldownMinutes` | int ≥ 0 | `5` | Floor between two reviews — `threshold` only |
```

and extend the validation sentence with: `coach` boolean; `coachCadence` one of the two words;
every `coach*` integer at or above the floor in the table. `coachWorkMaxMinutes` below
`coachWorkMinutes` clamps to `coachWorkMinutes` rather than being rejected — the intent of that
pair is unambiguous.

Finally, in § Status step 3, add one line to what gets printed: coach on/off, the current cycle,
and the delegated globs, read from
`$TMPDIR/claude-learner-<session-id>.coach-scope` when it exists.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./test.sh`
Expected: PASS, all twelve config-key guards and all four dispatch guards included.

- [ ] **Step 6: Commit**

```bash
git add skills/learner/SKILL.md skills/learner/references/coach.md test.sh
git commit -m "feat(skill): the coach review protocol and its register axis

references/coach.md is what the watcher's trigger line points at: read
memory.md so open weak spots steer the reading, diff the named files, then
produce exactly one challenge, up to three located findings and up to two
leads — and never a patch.

The level now drives two axes rather than one. It already decided what a
question attacks; it now also decides the register everything is written in,
findings and leads included. The same empty-list bug reads as \"this crashes
when the list is empty, what should happen instead\" at J and as \"the empty
path is uncovered and it propagates into the mapper\" at S. Calibrating the
question while leaving the feedback at a fixed register was the gap this closes.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Docs — README and the site

Coach mode is invisible to anyone who does not read the source until it is documented. Three
pages, matching the structure each already has.

**Files:**
- Modify: `README.md`
- Modify: `docs/usage.html`
- Modify: `docs/config.html` — **grouping only**; the twelve rows landed in Task 2 (see Step 5)
- Modify: `test.sh` — doc guards

**Interfaces:**
- Consumes: the config table (Task 2, which also already placed the `config.html` rows), the subcommands (Task 7).
- Produces: nothing.

- [ ] **Step 1: Write the failing tests**

```sh
# --- coach docs -------------------------------------------------------------
grep -qi 'coach' "$ROOT/README.md" && ok "README covers coach mode" || ko "README covers coach mode"
grep -q 'learner coach on' "$ROOT/README.md" \
  && ok "README shows how to turn coach on" || ko "README shows how to turn coach on"
grep -q 'coach delegate' "$ROOT/README.md" \
  && ok "README shows delegation" || ko "README shows delegation"
grep -qi 'coach' "$ROOT/docs/usage.html" && ok "usage.html covers coach mode" \
  || ko "usage.html covers coach mode"
for k in coachCadence coachWorkMinutes coachIdleCycles; do
  grep -q "$k" "$ROOT/docs/config.html" && ok "config.html documents $k" \
    || ko "config.html documents $k"
done
# The interactive-session-only limitation must be stated where a dev will hit it,
# not only in the design doc they will never read.
grep -qi 'interactive' "$ROOT/docs/usage.html" \
  && ok "usage.html states the interactive-session limitation" \
  || ko "usage.html states the interactive-session limitation"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep FAIL`
Expected: every doc assertion FAILs.

- [ ] **Step 3: Add a coach section to `README.md`**

Insert after the section that documents the on-demand commands (find it with
`grep -n '^#' README.md`), keeping the file's existing heading level and prose voice:

```markdown
## Coach mode — you write, Claude challenges

The default regime has Claude write the code and quiz you afterwards. Coach mode inverts it:
you write the code, and Claude watches your working tree and comes back at intervals with one
question, a few findings and a couple of leads — never with a patch.

```
learner coach on
```

From then on, Claude is **denied** write access to your source: a `PreToolUse` hook refuses any
`Write` or `Edit` outside the slice you hand it explicitly.

```
learner coach delegate 'src/**/repository/**'
```

Now Claude writes the repositories — the layer that looks the same in every project — and you
write the service and the business logic. Both regimes feed the same record: Claude quizzes you
on what it wrote, the coach challenges you on what you wrote, and `learner status` sees all of
it.

Reviews arrive on a pomodoro by default: a 25-minute work block in silence, then one
notification, then an ~8-minute challenge window. The work block grows 5 minutes per cycle
(capped at 45) — only for cycles where you actually wrote something. After two consecutive
empty blocks the watcher stops itself and asks whether you want to continue.

Prefer change-driven reviews to time-driven ones? `learner config coachCadence=threshold`, then
tune `coachLines`, `coachFiles` and `coachCooldownMinutes`.

Coach mode needs an interactive Claude Code session: the watcher runs as a `Monitor`, which
does not exist in `claude -p`, in a subagent or in a cloud session. The write refusal still
applies everywhere, since it is an ordinary hook.
```

- [ ] **Step 4: Add a coach section to `docs/usage.html`**

Add a `<h2 id="coach">Coach mode — you write, Claude challenges</h2>` section after the
`<h2 id="commands">On demand</h2>` section, using the same markup vocabulary the existing
sections use (inspect them first with `sed -n '25,80p' docs/usage.html`). Cover, in prose: the
inversion, `learner coach on`, `learner coach delegate '<glob>'`, the pomodoro cadence with its
growth and its idle stop, `learner coach review` for an off-cadence review, and the
interactive-session-only limitation. Add `<a href="#coach">` to whatever in-page navigation the
file already has.

- [ ] **Step 5: Group the coach keys already in `docs/config.html`**

**Scope narrowed by a ruling during execution — read this before you start.** The twelve rows
are already in the table: `test.sh:1670-1689` is a pre-existing invariant that parses
`LEARNER_DEFAULTS` out of `hooks/learner-config.sh` and asserts every key's default appears in
`docs/config.html`, so Task 2 could not land green without adding them. It added twelve plain
rows using the spec's own wording. Three of this task's `config.html` assertions therefore
already pass at the RED step — that is expected, not a sign you have the wrong brief.

Your job here is presentation, not content: group the rows so the pomodoro keys and the
threshold-only keys are visually distinguishable, exactly as the spec's table distinguishes
them, using the same `<td>` structure the existing rows use (inspect with
`sed -n '25,110p' docs/config.html`). Do not restate a default in prose — the invariant above
parses the table, and a second copy of a default is a second thing to keep in sync.

Leave the `learner.json.example` allow-list in `test.sh` alone; Task 2 already widened it.

- [ ] **Step 6: Run the tests, and check the site still renders**

Run: `./test.sh`
Expected: PASS.

Then open `docs/usage.html` and `docs/config.html` in a browser (or
`python3 -m http.server -d docs 8000`) and confirm the new sections match the surrounding
typography and that no tag is left unclosed.

- [ ] **Step 7: Commit**

```bash
git add README.md docs/usage.html docs/config.html test.sh
git commit -m "docs: cover coach mode on the README and the site

The inversion, learner coach on, delegating a slice with a glob, the pomodoro
cadence with its growing work block and its idle stop, and the twelve config
keys.

States the interactive-session-only limitation where a dev will actually hit
it, rather than only in a design doc they will never read: the watcher is a
Monitor and does not exist in claude -p, in a subagent or in a cloud session,
while the write refusal — an ordinary hook — applies everywhere.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Real end-to-end verification

No commits. `test.sh` proves the scripts' logic against synthetic payloads; it cannot prove that
Claude Code arms the watcher, honours the deny, or renders the trigger. Verify the combined
result of Tasks 1–8 for real, the way the plugin work was verified with real installs rather
than code review alone.

**Files:** none.

**Interfaces:**
- Consumes: everything.
- Produces: a written verification report, and either a green light or a list of defects to fix before this branch merges.

- [ ] **Step 1: Validate the plugin manifest still loads**

Run: `claude plugin validate .`
Expected: valid. A malformed `PreToolUse` block in `hooks/hooks.json` fails here.

- [ ] **Step 2: Set up a scratch repo with a fast cadence**

```bash
rm -rf /tmp/coach-e2e && mkdir -p /tmp/coach-e2e/src && cd /tmp/coach-e2e
git init -q && git commit -q --allow-empty -m init
mkdir -p .claude
cat > .claude/learner.local.json <<'JSON'
{ "coach": true, "coachWorkMinutes": 2, "coachWorkGrowthMinutes": 0, "coachChallengeMinutes": 1 }
JSON
```
Make sure your real `~/.claude/learner.json` has a `level` set (any of `D`–`E`), since
`learner_coach_active` requires one.

- [ ] **Step 3: Start a real session and confirm the watcher is armed**

Run: `claude --plugin-dir /path/to/claude-learner-mode` from `/tmp/coach-e2e`
Expected: Claude arms a `Monitor` on `coach-watch.sh` at the start of the session, without being
asked. Confirm with `/tasks` that the monitor is listed and running. Record whether it armed
itself or had to be prompted.

- [ ] **Step 4: Confirm the deny actually blocks**

In that session, ask Claude to edit `src/Service.kt`.
Expected: the write is **refused**, and Claude reports the coach reason including a
copy-pasteable `learner coach delegate` glob. If the write succeeds, the payload shape from
Task 3 is wrong — this is the fail-open case, and it must be fixed before merge.

- [ ] **Step 5: Confirm delegation opens exactly one slice**

Run `learner coach delegate 'src/repository/**'`, then ask Claude to create
`src/repository/UserRepo.kt` **and** to edit `src/Service.kt`.
Expected: the repository write succeeds, the service write is still refused.

- [ ] **Step 6: Confirm a review actually arrives**

Write ~30 lines into `src/Service.kt` yourself, from another terminal, and wait out the
two-minute block.
Expected: a `🧑‍🏫 Coach (…)` notification appears in the session; Claude reads
`references/coach.md` and produces **one** challenge plus a few located findings, at the
register your level calls for; it does **not** produce a patch. Answer the challenge and confirm
`memory.md` and `recap.md` both gain an entry with `coach` in the `Style` column.

- [ ] **Step 7: Confirm the quiz and the coach do not collide**

The `src/repository/UserRepo.kt` that Claude wrote in Step 5 should be quizzed by the existing
`Stop` hook, and must **not** appear in any coach review.
Expected: exactly that split. This is the `SESSION`-log subtraction from Task 4 working end to
end.

- [ ] **Step 8: Confirm the idle stop**

Stop editing and wait out two work blocks (~4 minutes).
Expected: one `the watcher has stopped` notification, Claude asks whether to continue, and
`/tasks` shows the monitor is gone. Confirm nothing further arrives.

- [ ] **Step 9: Confirm coach off is a true no-op**

Set `.claude/learner.local.json` to `{ "coach": false }`, restart the session, and ask Claude to
edit a source file.
Expected: no arming context, no monitor, no refusal, no coach output anywhere. The current
product, byte for byte.

- [ ] **Step 10: Confirm the traditional install path**

Run `./install.sh` into a throwaway `CLAUDE_CONFIG_DIR` and check that `coach-gate.sh` and
`coach-watch.sh` both land in the hooks directory and that the generated `settings.json`
contains the `PreToolUse` block.

```bash
CLAUDE_CONFIG_DIR=/tmp/coach-cfg ./install.sh
ls /tmp/coach-cfg/hooks/coach-*.sh
jq '.hooks.PreToolUse' /tmp/coach-cfg/settings.json
```
Expected: both scripts present, the block wired. A missing script here means every write in
every repo fires a hook against a nonexistent file.

- [ ] **Step 11: Write the verification report**

Record, for each step: what you ran, what happened, and pass/fail. Name any defect found and
whether it was fixed. Do **not** report this plan as complete while any step above failed —
`test.sh` passing is not evidence about the harness's behaviour, which is the entire point of
this task.

---

## Post-plan note (not a task)

Two things this plan deliberately does not do, both recorded in the spec's § Out of scope:

- **Per-hunk authorship.** A file both Claude and the dev touched in one session is attributed
  to Claude and skipped by the coach. A shell script cannot do better, and the conservative
  direction is the right one: reviewing Claude's own code as if it were the dev's would produce
  a challenge the dev cannot answer.
- **Coach in non-interactive sessions.** `Monitor` does not exist there. If a mechanism appears,
  the watcher script itself needs no change — only the arming path in `learner-onboard.sh`.
