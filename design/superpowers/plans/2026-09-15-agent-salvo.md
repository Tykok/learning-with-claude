# Agent salvo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While Claude's subagents run, have the main conversation serve the dev one bounded burst of learning per dispatched agent — two questions plus one fill-in exercise cut for them by a dedicated preparation agent.

**Architecture:** One new POSIX `sh` script, `hooks/learner-agent-track.sh`, wired twice against the `Task` tool (`PreToolUse --start`, `PostToolUse --end`); it keeps three per-session counter files in `TMPDIR` and decides nothing. The existing `Stop` hook, `hooks/learner-quiz.sh`, grows a salvo branch between its `LEARNER-TODO` guardrail and its quiz trigger: while at least one agent is in flight and fewer salvos have been served than agents dispatched, it blocks with a `🤖` trigger instead of the `🎓` one. The protocol behind that trigger is a new skill reference, `skills/learner/references/agent-salvo.md`, which reuses `hook-quiz.md`'s questioning and `fill` rules rather than restating them.

**Tech Stack:** POSIX `sh` (these scripts run under `sh` on macOS and Debian), `jq` for all JSON, `git` for repo detection. Tests are plain `sh`/`bash` assertions appended to the existing `test.sh` — no framework, no network, no sleeping.

**Spec:** `design/superpowers/specs/2026-09-15-agent-salvo-design.md`

## Global Constraints

- Spec: `design/superpowers/specs/2026-09-15-agent-salvo-design.md` — every task implements one or more of its numbered sections. Its "Locked decisions" table is binding; do not re-litigate a decision during implementation.
- **POSIX `sh` only.** No `[[`, no arrays, no `local`, no `$'...'`, no process substitution. Prefix function-local variables with `_` plus a function-specific tag, matching `hooks/learner-config.sh`.
- Every new script starts with `#!/bin/sh` and `# SPDX-License-Identifier: GPL-3.0-or-later`, matching all eight existing hooks. Never write the string `MIT` into a shipped or user-facing file — `test.sh` scans for it.
- Every hook exits **0** on every path that is not a deliberate block. A learner hook must never fail a tool call or a session because `jq` is missing, the repo has no commits, or a config file is malformed.
- `learner-agent-track.sh` **emits nothing on stdout and makes no permission decision.** A `Task` call must run exactly as it would have without it.
- The anti-recursion contract is the one defect in this feature with no bottom: a description starting with `learner-prep:` is never recorded. It is stated in three places (the script header, `references/agent-salvo.md`, `test.sh`) and all three must agree.
- Both `hooks/hooks.json` (plugin install) and `hooks/settings.snippet.json` (curl/clone/brew/apt install) must be updated together whenever hook wiring changes. Forgetting one ships a half-working feature to half the users.
- Trigger lines are **English machine parameters**, like the existing `🎓` and `🧑‍🏫` lines, and stay within **3 lines** (`test.sh` asserts this for the quiz and will for the salvo). The skill renders them to the dev in the dev's own language. There is no language setting and this plan does not add one.
- Levels are the five existing letters `D`/`J`/`C`/`S`/`E` via `learner_level`. The salvo adds no sixth level and no second activation switch: `learner_active` governs it.
- `test.sh` must stay fast (seconds) and offline. Run `./test.sh` before every commit, and `shellcheck hooks/*.sh` if available (CI runs it — see `.github/workflows/ci.yml`).
- Several `test.sh` guards derive ground truth from disk: the hook-count guard (`test.sh:1920-1980`) reads `hooks/*.sh` and `hooks/settings.snippet.json`, and the defaults guard (`test.sh:1845-1870`) reads `LEARNER_DEFAULTS`. Adding a file or a config key turns prose red in README and three site pages. Each task below names the exact strings to update **in the same commit** that trips the guard.

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `hooks/learner-agent-track.sh` | create | Count in-flight subagents; nothing else |
| `hooks/learner-config.sh` | modify | Three new defaults + `learner_salvo_active` |
| `hooks/learner-quiz.sh` | modify | Salvo branch before the quiz branch |
| `hooks/learner-cleanup.sh` | modify | Remove the three new scratch files |
| `hooks/hooks.json` | modify | Two `Task` entries |
| `hooks/settings.snippet.json` | modify | The same two entries, config-dir path form |
| `install.sh` / `uninstall.sh` | modify | Ship / remove the new script |
| `skills/learner/references/agent-salvo.md` | create | The salvo protocol |
| `skills/learner/SKILL.md` | modify | Config keys + the `🤖` trigger |
| `skills/learner/references/coach.md` | modify | One line: a coach challenge outranks a salvo |
| `test.sh` | modify | 14 new assertions |
| `README.md`, `docs/*.html` | modify | User-facing documentation + count guards |

---

### Task 1: Config keys and the activation helper

Spec §5. Three defaults and one helper, so every later task can ask "is the salvo on here?" in one call.

**Files:**
- Modify: `hooks/learner-config.sh:16` (the `LEARNER_DEFAULTS` line) and the helper list in its header comment
- Modify: `hooks/learner-config.sh` (append `learner_salvo_active` after `learner_coach_active`)
- Test: `test.sh` (append to the config-resolution section, near `test.sh:285`)

**Interfaces:**
- Consumes: `learner_active CFG ROOT`, `learner_int RAW FALLBACK FLOOR` (both already in this file)
- Produces: `learner_salvo_active CFG ROOT` → exit 0 when the salvo may run here, 1 otherwise. Config keys `agentSalvo` (bool, default `true`), `agentSalvoQuestions` (int ≥ 0, default `2`), `agentSalvoFill` (bool, default `true`).

- [ ] **Step 1: Write the failing test**

Append to `test.sh`, immediately after the `leading-zero coachWorkMinutes` assertion (ends `test.sh:292`):

```bash
# --- agent salvo: config resolution ------------------------------------------
sactive() { cfgsh 'learner_salvo_active "$(learner_config)" "$(learner_repo_root)" && echo on || echo off'; }

echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"
[ "$(cfgsh 'learner_config | jq -r .agentSalvo')" = "true" ] \
  && ok "agentSalvo defaults to true" || ko "agentSalvo defaults to true"
[ "$(cfgsh 'learner_config | jq -r .agentSalvoQuestions')" = "2" ] \
  && ok "agentSalvoQuestions defaults to 2" || ko "agentSalvoQuestions defaults to 2"
[ "$(cfgsh 'learner_config | jq -r .agentSalvoFill')" = "true" ] \
  && ok "agentSalvoFill defaults to true" || ko "agentSalvoFill defaults to true"

[ "$(sactive)" = "on" ] \
  && ok "the salvo is active with a level set and agentSalvo defaulted" \
  || ko "the salvo is active with a level set and agentSalvo defaulted"

echo '{"level":"S","agentSalvo":false}' > "$GCFG"
[ "$(sactive)" = "off" ] \
  && ok "agentSalvo=false switches the salvo off" || ko "agentSalvo=false switches the salvo off"

echo '{"level":"S","enabled":false}' > "$GCFG"
[ "$(sactive)" = "off" ] \
  && ok "enabled=false switches the salvo off too" || ko "enabled=false switches the salvo off too"

echo '{"agentSalvo":true}' > "$GCFG"
[ "$(sactive)" = "off" ] \
  && ok "no level means no salvo" || ko "no level means no salvo"

# agentSalvoQuestions accepts 0 (exercise-only), so its floor is 0, not 1.
echo '{"level":"S","agentSalvoQuestions":0}' > "$GCFG"
[ "$(cfgsh 'learner_int "$(learner_config | jq -r .agentSalvoQuestions)" 2 0')" = "0" ] \
  && ok "agentSalvoQuestions=0 survives learner_int with floor 0" \
  || ko "agentSalvoQuestions=0 survives learner_int with floor 0"

echo '{"level":"S","agentSalvoQuestions":"many"}' > "$GCFG"
[ "$(cfgsh 'learner_int "$(learner_config | jq -r .agentSalvoQuestions)" 2 0')" = "2" ] \
  && ok "a non-numeric agentSalvoQuestions falls back to 2" \
  || ko "a non-numeric agentSalvoQuestions falls back to 2"

echo '{"level":"S"}' > "$GCFG"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./test.sh 2>&1 | grep -E 'agentSalvo|salvo is active'`
Expected: FAIL lines — `agentSalvo defaults to true` and the rest, because the keys and `learner_salvo_active` do not exist yet.

- [ ] **Step 3: Add the defaults**

In `hooks/learner-config.sh`, replace the `LEARNER_DEFAULTS` assignment with the same JSON plus three keys at the end (single line, as it is today):

```sh
LEARNER_DEFAULTS='{"enabled":true,"questionStyles":"auto","synthesisFrequency":"normal","blanksPerExercise":2,"untrackGlobs":[],"disabledPaths":[],"coach":false,"coachCadence":"pomodoro","coachWorkMinutes":25,"coachWorkGrowthMinutes":5,"coachWorkMaxMinutes":45,"coachChallengeMinutes":8,"coachIdleCycles":2,"coachPollSeconds":45,"coachLines":40,"coachFiles":3,"coachEveryMinutes":0,"coachCooldownMinutes":5,"agentSalvo":true,"agentSalvoQuestions":2,"agentSalvoFill":true}'
```

- [ ] **Step 4: Add the helper**

Append to `hooks/learner-config.sh`, after `learner_coach_work_minutes`:

```sh
# learner_salvo_active CFG ROOT — true when the agent salvo may run here. The
# salvo is the learner regime plus one switch, exactly like the coach: anything
# that silences the quiz (no level, enabled:false, a disabledPaths prefix)
# silences the salvo too. A malformed `agentSalvo` reads as off rather than on:
# a default-true key whose value is garbage should go quiet, not louder.
learner_salvo_active() {
  _lsacfg="$1"
  _lsaroot="$2"
  learner_active "$_lsacfg" "$_lsaroot" || return 1
  [ "$(printf '%s' "$_lsacfg" | jq -r '.agentSalvo')" = "true" ] || return 1
  return 0
}
```

Add one line to the helper list in the file's header comment, after the `learner_coach_work_minutes` line:

```sh
#   learner_salvo_active CFG ROOT   true when the agent salvo may run here
```

- [ ] **Step 5: Run the tests**

Run: `./test.sh`
Expected: the nine new assertions pass, and the pre-existing count stays green — including `config.html's default for …` guards, which do **not** fire yet because the new keys are documented in Task 7. If they do fire, stop: that means the guard reads keys rather than rows, and Task 7 must merge into this one.

> If `./test.sh` reports failures for `config.html's default for agentSalvo…`, the defaults guard iterates `LEARNER_DEFAULTS` keys. In that case, do Task 7 Step 3 (the `config.html` rows) now, in this commit, and note it in the commit body.

- [ ] **Step 6: Commit**

```bash
git add hooks/learner-config.sh test.sh
git commit -m "feat(salvo): add the three agent-salvo config keys"
```

---

### Task 2: The tracker, `--start`

Spec §1.1. Record one line per dispatched agent, and never record the preparation agent.

**Files:**
- Create: `hooks/learner-agent-track.sh`
- Modify: `README.md:22`, `README.md:226`, `docs/index.html:274`, `docs/install.html:241`, `docs/install.html:291`, `docs/safety.html:131`, `docs/safety.html:171` (hook-count prose — the ninth hook file trips `test.sh`'s count guard the moment the file exists)
- Test: `test.sh` (new section after the quiz section, which ends around `test.sh:600`)

**Interfaces:**
- Consumes: `learner_salvo_active CFG ROOT`, `learner_config`, `learner_repo_root` (Task 1)
- Produces: three per-session files in `${TMPDIR:-/tmp}`, all named `claude-learner-<session-id>.<suffix>`:
  - `.agents` — one `<epoch><TAB><description>` line per in-flight agent
  - `.agents-dispatched` — decimal count of dispatches in the current batch
  - `.agents-served` — decimal count of salvos served against that batch (written by Task 4, deleted here)

- [ ] **Step 1: Write the failing test**

Append to `test.sh`, after the quiz section (before `# --- onboarding` if that is what follows; otherwise at the end of the hook sections):

```bash
# --- agent salvo: tracker ----------------------------------------------------
TRACK="$ROOT/hooks/learner-agent-track.sh"
agents()     { echo "$TMPDIR/claude-learner-$1.agents"; }
dispatched() { echo "$TMPDIR/claude-learner-$1.agents-dispatched"; }
served()     { echo "$TMPDIR/claude-learner-$1.agents-served"; }
# $1 session id, $2 description
tstart() { printf '{"session_id":"%s","tool_name":"Task","tool_input":{"description":"%s"}}' \
             "$1" "$2" | sh "$TRACK" --start; }

echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"

SIDA=salvo1
out=$(tstart "$SIDA" "Refactor the repository layer")
[ -z "$out" ] \
  && ok "--start writes nothing to stdout" || ko "--start writes nothing to stdout"
[ "$(grep -c . "$(agents "$SIDA")")" = "1" ] \
  && ok "--start records one in-flight agent" || ko "--start records one in-flight agent"
[ "$(cat "$(dispatched "$SIDA")")" = "1" ] \
  && ok "--start increments the dispatched counter" || ko "--start increments the dispatched counter"
grep -qF 'Refactor the repository layer' "$(agents "$SIDA")" \
  && ok "--start keeps the task description" || ko "--start keeps the task description"

# The anti-recursion contract: the salvo's own preparation agent must not arm a salvo.
SIDP=salvo2
tstart "$SIDP" "learner-prep: cut a fill exercise in Foo.kt"
[ ! -f "$(agents "$SIDP")" ] \
  && ok "a learner-prep: dispatch is never recorded" || ko "a learner-prep: dispatch is never recorded"
tstart "$SIDP" "   learner-prep: leading spaces still count"
[ ! -f "$(agents "$SIDP")" ] \
  && ok "leading whitespace does not defeat the learner-prep: contract" \
  || ko "leading whitespace does not defeat the learner-prep: contract"

# One agent is always one line, whatever the description contains.
SIDM=salvo3
printf '{"session_id":"%s","tool_input":{"description":"two\\nlines\\tand a tab"}}' "$SIDM" \
  | sh "$TRACK" --start
[ "$(grep -c . "$(agents "$SIDM")")" = "1" ] \
  && ok "a multi-line description still records exactly one agent" \
  || ko "a multi-line description still records exactly one agent"

# Every off switch.
SIDX=salvo4
echo '{"level":"S","agentSalvo":false}' > "$GCFG"
tstart "$SIDX" "Some task"
[ ! -f "$(agents "$SIDX")" ] \
  && ok "agentSalvo=false makes --start a no-op" || ko "agentSalvo=false makes --start a no-op"
echo '{"level":"S","enabled":false}' > "$GCFG"
tstart "$SIDX" "Some task"
[ ! -f "$(agents "$SIDX")" ] \
  && ok "enabled=false makes --start a no-op" || ko "enabled=false makes --start a no-op"
printf '{"level":"S","disabledPaths":["%s"]}' "$WORK/proj" > "$GCFG"
tstart "$SIDX" "Some task"
[ ! -f "$(agents "$SIDX")" ] \
  && ok "a disabledPaths prefix makes --start a no-op" || ko "a disabledPaths prefix makes --start a no-op"

# An unknown flag, or none, is a no-op rather than a crash.
echo '{"level":"S"}' > "$GCFG"
SIDF=salvo5
printf '{"session_id":"%s","tool_input":{"description":"x"}}' "$SIDF" | sh "$TRACK" >/dev/null 2>&1
[ ! -f "$(agents "$SIDF")" ] \
  && ok "the tracker with no flag is a no-op" || ko "the tracker with no flag is a no-op"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./test.sh 2>&1 | grep -E '^\s+(ok|FAIL)\s+- (--start|a learner-prep|leading whitespace|a multi-line|agentSalvo=false makes|enabled=false makes|a disabledPaths prefix|the tracker with no flag)'`
Expected: FAIL throughout — `hooks/learner-agent-track.sh` does not exist.

- [ ] **Step 3: Write the tracker**

Create `hooks/learner-agent-track.sh`:

```sh
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# PreToolUse / PostToolUse on Task: count the subagents currently in flight, so
# hooks/learner-quiz.sh can serve one "agent salvo" per dispatched agent while
# the dev has nothing to do but wait for a result.
#
#   --start  (PreToolUse)   one agent was just dispatched
#   --end    (PostToolUse)  one agent came back
#
# It emits nothing and decides nothing: a Task call must run exactly as it would
# have without this hook.
#
# ANTI-RECURSION CONTRACT — the salvo's own exercise-preparation agent is itself
# a Task. Its description starts with `learner-prep:` and is never recorded here.
# Recording it would arm a salvo, whose preparation agent would arm another
# salvo, with no bottom. The same contract is stated in
# skills/learner/references/agent-salvo.md and pinned by test.sh.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

MODE="${1:-}"
case "$MODE" in --start|--end) ;; *) exit 0 ;; esac

DATA=$(cat)
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""')
[ -n "$SID" ] || exit 0

TMPD="${TMPDIR:-/tmp}"
AGENTS="$TMPD/claude-learner-${SID}.agents"
DISPATCHED="$TMPD/claude-learner-${SID}.agents-dispatched"
SERVED="$TMPD/claude-learner-${SID}.agents-served"

if [ "$MODE" = "--end" ]; then
  # Deliberately NOT gated on learner_salvo_active: a key switched off mid-session
  # must still drain the counters rather than freeze them at a stale value that
  # would serve salvos again the moment it is switched back on.
  if [ -s "$AGENTS" ]; then
    REST=$(sed '1d' "$AGENTS")
    if [ -n "$REST" ]; then
      printf '%s\n' "$REST" > "$AGENTS"
      exit 0
    fi
  fi
  # Nothing left in flight: the batch is over and its three files die together.
  rm -f "$AGENTS" "$DISPATCHED" "$SERVED"
  exit 0
fi

CFG=$(learner_config)
ROOT=$(learner_repo_root)
learner_salvo_active "$CFG" "$ROOT" || exit 0

# One agent is one line, so the description is flattened and bounded before it
# is written: a newline in it would otherwise read as a second agent in flight.
DESC=$(printf '%s' "$DATA" | jq -r '.tool_input.description // ""' \
  | tr '\n' ' ' | tr '\t' ' ' | cut -c1-200)

# Strip leading blanks before the prefix test — "  learner-prep: …" is the same
# contract as "learner-prep: …", and an agent that slips through it is the one
# failure in this feature with no bottom.
TRIM=${DESC#"${DESC%%[! ]*}"}
case "$TRIM" in learner-prep:*) exit 0 ;; esac

printf '%s\t%s\n' "$(date +%s)" "$DESC" >> "$AGENTS"

ND=$(cat "$DISPATCHED" 2>/dev/null); case "$ND" in ''|*[!0-9]*) ND=0 ;; esac
echo $((ND + 1)) > "$DISPATCHED"
exit 0
```

Then: `chmod +x hooks/learner-agent-track.sh`

- [ ] **Step 4: Update the hook-count prose (the ninth file trips the guard)**

Five prose spots state how many hook files ship. With `learner-agent-track.sh` on disk the count is **nine**. Make exactly these replacements (`eight` → `nine`, `Eight` → `Nine`):

- `README.md:22` — `Eight POSIX \`sh\` hooks plus a \`learner\` skill:` → `Nine POSIX \`sh\` hooks plus a \`learner\` skill:`
- `README.md:226` — `covers all eight shipped hook files` → `covers all nine shipped hook files`
- `docs/index.html:274` — `One skill and eight POSIX <code>sh</code> hooks` → `nine`
- `docs/install.html:241` — `Eight hook files ship and six are wired` → `Nine hook files ship and six are wired` (the *wired* count changes in Task 5, not here)
- `docs/install.html:291` — the same footer blurb as index.html → `nine`
- `docs/safety.html:131` — `the eight hook files, the skill,` → `the nine hook files, the skill,`
- `docs/safety.html:171` — the same footer blurb → `nine`

Also add the new row to `docs/install.html`'s "what gets installed" table — the guard asserts every shipped hook file is named there as `hooks/<basename>`:

```html
<tr><td><code>hooks/learner-agent-track.sh</code></td><td>Counts the subagents in flight so the salvo knows when you are waiting</td></tr>
```

Match the surrounding rows' exact markup; copy the shape of the `hooks/coach-watch.sh` row rather than inventing one.

- [ ] **Step 5: Run the tests**

Run: `./test.sh`
Expected: the new tracker assertions pass, and the hook-count guard prints `ok` for all five prose spots plus `install.html's table lists learner-agent-track.sh`. `install.html's ship/wired counts match disk (9 ship, 6 wired)` must be `ok`.

Run: `shellcheck hooks/learner-agent-track.sh`
Expected: clean. `SC2034` on an unused variable means a typo — fix, do not suppress.

- [ ] **Step 6: Commit**

```bash
git add hooks/learner-agent-track.sh test.sh README.md docs/index.html docs/install.html docs/safety.html
git commit -m "feat(salvo): track dispatched subagents on PreToolUse Task"
```

---

### Task 3: The tracker, `--end`

Spec §1.2. One agent back, one line gone; the last one back takes the whole batch with it.

**Files:**
- Modify: `hooks/learner-agent-track.sh` (already written in Task 2 — this task only proves the `--end` half)
- Test: `test.sh` (append to the tracker section from Task 2)

**Interfaces:**
- Consumes: the three files produced in Task 2
- Produces: nothing new. On the last `--end`, `.agents`, `.agents-dispatched` and `.agents-served` are all removed.

- [ ] **Step 1: Write the failing test**

Append to `test.sh`'s tracker section:

```bash
# $1 session id
tend() { printf '{"session_id":"%s","tool_name":"Task"}' "$1" | sh "$TRACK" --end; }

echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"

SIDE=salvo6
tstart "$SIDE" "Agent one"; tstart "$SIDE" "Agent two"; tstart "$SIDE" "Agent three"
[ "$(grep -c . "$(agents "$SIDE")")" = "3" ] \
  && ok "three dispatches are three in-flight lines" || ko "three dispatches are three in-flight lines"

tend "$SIDE"
[ "$(grep -c . "$(agents "$SIDE")")" = "2" ] \
  && ok "--end removes exactly one in-flight line" || ko "--end removes exactly one in-flight line"
grep -qF 'Agent one' "$(agents "$SIDE")" \
  && ko "--end removes the oldest line first (FIFO)" || ok "--end removes the oldest line first (FIFO)"
[ "$(cat "$(dispatched "$SIDE")")" = "3" ] \
  && ok "--end leaves the dispatched counter alone while agents remain" \
  || ko "--end leaves the dispatched counter alone while agents remain"

echo 2 > "$(served "$SIDE")"
tend "$SIDE"; tend "$SIDE"
{ [ ! -f "$(agents "$SIDE")" ] && [ ! -f "$(dispatched "$SIDE")" ] && [ ! -f "$(served "$SIDE")" ]; } \
  && ok "the last --end deletes all three batch files" \
  || ko "the last --end deletes all three batch files"

# A dev who switches the key off mid-flight must not be left with frozen counters.
SIDD=salvo7
tstart "$SIDD" "In flight when the key flips"
echo '{"level":"S","agentSalvo":false}' > "$GCFG"
tend "$SIDD"
[ ! -f "$(agents "$SIDD")" ] \
  && ok "--end drains the counters even with agentSalvo=false" \
  || ko "--end drains the counters even with agentSalvo=false"

# An --end with nothing in flight is harmless.
echo '{"level":"S"}' > "$GCFG"
SIDN=salvo8
tend "$SIDN"
[ ! -f "$(agents "$SIDN")" ] \
  && ok "--end with no batch in flight is a no-op" || ko "--end with no batch in flight is a no-op"
```

- [ ] **Step 2: Run it and check**

Run: `./test.sh 2>&1 | grep -E '\- (three dispatches|--end )'`
Expected: every listed assertion passes — the `--end` branch was written in Task 2 Step 3. **If any fails, fix the script, not the test:** the most likely defects are `sed '1d'` on a file with no trailing newline (use the `REST` round-trip exactly as written) and deleting `.agents` before reading it.

- [ ] **Step 3: Commit**

```bash
git add test.sh
git commit -m "test(salvo): pin the tracker's --end drain and FIFO order"
```

---

### Task 4: The Stop-hook salvo branch

Spec §2. The heart of the feature: one salvo per dispatched agent, only while one is in flight, ahead of the quiz and behind the guardrail.

**Files:**
- Modify: `hooks/learner-quiz.sh:80-119` (insert the salvo branch; move the `LEVEL`/`STYLES`/`BLANKS` resolution above the pending-edits early exit)
- Test: `test.sh` (append to the tracker section)

**Interfaces:**
- Consumes: `.agents`, `.agents-dispatched` (Task 2), `learner_salvo_active`, `learner_coach_active`, `learner_int`, `learner_level` (Task 1 and existing)
- Produces: the `🤖` trigger line, consumed by `references/agent-salvo.md` (Task 6):

```
🤖 Learner salvo (level: S, questions: 2, blanks: 2, styles: auto, agent 2/3, coach: off) — task: <description> — files: a.kt b.kt
Invoke the `learner` skill and follow references/agent-salvo.md. Ask ONE question at a time, then wait for the dev's answer.
```

- [ ] **Step 1: Write the failing test**

Append to `test.sh`'s tracker section (`quiz()` is already defined at `test.sh:522`):

```bash
# --- agent salvo: the Stop-hook branch ---------------------------------------
echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"

SIDS1=salvoq1
tstart "$SIDS1" "Port the mapper to the new DTO"
out=$(quiz "$SIDS1")
reason=$(echo "$out" | jq -r '.reason')
echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && ok "the salvo blocks with an agent in flight and no edits pending" \
  || ko "the salvo blocks with an agent in flight and no edits pending"
printf '%s' "$reason" | grep -qF '🤖 Learner salvo' \
  && ok "the salvo trigger is distinguishable from the quiz trigger" \
  || ko "the salvo trigger is distinguishable from the quiz trigger"
printf '%s' "$reason" | grep -qF 'references/agent-salvo.md' \
  && ok "the salvo trigger points at its own protocol" \
  || ko "the salvo trigger points at its own protocol"
printf '%s' "$reason" | grep -qF 'agent 1/1' \
  && ok "the salvo trigger carries its rank in the batch" \
  || ko "the salvo trigger carries its rank in the batch"
printf '%s' "$reason" | grep -qF 'level: S' \
  && ok "the salvo trigger carries the canonical level letter" \
  || ko "the salvo trigger carries the canonical level letter"
printf '%s' "$reason" | grep -qF 'questions: 2' \
  && ok "the salvo trigger carries the question count" \
  || ko "the salvo trigger carries the question count"
printf '%s' "$reason" | grep -qF 'coach: off' \
  && ok "the salvo trigger states the coach regime" \
  || ko "the salvo trigger states the coach regime"
printf '%s' "$reason" | grep -qF 'Port the mapper to the new DTO' \
  && ok "the salvo trigger carries the delegated task" \
  || ko "the salvo trigger carries the delegated task"
lines=$(printf '%s\n' "$reason" | wc -l | tr -d ' ')
[ "$lines" -le 3 ] \
  && ok "the salvo reason stays within 3 lines" || ko "the salvo reason stays within 3 lines (got $lines)"
printf '%s' "$reason" | grep -qiE 'memory\.md|spaced repetition|preparation agent' \
  && ko "the salvo reason carries no protocol prose" \
  || ok "the salvo reason carries no protocol prose"

# One salvo per dispatched agent, then the quiz takes over.
SIDS2=salvoq2
tstart "$SIDS2" "A"; tstart "$SIDS2" "B"; tstart "$SIDS2" "C"
n=0
for i in 1 2 3 4; do
  printf '%s' "$(quiz "$SIDS2" | jq -r '.reason // ""')" | grep -qF '🤖' && n=$((n + 1))
done
[ "$n" = "3" ] \
  && ok "three dispatched agents earn exactly three salvos" \
  || ko "three dispatched agents earn exactly three salvos (got $n)"

# No agent in flight, no salvo — even with a stale dispatched counter.
SIDS3=salvoq3
tstart "$SIDS3" "A"; tstart "$SIDS3" "B"; tstart "$SIDS3" "C"
tend "$SIDS3"; tend "$SIDS3"; tend "$SIDS3"
echo 3 > "$(dispatched "$SIDS3")"   # stale on purpose
printf '%s' "$(quiz "$SIDS3" | jq -r '.reason // ""')" | grep -qF '🤖' \
  && ko "an empty in-flight list serves no salvo" || ok "an empty in-flight list serves no salvo"

# The salvo consumes pending edits, exactly as the quiz does.
SIDS4=salvoq4
rec "$SIDS4" "$WORK/proj/src/Salvo.kt"
tstart "$SIDS4" "Some delegation"
printf '%s' "$(quiz "$SIDS4" | jq -r '.reason')" | grep -qF 'Salvo.kt' \
  && ok "the salvo trigger carries the pending edits" || ko "the salvo trigger carries the pending edits"
[ -s "$(edits "$SIDS4")" ] \
  && ko "the salvo consumes the pending edits" || ok "the salvo consumes the pending edits"

# The coach regime reaches the trigger and turns the exercise off downstream.
SIDS5=salvoq5
echo '{"level":"S","coach":true}' > "$GCFG"
tstart "$SIDS5" "Delegated slice"
printf '%s' "$(quiz "$SIDS5" | jq -r '.reason')" | grep -qF 'coach: on' \
  && ok "coach mode is announced on the salvo trigger" || ko "coach mode is announced on the salvo trigger"

# Nothing to ask: no questions and no exercise means fall through, not an empty block.
SIDS6=salvoq6
echo '{"level":"S","coach":true,"agentSalvoQuestions":0}' > "$GCFG"
tstart "$SIDS6" "Delegated slice"
printf '%s' "$(quiz "$SIDS6" | jq -r '.reason // ""')" | grep -qF '🤖' \
  && ko "a salvo with no questions and no exercise does not block" \
  || ok "a salvo with no questions and no exercise does not block"

# A malformed count must never reach the trigger as an empty field.
SIDS7=salvoq7
echo '{"level":"S","agentSalvoQuestions":"many"}' > "$GCFG"
tstart "$SIDS7" "Delegated slice"
printf '%s' "$(quiz "$SIDS7" | jq -r '.reason')" | grep -qF 'questions: 2' \
  && ok "a malformed agentSalvoQuestions falls back to 2 on the trigger" \
  || ko "a malformed agentSalvoQuestions falls back to 2 on the trigger"

# The guardrail still outranks everything.
SIDS8=salvoq8
echo '{"level":"S"}' > "$GCFG"
mkdir -p "$WORK/proj/src"   # earlier tests only record paths; the file must really exist here
printf 'fun f() {\n  // LEARNER-TODO: the body\n}\n' > "$WORK/proj/src/Hole.kt"
tstart "$SIDS8" "Delegated slice"
printf '%s' "$(quiz "$SIDS8" | jq -r '.reason')" | grep -qF 'LEARNER-TODO' \
  && ok "the LEARNER-TODO guardrail still outranks a pending salvo" \
  || ko "the LEARNER-TODO guardrail still outranks a pending salvo"
rm -f "$WORK/proj/src/Hole.kt"

# The quiz still works when nothing is in flight.
SIDS9=salvoq9
rec "$SIDS9" "$WORK/proj/src/Plain.kt"
printf '%s' "$(quiz "$SIDS9" | jq -r '.reason')" | grep -qF '🎓 Learner (' \
  && ok "the quiz trigger is untouched when no agent is in flight" \
  || ko "the quiz trigger is untouched when no agent is in flight"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./test.sh 2>&1 | grep -E '\- (the salvo|three dispatched agents earn|an empty in-flight|coach mode is announced|a salvo with no questions|a malformed agentSalvo|the LEARNER-TODO guardrail still|the quiz trigger is untouched)'`
Expected: FAIL on every salvo assertion; the guardrail and quiz ones already pass.

- [ ] **Step 3: Move the trigger-parameter resolution above the early exit**

In `hooks/learner-quiz.sh`, cut lines 88-98 and re-order them so the level, styles and blanks are resolved **before** the pending-edits check — the salvo needs them on a turn that edited nothing. The region from the `stop_hook_active` check down to `EVERY=` becomes:

```sh
ACTIVE=$(printf '%s' "$DATA" | jq -r '.stop_hook_active // false')
[ "$ACTIVE" = "true" ] && exit 0

# Resolved before the pending-edits check below, because the agent salvo needs
# them on a turn that edited nothing at all — which is exactly the turn that
# only dispatched subagents.
LEVEL=$(learner_level "$(printf '%s' "$CFG" | jq -r '.level // empty')")
STYLES=$(printf '%s' "$CFG" | jq -r '
  if (.questionStyles | type) == "array"
  then (.questionStyles | join(","))
  else (.questionStyles // "auto") end')
case "$STYLES" in ''|null) STYLES=auto ;; esac
BLANKS=$(printf '%s' "$CFG" | jq -r '.blanksPerExercise // 2')
case "$BLANKS" in ''|*[!0-9]*) BLANKS=2 ;; esac
[ "$BLANKS" -lt 1 ] && BLANKS=1
```

- [ ] **Step 4: Insert the salvo branch**

Immediately after that block, and **before** `[ -s "$STATE" ] || exit 0`, insert:

```sh
# --- 3) Agent salvo ---------------------------------------------------------
# While a subagent is in flight the main conversation has nothing to do but
# wait, which is the best teaching window a session offers: serve one salvo per
# dispatched agent, then fall through to the quiz. Deliberately ahead of the
# pending-edits check and deliberately behind the guardrail above.
AGENTS="$TMPD/claude-learner-${SID}.agents"
DISPATCHED="$TMPD/claude-learner-${SID}.agents-dispatched"
SERVED="$TMPD/claude-learner-${SID}.agents-served"

if learner_salvo_active "$CFG" "$ROOT" && [ -s "$AGENTS" ]; then
  # grep -c rather than wc -l: a last line with no trailing newline still counts.
  INFLIGHT=$(grep -c . "$AGENTS" 2>/dev/null); case "$INFLIGHT" in ''|*[!0-9]*) INFLIGHT=0 ;; esac
  ND=$(cat "$DISPATCHED" 2>/dev/null); case "$ND" in ''|*[!0-9]*) ND=0 ;; esac
  NS=$(cat "$SERVED" 2>/dev/null); case "$NS" in ''|*[!0-9]*) NS=0 ;; esac

  QN=$(learner_int "$(printf '%s' "$CFG" | jq -r '.agentSalvoQuestions // empty')" 2 0)
  FILL=$(printf '%s' "$CFG" | jq -r '.agentSalvoFill')
  COACH=off
  learner_coach_active "$CFG" "$ROOT" && COACH=on

  # No questions AND no exercise is an empty salvo. Don't spend the turn's one
  # block on it — the quiz below may still have something to ask.
  EMPTY=0
  if [ "$QN" -eq 0 ]; then
    if [ "$FILL" != "true" ] || [ "$COACH" = "on" ]; then EMPTY=1; fi
  fi

  if [ "$INFLIGHT" -gt 0 ] && [ "$NS" -lt "$ND" ] && [ "$EMPTY" -eq 0 ]; then
    NS=$((NS + 1)); echo "$NS" > "$SERVED"
    # The most recent dispatch is the delegation the dev just watched Claude make.
    TASK=$(tail -n 1 "$AGENTS" | cut -f2-)
    SFILES=''
    [ -s "$STATE" ] && SFILES=$(sort -u "$STATE" | head -n 20 | tr '\n' ' ')

    SREASON="🤖 Learner salvo (level: $LEVEL, questions: $QN, blanks: $BLANKS, styles: $STYLES, agent $NS/$ND, coach: $COACH) — task: $TASK — files: $SFILES
Invoke the \`learner\` skill and follow references/agent-salvo.md. Ask ONE question at a time, then wait for the dev's answer."

    # Same batch discipline as the quiz: one channel per batch of edits, never two.
    : > "$STATE"

    jq -n --arg r "$SREASON" '{decision:"block", reason:$r}'
    exit 0
  fi
fi

```

Renumber the following comment banner from `# --- 2) Quiz trigger` to `# --- 4) Quiz trigger`, and the guardrail's from `# --- 1)` — leave `1` and add the salvo as `3`? No: keep it simple and correct — the banners become `1) LEARNER-TODO guardrail`, `2) Agent salvo`, `3) Quiz trigger`. Update the file's header comment, which today says "two jobs", to "three jobs" and describe the salvo in one sentence.

- [ ] **Step 5: Run the tests**

Run: `./test.sh`
Expected: all salvo assertions pass and the entire pre-existing suite stays green — in particular `quiz blocks once when edits are pending`, `first question is granular` and the synthesis cadence tests, which prove the moved parameter block did not change quiz behaviour.

Run: `shellcheck hooks/learner-quiz.sh`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add hooks/learner-quiz.sh test.sh
git commit -m "feat(salvo): serve one salvo per in-flight agent from the Stop hook"
```

---

### Task 5: Wiring, cleanup and the installers

Spec §6 and §7. Until this task the feature exists but nothing calls it.

**Files:**
- Modify: `hooks/learner-cleanup.sh:15-22` (the `rm -f` list)
- Modify: `hooks/hooks.json` (a `PreToolUse` and a `PostToolUse` entry, matcher `Task`)
- Modify: `hooks/settings.snippet.json` (the same two)
- Modify: `install.sh:132-133` (hook copy list)
- Modify: `uninstall.sh:110-116` and `uninstall.sh:138-147` (both removal lists)
- Modify: `docs/install.html:241` (the *wired* count: six → eight)
- Test: `test.sh` (append to the tracker section)

**Interfaces:**
- Consumes: `hooks/learner-agent-track.sh` (Task 2)
- Produces: the hooks actually fire in a real session. No new interface.

- [ ] **Step 1: Write the failing test**

Append to `test.sh`'s salvo section:

```bash
# --- agent salvo: wiring and cleanup -----------------------------------------
for f in "$ROOT/hooks/hooks.json" "$ROOT/hooks/settings.snippet.json"; do
  b=$(basename "$f")
  jq -e '[.hooks.PreToolUse[] | select(.matcher == "Task") | .hooks[].command]
         | map(select(test("learner-agent-track.sh"))) | length == 1' "$f" >/dev/null 2>&1 \
    && ok "$b wires the tracker on PreToolUse Task" || ko "$b wires the tracker on PreToolUse Task"
  jq -e '[.hooks.PostToolUse[] | select(.matcher == "Task") | .hooks[].command]
         | map(select(test("learner-agent-track.sh"))) | length == 1' "$f" >/dev/null 2>&1 \
    && ok "$b wires the tracker on PostToolUse Task" || ko "$b wires the tracker on PostToolUse Task"
  jq -e '[.. | .command? // empty] | map(select(test("learner-agent-track.sh --start"))) | length == 1' "$f" \
    >/dev/null 2>&1 \
    && ok "$b passes --start exactly once" || ko "$b passes --start exactly once"
  jq -e '[.. | .command? // empty] | map(select(test("learner-agent-track.sh --end"))) | length == 1' "$f" \
    >/dev/null 2>&1 \
    && ok "$b passes --end exactly once" || ko "$b passes --end exactly once"
  # The Task matcher must not sweep in Write/Edit, or every edit would look like an agent.
  jq -e '[.hooks.PostToolUse[] | select(.matcher == "Write|Edit") | .hooks[].command]
         | map(select(test("learner-agent-track.sh"))) | length == 0' "$f" >/dev/null 2>&1 \
    && ok "$b keeps the tracker out of the Write|Edit matcher" \
    || ko "$b keeps the tracker out of the Write|Edit matcher"
done

grep -qF 'learner-agent-track.sh' "$ROOT/install.sh" \
  && ok "install.sh copies the tracker" || ko "install.sh copies the tracker"
[ "$(grep -cF 'learner-agent-track.sh' "$ROOT/uninstall.sh")" = "2" ] \
  && ok "uninstall.sh removes the tracker from both install shapes" \
  || ko "uninstall.sh removes the tracker from both install shapes"

SIDC=salvoc1
echo '{"level":"S"}' > "$GCFG"
tstart "$SIDC" "Something"
echo 1 > "$(served "$SIDC")"
printf '{"session_id":"%s"}' "$SIDC" | sh "$CLEAN"
{ [ ! -f "$(agents "$SIDC")" ] && [ ! -f "$(dispatched "$SIDC")" ] && [ ! -f "$(served "$SIDC")" ]; } \
  && ok "SessionEnd cleans up the three salvo files" \
  || ko "SessionEnd cleans up the three salvo files"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./test.sh 2>&1 | grep -E '\- (hooks.json|settings.snippet.json|install.sh copies|uninstall.sh removes|SessionEnd cleans)'`
Expected: FAIL on all of them.

- [ ] **Step 3: Wire `hooks/hooks.json`**

Add a second `PreToolUse` block and a second `PostToolUse` block. A separate matcher block is clearer than widening the existing `Write|Edit` ones, and the tracker must never see a `Write` event:

```json
    "PreToolUse": [
      {
        "matcher": "Write|Edit|NotebookEdit",
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/coach-gate.sh\"", "timeout": 10 }
        ]
      },
      {
        "matcher": "Task",
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/learner-agent-track.sh\" --start", "timeout": 10 }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/learner-record-edit.sh\"", "timeout": 10 }
        ]
      },
      {
        "matcher": "Task",
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/learner-agent-track.sh\" --end", "timeout": 10 }
        ]
      }
    ],
```

- [ ] **Step 4: Wire `hooks/settings.snippet.json`**

The same two blocks, in this file's path form and its expanded formatting:

```json
      {
        "matcher": "Task",
        "hooks": [
          {
            "type": "command",
            "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/learner-agent-track.sh\" --start",
            "timeout": 10
          }
        ]
      }
```

and the `--end` twin under `PostToolUse`.

- [ ] **Step 5: Cleanup and installers**

In `hooks/learner-cleanup.sh`, add three paths to the `rm -f` list, after `.coach-last`:

```sh
      "$DIR/claude-learner-${SID}.agents" \
      "$DIR/claude-learner-${SID}.agents-dispatched" \
      "$DIR/claude-learner-${SID}.agents-served"
```

In `install.sh`, extend the copy loop's file list:

```sh
for h in learner-config.sh learner-onboard.sh learner-record-edit.sh \
         learner-quiz.sh learner-cleanup.sh learner-update-check.sh \
         coach-gate.sh coach-watch.sh learner-agent-track.sh; do
```

In `uninstall.sh`, add `"$TARGET/.claude/hooks/learner-agent-track.sh" \` to the legacy per-project `rm -f` list and `"$CFG_DIR/hooks/learner-agent-track.sh" \` to the config-dir one.

In `docs/install.html:241`, the wired count is now eight: `Nine hook files ship and eight are wired`. Check the sentence that follows it, which enumerates the events — add `PreToolUse`/`PostToolUse` on `Task` to that enumeration so the prose matches the JSON.

- [ ] **Step 6: Run the tests**

Run: `./test.sh`
Expected: green, including `install.html's ship/wired counts match disk (9 ship, 8 wired)`. A failure there means the `wired_n` the guard counts (`[.. | .command? // empty] | length` over `settings.snippet.json`) is not 8 — recount rather than editing the prose to match a wrong number.

- [ ] **Step 7: Commit**

```bash
git add hooks/hooks.json hooks/settings.snippet.json hooks/learner-cleanup.sh install.sh uninstall.sh docs/install.html test.sh
git commit -m "feat(salvo): wire the tracker on Task and clean up after it"
```

---

### Task 6: The skill protocol

Spec §3 and §4. The trigger is parameters; this task is the protocol behind it.

**Files:**
- Create: `skills/learner/references/agent-salvo.md`
- Modify: `skills/learner/SKILL.md` (config table, the `🤖` trigger paragraph, the `description` front-matter)
- Modify: `skills/learner/references/coach.md` (one paragraph: a coach challenge outranks a salvo)
- Test: `test.sh` (append to the salvo section)

**Interfaces:**
- Consumes: the `🤖` trigger from Task 4
- Produces: nothing machine-readable. The contract that matters is that the preparation agent's description starts with `learner-prep:`, which Task 2's tracker enforces.

- [ ] **Step 1: Write the failing test**

Append to `test.sh`'s salvo section:

```bash
# --- agent salvo: the skill protocol -----------------------------------------
SALVO_REF="$ROOT/skills/learner/references/agent-salvo.md"
SKILLMD="$ROOT/skills/learner/SKILL.md"

[ -f "$SALVO_REF" ] \
  && ok "the salvo protocol reference exists" || ko "the salvo protocol reference exists"
grep -qF 'learner-prep:' "$SALVO_REF" \
  && ok "the protocol states the anti-recursion contract" \
  || ko "the protocol states the anti-recursion contract"
grep -qF 'hook-quiz.md' "$SALVO_REF" \
  && ok "the protocol defers to hook-quiz.md instead of restating it" \
  || ko "the protocol defers to hook-quiz.md instead of restating it"
grep -qF 'data.md' "$SALVO_REF" \
  && ok "the protocol defers to data.md for the record files" \
  || ko "the protocol defers to data.md for the record files"
grep -qiF 'coach' "$SALVO_REF" \
  && ok "the protocol covers the coach-mode case" || ko "the protocol covers the coach-mode case"

grep -qF '🤖' "$SKILLMD" \
  && ok "SKILL.md documents the salvo trigger" || ko "SKILL.md documents the salvo trigger"
grep -qF 'references/agent-salvo.md' "$SKILLMD" \
  && ok "SKILL.md points at the salvo protocol" || ko "SKILL.md points at the salvo protocol"
for k in agentSalvo agentSalvoQuestions agentSalvoFill; do
  grep -qF "$k" "$SKILLMD" && ok "SKILL.md documents $k" || ko "SKILL.md documents $k"
done
grep -qiF 'salvo' "$ROOT/skills/learner/references/coach.md" \
  && ok "coach.md states which channel wins when both land" \
  || ko "coach.md states which channel wins when both land"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./test.sh 2>&1 | grep -E '\- (the salvo protocol|the protocol|SKILL.md documents|SKILL.md points|coach.md states)'`
Expected: FAIL on all of them.

- [ ] **Step 3: Write `skills/learner/references/agent-salvo.md`**

```markdown
# Agent salvo — questions while the subagents work

Read on a `🤖 Learner salvo (…)` trigger. Read `references/data.md` once for the data-file
rules and `references/hook-quiz.md` for the questioning rules; this file does not restate
either — three channels drifting apart is exactly what restating them causes.

**Language: mirror the dev**, as everywhere else in this skill. The trigger line is an English
machine parameter list; it is not what the dev reads.

## Why this exists

Claude has just delegated work to one or more subagents. Until they return, the main
conversation has nothing to do and the dev is a spectator — with the decision that produced the
delegation still fresh and the code the agents will touch still unmodified. That window is the
best teaching material a session produces, and it expires when the agents come back.

The salvo is **bounded**: `questions` questions, then one exercise, then silence. It does not
refill while the agents keep working. A dev who wanted an endless quiz would have asked for one.

## The trigger

`🤖 Learner salvo (level: S, questions: 2, blanks: 2, styles: auto, agent 2/3, coach: off) — task: … — files: …`

| Field | Meaning |
|-------|---------|
| `level` | Difficulty and register — the level table in `SKILL.md` |
| `questions` | How many questions to ask before the exercise. May be `0` |
| `blanks` | Holes to cut in the exercise |
| `styles` | Allowed question formats, as in `hook-quiz.md` |
| `agent N/M` | This salvo's rank in the current batch of dispatches |
| `coach` | `on` means no exercise — see § The exercise |
| `task` | The description of the most recently dispatched agent still in flight |
| `files` | Files edited since the last question, possibly empty |

## Order of operations

1. **Launch the preparation agent first** (§ The exercise), unless `coach: on` or the exercise
   is off. It works while the dev answers, which is the entire reason the exercise comes last.
2. **Read `memory.md`** (path in `references/data.md`). Open weak spots pull the choice of
   question, the same spaced repetition the quiz and the coach use.
3. **Ask `questions` questions, one at a time.** Wait for each answer and give brief feedback
   before the next. Never two at once, never a question with sub-questions.
4. **Run the exercise** when the preparation agent reports.
5. **Record** every answer in `memory.md` and `recap.md` per `references/data.md` § *After every
   answer*, with `salvo` in the `Style` column.

`references/hook-quiz.md` § *Never hand the answer over* applies in full. A question that
quotes both sides of a hunk has already answered itself, and the failure is invisible from
here — the answer comes back correct.

## Material

All four sources are in scope. The order is what to reach for first when several apply.

1. **The delegated task** — from `task:`. Why this slice was split off, what its output has to
   satisfy, which failure mode it invites. No other channel can reach this material, and it is
   fresh for exactly as long as the agent runs.
2. **The branch diff** — as `references/quiz.md` resolves the base ref.
3. **The code the agents are about to touch** — read it *now*, before it changes: what it
   currently guarantees, what the change could break, what the callers assume.
4. **Open weak spots** — a `To improve` entry from `memory.md`, even unrelated to the task.

At `agent 2/3` and `3/3`, prefer a source the earlier salvos of this batch did not use. Three
near-identical questions in a row is the failure mode of a per-agent cadence.

## The exercise

The last step of the salvo is one `fill` exercise — real holes in the dev's real code, cut by a
**dedicated preparation agent** so it is ready by the time the questions are answered.

**Skip it entirely when `coach: on`.** In the coach regime `hooks/coach-gate.sh` denies writes
outside the delegated globs, and the preparation agent's edit is one of them. The barrier is not
weakened for the learner's own convenience; the salvo is questions-only there.

### Dispatching the preparation agent

**Its description MUST start with `learner-prep:`.** This is a contract, not a convention:
`hooks/learner-agent-track.sh` skips those dispatches, and a preparation agent that is *not*
skipped arms a salvo of its own, whose preparation agent arms another, with no bottom.

Its prompt carries the level letter, `blanks`, the candidate files, and the descriptions of the
agents currently in flight. Its mission:

- Pick **one** short function among the candidates and cut `blanks` holes in it as
  `// LEARNER-TODO: <hint>` comments calibrated to the level — `hook-quiz.md` § *The `fill`
  protocol*, steps 1–3.
- **Stay outside the in-flight agents' scope.** It is handed their descriptions and must avoid a
  file they plausibly touch. Two writers on one function is a merge conflict dressed up as a
  lesson.
- **Prefer committed code.** A function already in `HEAD` can be restored from git if anything
  goes wrong; an uncommitted one cannot.
- **Report the file and the function, and nothing else.** No hint that names the construct, no
  sketch of the answer: the report is pasted to the dev as it stands.

### When it reports

Tell the dev the file and the function, ask them to write the missing code **in the file**, and
wait. Feedback, restoration and verification follow `hook-quiz.md` § *The `fill` protocol*,
steps 5–7 — including the rule that a turn never ends with a `// LEARNER-TODO` surviving. The
Stop hook's guardrail enforces it either way.

### When it fails

It finds no suitable function, it errors, or the dev has moved on: say one line and end the
salvo on the questions. A missing exercise is not worth a retry loop.

## When another channel is already in progress

A coach challenge in progress wins: finish it, record the answer, then open the salvo. Never
both at once. `references/coach.md` states the same rule from the other side.
```

- [ ] **Step 4: Update `SKILL.md`**

Add three rows to the Config table, after `coachCooldownMinutes`:

```markdown
| `agentSalvo` | bool | `true` | Salvo of questions while a subagent is in flight |
| `agentSalvoQuestions` | int ≥ 0 | `2` | Questions in a salvo, before the exercise |
| `agentSalvoFill` | bool | `true` | Cut a `fill` exercise at the end of a salvo |
```

Add to the validation paragraph ("To edit: read the target file…") so the new keys are checked
like their neighbours: `agentSalvo` and `agentSalvoFill` booleans, `agentSalvoQuestions` an
integer ≥ 0 — note the floor is **0**, not 1, unlike every other integer key, because an
exercise-only salvo is a legitimate setting.

Add a trigger paragraph after the coach-watcher one:

```markdown
**Invoked by the agent salvo.** While a subagent is in flight, the Stop hook blocks with
`🤖 Learner salvo (level: S, questions: 2, blanks: 2, styles: auto, agent 2/3, coach: off) — task: … — files: …`.
Read `references/agent-salvo.md` and follow it with those values. As with the other two
triggers, the line is parameters, not the protocol.
```

Extend the front-matter `description` so the salvo is discoverable, keeping the existing list
intact and appending after the coach clause: `, and by the agent salvo's trigger line while a
subagent is in flight`.

- [ ] **Step 5: Update `coach.md`**

Under § *A quiz block landing mid-challenge*, add one paragraph:

```markdown
The same holds for an agent salvo (`🤖`): a coach challenge already open finishes first — get
the answer, update `memory.md`/`recap.md` — and only then does the salvo's first question open.
`references/agent-salvo.md` states this from the other side. A salvo also never cuts a `fill`
exercise while the coach regime is on: its trigger carries `coach: on` precisely so it knows,
and `hooks/coach-gate.sh` would refuse the write anyway.
```

- [ ] **Step 6: Run the tests**

Run: `./test.sh`
Expected: the protocol assertions pass. Watch for the `block reason carries no protocol prose`
style guards — they apply to trigger lines, not to reference files, so they stay green.

- [ ] **Step 7: Commit**

```bash
git add skills/learner/references/agent-salvo.md skills/learner/SKILL.md skills/learner/references/coach.md test.sh
git commit -m "feat(salvo): write the salvo protocol and its preparation-agent contract"
```

---

### Task 7: User-facing documentation

Spec §8. The site is hand-written HTML sharing one stylesheet and is guarded by `test.sh`.

**Files:**
- Modify: `README.md` (a section after *Coach mode*)
- Modify: `docs/usage.html` (a salvo section beside the quiz and the coach)
- Modify: `docs/config.html` (three key rows)
- Test: `test.sh` (append to the site-guard section, near `test.sh:1900`)

**Interfaces:**
- Consumes: the config keys (Task 1), the behaviour (Tasks 2-6)
- Produces: nothing code-facing.

- [ ] **Step 1: Write the failing test**

Append to `test.sh`, beside the existing `usage.html covers coach mode` guard (`test.sh:1903`):

```bash
grep -qF 'id="salvo"' "$SITE_USAGE" \
  && ok "usage.html covers the agent salvo" || ko "usage.html covers the agent salvo"
grep -qF 'learner-prep:' "$SITE_USAGE" \
  && ok "usage.html names the learner-prep: contract the dev will see" \
  || ko "usage.html names the learner-prep: contract the dev will see"
for k in agentSalvo agentSalvoQuestions agentSalvoFill; do
  grep -qF "$k" "$SITE_CONFIG" && ok "config.html documents $k" || ko "config.html documents $k"
done
grep -qiF 'salvo' "$RM" \
  && ok "README covers the agent salvo" || ko "README covers the agent salvo"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./test.sh 2>&1 | grep -E '\- (usage.html covers the agent|usage.html names|config.html documents agentSalvo|README covers the agent)'`
Expected: FAIL on all of them.

- [ ] **Step 3: `docs/config.html` — three rows**

Add three rows to the settings table, in the markup shape the defaults guard reads (four `<td>`
cells: Key, Values, Default, Effect — the guard isolates cell 3 by splitting on `</td>`):

```html
<tr><td><code>agentSalvo</code></td><td>bool</td><td><code>true</code></td><td>Questions while a subagent is working</td></tr>
<tr><td><code>agentSalvoQuestions</code></td><td>int ≥ 0</td><td><code>2</code></td><td>Questions in a salvo, before the exercise</td></tr>
<tr><td><code>agentSalvoFill</code></td><td>bool</td><td><code>true</code></td><td>Cut a fill-in exercise at the end of a salvo</td></tr>
```

Place them **after** the `coach*` rows. The page has prose stating that "the last N keys are
`threshold`-only", counted dynamically by `test.sh:295-307` from the number of
`— <code>threshold</code>` markers; keep the new rows clear of that marker so the count is
unchanged.

- [ ] **Step 4: `docs/usage.html` — the salvo section**

Add a section with `id="salvo"` after the coach section (which starts at `docs/usage.html:99`),
in the same `<h2 id="…">` + `<p>` + `<dl>` shape that section uses:

```html
  <h2 id="salvo">Agent salvo — questions while the subagents work</h2>

  <p>When Claude hands work to subagents, the main conversation would otherwise go quiet. It
  owes you a short burst instead, once per dispatched agent: two questions — about the
  delegation itself, the branch diff, the code those agents are about to touch, or an open weak
  spot — then one fill-in exercise cut in your own code. Three agents dispatched at once earn
  three salvos, served one per turn as you answer. The moment the last agent returns, the
  unserved ones are dropped: the queue never trails into work that has resumed.</p>

  <p>The exercise is cut by a dedicated agent launched while you answer the questions, so it is
  ready when you get to it. You will see it start with a description beginning
  <code>learner-prep:</code> — that prefix is a contract, not a label: the salvo deliberately
  does not count its own preparation agent as an agent to quiz you about.</p>

  <p>In coach mode the salvo is questions only. Cutting the exercise needs a write, and
  <code>coach-gate.sh</code> denies it — the barrier is not weakened for the learner's
  convenience.</p>

  <p>One limitation, stated where you will hit it: if your client runs subagents synchronously,
  the salvo lands just after the result instead of during the wait. The questions are still
  asked; only the overlap is lost. No hook fires when a subagent <em>starts</em>, so there is no
  mechanism that does better.</p>

  <dl>
    <dt><code>learner config agentSalvo=false</code></dt>
    <dd>Turns the salvo off. On is the default: it costs nothing in a session that dispatches
    no agent.</dd>
    <dt><code>learner config agentSalvoQuestions=1</code></dt>
    <dd>Questions per salvo, before the exercise. <code>0</code> means exercise only.</dd>
    <dt><code>learner config agentSalvoFill=false</code></dt>
    <dd>Questions only, no exercise.</dd>
  </dl>
```

Check the surrounding markup before pasting and match it — the guards in `test.sh` assert the
page's shape, not this plan's. The section must cover, whatever the final wording:

- What it is: while Claude's subagents work, the main conversation asks — two questions, then
  one fill-in exercise, per dispatched agent.
- That three agents dispatched at once earn three salvos, served one per turn.
- That the salvo stops as soon as the last agent returns, so a queue never trails into resumed
  work.
- That the dev will see an agent launched with a description starting `learner-prep:` — that is
  the exercise being cut, and it is deliberately not counted as work to quiz on.
- That in coach mode the salvo is questions-only, because `coach-gate.sh` denies the
  preparation agent's write.
- The accepted limitation, in the dev's words: if subagents run synchronously in their client,
  the salvo lands just after the result rather than during the wait — the questions are still
  asked, only the overlap is lost.

- [ ] **Step 5: `README.md` — a short section**

After *Coach mode — you write, Claude challenges*, add a section of comparable length:

```markdown
## Agent salvo — questions while the subagents work

When Claude hands work to subagents, the main conversation would otherwise go quiet. Instead it
owes you a short burst per dispatched agent: two questions about the delegation, the diff and
your open weak spots, then one fill-in exercise cut in your own code by a dedicated agent while
you answer. Three agents dispatched at once earn three salvos, served one per turn; the moment
the last agent returns, the rest are dropped.

    learner config agentSalvo=false     # off
    learner config agentSalvoQuestions=1
    learner config agentSalvoFill=false # questions only

In coach mode the salvo is questions-only: the exercise would need a write, and the coach gate
denies it. If your client runs subagents synchronously, the salvo lands just after the result
instead of during the wait — the questions are still asked.
```

- [ ] **Step 6: Run the full suite**

Run: `./test.sh`
Expected: **everything** green, including every count guard. This is the last task, so the whole
suite must pass with no known failures.

Run: `shellcheck hooks/*.sh`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add README.md docs/usage.html docs/config.html test.sh
git commit -m "docs: document the agent salvo and its three config keys"
```

---

## Verification

Before calling the branch done, per `superpowers:verification-before-completion` — run these and paste the output, do not assert from memory:

```bash
./test.sh; echo "exit=$?"
shellcheck hooks/*.sh; echo "shellcheck=$?"
jq -e . hooks/hooks.json hooks/settings.snippet.json >/dev/null && echo "json ok"
```

Then one manual check no test can make, because it needs a real session: in a scratch git repo
with `learner.json` set to a level, ask Claude to dispatch a subagent and confirm that the
`🤖 Learner salvo` trigger appears, that the preparation agent's own dispatch does **not** add a
fourth salvo, and that `$TMPDIR/claude-learner-<sid>.agents*` are gone after the session ends.
