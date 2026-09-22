#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Tests for the learning-mode hooks + installer.
# Plain sh/bash, no framework. Requires: jq, git. Run: ./test.sh
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
PLUG="$ROOT/plugins/learner"
REC="$PLUG/hooks/learner-record-edit.sh"
QUIZ="$PLUG/hooks/learner-quiz.sh"
ONB="$PLUG/hooks/learner-onboard.sh"
CLEAN="$PLUG/hooks/learner-cleanup.sh"
UCHK="$PLUG/hooks/learner-update-check.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
ko()  { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
skip() { printf '  skip - %s\n' "$1"; }

command -v jq  >/dev/null 2>&1 || { echo "jq required"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

# Isolated config dir + project repo + tmp so nothing collides with a real session.
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"  # Resolve symlinks (macOS /tmp → /private/tmp)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cfg" "$WORK/proj/.claude" "$WORK/tmp"
git -C "$WORK/proj" init -q
export CLAUDE_CONFIG_DIR="$WORK/cfg"
export CLAUDE_PROJECT_DIR="$WORK/proj"
export TMPDIR="$WORK/tmp"
GCFG="$WORK/cfg/learner.json"
PCFG="$WORK/proj/.claude/learner.local.json"
edits() { echo "$TMPDIR/claude-learner-$1.edits"; }

# Run a snippet with learner-config.sh sourced.
cfgsh() { sh -c '. "$1"; shift; eval "$@"' _ "$PLUG/hooks/learner-config.sh" "$@"; }

# --- config resolution ------------------------------------------------------
echo '{"level":"senior","blanksPerExercise":3}' > "$GCFG"
rm -f "$PCFG"
out=$(cfgsh 'learner_config')
{ [ "$(echo "$out" | jq -r .level)" = "senior" ] \
  && [ "$(echo "$out" | jq -r .blanksPerExercise)" = "3" ] \
  && [ "$(echo "$out" | jq -r .synthesisFrequency)" = "normal" ]; } \
  && ok "global config merges over defaults" \
  || ko "global config merges over defaults"

echo '{"blanksPerExercise":1,"enabled":false}' > "$PCFG"
out=$(cfgsh 'learner_config')
{ [ "$(echo "$out" | jq -r .blanksPerExercise)" = "1" ] \
  && [ "$(echo "$out" | jq -r .enabled)" = "false" ] \
  && [ "$(echo "$out" | jq -r .level)" = "senior" ]; } \
  && ok "project config wins key by key, keeps enabled=false" \
  || ko "project config wins key by key, keeps enabled=false"

echo '{"level":"S","untrackGlobs":["*.md"]}' > "$GCFG"
echo '{"untrackGlobs":["*.sql"]}' > "$PCFG"
out=$(cfgsh 'learner_config' | jq -c '.untrackGlobs')
[ "$out" = '["*.sql"]' ] \
  && ok "arrays are replaced by the project layer, not merged" \
  || ko "arrays are replaced by the project layer, not merged (got $out)"

printf '{ not json' > "$GCFG"
out=$(cfgsh 'learner_config' | jq -r '.synthesisFrequency')
[ "$out" = "normal" ] \
  && ok "invalid global config falls back to defaults" \
  || ko "invalid global config falls back to defaults"

echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"

# learner_config must fail clean (no stderr noise, empty stdout, nonzero exit)
# when jq is not on PATH, so a `set -u` caller can tell "no config" apart from
# a real merge without ever touching an unbound variable. sh must stay
# resolvable, so only jq is excluded from PATH (an empty dir), not the shell.
NOJQ_PATH="$WORK/tmp/no-jq-path"
mkdir -p "$NOJQ_PATH"
noJqErr="$WORK/tmp/no-jq.stderr"
out=$(PATH="$NOJQ_PATH" /bin/sh -c '. "$1"; learner_config' _ "$PLUG/hooks/learner-config.sh" 2>"$noJqErr")
rc=$?
err=$(cat "$noJqErr")
{ [ -z "$err" ] && [ -z "$out" ] && [ "$rc" -ne 0 ]; } \
  && ok "learner_config fails clean (no stderr, empty stdout) when jq is missing" \
  || ko "learner_config fails clean (no stderr, empty stdout) when jq is missing (out='$out' rc=$rc err='$err')"

# Pilot is opt-in: the master switch must default to false, or installing an
# update would silently start reading every prompt the dev types.
CFG_P=$(cd "$ROOT" && CLAUDE_CONFIG_DIR="$WORK/empty" CLAUDE_PROJECT_DIR="$WORK/empty" \
  sh -c '. plugins/learner/hooks/learner-config.sh; learner_config')
[ "$(printf '%s' "$CFG_P" | jq -r '.pilotEnabled')" = "false" ] \
  && ok "pilotEnabled defaults to false" \
  || ko "pilotEnabled defaults to false"

[ "$(printf '%s' "$CFG_P" | jq -r '.pilotCadenceDays')" = "7" ] \
  && ok "pilotCadenceDays defaults to 7" \
  || ko "pilotCadenceDays defaults to 7"

[ "$(printf '%s' "$CFG_P" | jq -r '.pilotJudgeIntervalHours')" = "24" ] \
  && ok "pilotJudgeIntervalHours defaults to 24" \
  || ko "pilotJudgeIntervalHours defaults to 24"

[ "$(printf '%s' "$CFG_P" | jq -r '.pilotNudge')" = "true" ] \
  && ok "pilotNudge defaults to true" \
  || ko "pilotNudge defaults to true"

# pilot_enabled is a predicate, so assert both directions: a truthy string must
# not pass, or a typo like "yes" would enable the whole subsystem.
if (cd "$ROOT" && sh -c '. plugins/learner/hooks/learner-config.sh; pilot_enabled "{\"pilotEnabled\":true}"'); then
  ok "pilot_enabled is true for pilotEnabled:true"
else
  ko "pilot_enabled is true for pilotEnabled:true"
fi
if (cd "$ROOT" && sh -c '. plugins/learner/hooks/learner-config.sh; pilot_enabled "{\"pilotEnabled\":\"yes\"}"'); then
  ko "pilot_enabled rejects any value other than the literal string \"true\""
else
  ok "pilot_enabled rejects any value other than the literal string \"true\""
fi
# It is a text comparison, not a JSON-type check: a JSON STRING "true" passes
# exactly like the boolean does, because jq -r renders both the same way.
# Pinned explicitly so the guard's own comment and this test's name cannot
# drift back to claiming "boolean" when the code has never checked JSON type.
if (cd "$ROOT" && sh -c '. plugins/learner/hooks/learner-config.sh; pilot_enabled "{\"pilotEnabled\":\"true\"}"'); then
  ok "pilot_enabled accepts the JSON string \"true\", not only the boolean"
else
  ko "pilot_enabled accepts the JSON string \"true\", not only the boolean"
fi

# --- pilot-record -------------------------------------------------------------
PR_TMP="$WORK/pilot-record"
mkdir -p "$PR_TMP/cfg/learner" "$PR_TMP/norepo"
PR_FIX="$ROOT/test/fixtures/pilot-transcript.jsonl"
PR_FIX_REM="$ROOT/test/fixtures/pilot-transcript-reminder.jsonl"
PR_FIX_BURST="$ROOT/test/fixtures/pilot-transcript-burst.jsonl"

pr_run() {  # pr_run <cfgdir> <cwd> <extra-config-json>
  printf '{"pilotEnabled":true}' > "$1/learner.json"
  [ -n "${3:-}" ] && printf '%s' "$3" > "$1/learner.json"
  printf '{"session_id":"S1","transcript_path":"%s","cwd":"%s","source":"other"}' "$PR_FIX" "$2" \
    | (cd "$2" && CLAUDE_CONFIG_DIR="$1" CLAUDE_PROJECT_DIR="$2" sh "$PLUG/hooks/pilot-record.sh")
}

# pr_run_fix <cfgdir> <cwd> <sid> <fixture> — like pr_run, but for a fixture
# other than the pinned one, under its own session id.
pr_run_fix() {
  printf '{"pilotEnabled":true}' > "$1/learner.json"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","source":"other"}' "$3" "$4" "$2" \
    | (cd "$2" && CLAUDE_CONFIG_DIR="$1" CLAUDE_PROJECT_DIR="$2" sh "$PLUG/hooks/pilot-record.sh")
}

# 1. The prompt filter. isMeta, tool_result arrays, <local-command-…> and
#    <command-name> wrappers are all machinery; only two lines are the dev.
pr_run "$PR_TMP/cfg" "$PR_TMP/norepo"
PR_LINE=$(head -1 "$PR_TMP/cfg/learner/pilot-queue" 2>/dev/null)
case "$PR_LINE" in
  *" prompts=2 "*) ok "pilot-record counts only the dev's real prompts" ;;
  *) ko "pilot-record counts only the dev's real prompts (got: $PR_LINE)" ;;
esac

# 2. Decision 8. Every other learner hook exits early without a git repo; this
#    one must not, or the sessions with the worst delegation go unmeasured.
case "$PR_LINE" in
  *" repo=- "*) ok "pilot-record queues a session held outside any git repo" ;;
  *) ko "pilot-record queues a session held outside any git repo (got: $PR_LINE)" ;;
esac

# 3. Every counter and the field order, pinned in one literal comparison
#    against test/fixtures/pilot-transcript.jsonl. pw_med=12 and burst=1 are
#    hand-recounted values (12: "add a retry to the http client, max three
#    attempts, exponential backoff" is 12 words by plain word count; 1: the
#    fixture's two real prompts are ten minutes apart, so no 5-minute window
#    ever holds more than one of them) — not the numbers the task brief
#    guessed, which is why this is a literal string and not a re-derivation of
#    the same arithmetic the script already does.
PR_EXPECT="sid=S1 date=2026-09-10 repo=- dur_min=11 prompts=2 pw_med=12 pw_min=5 burst=1 tools=2 cl_writes=1 cl_lines=4 dev_lines=- est=- coach=0 jsonl=$PR_FIX"
[ "$PR_LINE" = "$PR_EXPECT" ] \
  && ok "pilot-record's queue line matches every counter and the field order" \
  || ko "pilot-record's queue line matches every counter and the field order (got: $PR_LINE)"

# 4. A real prompt can legitimately BEGIN with a <system-reminder> block the
#    harness prepends ahead of the actual text in the same message. Classifying
#    by prefix would drop it entirely and silently corrupt prompts/pw_med/
#    pw_min/burst; stripping the wrapper and judging what remains keeps it.
rm -f "$PR_TMP/cfg/learner/pilot-queue"
pr_run_fix "$PR_TMP/cfg" "$PR_TMP/norepo" SR "$PR_FIX_REM"
PR_LINE_REM=$(head -1 "$PR_TMP/cfg/learner/pilot-queue" 2>/dev/null)
case "$PR_LINE_REM" in
  *" prompts=1 "*) ok "pilot-record counts a prompt that carries a leading system-reminder" ;;
  *) ko "pilot-record counts a prompt that carries a leading system-reminder (got: $PR_LINE_REM)" ;;
esac
# Checked as two independent substrings rather than one combined pattern: a
# single glob requiring both " pw_med=5 " and " pw_min=5 " in sequence would
# have the second copy consume the space the first copy already matched,
# which is exactly the kind of self-inflicted false negative this file exists
# to avoid.
PR_REM_OK=1
case "$PR_LINE_REM" in *" pw_med=5 "*) ;; *) PR_REM_OK=0 ;; esac
case "$PR_LINE_REM" in *" pw_min=5 "*) ;; *) PR_REM_OK=0 ;; esac
[ "$PR_REM_OK" = 1 ] \
  && ok "pilot-record's word count is taken on the stripped text, not the reminder" \
  || ko "pilot-record's word count is taken on the stripped text, not the reminder (got: $PR_LINE_REM)"

# 5. The burst window is the most intricate part of the jq program and the
#    pinned fixture never exercises it (its two real prompts are ten minutes
#    apart). A second fixture with three prompts inside one 5-minute window
#    (09:00, 09:02, 09:04) pins the true widest cluster.
rm -f "$PR_TMP/cfg/learner/pilot-queue"
pr_run_fix "$PR_TMP/cfg" "$PR_TMP/norepo" SB "$PR_FIX_BURST"
PR_LINE_BURST=$(head -1 "$PR_TMP/cfg/learner/pilot-queue" 2>/dev/null)
case "$PR_LINE_BURST" in
  *" burst=3 "*) ok "pilot-record's burst window counts the true widest cluster" ;;
  *) ko "pilot-record's burst window counts the true widest cluster (got: $PR_LINE_BURST)" ;;
esac

# 6. Decision 10. The scratch files are deleted by learner-cleanup.sh at the
#    same SessionEnd, in parallel, so nothing here may read them. A merely
#    absent file can't tell a regression apart from compliance, so the files
#    are PLANTED with values that contradict the transcript's truth — if
#    anything here ever starts trusting them, the line changes and this fails.
rm -f "$PR_TMP/cfg/learner/pilot-queue"
PR_TD="${TMPDIR:-/tmp}"
printf '/fake/one\n/fake/two\n/fake/three\n/fake/four\n' > "$PR_TD/claude-learner-S1.edits"
printf '/fake/one\n/fake/two\n' > "$PR_TD/claude-learner-S1.session"
printf '999' > "$PR_TD/claude-learner-S1.count"
printf '1' > "$PR_TD/claude-learner-S1.guard"
printf 'bogus-scope' > "$PR_TD/claude-learner-S1.coach-scope"
printf '1' > "$PR_TD/claude-learner-S1.coach-idle"
printf '2020-01-01T00:00:00.000Z' > "$PR_TD/claude-learner-S1.coach-last"
mkdir -p "$PR_TD/claude-learner-S1.coach-base/bogus"
printf 'bogus\n' > "$PR_TD/claude-learner-S1.coach-base/bogus/file"
pr_run "$PR_TMP/cfg" "$PR_TMP/norepo"
[ "$(head -1 "$PR_TMP/cfg/learner/pilot-queue")" = "$PR_LINE" ] \
  && ok "pilot-record does not depend on the TMPDIR scratch files" \
  || ko "pilot-record does not depend on the TMPDIR scratch files"
rm -rf "$PR_TD/claude-learner-S1."*

# 7. Opt-in. Nothing anywhere when the switch is off.
rm -rf "$PR_TMP/off"; mkdir -p "$PR_TMP/off/learner"
pr_run "$PR_TMP/off" "$PR_TMP/norepo" '{"pilotEnabled":false}'
[ ! -f "$PR_TMP/off/learner/pilot-queue" ] \
  && ok "pilot-record is inert while pilotEnabled is false" \
  || ko "pilot-record is inert while pilotEnabled is false"

# 7b. disabledPaths silences Pilot's record hook too, same as the quiz: a repo
#     listed there gets no queue line at all, even though the transcript
#     itself would otherwise be perfectly readable.
PR_DIS_REPO="$WORK/pr-disabled-repo"; rm -rf "$PR_DIS_REPO"; mkdir -p "$PR_DIS_REPO"
git -C "$PR_DIS_REPO" init -q
rm -rf "$PR_TMP/disabled"; mkdir -p "$PR_TMP/disabled/learner"
pr_run "$PR_TMP/disabled" "$PR_DIS_REPO" \
  "$(printf '{"pilotEnabled":true,"disabledPaths":["%s"]}' "$PR_DIS_REPO")"
[ ! -f "$PR_TMP/disabled/learner/pilot-queue" ] \
  && ok "pilot-record is inert inside a disabledPaths repo" \
  || ko "pilot-record is inert inside a disabledPaths repo"

# 8. Idempotent. SessionEnd can fire more than once for one session id
#    (clear, resume); a second line would double-count the session in the index.
rm -f "$PR_TMP/cfg/learner/pilot-queue"
pr_run "$PR_TMP/cfg" "$PR_TMP/norepo"
pr_run "$PR_TMP/cfg" "$PR_TMP/norepo"
[ "$(grep -c '^sid=S1 ' "$PR_TMP/cfg/learner/pilot-queue")" = "1" ] \
  && ok "pilot-record queues a session id at most once" \
  || ko "pilot-record queues a session id at most once"

# 9. Budget. SessionEnd hooks share 1.5s, raised to the wired timeout of 15.
#    A 5,000-line transcript must be nowhere near it.
awk 'NR==1{for(i=0;i<5000;i++) print}' "$PR_FIX" > "$PR_TMP/big.jsonl"
rm -f "$PR_TMP/cfg/learner/pilot-queue"
PR_T0=$(date +%s)
printf '{"session_id":"S2","transcript_path":"%s","cwd":"%s"}' "$PR_TMP/big.jsonl" "$PR_TMP/norepo" \
  | (cd "$PR_TMP/norepo" && CLAUDE_CONFIG_DIR="$PR_TMP/cfg" sh "$PLUG/hooks/pilot-record.sh")
[ $(( $(date +%s) - PR_T0 )) -le 5 ] \
  && ok "pilot-record stays well inside its SessionEnd budget" \
  || ko "pilot-record stays well inside its SessionEnd budget"

# 10. A missing or unreadable transcript is a no-op, not a crash: the path
#     comes from the harness and Pilot does not own its lifetime.
rm -f "$PR_TMP/cfg/learner/pilot-queue"
printf '{"session_id":"S3","transcript_path":"/nonexistent.jsonl","cwd":"%s"}' "$PR_TMP/norepo" \
  | (cd "$PR_TMP/norepo" && CLAUDE_CONFIG_DIR="$PR_TMP/cfg" sh "$PLUG/hooks/pilot-record.sh") \
  && [ ! -f "$PR_TMP/cfg/learner/pilot-queue" ] \
  && ok "pilot-record no-ops on a missing transcript" \
  || ko "pilot-record no-ops on a missing transcript"

# 11. The writing axis's coach-tally branch (ruling, Task 3 fix round 1): a
#     coach tally alone is a lower bound, not an exact count — the watcher
#     only records one when a review actually fires, so everything written
#     since the last one is unmeasured — so dev_lines is the LARGER of the
#     tally and the git working-tree estimate, and est=0 only when the
#     estimate does not exceed the tally. This is the least-inspected code in
#     the task and the code the whole axis reads, so each reachable branch
#     but one gets its own case here, each in a fresh cfg dir and repo so one
#     case's tally or commit state cannot leak into another's. The fifth
#     branch (no tally, no repo) is already PR_EXPECT above.
#     PR_FIX's cl_lines is 4 throughout (pinned at item 3).

# (a) tally covers the tree: 5 uncommitted insertions minus cl_lines=4 nets
#     an estimate of 1, well under a tally of 50 — chosen large enough that
#     no plausible off-by-one in the comparison could flip the branch.
PR_A="$WORK/pr-axis-a"; rm -rf "$PR_A"; mkdir -p "$PR_A/cfg/learner" "$PR_A/repo"
git -C "$PR_A/repo" init -q
printf 'orig\n' > "$PR_A/repo/f.txt"
git -C "$PR_A/repo" add f.txt
git -C "$PR_A/repo" -c user.email=t@t -c user.name=t commit -qm init
printf 'x1\nx2\nx3\nx4\nx5\n' > "$PR_A/repo/f.txt"
printf 'S1 50\n' > "$PR_A/cfg/learner/pilot-devlines"
pr_run "$PR_A/cfg" "$PR_A/repo"
PR_A_LINE=$(grep '^sid=S1 ' "$PR_A/cfg/learner/pilot-queue" 2>/dev/null)
PR_A_OK=1
case "$PR_A_LINE" in *" dev_lines=50 "*) ;; *) PR_A_OK=0 ;; esac
case "$PR_A_LINE" in *" est=0 "*) ;; *) PR_A_OK=0 ;; esac
[ "$PR_A_OK" = 1 ] \
  && ok "pilot-record's writing axis: a tally that covers the tree wins exact (dev_lines=50 est=0)" \
  || ko "pilot-record's writing axis: a tally that covers the tree wins exact (got: $PR_A_LINE)"

# (b) the estimate exceeds the tally by a margin no sign error or off-by-one
#     could produce by accident: 100 uncommitted insertions minus cl_lines=4
#     nets an estimate of 96 against a tally of 3.
PR_B="$WORK/pr-axis-b"; rm -rf "$PR_B"; mkdir -p "$PR_B/cfg/learner" "$PR_B/repo"
git -C "$PR_B/repo" init -q
printf 'orig\n' > "$PR_B/repo/f.txt"
git -C "$PR_B/repo" add f.txt
git -C "$PR_B/repo" -c user.email=t@t -c user.name=t commit -qm init
awk 'BEGIN { for (i = 0; i < 100; i++) print "y" i }' > "$PR_B/repo/f.txt"
printf 'S1 3\n' > "$PR_B/cfg/learner/pilot-devlines"
pr_run "$PR_B/cfg" "$PR_B/repo"
PR_B_LINE=$(grep '^sid=S1 ' "$PR_B/cfg/learner/pilot-queue" 2>/dev/null)
PR_B_OK=1
case "$PR_B_LINE" in *" dev_lines=96 "*) ;; *) PR_B_OK=0 ;; esac
case "$PR_B_LINE" in *" est=1 "*) ;; *) PR_B_OK=0 ;; esac
[ "$PR_B_OK" = 1 ] \
  && ok "pilot-record's writing axis: an estimate that exceeds the tally wins, marked est=1 (dev_lines=96)" \
  || ko "pilot-record's writing axis: an estimate that exceeds the tally wins (got: $PR_B_LINE)"

# (c) no tally, repo present, clean tree: the estimate itself computes to 0
#     (0 insertions minus cl_lines=4, floored), but it is still a GUESS, not
#     a measurement — est=1 on that zero is the whole point (it means "we
#     did not measure this, we guessed, and the guess is zero", not "we
#     measured, and they wrote nothing"), so both the value and the marker
#     are pinned, not just the zero.
PR_C="$WORK/pr-axis-c"; rm -rf "$PR_C"; mkdir -p "$PR_C/cfg/learner" "$PR_C/repo"
git -C "$PR_C/repo" init -q
printf 'orig\n' > "$PR_C/repo/f.txt"
git -C "$PR_C/repo" add f.txt
git -C "$PR_C/repo" -c user.email=t@t -c user.name=t commit -qm init
pr_run "$PR_C/cfg" "$PR_C/repo"
PR_C_LINE=$(grep '^sid=S1 ' "$PR_C/cfg/learner/pilot-queue" 2>/dev/null)
PR_C_OK=1
case "$PR_C_LINE" in *" dev_lines=0 "*) ;; *) PR_C_OK=0 ;; esac
case "$PR_C_LINE" in *" est=1 "*) ;; *) PR_C_OK=0 ;; esac
[ "$PR_C_OK" = 1 ] \
  && ok "pilot-record's writing axis: no tally with a clean repo is a guessed zero, marked est=1" \
  || ko "pilot-record's writing axis: no tally with a clean repo is a guessed zero, marked est=1 (got: $PR_C_LINE)"

# (e) tally exists, no repo to estimate against at all: the tally stands
#     alone and is exact.
PR_E="$WORK/pr-axis-e"; rm -rf "$PR_E"; mkdir -p "$PR_E/cfg/learner" "$PR_E/norepo"
printf 'S1 7\n' > "$PR_E/cfg/learner/pilot-devlines"
pr_run "$PR_E/cfg" "$PR_E/norepo"
PR_E_LINE=$(grep '^sid=S1 ' "$PR_E/cfg/learner/pilot-queue" 2>/dev/null)
PR_E_OK=1
case "$PR_E_LINE" in *" dev_lines=7 "*) ;; *) PR_E_OK=0 ;; esac
case "$PR_E_LINE" in *" est=0 "*) ;; *) PR_E_OK=0 ;; esac
[ "$PR_E_OK" = 1 ] \
  && ok "pilot-record's writing axis: a tally with no repo to compare against is exact" \
  || ko "pilot-record's writing axis: a tally with no repo to compare against is exact (got: $PR_E_LINE)"

for pair in "d:D" "junior:J" "JUNIOR:J" "c:C" "senior:S" "Expert:E" "wizard:"; do
  raw="${pair%%:*}"; want="${pair##*:}"
  got=$(cfgsh "learner_level $raw")
  [ "$got" = "$want" ] \
    && ok "level '$raw' normalises to '$want'" \
    || ko "level '$raw' normalises to '$want' (got '$got')"
done

for pair in "off:0" "rare:8" "normal:4" "often:2" "banana:4"; do
  raw="${pair%%:*}"; want="${pair##*:}"
  got=$(cfgsh "learner_synthesis_n $raw")
  [ "$got" = "$want" ] \
    && ok "synthesisFrequency '$raw' -> $want" \
    || ko "synthesisFrequency '$raw' -> $want (got '$got')"
done

for pair in "1.2.3:yes" "0.1.0:yes" "1.0:no" "1.x.0:no" "1.2.3.4:no" "1.2.:no" "1..3:no"; do
  raw="${pair%%:*}"; want="${pair##*:}"
  if cfgsh "learner_version_valid $raw"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] \
    && ok "learner_version_valid '$raw' -> $want" \
    || ko "learner_version_valid '$raw' -> $want (got $got)"
done

for t in "1.2.3:1.2.3:no" "1.2.4:1.2.3:yes" "1.2.3:1.2.4:no" \
         "1.3.0:1.2.9:yes" "2.0.0:1.9.9:yes" "1.9.9:2.0.0:no" "1.2.9:1.3.0:no"; do
  a=$(printf '%s' "$t" | cut -d: -f1)
  b=$(printf '%s' "$t" | cut -d: -f2)
  want=$(printf '%s' "$t" | cut -d: -f3)
  if cfgsh "learner_version_gt $a $b"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] \
    && ok "learner_version_gt $a vs $b -> $want" \
    || ko "learner_version_gt $a vs $b -> $want (got $got)"
done

out=$(cfgsh 'learner_repo_root')
[ "$out" = "$(cd "$WORK/proj" && pwd -P)" ] \
  && ok "repo root resolves inside a git repo" \
  || ko "repo root resolves inside a git repo (got '$out')"

out=$(CLAUDE_PROJECT_DIR="$WORK/tmp" cfgsh 'learner_repo_root')
[ -z "$out" ] \
  && ok "repo root is empty outside a git repo" \
  || ko "repo root is empty outside a git repo (got '$out')"

cfgsh 'learner_path_disabled "/a/b/c" "{\"disabledPaths\":[\"/a/b\"]}"' \
  && ok "disabledPaths matches a parent prefix" \
  || ko "disabledPaths matches a parent prefix"

cfgsh 'learner_path_disabled "/a/bee" "{\"disabledPaths\":[\"/a/b\"]}"' \
  && ko "disabledPaths does not match a sibling with a shared prefix" \
  || ok "disabledPaths does not match a sibling with a shared prefix"

# The root an entry is compared against is physical (git rev-parse --show-toplevel),
# so an entry that reaches the repo through a symlink must still match — otherwise
# the only off-switch the guardrail honours fails silently. /a/b above covers the
# other half: an entry that does not exist on disk keeps its raw string.
SYMB="$WORK/symbase"; mkdir -p "$SYMB/real/repo"
ln -sfn "$SYMB/real" "$SYMB/link"
cfgsh "learner_path_disabled '$SYMB/real/repo' '{\"disabledPaths\":[\"$SYMB/link\"]}'" \
  && ok "disabledPaths matches an entry that points through a symlink" \
  || ko "disabledPaths matches an entry that points through a symlink"

cfgsh 'learner_active "{\"level\":\"S\",\"enabled\":true}" "/a/b"' \
  && ok "learner_active passes with a level, enabled, inside a repo" \
  || ko "learner_active passes with a level, enabled, inside a repo"

cfgsh 'learner_active "{\"enabled\":true}" "/a/b"' \
  && ko "learner_active fails without a valid level" \
  || ok "learner_active fails without a valid level"

cfgsh 'learner_active "{\"level\":\"S\",\"enabled\":false}" "/a/b"' \
  && ko "learner_active fails when enabled is false" \
  || ok "learner_active fails when enabled is false"

cfgsh 'learner_active "{\"level\":\"S\",\"enabled\":true}" ""' \
  && ko "learner_active fails outside a git repo" \
  || ok "learner_active fails outside a git repo"

cfgsh 'learner_active "{\"level\":\"S\",\"disabledPaths\":[\"/a\"]}" "/a/b"' \
  && ko "learner_active fails under a disabled path" \
  || ok "learner_active fails under a disabled path"

# --- pilot-brief --------------------------------------------------------------
PB_TMP="$WORK/pilot-brief"
pb_reset() {
  rm -rf "$PB_TMP"; mkdir -p "$PB_TMP/cfg/learner" "$PB_TMP/wd"
  printf '{"pilotEnabled":true}' > "$PB_TMP/cfg/learner.json"
}
pb_run() {
  printf '{"session_id":"B1","source":"%s","cwd":"%s"}' "${1:-startup}" "$PB_TMP/wd" \
    | (cd "$PB_TMP/wd" && CLAUDE_CONFIG_DIR="$PB_TMP/cfg" sh "$PLUG/hooks/pilot-brief.sh")
}
# A Sessions table with N valid data rows (the row shape the floor counts:
# `| YYYY-MM-DD | ... |`), prefixed to whatever $2 (an Index block etc.) holds.
pb_sessions() {  # pb_sessions N [rest-of-file]
  _pbn="$1"; shift
  _pbrows=''
  _pbi=1
  while [ "$_pbi" -le "$_pbn" ]; do
    _pbrows="${_pbrows}| 2026-09-0$_pbi | r | 2 | 2 | 2 | 2 | - |
"
    _pbi=$((_pbi + 1))
  done
  printf '# Sessions\n\n| Date | Repo | Dir | Ver | Con | Wri | Note |\n|---|---|---|---|---|---|---|\n%s\n%s' \
    "$_pbrows" "${1:-}"
}

# 1. An empty queue and no history is silence, not a brief about nothing.
pb_reset
[ -z "$(pb_run)" ] \
  && ok "pilot-brief says nothing with an empty queue and no history" \
  || ko "pilot-brief says nothing with an empty queue and no history"

# 2. A queued session with no prior drain is due immediately.
pb_reset
printf 'sid=X date=2026-09-10 repo=r prompts=3 jsonl=/tmp/x.jsonl\n' > "$PB_TMP/cfg/learner/pilot-queue"
PB_OUT=$(pb_run)
printf '%s' "$PB_OUT" | jq -e '.hookSpecificOutput.additionalContext | test("score.md")' >/dev/null \
  && ok "pilot-brief asks for a scoring pass when the queue is stale" \
  || ko "pilot-brief asks for a scoring pass when the queue is stale"

# 3. Within pilotJudgeIntervalHours of the last drain, it stays quiet: the whole
#    point of batching is one subagent a day, not one per session.
pb_reset
printf 'sid=X date=2026-09-10 repo=r prompts=3 jsonl=/tmp/x.jsonl\n' > "$PB_TMP/cfg/learner/pilot-queue"
printf 'score=%s\n' "$(date +%s)" > "$PB_TMP/cfg/learner/pilot-stamps"
[ -z "$(pb_run)" ] \
  && ok "pilot-brief respects pilotJudgeIntervalHours" \
  || ko "pilot-brief respects pilotJudgeIntervalHours"

# 4. Ordering. When both are due, the scorer must be named first and the brief
#    deferred — a brief opened on a stale index quotes last week's numbers.
#    Four Sessions rows so the floor from test set 4b below does not itself
#    suppress the brief and mask what this test is actually checking.
pb_reset
printf 'sid=X date=2026-09-10 repo=r prompts=3 jsonl=/tmp/x.jsonl\n' > "$PB_TMP/cfg/learner/pilot-queue"
pb_sessions 4 '
# Index

- direction: 40
' > "$PB_TMP/cfg/learner/pilot.md"
printf 'brief=1\n' > "$PB_TMP/cfg/learner/pilot-stamps"
PB_OUT=$(pb_run)
# The deferral message names no reference file — that is the point, the brief
# must not be opened. So assert the scorer is asked for AND the brief is
# explicitly deferred, AND that the scorer text comes first: a "both present,
# either order" check would pass even if the deferral were emitted before the
# scoring instruction, which defeats the ordering this task exists to provide.
printf '%s' "$PB_OUT" | jq -e '.hookSpecificOutput.additionalContext
    | test("score.md") and test("Do NOT open it") and (index("score.md") < index("Do NOT open it"))' >/dev/null \
  && ok "pilot-brief names the scoring pass before it defers the brief" \
  || ko "pilot-brief names the scoring pass before it defers the brief"

# 5. Only startup and resume. A compaction mid-session must not re-fire either,
#    the same guard learner-onboard.sh already applies for the same reason.
pb_reset
printf 'sid=X date=2026-09-10 repo=r prompts=3 jsonl=/tmp/x.jsonl\n' > "$PB_TMP/cfg/learner/pilot-queue"
[ -z "$(pb_run compact)" ] \
  && ok "pilot-brief ignores a compaction" \
  || ko "pilot-brief ignores a compaction"

# 6. Opt-in.
pb_reset
printf '{"pilotEnabled":false}' > "$PB_TMP/cfg/learner.json"
printf 'sid=X date=2026-09-10 repo=r prompts=3 jsonl=/tmp/x.jsonl\n' > "$PB_TMP/cfg/learner/pilot-queue"
[ -z "$(pb_run)" ] \
  && ok "pilot-brief is inert while pilotEnabled is false" \
  || ko "pilot-brief is inert while pilotEnabled is false"

# 7. Declined twice, never offered again unasked. Pilot is not allowed to nag.
pb_reset
printf '# Index\n\n- direction: 40\n' > "$PB_TMP/cfg/learner/pilot.md"
printf 'brief=1\ndeclined=2\n' > "$PB_TMP/cfg/learner/pilot-stamps"
[ -z "$(pb_run)" ] \
  && ok "pilot-brief stops offering the brief after two declines" \
  || ko "pilot-brief stops offering the brief after two declines"

# 8. `declined` must gate the brief and nothing else: a dev who does not want the
#    weekly conversation has not asked to stop being measured. A queued session
#    stays due for scoring even while the brief is suppressed.
pb_reset
printf 'sid=X date=2026-09-10 repo=r prompts=3 jsonl=/tmp/x.jsonl\n' > "$PB_TMP/cfg/learner/pilot-queue"
printf '# Index\n\n- direction: 40\n' > "$PB_TMP/cfg/learner/pilot.md"
printf 'brief=1\ndeclined=2\n' > "$PB_TMP/cfg/learner/pilot-stamps"
pb_run | jq -e '.hookSpecificOutput.additionalContext | test("score.md")' >/dev/null \
  && ok "declining the brief does not suppress a due scoring pass" \
  || ko "declining the brief does not suppress a due scoring pass"

# 9. The four-session floor. rubric.md: naming anything off two or three
#    sessions "is the fastest way to make the whole number look like
#    guesswork" — the brief must not open on that thin a Sessions table even
#    when every other condition (cadence elapsed, not declined) is met.
pb_reset
pb_sessions 3 '
# Index

- direction: 40
' > "$PB_TMP/cfg/learner/pilot.md"
printf 'brief=1\n' > "$PB_TMP/cfg/learner/pilot-stamps"
[ -z "$(pb_run)" ] \
  && ok "pilot-brief withholds itself below the four-session floor" \
  || ko "pilot-brief withholds itself below the four-session floor"

# 10. One more row clears it — pinned right against test 9 so the floor is
#     shown to sit exactly at four, not merely "somewhere low".
pb_reset
pb_sessions 4 '
# Index

- direction: 40
' > "$PB_TMP/cfg/learner/pilot.md"
printf 'brief=1\n' > "$PB_TMP/cfg/learner/pilot-stamps"
[ -n "$(pb_run)" ] \
  && ok "pilot-brief is due at exactly four Sessions rows" \
  || ko "pilot-brief is due at exactly four Sessions rows"

# 11. disabledPaths silences pilot-brief entirely inside a disabled repo —
#     neither a scoring dispatch nor a brief, even with a stale queue and a
#     due brief, since either would surface evidence gathered elsewhere into
#     a repo the dev asked Pilot to leave alone.
PB_DIS_REPO="$WORK/pb-disabled-repo"; rm -rf "$PB_DIS_REPO"; mkdir -p "$PB_DIS_REPO"
git -C "$PB_DIS_REPO" init -q
pb_reset
pb_sessions 4 '
# Index

- direction: 40
' > "$PB_TMP/cfg/learner/pilot.md"
printf 'brief=1\n' > "$PB_TMP/cfg/learner/pilot-stamps"
printf 'sid=X date=2026-09-10 repo=r prompts=3 jsonl=/tmp/x.jsonl\n' > "$PB_TMP/cfg/learner/pilot-queue"
printf '{"pilotEnabled":true,"disabledPaths":["%s"]}' "$PB_DIS_REPO" > "$PB_TMP/cfg/learner.json"
PB_OUT=$(printf '{"session_id":"B1","source":"startup","cwd":"%s"}' "$PB_DIS_REPO" \
  | (cd "$PB_DIS_REPO" && CLAUDE_CONFIG_DIR="$PB_TMP/cfg" CLAUDE_PROJECT_DIR="$PB_DIS_REPO" sh "$PLUG/hooks/pilot-brief.sh"))
[ -z "$PB_OUT" ] \
  && ok "pilot-brief is silent inside a disabledPaths repo" \
  || ko "pilot-brief is silent inside a disabledPaths repo"

# --- pilot-nudge ----------------------------------------------------------
PN_TMP="$WORK/pilot-nudge"
pn_reset() {
  rm -rf "$PN_TMP"; mkdir -p "$PN_TMP/cfg/learner" "$PN_TMP/wd"
  printf '{"pilotEnabled":true}' > "$PN_TMP/cfg/learner.json"
  rm -f "${TMPDIR:-/tmp}/claude-learner-N1.pilot-nudged"
}
pn_live() {  # pn_live <axis> <until>
  printf '# Manoeuvres\n\n- live: %s | name the result you want and one constraint | until %s\n' \
    "$1" "$2" > "$PN_TMP/cfg/learner/pilot.md"
}
pn_run() {  # pn_run <prompt> [session_id]
  pn_sid="${2:-N1}"
  printf '{"session_id":"%s","prompt":"%s","cwd":"%s"}' "$pn_sid" "$1" "$PN_TMP/wd" \
    | (cd "$PN_TMP/wd" && CLAUDE_CONFIG_DIR="$PN_TMP/cfg" sh "$PLUG/hooks/pilot-nudge.sh")
}
# Every pn_ helper below defaults to session "N1"; pn_reset also clears that
# session's once-per-session nudge marker so each fresh config starts unnudged,
# same as a fresh `pn_reset` already gives a fresh pilot.md.
pn_clear_marker() { rm -f "${TMPDIR:-/tmp}/claude-learner-${1:-N1}.pilot-nudged"; }

# 1. THE constraint of this file. Exit 2 on UserPromptSubmit blocks the prompt
#    AND ERASES IT. Destroying what the dev typed to remind them to type it
#    better is indefensible, so assert status 0 on every path, loudest here.
pn_reset; pn_live direction "2099-01-01"
pn_run "fix it" >/dev/null 2>&1
[ $? -eq 0 ] && ok "pilot-nudge exits 0 with a live manoeuvre and a vague prompt" \
             || ko "pilot-nudge exits 0 with a live manoeuvre and a vague prompt"
pn_reset
pn_run "fix it" >/dev/null 2>&1
[ $? -eq 0 ] && ok "pilot-nudge exits 0 with no manoeuvre" \
             || ko "pilot-nudge exits 0 with no manoeuvre"
pn_reset; pn_live direction "2099-01-01"
printf '{"session_id":"N1","cwd":"%s"}' "$PN_TMP/wd" \
  | (cd "$PN_TMP/wd" && CLAUDE_CONFIG_DIR="$PN_TMP/cfg" sh "$PLUG/hooks/pilot-nudge.sh") >/dev/null 2>&1
[ $? -eq 0 ] && ok "pilot-nudge exits 0 with no prompt field at all" \
             || ko "pilot-nudge exits 0 with no prompt field at all"

# 2. Silence unless a manoeuvre is live. Pilot measures passively; the nudge is
#    the one place it speaks, and only while the dev has agreed to a manoeuvre.
pn_reset
[ -z "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge is silent with no live manoeuvre" \
  || ko "pilot-nudge is silent with no live manoeuvre"

# 3. An expired manoeuvre is not a live one.
pn_reset; pn_live direction "2020-01-01"
[ -z "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge ignores an expired manoeuvre" \
  || ko "pilot-nudge ignores an expired manoeuvre"

# 4. Live and vague: speak.
pn_reset; pn_live direction "2099-01-01"
pn_run 'fix it' | jq -e '.hookSpecificOutput.additionalContext | test("constraint")' >/dev/null \
  && ok "pilot-nudge reminds the dev on a vague prompt" \
  || ko "pilot-nudge reminds the dev on a vague prompt"

# 5. A specific prompt needs no reminder — a nudge on every prompt is noise,
#    and noise is how a manoeuvre gets switched off.
pn_reset; pn_live direction "2099-01-01"
[ -z "$(pn_run 'in src/http/client.py add a retry of at most three attempts, no new dependency')" ] \
  && ok "pilot-nudge stays quiet on a specific prompt" \
  || ko "pilot-nudge stays quiet on a specific prompt"

# 6. pilotNudge is its own consent, separate from the brief's.
pn_reset; pn_live direction "2099-01-01"
printf '{"pilotEnabled":true,"pilotNudge":false}' > "$PN_TMP/cfg/learner.json"
[ -z "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge honours pilotNudge:false" \
  || ko "pilot-nudge honours pilotNudge:false"

# 7. The path/backtick branch of the vagueness heuristic, exercised UNDER the
#    word floor so only that branch (not the word-count guard) can be keeping
#    these quiet — the review found this branch had no discriminating test.
pn_reset; pn_live direction "2099-01-01"
[ -z "$(pn_run 'check src/http/client.py')" ] \
  && ok "pilot-nudge stays quiet on a short prompt naming a path" \
  || ko "pilot-nudge stays quiet on a short prompt naming a path"
pn_reset; pn_live direction "2099-01-01"
[ -z "$(pn_run 'run `pytest -k foo`')" ] \
  && ok "pilot-nudge stays quiet on a short prompt with a code span" \
  || ko "pilot-nudge stays quiet on a short prompt with a code span"

# 8. The realistic "no live manoeuvre" case: pilot.md exists, holding a settled
#    manoeuvre's history, but the Manoeuvres block has no `- live:` line — the
#    normal state after an expiry (spec §8). Different from "no pilot.md at
#    all", which the earlier `[ -f ]` gate already catches. The settled line's
#    BODY is deliberately well-formed (a clean axis, constraint, and a future
#    until date — it would parse as a live manoeuvre if the prefix matched) so
#    the missing `- live:` prefix is the only thing keeping this silent, not
#    an incidental parse failure elsewhere in the line.
pn_reset
printf '# Manoeuvres\n\n- settled: direction | name the result you want and one constraint | until 2099-01-01\n' \
  > "$PN_TMP/cfg/learner/pilot.md"
[ -z "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge is silent when pilot.md holds only settled manoeuvre history" \
  || ko "pilot-nudge is silent when pilot.md holds only settled manoeuvre history"

# 9. A pipe inside the constraint text must not disable expiry, and must not
#    make the parser misread the date either. Under malformed-is-silent, a
#    PAST date can't discriminate the parser: the naive 3-field split and the
#    correct one both end up silent for a past date (the naive split loses
#    the date entirely and reads as malformed; the correct one reads it and
#    finds it expired) — silent either way, so that assertion proves nothing
#    about which parser ran. A date of TODAY does discriminate: the correct
#    parser reads it, today is not past, and the hook must speak; the naive
#    parser loses the date to the pipe and goes silent as malformed. Computed,
#    not hardcoded, so this does not start failing tomorrow.
PN_TODAY=$(date +%F)
pn_reset
printf '# Manoeuvres\n\n- live: direction | rule with a | pipe inside | until %s\n' "$PN_TODAY" \
  > "$PN_TMP/cfg/learner/pilot.md"
[ -n "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge speaks for a manoeuvre whose constraint contains a pipe and expires today" \
  || ko "pilot-nudge speaks for a manoeuvre whose constraint contains a pipe and expires today"
pn_reset
printf '# Manoeuvres\n\n- live: direction | rule with a | pipe inside | until 2099-01-01\n' \
  > "$PN_TMP/cfg/learner/pilot.md"
[ -n "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge still speaks for a live manoeuvre whose constraint contains a pipe" \
  || ko "pilot-nudge still speaks for a live manoeuvre whose constraint contains a pipe"

# 10. A malformed manoeuvre is not live: fail toward silence, never toward
#     nudging forever. Reverses the old default, which treated all three of
#     these shapes as "never expires".
pn_reset
printf '# Manoeuvres\n\n- live: direction | name the result you want and one constraint\n' \
  > "$PN_TMP/cfg/learner/pilot.md"
[ -z "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge stays silent when the until field is missing entirely" \
  || ko "pilot-nudge stays silent when the until field is missing entirely"
pn_reset
printf '# Manoeuvres\n\n- live: direction | name the result you want | whenever\n' \
  > "$PN_TMP/cfg/learner/pilot.md"
[ -z "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge stays silent when the last field is not until-shaped" \
  || ko "pilot-nudge stays silent when the last field is not until-shaped"
pn_reset
printf '# Manoeuvres\n\n- live: direction | name the result you want | until not-a-date\n' \
  > "$PN_TMP/cfg/learner/pilot.md"
[ -z "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge stays silent when the until date is garbage" \
  || ko "pilot-nudge stays silent when the until date is garbage"

# 11. A question is the opposite of delegated thinking: exempt outright, even
#     when short and otherwise vague.
pn_reset; pn_live direction "2099-01-01"
[ -z "$(pn_run 'explain what this error means?')" ] \
  && ok "pilot-nudge exempts a prompt with a question mark" \
  || ko "pilot-nudge exempts a prompt with a question mark"
pn_reset; pn_live direction "2099-01-01"
[ -z "$(pn_run 'why is CI failing')" ] \
  && ok "pilot-nudge exempts a prompt starting with an interrogative word" \
  || ko "pilot-nudge exempts a prompt starting with an interrogative word"

# 11b. An auxiliary (is/are/does/do/can/should) is not a wh-word: a prompt
#      starting with one, and carrying no question mark, is a vague
#      delegation ("do the refactor"), not a question, and must still nudge.
#      Guards against the exemption list quietly growing back to swallow it.
pn_reset; pn_live direction "2099-01-01"
[ -n "$(pn_run 'do the refactor')" ] \
  && ok "pilot-nudge nudges an auxiliary-led delegation with no question mark" \
  || ko "pilot-nudge nudges an auxiliary-led delegation with no question mark"

# 12. Once per session: the nudge fires at most once, no matter how many vague
#     prompts follow in the same session.
pn_reset; pn_live direction "2099-01-01"
[ -n "$(pn_run 'fix it' CAP1)" ] \
  && ok "pilot-nudge speaks on the first vague prompt of a session" \
  || ko "pilot-nudge speaks on the first vague prompt of a session"
[ -z "$(pn_run 'fix it' CAP1)" ] \
  && ok "pilot-nudge stays silent on a second vague prompt in the same session" \
  || ko "pilot-nudge stays silent on a second vague prompt in the same session"
rm -f "${TMPDIR:-/tmp}/claude-learner-CAP1.pilot-nudged"

# 13. brief.md is explicit that only `direction` has a UserPromptSubmit
#     mechanism — "the other three axes have no UserPromptSubmit mechanism".
#     A live manoeuvre on verification, contradiction or writing must leave
#     this hook silent no matter how vague the prompt is: the vagueness test
#     is direction-only by design, not merely untested for the other three.
pn_reset; pn_live verification "2099-01-01"
[ -z "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge stays silent for a live verification manoeuvre, however vague the prompt" \
  || ko "pilot-nudge stays silent for a live verification manoeuvre, however vague the prompt"
pn_reset; pn_live contradiction "2099-01-01"
[ -z "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge stays silent for a live contradiction manoeuvre, however vague the prompt" \
  || ko "pilot-nudge stays silent for a live contradiction manoeuvre, however vague the prompt"
pn_reset; pn_live writing "2099-01-01"
[ -z "$(pn_run 'fix it')" ] \
  && ok "pilot-nudge stays silent for a live writing manoeuvre, however vague the prompt" \
  || ko "pilot-nudge stays silent for a live writing manoeuvre, however vague the prompt"

# 11. disabledPaths silences the nudge too, even with a live, unexpired,
#     direction manoeuvre and a maximally vague prompt — the one combination
#     that would otherwise be guaranteed to speak.
PN_DIS_REPO="$WORK/pn-disabled-repo"; rm -rf "$PN_DIS_REPO"; mkdir -p "$PN_DIS_REPO"
git -C "$PN_DIS_REPO" init -q
pn_reset; pn_live direction "2099-01-01"
printf '{"pilotEnabled":true,"disabledPaths":["%s"]}' "$PN_DIS_REPO" > "$PN_TMP/cfg/learner.json"
PN_OUT=$(printf '{"session_id":"N1","prompt":"fix it","cwd":"%s"}' "$PN_DIS_REPO" \
  | (cd "$PN_DIS_REPO" && CLAUDE_CONFIG_DIR="$PN_TMP/cfg" CLAUDE_PROJECT_DIR="$PN_DIS_REPO" sh "$PLUG/hooks/pilot-nudge.sh"))
[ -z "$PN_OUT" ] \
  && ok "pilot-nudge is silent inside a disabledPaths repo" \
  || ko "pilot-nudge is silent inside a disabledPaths repo"

# --- pilot brief protocol and mechanisms corpus -----------------------------
# The nudge parses this line by field. If the brief writes a different shape,
# the manoeuvre is silently inert — the worst kind of broken, because the
# dashboard still says a manoeuvre is live.
grep -q '^- live: [a-z]* | .* | until [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$' \
  plugins/learner/skills/pilot/references/brief.md \
  && ok "brief.md states the manoeuvre line format the nudge parses" \
  || ko "brief.md states the manoeuvre line format the nudge parses"

# Round-trip the documented example through the nudge's own parser.
BR_TMP="$WORK/brief-format"; rm -rf "$BR_TMP"; mkdir -p "$BR_TMP/cfg/learner" "$BR_TMP/wd"
printf '{"pilotEnabled":true}' > "$BR_TMP/cfg/learner.json"
grep -m1 '^- live: ' plugins/learner/skills/pilot/references/brief.md \
  | sed 's/until [0-9-]*/until 2099-01-01/' > "$BR_TMP/cfg/learner/pilot.md"
printf '{"session_id":"R1","prompt":"fix it","cwd":"%s"}' "$BR_TMP/wd" \
  | (cd "$BR_TMP/wd" && CLAUDE_CONFIG_DIR="$BR_TMP/cfg" sh "$PLUG/hooks/pilot-nudge.sh") \
  | jq -e '.hookSpecificOutput.additionalContext | test("axis: direction")' >/dev/null \
  && ok "the manoeuvre line documented in brief.md parses in pilot-nudge.sh" \
  || ko "the manoeuvre line documented in brief.md parses in pilot-nudge.sh"

# One mechanism per brief, and the numbers cited rather than invented. The
# ~17%/~46% figures were traced back to a research summary, not the paper —
# none of the three cited sources publishes either number — so the entry must
# no longer assert them; the qualitative finding they were standing in for
# (weakest connectivity, markedly worse recall) is what the sources actually
# support and must survive the edit.
if grep -q '17%' plugins/learner/skills/pilot/references/mechanisms.md \
   || grep -q '46%' plugins/learner/skills/pilot/references/mechanisms.md; then
  ko "mechanisms.md no longer cites the untraceable ~17%/~46% figures"
else
  ok "mechanisms.md no longer cites the untraceable ~17%/~46% figures"
fi
grep -qi 'weakest neural connectivity' plugins/learner/skills/pilot/references/mechanisms.md \
  && ok "mechanisms.md keeps the qualitative connectivity finding the sources support" \
  || ko "mechanisms.md keeps the qualitative connectivity finding the sources support"
grep -q 'media.mit.edu' plugins/learner/skills/pilot/references/mechanisms.md \
  && ok "mechanisms.md links its source" || ko "mechanisms.md links its source"
grep -qF '54 subjects' plugins/learner/skills/pilot/references/mechanisms.md \
  && ok "mechanisms.md pins the 54-subject count to sessions 1-3" \
  || ko "mechanisms.md pins the 54-subject count to sessions 1-3"
grep -qF '18' plugins/learner/skills/pilot/references/mechanisms.md \
  && ok "mechanisms.md notes the fourth session's smaller subject count" \
  || ko "mechanisms.md notes the fourth session's smaller subject count"
grep -qi 'context-dependent' plugins/learner/skills/pilot/references/mechanisms.md \
  && ok "mechanisms.md notes the study's own context-dependent limitation" \
  || ko "mechanisms.md notes the study's own context-dependent limitation"
grep -qi 'one mechanism' plugins/learner/skills/pilot/references/brief.md \
  && ok "brief.md limits a brief to one mechanism" \
  || ko "brief.md limits a brief to one mechanism"
grep -qi 'not a failure\|deferral' plugins/learner/skills/pilot/references/brief.md \
  && ok "brief.md treats a deferral as a deferral" \
  || ko "brief.md treats a deferral as a deferral"

# The hook-level Sessions-row floor (pilot-brief.sh) is a cheap count, not a
# check of which axes actually cleared their own per-axis floor — brief.md
# must still check the Index block itself before running the four movements.
grep -qiE 'enough.*to argue from' plugins/learner/skills/pilot/references/brief.md \
  && ok "brief.md guards the four movements on the gating axes' own floor" \
  || ko "brief.md guards the four movements on the gating axes' own floor"

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

# --- coach config -----------------------------------------------------------
echo '{"level":"C"}' > "$GCFG"
rm -f "$PCFG"
out=$(cfgsh 'learner_config')
{ [ "$(echo "$out" | jq -r .coach)" = "false" ] \
  && [ "$(echo "$out" | jq -r .coachPollSeconds)" = "30" ] \
  && [ "$(echo "$out" | jq -r .coachQuietPolls)" = "1" ] \
  && [ "$(echo "$out" | jq -r .coachMinLines)" = "10" ] \
  && [ "$(echo "$out" | jq -r .coachCooldownMinutes)" = "3" ] \
  && [ "$(echo "$out" | jq -r .coachMaxWaitMinutes)" = "15" ] \
  && [ "$(echo "$out" | jq -r .coachIdleMinutes)" = "45" ]; } \
  && ok "coach defaults are present" || ko "coach defaults are present"

# The v1 keys are gone from the defaults. A config that still carries one must
# not fail — it simply has no effect — but the default set must not resurrect it.
{ [ "$(echo "$out" | jq -r '.coachCadence // "absent"')" = "absent" ] \
  && [ "$(echo "$out" | jq -r '.coachWorkMinutes // "absent"')" = "absent" ] \
  && [ "$(echo "$out" | jq -r '.coachIdleCycles // "absent"')" = "absent" ]; } \
  && ok "the pomodoro keys are gone from the defaults" \
  || ko "the pomodoro keys are gone from the defaults"

echo '{"level":"C","coach":true,"coachCadence":"threshold","coachWorkMinutes":25}' > "$GCFG"
out=$(cfgsh 'learner_config')
{ [ "$(echo "$out" | jq -r .coach)" = "true" ] \
  && [ "$(echo "$out" | jq -r .coachQuietPolls)" = "1" ]; } \
  && ok "a config still carrying v1 keys still resolves" \
  || ko "a config still carrying v1 keys still resolves"

# `coach` is a boolean, so it must survive the `*` merge (which `//` would break).
echo '{"level":"C","coach":true}' > "$GCFG"
echo '{"coach":false}' > "$PCFG"
out=$(cfgsh 'learner_config')
[ "$(echo "$out" | jq -r .coach)" = "false" ] \
  && ok "project layer can turn coach off" || ko "project layer can turn coach off"

echo '{"level":"C","coach":false}' > "$GCFG"
echo '{"coach":true,"coachMinLines":25}' > "$PCFG"
out=$(cfgsh 'learner_config')
{ [ "$(echo "$out" | jq -r .coach)" = "true" ] \
  && [ "$(echo "$out" | jq -r .coachMinLines)" = "25" ]; } \
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

# --- coach cadence clamps ---------------------------------------------------
# learner_int's third argument is a floor: RAW below it is treated as invalid
# and FALLBACK is returned instead (see learner_int's own header comment). A
# zero or negative value in the config must never produce a loop that spins
# or an emission on every poll — it must resolve to the safe default.
echo '{"level":"C","coach":true,"coachQuietPolls":0,"coachMinLines":0,"coachPollSeconds":1}' > "$GCFG"
rm -f "$PCFG"
out=$(cfgsh 'learner_config')
{ [ "$(cfgsh "learner_int \"\$(printf '%s' '$out' | jq -r .coachQuietPolls)\" 1 1")" = "1" ] \
  && [ "$(cfgsh "learner_int \"\$(printf '%s' '$out' | jq -r .coachMinLines)\" 10 1")" = "10" ] \
  && [ "$(cfgsh "learner_int \"\$(printf '%s' '$out' | jq -r .coachPollSeconds)\" 30 5")" = "30" ]; } \
  && ok "coachQuietPolls, coachMinLines and coachPollSeconds fall back below their floors" \
  || ko "coachQuietPolls, coachMinLines and coachPollSeconds fall back below their floors"

# coachCooldownMinutes and coachMaxWaitMinutes legitimately accept 0 (no floor,
# guard disabled) — their learner_int floor is 0, not 1.
echo '{"level":"C","coach":true,"coachCooldownMinutes":0,"coachMaxWaitMinutes":0}' > "$GCFG"
out=$(cfgsh 'learner_config')
{ [ "$(cfgsh "learner_int \"\$(printf '%s' '$out' | jq -r .coachCooldownMinutes)\" 3 0")" = "0" ] \
  && [ "$(cfgsh "learner_int \"\$(printf '%s' '$out' | jq -r .coachMaxWaitMinutes)\" 15 0")" = "0" ]; } \
  && ok "cooldown and max-wait accept 0" || ko "cooldown and max-wait accept 0"

# --- learner_int leading-zero safety (regression) ---------------------------
# /bin/sh's POSIX-mode arithmetic parses a leading-zero digit string as octal
# and aborts on an invalid digit (e.g. "008"); learner_int's digit-only guard
# lets such a string through, so it must normalise before ever reaching a
# caller's $(( )). Driven through cfgsh (sh -c), the interpreter every hook
# actually runs under: this does NOT reproduce under an interactive zsh, where
# $((008)) silently evaluates to 8, so asserting on the numeric result (not
# just "no error") is what keeps this test meaningful.
li() { cfgsh "learner_int '$1' '$2' '$3'"; }
[ "$(li 008 25 1)" = "8" ]  && ok "learner_int strips leading zeros (008 -> 8)" \
  || ko "learner_int strips leading zeros (008 -> 8)"
[ "$(li 0 5 0)" = "0" ]    && ok "learner_int keeps a legitimate 0 at floor 0" \
  || ko "learner_int keeps a legitimate 0 at floor 0"
[ "$(li 00 5 0)" = "0" ]   && ok "learner_int normalises 00 to 0 at floor 0" \
  || ko "learner_int normalises 00 to 0 at floor 0"
[ "$(li 25 5 1)" = "25" ]  && ok "learner_int leaves a plain 25 unchanged" \
  || ko "learner_int leaves a plain 25 unchanged"

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

# --- docs/config.html: coach* keys prose count matches its table -----------
# Retargeted from the old pomodoro/threshold split (coach-v2 collapsed that
# to one pause-driven cadence, leaving no per-clock prose to guard), but the
# underlying guard is the same: the prose's key-count word must track the
# table's actual row count, counted dynamically rather than hard-coded, so a
# row added or removed later turns this red instead of leaving a stale count
# silently wrong — the exact defect ("twelve" surviving a table that grew to
# ten, then a table shrunk to seven still saying "six") this table has hit
# twice now.
tcount=$(awk '/<tbody class="group-coach">/,/<\/tbody>/' "$ROOT/docs/config.html" | grep -c '<tr>')
case "$tcount" in
  4) tword=four ;;
  5) tword=five ;;
  6) tword=six ;;
  7) tword=seven ;;
  8) tword=eight ;;
  *) tword='__no-word-mapped__' ;;
esac
grep -qF "The $tword <code>coach*</code> keys" "$ROOT/docs/config.html" \
  && ok "config.html's coach* key-count prose matches its table ($tcount)" \
  || ko "config.html's coach* key-count prose matches its table ($tcount)"

# --- onboarding -------------------------------------------------------------
rm -f "$GCFG" "$PCFG"
out=$(printf '{}' | sh "$ONB")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("learner config")' >/dev/null 2>&1 \
  && ok "onboard nags when no level is configured" \
  || ko "onboard nags when no level is configured"

printf '%s' "$out" | grep -qiE 'recapEvery|trouBlanks|language|trackGlobs' \
  && ko "onboard mentions no removed config key" \
  || ok "onboard mentions no removed config key"

echo '{"level":"S"}' > "$GCFG"
out=$(printf '{}' | sh "$ONB")
[ -z "$out" ] && ok "onboard silent once a level is set" \
             || ko "onboard silent once a level is set"

echo '{"level":"S","enabled":false}' > "$GCFG"
out=$(printf '{}' | sh "$ONB")
[ -z "$out" ] && ok "onboard silent when deliberately disabled" \
             || ko "onboard silent when deliberately disabled"

NOJQ_ONB_PATH="$WORK/tmp/no-jq-onb-path"
mkdir -p "$NOJQ_ONB_PATH"
out=$(printf '{}' | PATH="$NOJQ_ONB_PATH" /bin/sh "$ONB" 2>/dev/null)
printf '%s' "$out" | grep -q 'jq.*is not on PATH' \
  && ok "onboard warns when jq is missing" \
  || ko "onboard warns when jq is missing"

rm -f "$GCFG" "$PCFG"
out=$(printf '{}' | CLAUDE_PROJECT_DIR="$WORK/tmp" sh "$ONB")
[ -z "$out" ] && ok "onboard silent outside a git repo" \
             || ko "onboard silent outside a git repo"
echo '{"level":"S"}' > "$GCFG"

# --- installed twice ---------------------------------------------------------
# The plugin wiring and the $CLAUDE_CONFIG_DIR/settings.json wiring cannot see each
# other, so both at once silently runs every hook twice and quizzes the dev twice per
# turn. Nothing but this hook is in a position to notice.
DBL="$WORK/dbl"; mkdir -p "$DBL/hooks"
echo '{"level":"S"}' > "$DBL/learner.json"
cp "$PLUG/hooks/learner-quiz.sh" "$DBL/hooks/learner-quiz.sh"
out=$(printf '{}' | CLAUDE_CONFIG_DIR="$DBL" sh "$ONB")
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("installed twice")' >/dev/null 2>&1 \
  && ok "onboard reports a plugin install sitting on top of a traditional one" \
  || ko "onboard reports a plugin install sitting on top of a traditional one"

# …and says which one to remove, since the plugin is the one Claude Code can update.
printf '%s' "$out" | grep -qF 'learner-uninstall' \
  && ok "the installed-twice nudge names the uninstall route" \
  || ko "the installed-twice nudge names the uninstall route"

# Two plugin copies are the other way to be wired twice, and the traditional-install
# check above cannot see it — neither copy is the traditional install. SessionStart runs
# the hook once per wired copy, so the second one along finds a stranger's directory in
# the per-session file and says so; the first stays silent, having nothing to compare to.
DBL2="$WORK/dbl2"; mkdir -p "$DBL2/a/hooks" "$DBL2/b/hooks" "$DBL2/cfg" "$DBL2/tmp"
echo '{"level":"S"}' > "$DBL2/cfg/learner.json"
for side in a b; do
  cp "$PLUG/hooks/learner-onboard.sh" "$PLUG/hooks/learner-config.sh" "$DBL2/$side/hooks/"
done
onb2() { printf '{"session_id":"dblsid"}' \
  | CLAUDE_CONFIG_DIR="$DBL2/cfg" CLAUDE_PROJECT_DIR="$WORK/tmp" TMPDIR="$DBL2/tmp" \
    sh "$DBL2/$1/hooks/learner-onboard.sh"; }

out=$(onb2 a)
printf '%s' "$out" | grep -qF 'wired twice as a plugin' \
  && ko "the first plugin copy stays silent" \
  || ok "the first plugin copy stays silent"

out=$(onb2 b)
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("wired twice as a plugin")' >/dev/null 2>&1 \
  && ok "the second plugin copy reports the duplicate wiring" \
  || ko "the second plugin copy reports the duplicate wiring"

# Naming both directories is the whole point: "one of them" is not actionable.
printf '%s' "$out" | grep -qF "$DBL2/a/hooks" && printf '%s' "$out" | grep -qF "$DBL2/b/hooks" \
  && ok "the duplicate-wiring nudge names both copies" \
  || ko "the duplicate-wiring nudge names both copies"

# Re-entry by the same copy is not a duplicate — a resumed session must not cry wolf.
out=$(onb2 a)
printf '%s' "$out" | grep -qF 'wired twice as a plugin' \
  && ko "a copy that already reported does not re-report" \
  || ok "a copy that already reported does not re-report"
rm -rf "$DBL2"

# The mirror case: the SAME copy, running as the traditional install, must stay silent.
# The test is "two installs", not "these files exist".
cp "$PLUG/hooks/learner-onboard.sh" "$PLUG/hooks/learner-config.sh" "$DBL/hooks/"
out=$(printf '{}' | CLAUDE_CONFIG_DIR="$DBL" CLAUDE_PROJECT_DIR="$WORK/tmp" sh "$DBL/hooks/learner-onboard.sh")
printf '%s' "$out" | grep -qF 'installed twice' \
  && ko "a lone traditional install is not reported as a double install" \
  || ok "a lone traditional install is not reported as a double install"
rm -rf "$DBL"

# --- update-check hook -------------------------------------------------------
uchk() { printf '{}' | sh "$UCHK"; }
VFIX="$WORK/tmp/remote-version"

UC1="$WORK/uc1"; mkdir -p "$UC1/skills/learner"
echo '0.1.0' > "$UC1/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC1" LEARNER_VERSION_URL="file://$VFIX" uchk)
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("v0\\.2\\.0.*v0\\.1\\.0")' >/dev/null 2>&1 \
  && ok "update-check notifies with remote and installed version when remote is newer" \
  || ko "update-check notifies with remote and installed version when remote is newer (got '$out')"

UC2="$WORK/uc2"; mkdir -p "$UC2/skills/learner"
echo '0.2.0' > "$UC2/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC2" LEARNER_VERSION_URL="file://$VFIX" uchk)
[ -z "$out" ] \
  && ok "update-check silent when versions are equal" \
  || ko "update-check silent when versions are equal (got '$out')"

UC3="$WORK/uc3"; mkdir -p "$UC3/skills/learner"
echo '0.3.0' > "$UC3/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC3" LEARNER_VERSION_URL="file://$VFIX" uchk)
[ -z "$out" ] \
  && ok "update-check silent when the installed version is newer than remote" \
  || ko "update-check silent when the installed version is newer than remote (got '$out')"

UC4="$WORK/uc4"; mkdir -p "$UC4/skills/learner"
printf '0.2.0' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC4" LEARNER_VERSION_URL="file://$VFIX" uchk)
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("none installed")' >/dev/null 2>&1 \
  && ok "update-check notifies unconditionally when no local VERSION file exists" \
  || ko "update-check notifies unconditionally when no local VERSION file exists (got '$out')"

UC5="$WORK/uc5"; mkdir -p "$UC5/skills/learner"
echo '0.1.0' > "$UC5/skills/learner/VERSION"
printf 'not-a-version' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC5" LEARNER_VERSION_URL="file://$VFIX" uchk)
[ -z "$out" ] \
  && ok "update-check silent on malformed remote content" \
  || ko "update-check silent on malformed remote content (got '$out')"

UC6="$WORK/uc6"; mkdir -p "$UC6/skills/learner"
printf 'not-a-version' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC6" LEARNER_VERSION_URL="file://$VFIX" uchk)
[ -z "$out" ] \
  && ok "update-check silent on malformed remote even with no local VERSION" \
  || ko "update-check silent on malformed remote even with no local VERSION (got '$out')"

# Everything except curl: date/mkdir/dirname/cat are the hook's other externals,
# and an empty PATH (the trick used for jq elsewhere in this suite) would break
# those too, before the curl check is ever reached.
NOCURL_PATH="$WORK/tmp/no-curl-path"; mkdir -p "$NOCURL_PATH"
for b in date mkdir dirname cat; do
  bp=$(command -v "$b") && ln -sf "$bp" "$NOCURL_PATH/$b"
done
UC7="$WORK/uc7"; mkdir -p "$UC7/skills/learner"
echo '0.1.0' > "$UC7/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
out=$(printf '{}' | CLAUDE_CONFIG_DIR="$UC7" LEARNER_VERSION_URL="file://$VFIX" PATH="$NOCURL_PATH" /bin/sh "$UCHK" 2>/dev/null)
rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } \
  && ok "update-check hook is silent, not an error, when curl is missing" \
  || ko "update-check hook is silent, not an error, when curl is missing (out='$out' rc=$rc)"

UC8="$WORK/uc8"; mkdir -p "$UC8/skills/learner"
echo '0.1.0' > "$UC8/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
CLAUDE_CONFIG_DIR="$UC8" LEARNER_VERSION_URL="file://$VFIX" uchk >/dev/null
out=$(CLAUDE_CONFIG_DIR="$UC8" LEARNER_VERSION_URL="file://$VFIX" uchk)
[ -z "$out" ] \
  && ok "update-check is throttled: a second call within 24h is silent" \
  || ko "update-check is throttled: a second call within 24h is silent (got '$out')"

UC9="$WORK/uc9"; mkdir -p "$UC9/skills/learner" "$UC9/learner"
echo '0.1.0' > "$UC9/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
printf '%s' "$(( $(date +%s) - 90000 ))" > "$UC9/learner/.last-update-check"
out=$(CLAUDE_CONFIG_DIR="$UC9" LEARNER_VERSION_URL="file://$VFIX" uchk)
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("0\\.2\\.0")' >/dev/null 2>&1 \
  && ok "update-check proceeds again once the throttle stamp is 25h old" \
  || ko "update-check proceeds again once the throttle stamp is 25h old (got '$out')"

UC10="$WORK/uc10"; mkdir -p "$UC10/skills/learner"
echo '0.1.0' > "$UC10/skills/learner/VERSION"
CLAUDE_CONFIG_DIR="$UC10" LEARNER_VERSION_URL="file:///no/such/file" uchk >/dev/null 2>&1
[ -f "$UC10/learner/.last-update-check" ] \
  && ok "update-check writes the throttle stamp even when the fetch fails" \
  || ko "update-check writes the throttle stamp even when the fetch fails"

# --- record-edit ------------------------------------------------------------
echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"
rec() { printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" | sh "$REC"; }

SID=rec1
rec "$SID" "$WORK/proj/src/Foo.kt"
grep -q 'Foo.kt' "$(edits "$SID")" 2>/dev/null \
  && ok "records an ordinary source file" \
  || ko "records an ordinary source file"

rec "$SID" "$WORK/proj/docs/notes.md"
grep -q 'notes.md' "$(edits "$SID")" 2>/dev/null \
  && ok "records any extension by default (exclusion-list model)" \
  || ko "records any extension by default (exclusion-list model)"

for p in build/Gen.kt node_modules/x/index.js dist/app.js vendor/lib.php \
         coverage/report.html __snapshots__/a.snap pnpm-lock.yaml app.min.js \
         schema.generated.ts Cargo.lock; do
  SIDF="floor-$(echo "$p" | tr '/.' '--')"
  rec "$SIDF" "$WORK/proj/$p"
  [ -s "$(edits "$SIDF")" ] \
    && ko "exclusion floor drops $p" \
    || ok "exclusion floor drops $p"
done

echo '{"level":"S","untrackGlobs":["*.md","*/generated/*"]}' > "$GCFG"
SID3=rec3
rec "$SID3" "$WORK/proj/README.md"
rec "$SID3" "$WORK/proj/src/generated/api.ts"
rec "$SID3" "$WORK/proj/src/Real.kt"
{ ! grep -q 'README.md' "$(edits "$SID3")" 2>/dev/null \
  && ! grep -q 'generated/api.ts' "$(edits "$SID3")" 2>/dev/null \
  && grep -q 'Real.kt' "$(edits "$SID3")" 2>/dev/null; } \
  && ok "untrackGlobs excludes on top of the floor" \
  || ko "untrackGlobs excludes on top of the floor"
echo '{"level":"S"}' > "$GCFG"

SID4=rec4
rm -f "$GCFG"
rec "$SID4" "$WORK/proj/src/Bar.kt"
[ -s "$(edits "$SID4")" ] \
  && ko "no-op when no level is configured" \
  || ok "no-op when no level is configured"
echo '{"level":"S"}' > "$GCFG"

SID5=rec5
printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$SID5" "$WORK/tmp/loose.kt" \
  | CLAUDE_PROJECT_DIR="$WORK/tmp" sh "$REC"
[ -s "$(edits "$SID5")" ] \
  && ko "no-op outside a git repo" \
  || ok "no-op outside a git repo"

SID6=rec6
echo '{"level":"S","disabledPaths":["'"$WORK/proj"'"]}' > "$GCFG"
rec "$SID6" "$WORK/proj/src/Baz.kt"
[ -s "$(edits "$SID6")" ] \
  && ko "no-op when the repo is under disabledPaths" \
  || ok "no-op when the repo is under disabledPaths"
echo '{"level":"S"}' > "$GCFG"

# Quiz material is repo material: a `fill` hole cut outside the repo would sit
# where the Stop hook's guardrail can never see it.
SID7=rec7
rec "$SID7" "$WORK/outside.kt"
[ -s "$(edits "$SID7")" ] \
  && ko "an edit outside the repo is never recorded" \
  || ok "an edit outside the repo is never recorded"

SID8=rec8
rec "$SID8" "${WORK}/projX/src/Sibling.kt"
[ -s "$(edits "$SID8")" ] \
  && ko "a sibling directory sharing the repo's name prefix is not recorded" \
  || ok "a sibling directory sharing the repo's name prefix is not recorded"

# …but a repo opened through a symlink must still be recorded: the root is physical
# (git rev-parse --show-toplevel) while file_path is whatever path the session used.
# $WORK is pre-resolved at the top of this file, so this needs its own symlink, and
# a real directory, since resolving a path means visiting it.
SID9=rec9
mkdir -p "$WORK/proj/src"
ln -sfn "$WORK/proj" "$WORK/projlink"
printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$SID9" "$WORK/projlink/src/Sym.kt" \
  | CLAUDE_PROJECT_DIR="$WORK/projlink" sh "$REC"
[ -s "$(edits "$SID9")" ] \
  && ok "an edit reaching the repo through a symlink is still recorded" \
  || ko "an edit reaching the repo through a symlink is still recorded"

# --- quiz (Stop hook) -------------------------------------------------------
quiz() { printf '{"session_id":"%s","stop_hook_active":%s}' "$1" "${2:-false}" | sh "$QUIZ"; }

echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"
SIDQ=quiz1
rec "$SIDQ" "$WORK/proj/src/Foo.kt"
out=$(quiz "$SIDQ")
echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && ok "quiz blocks once when edits are pending" \
  || ko "quiz blocks once when edits are pending"

reason=$(echo "$out" | jq -r '.reason')
lines=$(printf '%s\n' "$reason" | wc -l | tr -d ' ')
[ "$lines" -le 3 ] \
  && ok "block reason stays within 3 lines (console stays quiet)" \
  || ko "block reason stays within 3 lines (got $lines)"

printf '%s' "$reason" | grep -q 'references/hook-quiz.md' \
  && ok "block reason points at the skill protocol" \
  || ko "block reason points at the skill protocol"

printf '%s' "$reason" | grep -qiE 'memory\.md|recap\.md|spaced repetition' \
  && ko "block reason carries no protocol prose" \
  || ok "block reason carries no protocol prose"

printf '%s' "$reason" | grep -q 'level: S' \
  && ok "block reason carries the canonical level letter" \
  || ko "block reason carries the canonical level letter"

printf '%s' "$reason" | grep -q 'mode: granular' \
  && ok "first question is granular" \
  || ko "first question is granular"

printf '%s' "$reason" | grep -q 'styles: auto' \
  && ok "block reason carries the styles field" \
  || ko "block reason carries the styles field"

printf '%s' "$reason" | grep -qF -- '— files:' \
  && ok "block reason carries the files field" \
  || ko "block reason carries the files field"

# often = every 2nd question is a synthesis
echo '{"level":"S","synthesisFrequency":"often"}' > "$GCFG"
SIDS=quiz2
rec "$SIDS" "$WORK/proj/src/A.kt"
quiz "$SIDS" >/dev/null
rec "$SIDS" "$WORK/proj/src/B.kt"
printf '%s' "$(quiz "$SIDS" | jq -r .reason)" | grep -q 'mode: synthesis' \
  && ok "synthesisFrequency=often makes question 2 a synthesis" \
  || ko "synthesisFrequency=often makes question 2 a synthesis"

# off = never a synthesis
echo '{"level":"S","synthesisFrequency":"off"}' > "$GCFG"
SIDO=quiz3
for i in 1 2 3 4 5; do rec "$SIDO" "$WORK/proj/src/O$i.kt"; quiz "$SIDO" > "$WORK/o$i.json"; done
grep -l 'mode: synthesis' "$WORK"/o*.json >/dev/null 2>&1 \
  && ko "synthesisFrequency=off never triggers a synthesis" \
  || ok "synthesisFrequency=off never triggers a synthesis"

echo '{"level":"S","blanksPerExercise":4}' > "$GCFG"
SIDB=quiz4
rec "$SIDB" "$WORK/proj/src/C.kt"
printf '%s' "$(quiz "$SIDB" | jq -r .reason)" | grep -q 'blanks: 4' \
  && ok "blanksPerExercise reaches the trigger" \
  || ko "blanksPerExercise reaches the trigger"

echo '{"level":"S"}' > "$GCFG"
SIDL=quiz5
rec "$SIDL" "$WORK/proj/src/D.kt"
out=$(quiz "$SIDL" true)
[ -z "$out" ] && ok "quiz respects stop_hook_active (no loop)" \
             || ko "quiz respects stop_hook_active (no loop)"

echo '{"level":"S","enabled":false}' > "$GCFG"
SIDE=quiz6
rec "$SIDE" "$WORK/proj/src/E.kt"    # record-edit is inert too, so pre-arm by hand
echo "$WORK/proj/src/E.kt" > "$(edits "$SIDE")"
out=$(quiz "$SIDE")
[ -z "$out" ] && ok "enabled=false silences the quiz" \
             || ko "enabled=false silences the quiz"
echo '{"level":"S"}' > "$GCFG"

out=$(quiz "no-edits-sid")
[ -z "$out" ] && ok "quiz silent when nothing was edited" \
             || ko "quiz silent when nothing was edited"

# Item 1 sweep regression: the Stop hook's final `: > "$STATE"` consumes the
# pending-edit file after building the trigger. `:` is a POSIX special
# built-in, so a redirection failure on it aborts a non-interactive shell
# outright under dash — on a Stop hook that abort's exit 2 IS the deliberate
# block signal, so a read-only .edits file would hand the dev an inexplicable
# block instead of the quiz simply skipping a turn. Capture the status, not
# just stdout: an assertion on empty output alone would also pass against a
# crashed script.
SIDRO=quiz-ro
rec "$SIDRO" "$WORK/proj/src/F.kt"
chmod 444 "$(edits "$SIDRO")"
out=$(quiz "$SIDRO" 2>/dev/null); rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } \
  && ok "quiz exits 0 with no output when its .edits file cannot be truncated" \
  || ko "quiz exits 0 with no output when its .edits file cannot be truncated (rc=$rc out=$out)"
if command -v dash >/dev/null 2>&1; then
  out=$(printf '{"session_id":"%s","stop_hook_active":false}' "$SIDRO" | dash "$QUIZ" 2>/dev/null); rc=$?
  { [ -z "$out" ] && [ "$rc" = 0 ]; } \
    && ok "quiz exits 0 with no output under dash when its .edits file cannot be truncated" \
    || ko "quiz exits 0 with no output under dash when its .edits file cannot be truncated (rc=$rc out=$out)"
else
  echo "  (dash not found on this machine — the dash-specific read-only-.edits check was skipped, coverage not claimed)"
fi
chmod 644 "$(edits "$SIDRO")" 2>/dev/null
rm -f "$(edits "$SIDRO")"
# --- agent salvo: tracker ----------------------------------------------------
TRACK="$PLUG/hooks/learner-agent-track.sh"
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
[ "$(grep -c . "$(dispatched "$SIDA")")" = "1" ] \
  && ok "--start increments the dispatched counter" || ko "--start increments the dispatched counter"
grep -qF 'Refactor the repository layer' "$(agents "$SIDA")" \
  && ok "--start keeps the task description" || ko "--start keeps the task description"
grep -qF '  ' "$(agents "$SIDA")" \
  && ko "the recorded description carries no double space" \
  || ok "the recorded description carries no double space"

# FINDING 2: .agents-dispatched must not lose increments when several --start
# calls land at once — a batch of parallel Task dispatches is the spec's
# headline case for this feature, not an edge case. Backgrounded and waited,
# no sleep.
SIDPAR=salvopar
for i in 1 2 3 4 5 6; do
  tstart "$SIDPAR" "Parallel agent $i" >/dev/null &
done
wait
[ "$(grep -c . "$(agents "$SIDPAR")")" = "6" ] \
  && ok "six parallel --start calls record six in-flight agents" \
  || ko "six parallel --start calls record six in-flight agents (got $(grep -c . "$(agents "$SIDPAR")" 2>/dev/null))"
[ "$(grep -c . "$(dispatched "$SIDPAR")")" = "6" ] \
  && ok "six parallel --start calls all increment the dispatched counter" \
  || ko "six parallel --start calls all increment the dispatched counter (got $(grep -c . "$(dispatched "$SIDPAR")" 2>/dev/null))"

# The mirror race on --end is milder — two simultaneous returns can leave the
# in-flight count one too high, which over-reports but stays bounded and is
# reaped at SessionEnd either way — so it is left as-is; see the comment in
# hooks/learner-agent-track.sh.
grep -qF 'is acceptable' "$PLUG/hooks/learner-agent-track.sh" \
  && ok "learner-agent-track.sh explains why the --end race is left alone" \
  || ko "learner-agent-track.sh explains why the --end race is left alone"

# The anti-recursion contract: the salvo's own preparation agent must not arm a salvo.
SIDP=salvo2
tstart "$SIDP" "learner-prep: cut a fill exercise in Foo.kt"
[ ! -f "$(agents "$SIDP")" ] \
  && ok "a learner-prep: dispatch is never recorded" || ko "a learner-prep: dispatch is never recorded"
tstart "$SIDP" "   learner-prep: leading spaces still count"
[ ! -f "$(agents "$SIDP")" ] \
  && ok "leading whitespace does not defeat the learner-prep: contract" \
  || ko "leading whitespace does not defeat the learner-prep: contract"
tstart "$SIDP" '\tlearner-prep: a leading tab still counts'
[ ! -f "$(agents "$SIDP")" ] \
  && ok "a leading tab does not defeat the learner-prep: contract on --start" \
  || ko "a leading tab does not defeat the learner-prep: contract on --start"

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

# $1 session id, $2 optional description. A real PostToolUse payload can carry
# either shape — tool_input present, or absent entirely — and --end must
# behave correctly either way; the no-description call keeps exercising the
# no-tool_input shape, the with-description call is what lets the
# learner-prep: contract be pinned on --end at all.
tend() {
  if [ -n "${2:-}" ]; then
    printf '{"session_id":"%s","tool_name":"Task","tool_input":{"description":"%s"}}' \
      "$1" "$2" | sh "$TRACK" --end
  else
    printf '{"session_id":"%s","tool_name":"Task"}' "$1" | sh "$TRACK" --end
  fi
}

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
[ "$(grep -c . "$(dispatched "$SIDE")")" = "3" ] \
  && ok "--end leaves the dispatched counter alone while agents remain" \
  || ko "--end leaves the dispatched counter alone while agents remain"

echo 2 > "$(served "$SIDE")"
tend "$SIDE"; tend "$SIDE"
{ [ ! -f "$(agents "$SIDE")" ] && [ ! -f "$(dispatched "$SIDE")" ] && [ ! -f "$(served "$SIDE")" ]; } \
  && ok "the last --end deletes all three batch files" \
  || ko "the last --end deletes all three batch files"

# FINDING 1: --end must honour the learner-prep: contract exactly as --start
# does — the preparation agent's own return must never drain a REAL agent's
# in-flight count. Leading-space and leading-tab variants both count.
SIDPE=salvo6b
tstart "$SIDPE" "Agent one"; tstart "$SIDPE" "Agent two"
tend "$SIDPE" "learner-prep: cut a fill exercise in Foo.kt"
[ "$(grep -c . "$(agents "$SIDPE")")" = "2" ] \
  && ok "a learner-prep: --end never drains a real agent's in-flight count" \
  || ko "a learner-prep: --end never drains a real agent's in-flight count"
tend "$SIDPE" "  learner-prep: leading spaces still count on --end"
[ "$(grep -c . "$(agents "$SIDPE")")" = "2" ] \
  && ok "leading spaces do not defeat the learner-prep: contract on --end" \
  || ko "leading spaces do not defeat the learner-prep: contract on --end"
tend "$SIDPE" '\tlearner-prep: a leading tab still counts on --end'
[ "$(grep -c . "$(agents "$SIDPE")")" = "2" ] \
  && ok "a leading tab does not defeat the learner-prep: contract on --end" \
  || ko "a leading tab does not defeat the learner-prep: contract on --end"
tend "$SIDPE"
[ "$(grep -c . "$(agents "$SIDPE")")" = "1" ] \
  && ok "a real --end still drains normally after prep-agent --ends were ignored" \
  || ko "a real --end still drains normally after prep-agent --ends were ignored"
tend "$SIDPE"
[ ! -f "$(agents "$SIDPE")" ] \
  && ok "the batch still ends once every real agent has returned" \
  || ko "the batch still ends once every real agent has returned"

# The reviewer-recommended interleaved sequence: dispatch 3, serve a salvo,
# --end a learner-prep: agent (must not drain), --end a real agent (must
# drain), then a third salvo must still be owed. This is exactly what
# tend()'s old no-tool_input-at-all payload could never exercise — it is why
# the one-sided --end survived seven task reviews.
SIDIL=salvo6c
echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"
tstart "$SIDIL" "Agent one"; tstart "$SIDIL" "Agent two"; tstart "$SIDIL" "Agent three"
quiz "$SIDIL" >/dev/null                              # serve salvo 1/3
tend "$SIDIL" "learner-prep: cut a fill exercise"      # must not drain a real slot
tend "$SIDIL"                                          # a real agent's return
[ "$(grep -c . "$(agents "$SIDIL")")" = "2" ] \
  && ok "interleaved: a prep --end plus one real --end leaves 2 in flight" \
  || ko "interleaved: a prep --end plus one real --end leaves 2 in flight"
printf '%s' "$(quiz "$SIDIL" | jq -r '.reason // ""')" | grep -qF '🤖' \
  && ok "interleaved: a salvo still serves instead of the batch ending early" \
  || ko "interleaved: a salvo still serves instead of the batch ending early"
{ [ "$(cat "$(served "$SIDIL")")" = "2" ] && [ "$(grep -c . "$(dispatched "$SIDIL")")" = "3" ]; } \
  && ok "interleaved: a third salvo is still owed (served 2 of 3 dispatched)" \
  || ko "interleaved: a third salvo is still owed (served 2 of 3 dispatched)"

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

# FINDING 4: a crashed or `claude --resume`d session must not leave $AGENTS
# stale forever. Batch files are written directly here (bypassing tstart,
# which always stamps "now") so a line's age can be controlled precisely.
echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"
NOWTS=$(date +%s)
STALE_TS=$((NOWTS - 5 * 3600))   # 5h old, past the 4h staleness bound

SIDF1=salvofresh1
printf '%s\t%s\n' "$STALE_TS" "Stale agent" > "$(agents "$SIDF1")"
printf '%s\n' "$STALE_TS" > "$(dispatched "$SIDF1")"
echo 0 > "$(served "$SIDF1")"
printf '%s' "$(quiz "$SIDF1" | jq -r '.reason // ""')" | grep -qF '🤖' \
  && ko "an all-stale batch serves no salvo" || ok "an all-stale batch serves no salvo"
{ [ ! -f "$(agents "$SIDF1")" ] && [ ! -f "$(dispatched "$SIDF1")" ] && [ ! -f "$(served "$SIDF1")" ]; } \
  && ok "an all-stale batch is cleaned up (all three files removed)" \
  || ko "an all-stale batch is cleaned up (all three files removed)"

SIDF2=salvofresh2
printf '%s\t%s\n' "$NOWTS" "Fresh agent" > "$(agents "$SIDF2")"
printf '%s\n' "$NOWTS" > "$(dispatched "$SIDF2")"
printf '%s' "$(quiz "$SIDF2" | jq -r '.reason // ""')" | grep -qF '🤖' \
  && ok "a fresh line still serves a salvo" || ko "a fresh line still serves a salvo"

SIDF3=salvofresh3
{ printf '%s\t%s\n' "$STALE_TS" "Stale agent"; printf '%s\t%s\n' "$NOWTS" "Fresh agent"; } \
  > "$(agents "$SIDF3")"
printf '%s\n%s\n' "$STALE_TS" "$NOWTS" > "$(dispatched "$SIDF3")"
printf '%s' "$(quiz "$SIDF3" | jq -r '.reason // ""')" | grep -qF '🤖' \
  && ok "a mixed stale+fresh batch still serves a salvo (the fresh line is counted)" \
  || ko "a mixed stale+fresh batch still serves a salvo (the fresh line is counted)"

SIDF4=salvofresh4
printf '%s\t%s\n' "not-a-number" "Malformed epoch agent" > "$(agents "$SIDF4")"
printf '%s\n' "$NOWTS" > "$(dispatched "$SIDF4")"
printf '%s' "$(quiz "$SIDF4" | jq -r '.reason // ""')" | grep -qF '🤖' \
  && ok "a line with a malformed epoch counts as fresh, not stale" \
  || ko "a line with a malformed epoch counts as fresh, not stale"
grep -qF 'AGENT_STALE_SECONDS=14400' "$PLUG/hooks/learner-quiz.sh" \
  && ok "the staleness bound is a named constant, not a bare magic number" \
  || ko "the staleness bound is a named constant, not a bare magic number"

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

# --- agent salvo: wiring and cleanup -----------------------------------------
for f in "$PLUG/hooks/hooks.json" "$PLUG/hooks/settings.snippet.json"; do
  b=$(basename "$f")
  jq -e '[.hooks.PreToolUse[] | select(.matcher == "Task") | .hooks[].command]
         | map(select(test("learner-agent-track.sh"))) | length == 1' "$f" >/dev/null 2>&1 \
    && ok "$b wires the tracker on PreToolUse Task" || ko "$b wires the tracker on PreToolUse Task"
  jq -e '[.hooks.PostToolUse[] | select(.matcher == "Task") | .hooks[].command]
         | map(select(test("learner-agent-track.sh"))) | length == 1' "$f" >/dev/null 2>&1 \
    && ok "$b wires the tracker on PostToolUse Task" || ko "$b wires the tracker on PostToolUse Task"
  jq -e '[.. | .command? // empty] | map(select(test("learner-agent-track.sh\" --start"))) | length == 1' "$f" \
    >/dev/null 2>&1 \
    && ok "$b passes --start exactly once" || ko "$b passes --start exactly once"
  jq -e '[.. | .command? // empty] | map(select(test("learner-agent-track.sh\" --end"))) | length == 1' "$f" \
    >/dev/null 2>&1 \
    && ok "$b passes --end exactly once" || ko "$b passes --end exactly once"
  # The Task matcher must not sweep in Write/Edit, or every edit would look like an agent.
  jq -e '[.hooks.PostToolUse[] | select(.matcher == "Write|Edit") | .hooks[].command]
         | map(select(test("learner-agent-track.sh"))) | length == 0' "$f" >/dev/null 2>&1 \
    && ok "$b keeps the tracker out of the Write|Edit matcher" \
    || ko "$b keeps the tracker out of the Write|Edit matcher"
done

IT="$WORK/install-tracker"; rm -rf "$IT"; mkdir -p "$IT"
CLAUDE_CONFIG_DIR="$IT" bash "$ROOT/install.sh" --level S >/dev/null 2>&1
[ -x "$IT/hooks/learner-agent-track.sh" ] \
  && ok "install.sh copies the tracker" || ko "install.sh copies the tracker"
rm -rf "$IT"
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

# --- agent salvo: the skill protocol -----------------------------------------
SALVO_REF="$PLUG/skills/learner/references/agent-salvo.md"
SKILLMD="$PLUG/skills/learner/SKILL.md"

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

# FINDING 3: a 🤖 landing while a salvo is still open must be queued, never
# dropped — stop_hook_active only suppresses the very next Stop, so a later
# turn's Stop can fire a second salvo before the first has finished asking.
grep -qiF 'queued' "$SALVO_REF" \
  && ok "the protocol states the salvo-vs-salvo queue rule" \
  || ko "the protocol states the salvo-vs-salvo queue rule"
grep -qiF 'not dropped' "$SALVO_REF" \
  && ok "the protocol states a queued salvo is never dropped" \
  || ko "the protocol states a queued salvo is never dropped"

grep -qF '🤖' "$SKILLMD" \
  && ok "SKILL.md documents the salvo trigger" || ko "SKILL.md documents the salvo trigger"
grep -qF 'references/agent-salvo.md' "$SKILLMD" \
  && ok "SKILL.md points at the salvo protocol" || ko "SKILL.md points at the salvo protocol"
for k in agentSalvo agentSalvoQuestions agentSalvoFill; do
  grep -qF "$k" "$SKILLMD" "$PLUG/skills/learner/references/config.md" \
    && ok "the config key $k is documented" || ko "the config key $k is documented"
done
grep -qiF 'salvo' "$PLUG/skills/coach/references/coach.md" \
  && ok "coach.md states which channel wins when both land" \
  || ko "coach.md states which channel wins when both land"

# --- installer --------------------------------------------------------------
inst() { CLAUDE_CONFIG_DIR="$1" bash "$ROOT/install.sh" "${@:2}"; }
hookcount() { jq '[.. | .command? // empty | select(contains("learner-"))] | length' "$1/settings.json"; }

I="$WORK/inst"; mkdir -p "$I"
inst "$I" --level S --synthesis often --blanks 3 >/dev/null 2>&1
{ [ -f "$I/hooks/learner-config.sh" ] \
  && [ -f "$I/hooks/learner-quiz.sh" ] \
  && [ -f "$I/skills/learner/SKILL.md" ] \
  && [ -f "$I/skills/learner/references/data.md" ]; } \
  && ok "install copies hooks, skill and references" \
  || ko "install copies hooks, skill and references"

[ -f "$I/skills/learner/VERSION" ] && [ "$(cat "$I/skills/learner/VERSION")" = "$(cat "$ROOT/VERSION")" ] \
  && ok "install stamps the installed VERSION" \
  || ko "install stamps the installed VERSION"

echo '9.9.9' > "$I/skills/learner/VERSION"
inst "$I" --level S >/dev/null 2>&1
[ "$(cat "$I/skills/learner/VERSION")" = "$(cat "$ROOT/VERSION")" ] \
  && ok "a re-install always refreshes VERSION, unlike learner.json" \
  || ko "a re-install always refreshes VERSION, unlike learner.json"

[ -f "$I/skills/learner/INSTALL_ORIGIN" ] && [ "$(cat "$I/skills/learner/INSTALL_ORIGIN")" = "curl" ] \
  && ok "install defaults --origin to curl" \
  || ko "install defaults --origin to curl"

IB="$WORK/inst-brew"; mkdir -p "$IB"
inst "$IB" --level S --origin brew >/dev/null 2>&1
[ "$(cat "$IB/skills/learner/INSTALL_ORIGIN" 2>/dev/null)" = "brew" ] \
  && ok "install stamps --origin brew" \
  || ko "install stamps --origin brew"

IA="$WORK/inst-apt"; mkdir -p "$IA"
inst "$IA" --level S --origin apt >/dev/null 2>&1
[ "$(cat "$IA/skills/learner/INSTALL_ORIGIN" 2>/dev/null)" = "apt" ] \
  && ok "install stamps --origin apt" \
  || ko "install stamps --origin apt"

out=$(inst "$WORK/inst-bad-origin" --level S --origin homebrew 2>&1) \
  && ko "install rejects an unknown --origin value" \
  || ok "install rejects an unknown --origin value"
printf '%s' "$out" | grep -qF -- '--origin' \
  && ok "the --origin error message names the flag" \
  || ko "the --origin error message names the flag (got '$out')"

echo 'brew' > "$I/skills/learner/INSTALL_ORIGIN"
inst "$I" --level S --origin curl >/dev/null 2>&1
[ "$(cat "$I/skills/learner/INSTALL_ORIGIN")" = "curl" ] \
  && ok "a re-install always refreshes INSTALL_ORIGIN, unlike learner.json" \
  || ko "a re-install always refreshes INSTALL_ORIGIN, unlike learner.json"

jq -e '.level == "S" and .synthesisFrequency == "often" and .blanksPerExercise == 3' \
  "$I/learner.json" >/dev/null 2>&1 \
  && ok "install writes the global config from flags" \
  || ko "install writes the global config from flags"

n=$(find "$I/hooks" -name 'learner-*.sh' | wc -l | tr -d ' ')
want_n=$(find "$PLUG/hooks" -name 'learner-*.sh' | wc -l | tr -d ' ')
{ [ "$n" = "$want_n" ] && [ "$n" -gt 0 ]; } \
  && ok "install lays down all $want_n learner-*.sh hook files" \
  || ko "install lays down all $want_n learner-*.sh hook files (got $n)"

# hookcount() greps commands for "learner-", so it counts 7, not the 7 files
# that are actually wired by coincidence: learner-config.sh is sourced, never
# invoked, so it was never one of the 7 either way, and coach-gate.sh is a
# real wired hook that this filter simply doesn't name-match — it is offset
# by learner-agent-track.sh wiring twice (--start and --end). 7 is the right
# number for what this helper counts; it is not a count of every wired hook.
n1=$(hookcount "$I")
inst "$I" --level S >/dev/null 2>&1
n2=$(hookcount "$I")
{ [ "$n1" = 7 ] && [ "$n2" = 7 ]; } \
  && ok "hook merge is idempotent (7 name-matched hooks)" \
  || ko "hook merge is idempotent (got $n1 then $n2, want 7/7)"

# install.sh's own dedup — exercised end to end, not a re-typed copy of its
# jq — must catch every hook this project wires, coach's PreToolUse entry
# included. Installing twice (what `learner update` does on every version
# bump) must leave exactly one copy of every command the shipped snippet
# wires, not one per install: otherwise every Write/Edit/NotebookEdit spawns
# one more subprocess per reinstall, forever. Checked against every command
# in the real snippet file, not a sample, so a too-narrow anchor can't pass
# by only recognising some of them.
IC="$WORK/inst-coach-dedup"; mkdir -p "$IC"
inst "$IC" --level S >/dev/null 2>&1
inst "$IC" --level S >/dev/null 2>&1
n=$(jq -n --argjson got "$(jq '[.. | .command? // empty]' "$IC/settings.json")" \
          --argjson want "$(jq '[.. | .command? // empty]' "$PLUG/hooks/settings.snippet.json")" '
  [ $want[] as $w | ($got | map(select(. == $w)) | length) | select(. != 1) ] | length
')
[ "$n" = 0 ] \
  && ok "install's dedup keeps exactly one copy of every wired command across two installs" \
  || ko "install's dedup keeps exactly one copy of every wired command across two installs (got $n mismatched)"

# The opposite guard, same as strip_wiring's: an unrelated third-party hook
# already present in settings.json must survive a re-install intact. A fresh
# directory, not $IC: reusing it would let $IC's own corrupted-command debris
# (if the predicate were ever wrong) silently abort a later jq call and leave
# this assertion passing for the wrong reason — every fixture below gets its
# own directory for the same reason.
IC2="$WORK/inst-coach-survival"; mkdir -p "$IC2"
inst "$IC2" --level S >/dev/null 2>&1
jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"sh /opt/otherteam/hooks/pretty-linter.sh"}]}]' \
  "$IC2/settings.json" > "$IC2/settings.json.tmp" && mv "$IC2/settings.json.tmp" "$IC2/settings.json"
inst "$IC2" --level S >/dev/null 2>&1
jq -e '[.. | .command? // empty] | any(. == "sh /opt/otherteam/hooks/pretty-linter.sh")' "$IC2/settings.json" >/dev/null 2>&1 \
  && ok "install's dedup leaves an unrelated third-party hook intact" \
  || ko "install's dedup leaves an unrelated third-party hook intact (got $(jq -c '.hooks.PreToolUse' "$IC2/settings.json"))"

# The case that actually matters: a third-party hook whose path matches
# learner's naming convention ("coach-*.sh" under a "hooks/" directory) but
# lives under a tree learner never installs into. A bare path-shape match
# would dedup this away on every reinstall; the ".claude" anchor must leave
# it alone.
IC3="$WORK/inst-coach-collide"; mkdir -p "$IC3"
inst "$IC3" --level S >/dev/null 2>&1
jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"sh /opt/otherteam/hooks/coach-lint.sh"}]}]' \
  "$IC3/settings.json" > "$IC3/settings.json.tmp" && mv "$IC3/settings.json.tmp" "$IC3/settings.json"
inst "$IC3" --level S >/dev/null 2>&1
jq -e '[.. | .command? // empty] | any(. == "sh /opt/otherteam/hooks/coach-lint.sh")' "$IC3/settings.json" >/dev/null 2>&1 \
  && ok "install's dedup leaves a same-convention third-party hook outside .claude intact" \
  || ko "install's dedup leaves a same-convention third-party hook outside .claude intact (got $(jq -c '.hooks.PreToolUse' "$IC3/settings.json"))"

jq -e '[.. | .command? // empty | select(contains("learner-"))]
       | all(contains("CLAUDE_CONFIG_DIR"))' "$I/settings.json" >/dev/null 2>&1 \
  && ok "hook commands resolve CLAUDE_CONFIG_DIR at run time" \
  || ko "hook commands resolve CLAUDE_CONFIG_DIR at run time"

# $I has been installed into twice by now: the backup must still be the settings
# from before learner, not the already-merged file.
jq -e '[.. | .command? // empty | select(contains("learner-"))] | length == 0' \
  "$I/settings.json.bak" >/dev/null 2>&1 \
  && ok "the settings.json backup stays pristine across re-installs" \
  || ko "the settings.json backup stays pristine across re-installs"

I2="$WORK/inst2"; mkdir -p "$I2"
inst "$I2" --level senior >/dev/null 2>&1
jq -e '.level == "S"' "$I2/learner.json" >/dev/null 2>&1 \
  && ok "install normalises --level senior to S" \
  || ko "install normalises --level senior to S"

I3="$WORK/inst3"; mkdir -p "$I3"
inst "$I3" --level wizard >/dev/null 2>&1 \
  && ko "install rejects an invalid level" \
  || ok "install rejects an invalid level"

I4="$WORK/inst4"; mkdir -p "$I4"
inst "$I4" >/dev/null 2>&1 </dev/null \
  && ko "install aborts non-interactively without --level" \
  || ok "install aborts non-interactively without --level"

I4B="$WORK/inst4b"; mkdir -p "$I4B"
out=$(inst "$I4B" --yes 2>&1 </dev/null) \
  && ko "install aborts with --yes and no --level" \
  || ok "install aborts with --yes and no --level"
printf '%s' "$out" | grep -qF -- '--level' \
  && ok "the --yes abort message names --level" \
  || ko "the --yes abort message names --level"

I5="$WORK/inst5"; mkdir -p "$I5"
echo '{ broken' > "$I5/settings.json"
inst "$I5" --level S >/dev/null 2>&1 \
  && ko "install aborts on invalid settings.json" \
  || ok "install aborts on invalid settings.json"
grep -q 'broken' "$I5/settings.json" \
  && ok "install leaves an invalid settings.json untouched" \
  || ko "install leaves an invalid settings.json untouched"

I6="$WORK/inst6"; mkdir -p "$I6"
dry_out=$(inst "$I6" --level S --dry-run 2>&1)
{ [ ! -e "$I6/learner.json" ] && [ ! -e "$I6/hooks" ]; } \
  && ok "--dry-run writes nothing" \
  || ko "--dry-run writes nothing"

# FINDING 5: install.sh's --dry-run hook count must match what its own copy
# loop actually copies. Derived from disk, the same "ground truth from disk"
# style as the hook-count drift guard further down (search "hook count drift
# guard") — this exact class of staleness has now drifted three times on this
# branch.
hook_n_dry=$(find "$PLUG/hooks" -maxdepth 1 -name '*.sh' | grep -c .)
printf '%s' "$dry_out" | grep -qF "would copy $hook_n_dry hooks" \
  && ok "--dry-run reports the actual hook count ($hook_n_dry)" \
  || ko "--dry-run reports the actual hook count (want $hook_n_dry, got: $(printf '%s' "$dry_out" | grep 'would copy'))"

I7="$WORK/inst7"
out=$(PATH="/usr/bin:/bin" HOME="$WORK/nohome" CLAUDE_CONFIG_DIR="$I7" \
      bash "$ROOT/install.sh" --level S 2>&1) \
  && ko "install aborts when Claude Code is absent" \
  || ok "install aborts when Claude Code is absent"
printf '%s' "$out" | grep -qi 'claude' \
  && ok "the abort message names Claude Code" \
  || ko "the abort message names Claude Code"

I8="$WORK/inst8"; mkdir -p "$I8"
inst "$I8" --level S >/dev/null 2>&1
inst "$I8" --level D >/dev/null 2>&1
jq -e '.level == "S"' "$I8/learner.json" >/dev/null 2>&1 \
  && ok "re-install keeps an existing config" \
  || ko "re-install keeps an existing config"

jq -e 'keys - ["level","enabled","questionStyles","synthesisFrequency","blanksPerExercise","untrackGlobs","disabledPaths","coach","coachPollSeconds","coachQuietPolls","coachMinLines","coachCooldownMinutes","coachMaxWaitMinutes","coachIdleMinutes"] | length == 0' \
  "$ROOT/learner.json.example" >/dev/null 2>&1 \
  && ok "learner.json.example carries only supported keys" \
  || ko "learner.json.example carries only supported keys"

[ ! -e "$ROOT/learner.local.json.example" ] \
  && ok "the old example file is gone" \
  || ko "the old example file is gone"

# --- second skill (pilot) -----------------------------------------------------
# Two skills now ship. The installer hardcoded one path in six places; a
# separate copy of the same path in each packaging script is how a second
# skill ends up missing from one install path only (brew, apt, curl, plugin).
# The mutation that shows the derived loops actually discriminate — on both
# sides — rather than a hand-maintained list that happens to name today's two
# skills: a skill this repo has never heard of, with no edit to install.sh or
# uninstall.sh, must be copied in AND removed again. A hardcoded two-name
# `SKILLS='learner pilot'` (install) or a two-name `rm -rf` (uninstall) would
# satisfy every assertion about learner/pilot specifically while failing this
# one, on either side.
PROBE="$PLUG/skills/zz-probe"
mkdir -p "$PROBE"
printf '---\nname: zz-probe\ndescription: throwaway probe for the derived skill-copy loop, deleted immediately after.\n---\n\nprobe\n' > "$PROBE/SKILL.md"

IS="$WORK/install-skills"
rm -rf "$IS"; mkdir -p "$IS"
CLAUDE_CONFIG_DIR="$IS" bash "$ROOT/install.sh" --level S >/dev/null 2>&1
[ -f "$IS/skills/pilot/SKILL.md" ] \
  && ok "install ships the pilot skill" || ko "install ships the pilot skill"
[ -f "$IS/skills/learner/SKILL.md" ] \
  && ok "install still ships the learner skill" || ko "install still ships the learner skill"
[ -f "$IS/skills/zz-probe/SKILL.md" ] \
  && ok "install's derived skill loop copies a skill it has never been told about" \
  || ko "install's derived skill loop copies a skill it has never been told about"

# pilot now ships references/ (this task writes rubric.md and score.md) — the
# derived copy loop must carry them, and a skill with no references/ of its own
# (zz-probe, above) must still not fail, nor have an empty references/ invented
# for it.
[ -f "$IS/skills/pilot/references/rubric.md" ] && [ -f "$IS/skills/pilot/references/score.md" ] \
  && ok "install ships the pilot skill's reference files" \
  || ko "install ships the pilot skill's reference files"
[ -d "$IS/skills/zz-probe/references" ] \
  && ko "a skill with no references/ does not get one fabricated by install" \
  || ok "install does not fail or fabricate references/ for a skill that has none"

CLAUDE_CONFIG_DIR="$IS" bash "$ROOT/uninstall.sh" >/dev/null 2>&1
[ ! -d "$IS/skills/pilot" ] \
  && ok "uninstall removes the pilot skill" || ko "uninstall removes the pilot skill"
[ ! -d "$IS/skills/learner" ] \
  && ok "uninstall still removes the learner skill" || ko "uninstall still removes the learner skill"
[ ! -d "$IS/skills/zz-probe" ] \
  && ok "uninstall's derived skill loop removes a skill it has never been told about" \
  || ko "uninstall's derived skill loop removes a skill it has never been told about"

rm -rf "$PROBE"

# Neither packaging file has ever enumerated skills by name — both already
# ship the whole skills/ tree as one unit, which is what makes a second skill
# arrive in both without a code change. So the invariant to assert is that
# shape, not a name that happens to appear in a comment today: naming
# 'skills/pilot' literally would go red on a harmless comment rewrite and stay
# green if "skills" were ever narrowed to "skills/learner" — the false pass
# that would actually break shipping the second skill.
# Anchored to the actual install/copy line, not merely "'skills' appears
# somewhere in the file" — a bare file-wide grep would still pass reading a
# comment that says the right thing while the code beside it was narrowed to
# "skills/learner", which is exactly the false pass this guard exists to
# catch. Both patterns require the exact whole-directory token on the SAME
# line as the copy call, so "skills/learner" (no closing quote right after
# "skills") does not match either.
grep -qE 'pkgshare\.install.*"plugins/learner/skills"' "$ROOT/Formula/learner.rb" \
  && ok "the brew formula ships the skills/ tree as a unit" \
  || ko "the brew formula ships the skills/ tree as a unit"
grep -qE 'cp -r.*"\$ROOT/plugins/learner/skills"' "$ROOT/packaging/deb/build.sh" \
  && ok "the deb build ships the skills/ tree as a unit" \
  || ko "the deb build ships the skills/ tree as a unit"

# One line of forwarding, not a third regime inlined into the quiz's dispatch.
grep -q 'pilot' "$PLUG/skills/learner/SKILL.md" \
  && ok "the learner skill forwards pilot subcommands" \
  || ko "the learner skill forwards pilot subcommands"

# Decision 14: the mark and its profile labels stay out of every shipped file.
if grep -rqi 'cogniscore' "$PLUG/skills" "$PLUG/hooks" "$ROOT/README.md" "$ROOT/docs"; then
  ko "no shipped file reuses the CogniScore mark"
else
  ok "no shipped file reuses the CogniScore mark"
fi

# Decision 12, asserted where a reader will look rather than only in a spec
# they will never read.
grep -qi 'opt-in' "$PLUG/skills/pilot/SKILL.md" \
  && ok "the pilot skill states that it is opt-in" \
  || ko "the pilot skill states that it is opt-in"

# The dispatch table's "Read" column is the path a dispatching model actually
# follows for `pilot on`/`pilot off` — it must point at references/dashboard.md,
# where the global-file naming lives, not at "this file, § Privacy" (which
# never names a file at all and is what a model would land on instead).
PSK="$PLUG/skills/pilot/SKILL.md"
grep -qE '^\| `pilot on`.*references/dashboard\.md' "$PSK" \
  && ok "SKILL.md routes 'pilot on' to references/dashboard.md" \
  || ko "SKILL.md routes 'pilot on' to references/dashboard.md"
grep -qE '^\| `pilot off`.*references/dashboard\.md' "$PSK" \
  && ok "SKILL.md routes 'pilot off' to references/dashboard.md" \
  || ko "SKILL.md routes 'pilot off' to references/dashboard.md"

# pilot off must name the same global file pilot on does, in the page a
# dispatching model actually reaches (dashboard.md), not just in prose no
# dispatch path leads to.
DASH="$PLUG/skills/pilot/references/dashboard.md"
grep -qF 'learner.json' "$DASH" \
  && ok "dashboard.md names the global config file" \
  || ko "dashboard.md names the global config file"
[ "$(grep -c 'learner\.json' "$DASH")" -ge 2 ] \
  && ok "dashboard.md names the global config file for both pilot on and pilot off" \
  || ko "dashboard.md names the global config file for both pilot on and pilot off"

# --- pilot rubric and scorer -------------------------------------------------
# The reference files are the scorer's whole implementation, so assert the two
# properties that make the number defensible rather than prose that reads well.
RUBRIC="$PLUG/skills/pilot/references/rubric.md"

# Axis names derived from the file's own "## <axis> — <question>" headings,
# not named by hand — a fifth axis needs no edit here, only a new heading of
# the same shape in rubric.md. Scoped to a single lowercase word before the em
# dash so the file's other "## " heading ("The arithmetic — …", not an axis)
# is not picked up as a fifth, spurious axis.
RUBRIC_AXES=$(sed -n -E 's/^## ([a-z]+) — .*/\1/p' "$RUBRIC")

# Lines belonging to one axis's block: from its heading up to (not including)
# the next "## " heading, or end of file for the last axis.
rubric_block() {
  awk -v axis="$1" '
    $0 ~ "^## " axis "( |$)" { found=1; next }
    found && /^## / { exit }
    found { print }
  ' "$RUBRIC"
}

for A in $RUBRIC_AXES; do
  grep -q "^## $A" "$RUBRIC" \
    && ok "rubric.md anchors the $A axis" || ko "rubric.md anchors the $A axis"
done

# Scoped per axis block, not a whole-file count: a global count of ≥4 lines
# matching "^N — " is satisfied just as well by one axis supplying two anchors
# for a number while another axis has none, which is exactly the shape a
# mutation deleting one axis's anchors while leaving the others untouched
# would produce. Each axis block must carry exactly one anchor line for each
# of 0-4.
for A in $RUBRIC_AXES; do
  BLOCK=$(rubric_block "$A")
  BAD=0
  for N in 0 1 2 3 4; do
    [ "$(printf '%s\n' "$BLOCK" | grep -c "^$N — ")" -eq 1 ] || BAD=1
  done
  [ "$BAD" -eq 0 ] \
    && ok "rubric.md's $A block anchors each of 0-4 exactly once" \
    || ko "rubric.md's $A block anchors each of 0-4 exactly once"
done
grep -qi 'quote' "$PLUG/skills/pilot/references/score.md" \
  && ok "score.md requires a quote behind every score" \
  || ko "score.md requires a quote behind every score"
grep -qi 'subagent' "$PLUG/skills/pilot/references/score.md" \
  && ok "score.md states it must run in a subagent" \
  || ko "score.md states it must run in a subagent"
# A `-` floored to 0 would quietly punish short sessions, which is the most
# likely way for this index to become meaningless.
grep -qi 'never counted as 0\|not a zero\|never floored' "$PLUG/skills/pilot/references/rubric.md" \
  && ok "rubric.md states that a dash is not a zero" \
  || ko "rubric.md states that a dash is not a zero"

# Moved here from Task 7: the installer's skill loop must carry the references
# too, and this is the first task in which any of them exists to be shipped.
# Derived from disk rather than named one by one (dashboard.md included), so a
# reference file added or renamed later needs no matching edit to this test —
# this loop is the deliberate substitute for enumerating them by hand.
IR="$WORK/install-refs"; rm -rf "$IR"; mkdir -p "$IR"
CLAUDE_CONFIG_DIR="$IR" bash "$ROOT/install.sh" --level S >/dev/null 2>&1
for REF in "$PLUG"/skills/pilot/references/*.md; do
  REFNAME=$(basename "$REF")
  [ -f "$IR/skills/pilot/references/$REFNAME" ] \
    && ok "install ships plugins/learner/skills/pilot/references/$REFNAME" \
    || ko "install ships plugins/learner/skills/pilot/references/$REFNAME"
done

# --- pilot dashboard ----------------------------------------------------------
# Task 10: dashboard.md is prose, so most of these are greps rather than
# behavioural tests. The four below are given verbatim by the task brief.
DASH="$PLUG/skills/pilot/references/dashboard.md"

grep -qi 'not enough data yet' "$DASH" \
  && ok "dashboard.md refuses to render a thin index" \
  || ko "dashboard.md refuses to render a thin index"
grep -q '~' "$DASH" \
  && ok "dashboard.md explains the estimate marker" \
  || ko "dashboard.md explains the estimate marker"
# forget must not silently rewrite the scores: the dev asked to drop the
# quotes, and a score that quietly vanishes is a different promise.
grep -qi 'pilot-evidence.md only\|only from .*pilot-evidence\|evidence file only\|delete from .*pilot-evidence.md only' \
  "$DASH" \
  && ok "dashboard.md scopes forget to the evidence file" \
  || ko "dashboard.md scopes forget to the evidence file"
grep -qi 'say nothing\|silent' "$DASH" \
  && ok "dashboard.md keeps learner status quiet when pilot is off" \
  || ko "dashboard.md keeps learner status quiet when pilot is off"

# rubric.md now defines six profiles (Backseat added during implementation
# for the argues-without-reading vector). dashboard.md special-cases Backseat
# for its remedy callout rather than restating the whole table, so pin the
# ONE name it does repeat to rubric.md's own table instead of hand-typing it
# twice: derive the name from rubric.md's profile rows and require dashboard.md
# to use that same, actually-current, name. If rubric.md ever renames or drops
# Backseat, this goes red rather than dashboard.md silently pointing at a
# profile that no longer exists.
RUBRIC="$PLUG/skills/pilot/references/rubric.md"
BACKSEAT_NAME=$(sed -nE 's/^\| [0-9]+ \| `([A-Za-z-]+)` \|.*/\1/p' "$RUBRIC" | grep -ix backseat)
{ [ -n "$BACKSEAT_NAME" ] && grep -qF "$BACKSEAT_NAME" "$DASH"; } \
  && ok "dashboard.md's Backseat callout names the profile rubric.md's table actually defines" \
  || ko "dashboard.md's Backseat callout names the profile rubric.md's table actually defines"

# dashboard.md must defer to rubric.md's arithmetic, not fork a second copy of
# it: a real structural check, not a phrase match — rubric.md's profile table
# rows look like "| N | `Name` | rule |"; dashboard.md must contain none of
# that shape (it names Backseat in prose, never as a re-typed table row).
if grep -qE '^\| [0-9]+ \| `[A-Za-z-]+` \|' "$DASH"; then
  ko "dashboard.md does not re-fork rubric.md's profile-table rows"
else
  ok "dashboard.md does not re-fork rubric.md's profile-table rows"
fi

grep -qi 'never render a .-. in a way that reads as a low score\|reads as a low score' "$DASH" \
  && ok "dashboard.md forbids rendering a dash as a low score" \
  || ko "dashboard.md forbids rendering a dash as a low score"
grep -qi 'nearest-looking profile' "$DASH" \
  && ok "dashboard.md forbids a placeholder profile below the session floor" \
  || ko "dashboard.md forbids a placeholder profile below the session floor"
grep -qi 'floors are independent' "$DASH" \
  && ok "dashboard.md renders each axis's floor independently of the others" \
  || ko "dashboard.md renders each axis's floor independently of the others"
grep -qi 'no quote by design' "$DASH" \
  && ok "dashboard.md tells pilot why apart writing's designed lack of a quote from a missing one" \
  || ko "dashboard.md tells pilot why apart writing's designed lack of a quote from a missing one"
grep -qi 'not a silent' "$DASH" \
  && ok "dashboard.md refuses to default a bare pilot forget to --all" \
  || ko "dashboard.md refuses to default a bare pilot forget to --all"
grep -qi 'confirm' "$DASH" \
  && ok "dashboard.md confirms before pilot forget deletes anything" \
  || ko "dashboard.md confirms before pilot forget deletes anything"
grep -qi 'privacy paragraph' "$DASH" \
  && ok "dashboard.md has pilot on print the privacy paragraph before flipping the switch" \
  || ko "dashboard.md has pilot on print the privacy paragraph before flipping the switch"
grep -qi 'pilot forget --all' "$DASH" \
  && ok "dashboard.md's pilot off points at pilot forget --all to purge kept data" \
  || ko "dashboard.md's pilot off points at pilot forget --all to purge kept data"

# --- cleanup hook -----------------------------------------------------------
SID3=cln1
printf '{"session_id":"%s","tool_input":{"file_path":"%s/proj/src/Baz.kt"}}' "$SID3" "$WORK" | sh "$REC"
[ -s "$(edits "$SID3")" ] \
  && ok "the session scratch file exists before cleanup runs" \
  || ko "the session scratch file exists before cleanup runs"
printf '{"session_id":"%s"}' "$SID3" | sh "$CLEAN"
[ -e "$(edits "$SID3")" ] \
  && ko "cleanup removes this session's scratch files" \
  || ok "cleanup removes this session's scratch files"

# --- LEARNER-TODO guardrail -------------------------------------------------
# One throwaway repo per scenario: the guardrail is a HEAD-vs-working-tree diff,
# so what the fixture committed is the whole point.
gmk() {  # -> a repo with one committed, marker-free file
  _g="$(mktemp -d "$WORK/guard.XXXXXX")"
  mkdir -p "$_g/tmp"
  git -C "$_g" init -q
  printf 'fun f() {\n  return 1\n}\n' > "$_g/A.kt"
  git -C "$_g" add A.kt
  git -C "$_g" -c user.email=t@t -c user.name=t commit -qm init
  printf '%s' "$_g"
}
gcommit() { git -C "$1" add -A; git -C "$1" -c user.email=t@t -c user.name=t commit -qm "${2:-c}"; }
hole()    { printf 'fun f() {\n  // LEARNER-TODO: body\n}\n' > "$1/A.kt"; }
nohole()  { printf 'fun f() {\n  return 1\n}\n' > "$1/A.kt"; }
guard()   { printf '{"session_id":"%s","stop_hook_active":%s}' "${3:-g}" "${4:-false}" \
  | CLAUDE_PROJECT_DIR="$1" TMPDIR="$1/tmp" CLAUDE_CONFIG_DIR="$2" sh "$QUIZ"; }
blocks()  { echo "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

# A committed marker is repo content (this project documents the string in its own
# README, tests and skill files), never an unfinished exercise.
G=$(gmk); hole "$G"; gcommit "$G" marker
out=$(guard "$G" "$WORK/cfg")
blocks "$out" \
  && ko "a committed // LEARNER-TODO is repo content, not a leftover" \
  || ok "a committed // LEARNER-TODO is repo content, not a leftover"

G=$(gmk); hole "$G"
out=$(guard "$G" "$WORK/cfg")
{ blocks "$out" && echo "$out" | jq -e '.reason | test("A.kt")' >/dev/null 2>&1; } \
  && ok "guardrail blocks on a marker in a modified tracked file" \
  || ko "guardrail blocks on a marker in a modified tracked file"

# A committed marker that MOVED is still repo content. The set difference is by path,
# so a renamed file lands at a path no HEAD entry carries and every marker inside it
# reads as a fresh hole — blocking a session that cut nothing, on repeat, until the
# rename is committed. Renaming a file that documents the marker (this project renames
# its own hooks and skills) is all it takes.
G=$(gmk); hole "$G"; gcommit "$G" marker
git -C "$G" mv A.kt B.kt
out=$(guard "$G" "$WORK/cfg")
blocks "$out" \
  && ko "a committed // LEARNER-TODO survives a rename without blocking" \
  || ok "a committed // LEARNER-TODO survives a rename without blocking"

# The same content at a new path with the old one still in place — a copy, not a
# rename — is equally not a fresh hole.
G=$(gmk); hole "$G"; gcommit "$G" marker
cp "$G/A.kt" "$G/COPY.kt"
out=$(guard "$G" "$WORK/cfg")
blocks "$out" \
  && ko "a committed // LEARNER-TODO survives being copied without blocking" \
  || ok "a committed // LEARNER-TODO survives being copied without blocking"

# …and the guarantee that matters: relaxing by content must not let a real hole
# through. Same file, cut fresh, at a path HEAD has never seen.
G=$(gmk); printf 'fun f() {\n  // LEARNER-TODO: cut\n}\n' > "$G/MOVED.kt"
out=$(guard "$G" "$WORK/cfg")
{ blocks "$out" && echo "$out" | jq -e '.reason | test("MOVED.kt")' >/dev/null 2>&1; } \
  && ok "a fresh hole at an unseen path still blocks" \
  || ko "a fresh hole at an unseen path still blocks"

# The primary case: the session just wrote the file, so git does not know it yet.
G=$(gmk); printf 'fun g() {\n  // LEARNER-TODO: body\n}\n' > "$G/NEW.kt"
out=$(guard "$G" "$WORK/cfg")
{ blocks "$out" && echo "$out" | jq -e '.reason | test("NEW.kt")' >/dev/null 2>&1; } \
  && ok "guardrail blocks on a marker in a brand-new untracked file" \
  || ko "guardrail blocks on a marker in a brand-new untracked file"

# A repo whose path is disabled must stay silent and untouched, guardrail included.
G=$(gmk); hole "$G"
DCFG="$G/cfg"; mkdir -p "$DCFG"
echo '{"level":"S","disabledPaths":["'"$G"'"]}' > "$DCFG/learner.json"
out=$(guard "$G" "$DCFG")
[ -z "$out" ] \
  && ok "guardrail stays silent in a repo under disabledPaths" \
  || ko "guardrail stays silent in a repo under disabledPaths"

G=$(gmk); hole "$G"
ECFG="$G/cfg"; mkdir -p "$ECFG"
echo '{"level":"S","enabled":false}' > "$ECFG/learner.json"
out=$(guard "$G" "$ECFG")
blocks "$out" \
  && ok "guardrail fires even when enabled is false" \
  || ko "guardrail fires even when enabled is false"

G=$(gmk); hole "$G"
out=$(guard "$G" "$WORK/empty-cfg")
blocks "$out" \
  && ok "guardrail fires even with no config at all" \
  || ko "guardrail fires even with no config at all"

# Claude says it fixed the file and stops again: the guardrail must re-check.
G=$(gmk); hole "$G"
out=$(guard "$G" "$WORK/cfg" active true)
blocks "$out" \
  && ok "guardrail re-checks even with stop_hook_active" \
  || ko "guardrail re-checks even with stop_hook_active"

# Bounded: two blocks, then the session is allowed to end.
G=$(gmk); hole "$G"
b1=$(guard "$G" "$WORK/cfg" cap); b2=$(guard "$G" "$WORK/cfg" cap); b3=$(guard "$G" "$WORK/cfg" cap)
{ blocks "$b1" && blocks "$b2" && [ -z "$b3" ]; } \
  && ok "guardrail blocks twice, then lets the session end" \
  || ko "guardrail blocks twice, then lets the session end"

# …and a clean stop restores the budget for the next exercise.
G=$(gmk); hole "$G"
guard "$G" "$WORK/cfg" rst >/dev/null; guard "$G" "$WORK/cfg" rst >/dev/null
nohole "$G"; clean=$(guard "$G" "$WORK/cfg" rst)
hole "$G";   again=$(guard "$G" "$WORK/cfg" rst)
{ [ -z "$clean" ] && blocks "$again"; } \
  && ok "a clean stop refreshes the guardrail budget" \
  || ko "a clean stop refreshes the guardrail budget"

# No commits yet: `git grep … HEAD` fails, and every marker is a leftover.
G="$(mktemp -d "$WORK/guard.XXXXXX")"; mkdir -p "$G/tmp"; git -C "$G" init -q
printf 'fun g() {\n  // LEARNER-TODO: body\n}\n' > "$G/NEW.kt"
out=$(guard "$G" "$WORK/cfg")
blocks "$out" \
  && ok "guardrail works in a repo with no commits yet" \
  || ko "guardrail works in a repo with no commits yet"

# The marker is a code comment: the bare word in prose is not an exercise.
# A brand-new markdown page that NAMES the marker in an inline code span is
# documenting the feature — every README and skill file in this project does it —
# and blocking on it would hold the session hostage to its own docs until they are
# committed, since an untracked file matches neither a HEAD path nor a HEAD blob.
G=$(gmk); printf 'Claude cuts `// LEARNER-TODO` holes in a real function.\n' > "$G/DOC.md"
out=$(guard "$G" "$WORK/cfg")
blocks "$out" \
  && ko "a new .md naming // LEARNER-TODO in an inline code span does not block" \
  || ok "a new .md naming // LEARNER-TODO in an inline code span does not block"

# The guarantee that matters, again: relaxing markdown must not swallow a real hole.
# A fenced block is where an exercise cutting a documented snippet puts its holes.
G=$(gmk); printf 'Example:\n\n```kotlin\nfun f() {\n  // LEARNER-TODO: body\n}\n```\n' > "$G/FENCE.md"
out=$(guard "$G" "$WORK/cfg")
{ blocks "$out" && echo "$out" | jq -e '.reason | test("FENCE.md")' >/dev/null 2>&1; } \
  && ok "a hole inside a fenced block in a .md still blocks" \
  || ko "a hole inside a fenced block in a .md still blocks"

# Bare prose, no span: nothing says this is documentation, so it still blocks.
G=$(gmk); printf 'some text\n// LEARNER-TODO: body\nmore text\n' > "$G/BARE.md"
out=$(guard "$G" "$WORK/cfg")
{ blocks "$out" && echo "$out" | jq -e '.reason | test("BARE.md")' >/dev/null 2>&1; } \
  && ok "a bare marker line in a .md still blocks" \
  || ko "a bare marker line in a .md still blocks"

# One page can do both. The span acquits its own line, never the file.
G=$(gmk); printf 'Claude cuts `// LEARNER-TODO` holes.\n\n    // LEARNER-TODO: cut\n' > "$G/MIXED.md"
out=$(guard "$G" "$WORK/cfg")
{ blocks "$out" && echo "$out" | jq -e '.reason | test("MIXED.md")' >/dev/null 2>&1; } \
  && ok "a .md that both names the marker and carries a hole still blocks" \
  || ko "a .md that both names the marker and carries a hole still blocks"

# The relaxation is markdown-only: a source file is never acquitted by backticks.
G=$(gmk); printf 'fun f() {\n  // LEARNER-TODO: `body`\n}\n' > "$G/TICKS.kt"
out=$(guard "$G" "$WORK/cfg")
{ blocks "$out" && echo "$out" | jq -e '.reason | test("TICKS.kt")' >/dev/null 2>&1; } \
  && ok "backticks never acquit a marker outside a markdown file" \
  || ko "backticks never acquit a marker outside a markdown file"

# The plugin's own README is the case that triggered this: it must not block.
G=$(gmk); mkdir -p "$G/plugins/learner"
cp "$ROOT/plugins/learner/README.md" "$G/plugins/learner/README.md"
out=$(guard "$G" "$WORK/cfg")
blocks "$out" \
  && ko "the plugin's own README does not trip the guardrail" \
  || ok "the plugin's own README does not trip the guardrail"

G=$(gmk); printf 'the string LEARNER-TODO appears in this doc\n' > "$G/NOTES.md"
out=$(guard "$G" "$WORK/cfg")
[ -z "$out" ] \
  && ok "guardrail matches // LEARNER-TODO, not the bare word" \
  || ko "guardrail matches // LEARNER-TODO, not the bare word"

# Long lists are truncated but say so.
G=$(gmk); i=1; while [ "$i" -le 25 ]; do printf '// LEARNER-TODO: h\n' > "$G/F$i.kt"; i=$((i + 1)); done
out=$(guard "$G" "$WORK/cfg")
echo "$out" | jq -e '.reason | test("and 5 more")' >/dev/null 2>&1 \
  && ok "guardrail reports the overflow instead of dropping files silently" \
  || ko "guardrail reports the overflow instead of dropping files silently"

# The guardrail's scratch file is cleaned up with the rest of the session.
G=$(gmk); hole "$G"
guard "$G" "$WORK/cfg" cln >/dev/null
[ -f "$G/tmp/claude-learner-cln.guard" ] \
  && ok "guardrail records its budget in a per-session scratch file" \
  || ko "guardrail records its budget in a per-session scratch file"
printf '{"session_id":"cln"}' | TMPDIR="$G/tmp" sh "$CLEAN"
[ -e "$G/tmp/claude-learner-cln.guard" ] \
  && ko "cleanup removes the guardrail scratch file" \
  || ok "cleanup removes the guardrail scratch file"
echo '{"level":"S"}' > "$GCFG"

# --- uninstall reverses install ---------------------------------------------

# strip_wiring's own predicate — not a re-typed copy of it — must remove
# every hook the shipped snippet wires, coach's PreToolUse entry included.
# A command matching only "coach-" once survived a "learner-"-only match;
# this checks every command in the real shipped file, not a sample, so a
# too-narrow anchor can't pass by only recognising some of them.
eval "$(sed -n '/^strip_wiring()/,/^}/p' "$ROOT/uninstall.sh")"
SWJD="$WORK/strip-wiring-snippet"; mkdir -p "$SWJD"
SWJ="$SWJD/settings.json"
cp "$PLUG/hooks/settings.snippet.json" "$SWJ"
strip_wiring "$SWJ"
left=$(jq '[.. | .command? // empty] | length' "$SWJ")
[ "$left" = 0 ] \
  && ok "strip_wiring removes every hook wired by the shipped snippet" \
  || ko "strip_wiring removes every hook wired by the shipped snippet (left=$left)"

# The other side of the same coin: an unrelated third-party hook must survive
# stripping. Without this, "just delete all hooks" would pass the assertion
# above while destroying a user's own configuration. This one doesn't share
# learner's naming convention at all — the harder case, a same-convention
# name under a different tree, is the next one below.
SWOD="$WORK/strip-wiring-other"; mkdir -p "$SWOD"
SWO="$SWOD/settings.json"
cat > "$SWO" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          { "type": "command", "command": "sh /opt/otherteam/hooks/pretty-linter.sh" }
        ]
      }
    ]
  }
}
JSON
strip_wiring "$SWO"
jq -e '.hooks.PreToolUse[0].hooks[0].command == "sh /opt/otherteam/hooks/pretty-linter.sh"' "$SWO" >/dev/null 2>&1 \
  && ok "strip_wiring leaves an unrelated third-party hook intact" \
  || ko "strip_wiring leaves an unrelated third-party hook intact (got $(cat "$SWO"))"

# The case that actually matters: a third-party hook whose path *does* match
# learner's naming convention (a "coach-*.sh" script under a "hooks/"
# directory) but lives under a tree learner never installs into. A bare
# path-shape match would strip this; the predicate must require the ".claude"
# anchor too and leave it alone.
SWCD="$WORK/strip-wiring-colliding"; mkdir -p "$SWCD"
SWC="$SWCD/settings.json"
cat > "$SWC" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          { "type": "command", "command": "sh /opt/otherteam/hooks/coach-lint.sh" }
        ]
      }
    ]
  }
}
JSON
strip_wiring "$SWC"
jq -e '.hooks.PreToolUse[0].hooks[0].command == "sh /opt/otherteam/hooks/coach-lint.sh"' "$SWC" >/dev/null 2>&1 \
  && ok "strip_wiring leaves a same-convention third-party hook outside .claude intact" \
  || ko "strip_wiring leaves a same-convention third-party hook outside .claude intact (got $(cat "$SWC"))"

# uninstall.sh's global removal list must name every hook this project ships,
# or a hook survives on disk even once the wiring above is stripped clean.
# Checked once, generically, further down (search "every hook is named in
# uninstall.sh's global removal list") once HOOK_SH is in scope — that single
# derived check replaced three hand-named ones here (coach-gate.sh,
# coach-watch.sh, and later the three pilot-*.sh hooks), each of which was
# itself the same frozen-enumeration defect this task exists to close: a
# twelfth hook could ship, get copied and wired, and never be named here,
# and none of the three literal checks would ever have caught it.

U="$WORK/uninst"; mkdir -p "$U"
CLAUDE_CONFIG_DIR="$U" bash "$ROOT/install.sh" --level S >/dev/null 2>&1

# Every skill in the payload has to land, under the same name: the siblings reach the
# hub through `../learner/…`, so the copy has to preserve the tree's shape, not just
# its files.
missing_skill=""
for n in quiz status improve coach export sync update pilot; do
  [ -f "$U/skills/$n/SKILL.md" ] || missing_skill="$missing_skill $n"
done
{ [ -z "$missing_skill" ] && [ -f "$U/skills/learner/SKILL.md" ]; } \
  && ok "install lays down the hub and every sibling skill" \
  || ko "install lays down the hub and every sibling skill (missing:$missing_skill)"

[ -f "$U/skills/quiz/../learner/references/data.md" ] \
  && ok "a sibling skill's ../learner/references link resolves once installed" \
  || ko "a sibling skill's ../learner/references link resolves once installed"

printf '# notes\n' > "$U/learner/memory.md"
CLAUDE_CONFIG_DIR="$U" bash "$ROOT/uninstall.sh" >/dev/null 2>&1
left=$(jq '[.. | .command? // empty | select(contains("learner-") or contains("coach-"))] | length' "$U/settings.json" 2>/dev/null || echo 0)
{ [ "$left" = 0 ] \
  && [ ! -e "$U/hooks/learner-quiz.sh" ] \
  && [ ! -e "$U/hooks/learner-config.sh" ] \
  && [ ! -e "$U/hooks/learner-update-check.sh" ] \
  && [ ! -e "$U/hooks/coach-gate.sh" ] \
  && [ ! -e "$U/hooks/coach-watch.sh" ] \
  && [ ! -e "$U/skills/learner/INSTALL_ORIGIN" ] \
  && [ ! -d "$U/skills/learner" ] \
  && [ ! -d "$U/skills/quiz" ] \
  && [ ! -d "$U/skills/status" ] \
  && [ ! -d "$U/skills/pilot" ]; } \
  && ok "uninstall removes hooks, every skill and the wiring" \
  || ko "uninstall removes hooks, every skill and the wiring (left=$left)"

{ [ -f "$U/learner.json" ] && [ -f "$U/learner/memory.md" ]; } \
  && ok "uninstall keeps config and progress data by default" \
  || ko "uninstall keeps config and progress data by default"

CLAUDE_CONFIG_DIR="$U" bash "$ROOT/uninstall.sh" --purge >/dev/null 2>&1
{ [ ! -e "$U/learner.json" ] && [ ! -e "$U/learner" ]; } \
  && ok "--purge deletes config and progress data" \
  || ko "--purge deletes config and progress data"

# An unparsable settings.json must stop the uninstall BEFORE anything is deleted:
# hooks removed + wiring left behind breaks every session in every project.
UB="$WORK/uninst-bad"; mkdir -p "$UB"
CLAUDE_CONFIG_DIR="$UB" bash "$ROOT/install.sh" --level S >/dev/null 2>&1
echo '{ broken' > "$UB/settings.json"
CLAUDE_CONFIG_DIR="$UB" bash "$ROOT/uninstall.sh" >/dev/null 2>&1 \
  && ko "uninstall aborts on an invalid settings.json" \
  || ok "uninstall aborts on an invalid settings.json"
{ [ -f "$UB/hooks/learner-quiz.sh" ] && [ -d "$UB/skills/learner" ]; } \
  && ok "the aborted uninstall left the hooks and skill in place" \
  || ko "the aborted uninstall left the hooks and skill in place"
grep -q 'broken' "$UB/settings.json" \
  && ok "the aborted uninstall left the invalid settings.json untouched" \
  || ko "the aborted uninstall left the invalid settings.json untouched"

# `--project=` is a typo for "clean one repo", never permission to wipe the
# user-level install and every repo's progress data.
UE="$WORK/uninst-empty"; mkdir -p "$UE"
CLAUDE_CONFIG_DIR="$UE" bash "$ROOT/install.sh" --level S >/dev/null 2>&1
for flag in "--project=" "--project"; do
  out=$(CLAUDE_CONFIG_DIR="$UE" bash "$ROOT/uninstall.sh" "$flag" 2>&1) \
    && ko "uninstall rejects '$flag' with no repo path" \
    || ok "uninstall rejects '$flag' with no repo path"
  printf '%s' "$out" | grep -qF -- '--project' \
    && ok "the '$flag' error message names the flag" \
    || ko "the '$flag' error message names the flag (got '$out')"
done
{ [ -f "$UE/hooks/learner-quiz.sh" ] && [ -f "$UE/learner.json" ] \
  && [ "$(hookcount "$UE")" = 7 ]; } \
  && ok "a rejected --project leaves the user-level install untouched" \
  || ko "a rejected --project leaves the user-level install untouched"

# legacy per-project layout
L="$(mktemp -d)"; git -C "$L" init -q
mkdir -p "$L/.claude/hooks" "$L/.claude/skills/learner"
touch "$L/.claude/hooks/learner-quiz.sh" "$L/.claude/skills/learner/SKILL.md"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh .claude/hooks/learner-quiz.sh"}]}]}}\n' \
  > "$L/.claude/settings.json"
printf '.claude/learner.local.json\n.claude/learner-memory.md\nbuild/\n' > "$L/.gitignore"
bash "$ROOT/uninstall.sh" --project "$L" >/dev/null 2>&1
left=$(jq '[.. | .command? // empty | select(contains("learner-"))] | length' "$L/.claude/settings.json")
{ [ "$left" = 0 ] \
  && [ ! -e "$L/.claude/hooks/learner-quiz.sh" ] \
  && [ ! -d "$L/.claude/skills/learner" ] \
  && ! grep -q 'learner-memory' "$L/.gitignore" \
  && grep -q 'build/' "$L/.gitignore"; } \
  && ok "--project cleans the legacy per-repo layout, keeps other gitignore lines" \
  || ko "--project cleans the legacy per-repo layout, keeps other gitignore lines (left=$left)"
rm -rf "$L"

# --- skill content ----------------------------------------------------------
SK="$PLUG/skills/learner/SKILL.md"
REFS="$PLUG/skills/learner/references"

# The hub keeps only what more than one mode reads; every subcommand's own protocol
# is its own skill, so Claude Code can expose it as /learner:<name>.
for f in hook-quiz.md data.md; do
  [ -f "$REFS/$f" ] && ok "references/$f exists" || ko "references/$f exists"
done
for n in quiz status improve coach export sync update; do
  [ -f "$PLUG/skills/$n/SKILL.md" ] && ok "the $n skill exists" || ko "the $n skill exists"
  head -1 "$PLUG/skills/$n/SKILL.md" 2>/dev/null | grep -qx -- '---' \
    && grep -qE '^description: .' "$PLUG/skills/$n/SKILL.md" \
    && ok "the $n skill has frontmatter with a description" \
    || ko "the $n skill has frontmatter with a description"
done

UPD="$PLUG/skills/update/SKILL.md"

# --- skill content: sync -----------------------------------------------------
SYNCMD="$PLUG/skills/sync/references/sync.md"

grep -qF 'the `sync` skill' "$SK" \
  && ok "SKILL.md routes the sync subcommand to the sync skill" \
  || ko "SKILL.md routes the sync subcommand to the sync skill"

for s in "sync push" "sync pull" "sync status" "sync use"; do
  grep -qF "$s" "$SK" \
    && ok "SKILL.md's dispatch table lists '$s'" \
    || ko "SKILL.md's dispatch table lists '$s'"
done

grep -qF 'learner-sync.sh' "$SYNCMD" \
  && ok "sync.md calls the shipped script rather than gh directly" \
  || ko "sync.md calls the shipped script rather than gh directly"

# Narrowed to an actual gist-surface invocation, not any mention of `gh `: sync.md's own
# prose tells the dev to run `gh auth login`, which must stay legal here. Leading
# whitespace is allowed after the line-start anchor so an invocation indented inside a
# code block (as every command in this file is) still matches.
grep -qE '(^[[:space:]]*|[$]\( *)gh (gist|api) ' "$SYNCMD" \
  && ko "sync.md never drives the gist itself" \
  || ok "sync.md never drives the gist itself"

grep -qF -- '--create-ok' "$SYNCMD" \
  && grep -qiE 'unlisted|url can read|anyone with the (link|url)' "$SYNCMD" \
  && ok "sync.md gates gist creation behind an explicit warning" \
  || ko "sync.md gates gist creation behind an explicit warning"

grep -qF 'pull-finish' "$SYNCMD" \
  && ok "sync.md closes the pull with pull-finish" \
  || ko "sync.md closes the pull with pull-finish"

grep -qiE 'never (merge|rename)|report' "$SYNCMD" \
  && grep -qF 'Theme' "$SYNCMD" \
  && ok "sync.md keeps near-duplicate themes out of an automatic rename" \
  || ko "sync.md keeps near-duplicate themes out of an automatic rename"

grep -qF 'CLAUDE_CONFIG_DIR' "$SYNCMD" \
  && grep -qF 'sync.json' "$SYNCMD" \
  && grep -qF 'sync-base' "$SYNCMD" \
  && ok "sync.md resolves its state under CLAUDE_CONFIG_DIR" \
  || ko "sync.md resolves its state under CLAUDE_CONFIG_DIR"

# --- the coach's record rules -----------------------------------------------
DMD="$PLUG/skills/learner/references/data.md"
SMD="$PLUG/skills/sync/references/sync.md"

grep -qF 'libs.md' "$DMD" && ok "data.md documents libs.md" || ko "data.md documents libs.md"
grep -q 'coach-lib' "$DMD" && ok "data.md documents the coach-lib style" \
  || ko "data.md documents the coach-lib style"
grep -q 'coach-ack' "$DMD" && ok "data.md documents the coach-ack style" \
  || ko "data.md documents the coach-ack style"

# The rule that keeps memory.md usable as the question picker: a finding the dev
# was never questioned on must not become a weak spot there.
grep -qi 'never writes to .memory.md.\|not write to .memory.md.' "$DMD" \
  && ok "data.md keeps findings out of memory.md" \
  || ko "data.md keeps findings out of memory.md"

grep -qF 'libs.md' "$SMD" && ok "sync carries libs.md" || ko "sync carries libs.md"
grep -qF 'libs.md' "$ROOT/docs/safety.html" \
  && ok "safety.html's consent list names libs.md" \
  || ko "safety.html's consent list names libs.md"

# export is deliberately NOT touched: it builds Notion rows from recap.md's
# themes, and a library ledger is not a theme.
grep -qF 'libs.md' "$PLUG/skills/export/references/export.md" \
  && ko "export must not carry libs.md" || ok "export deliberately does not carry libs.md"

UPD="$PLUG/skills/update/SKILL.md"

grep -qF 'INSTALL_ORIGIN' "$UPD" \
  && ok "update.md reads the install-origin marker" \
  || ko "update.md reads the install-origin marker"

grep -qF 'brew upgrade learner' "$UPD" \
  && ok "update.md tells a brew install to use brew upgrade" \
  || ko "update.md tells a brew install to use brew upgrade"

grep -qF 'apt install' "$UPD" \
  && ok "update.md tells an apt install to grab a new .deb" \
  || ko "update.md tells an apt install to grab a new .deb"

grep -qF 'learner-install' "$UPD" \
  && ok "update.md points package-managed installs at learner-install" \
  || ko "update.md points package-managed installs at learner-install"

grep -qF '/plugins/' "$UPD" \
  && ok "update.md detects a plugin install by its own load path" \
  || ko "update.md detects a plugin install by its own load path"

grep -qF '/plugin update learner' "$UPD" \
  && ok "update.md points a plugin install at /plugin update" \
  || ko "update.md points a plugin install at /plugin update"

# Every skill's SKILL.md, not just learner's — derived from skills/*/SKILL.md
# rather than a second hardcoded path, so a third skill inherits this budget
# without anyone remembering to add a check for it.
for sk in "$PLUG"/skills/*/SKILL.md; do
  skn=$(basename "$(dirname "$sk")")
  n=$(wc -l < "$sk" | tr -d ' ')
  [ "$n" -le 120 ] \
    && ok "$skn/SKILL.md stays under 120 lines (it is always loaded)" \
    || ko "$skn/SKILL.md stays under 120 lines (got $n)"
done

grep -qE 'recapEvery|trouBlanks|(^|[^A-Za-z])trackGlobs|"language"' "$SK" "$REFS"/*.md "$PLUG"/skills/*/SKILL.md \
  && ko "skill mentions no removed config key" \
  || ok "skill mentions no removed config key"

grep -q 'learner-memory.md\|learner-recap.md' "$SK" "$REFS"/*.md "$PLUG"/skills/*/SKILL.md \
  && ko "skill uses the new data paths, not the old per-project names" \
  || ok "skill uses the new data paths, not the old per-project names"

for k in level enabled questionStyles synthesisFrequency blanksPerExercise untrackGlobs disabledPaths; do
  grep -q "$k" "$SK" "$PLUG/skills/learner/references/config.md" && ok "the config key $k is documented" || ko "the config key $k is documented"
done

for l in D J C S E; do
  grep -qE "^\| \`?$l\`? " "$SK" && ok "SKILL.md documents level $l" || ko "SKILL.md documents level $l"
done

grep -q 'references/hook-quiz.md' "$SK" \
  && ok "SKILL.md routes the hook trigger to references/hook-quiz.md" \
  || ko "SKILL.md routes the hook trigger to references/hook-quiz.md"

# Same guard for the export Dispatch row: repointed at prose elsewhere, export.md would
# become dead weight and every assertion below would still pass.
for n in quiz status improve coach export sync update; do
  grep -qF "the \`$n\` skill" "$SK" \
    && ok "SKILL.md routes the $n subcommand to the $n skill" \
    || ko "SKILL.md routes the $n subcommand to the $n skill"
done

STAT="$PLUG/skills/status/SKILL.md"
grep -qi 'skills/learner/VERSION' "$STAT" \
  && ok "the status skill reads the installed VERSION file" \
  || ko "the status skill reads the installed VERSION file"

grep -qF '/plugin' "$STAT" \
  && ok "the status skill is plugin-aware" \
  || ko "the status skill is plugin-aware"

grep -q 'references/data.md' "$REFS/hook-quiz.md" \
  && grep -q 'references/data.md' "$PLUG/skills/quiz/SKILL.md" \
  && grep -q 'references/data.md' "$PLUG/skills/improve/SKILL.md" \
  && ok "the three quiz modes all defer to references/data.md" \
  || ko "the three quiz modes all defer to references/data.md"

grep -q 'CLAUDE_CONFIG_DIR' "$REFS/data.md" \
  && ok "data.md resolves the config dir from CLAUDE_CONFIG_DIR" \
  || ko "data.md resolves the config dir from CLAUDE_CONFIG_DIR"

# The Learning level in the Notion export is computed per theme from these rows, so a row
# that does not name its theme is uncountable. `Theme` going last is the decision, not an
# accident: an old six-cell row then reads unambiguously as untagged, where an inserted
# column would make cell 4 mean `Style` on old rows and `Theme` on new ones — and the
# reader here is a model, not a parser holding a schema.
grep -qF '| Date | Repo | Domain | Style | Verdict | Note | Theme |' "$REFS/data.md" \
  && ok "data.md's Session history table ends with the Theme column" \
  || ko "data.md's Session history table ends with the Theme column"

# The five-value scale is the export's whole contribution beyond a copy of recap.md, and
# rule 1 is what keeps recap.md authoritative over the tally. A value renamed or a rule
# dropped in a later edit would silently regrade every row, with no other symptom.
# Narrowed to the `Learning level` row: every value also appears in §5's rule table, and
# `Mastered` in the prose besides, so a file-wide grep stayed green with the Select row
# and rule 1 both gone.
for v in Discovered Shaky Progressing Solid Mastered; do
  grep -F 'Learning level' "$PLUG/skills/export/references/export.md" | grep -qF "\`$v\`" \
    && ok "export.md documents the '$v' learning level" \
    || ko "export.md documents the '$v' learning level"
done

# Bracket expressions, not `\|`: the rule rows are the only lines in the file that open
# with a pipe, a single digit and a pipe. Scoped to §5 so an unrelated `| N |` row added
# elsewhere cannot inflate the count and turn this red with a misleading message.
nrules=$(awk '/^## 5[.]/{f=1} /^## 6[.]/{f=0} f && /^[|] [1-6] [|]/{c++} END{print c+0}' "$PLUG/skills/export/references/export.md")
[ "$nrules" -eq 6 ] \
  && ok "export.md keeps all six level-derivation rules" \
  || ko "export.md keeps all six level-derivation rules (got $nrules)"

grep -qF 'CLAUDE_CONFIG_DIR' "$PLUG/skills/export/references/export.md" \
  && grep -qF 'export.json' "$PLUG/skills/export/references/export.md" \
  && ok "export.md resolves export.json under CLAUDE_CONFIG_DIR" \
  || ko "export.md resolves export.json under CLAUDE_CONFIG_DIR"

# Locked decision 2: no connector, no export. A file-shaped consolation prize would
# reopen the export surface this design defers, so the two words are banned outright —
# the protocol cannot drift into offering one without turning this red.
grep -qiE 'csv|markdown' "$PLUG/skills/export/references/export.md" \
  && ko "export.md offers no file-format fallback" \
  || ok "export.md offers no file-format fallback"

# The trigger's field names are a contract between the hook and the protocol file:
# renaming one in the hook, or dropping it from hook-quiz.md, breaks the read with
# no other symptom. Assert both halves, and cross-check what is actually emitted.
echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"
SIDT=triggerfields
rec "$SIDT" "$WORK/proj/src/T.kt"
trigger=$(quiz "$SIDT" | jq -r '.reason' | head -n 1)

for k in level mode styles blanks files; do
  printf '%s' "$trigger" | grep -qF "$k:" \
    && ok "the trigger emits the '$k' field" \
    || ko "the trigger emits the '$k' field"
  grep -qF "\`$k\`" "$REFS/hook-quiz.md" \
    && ok "hook-quiz.md reads the '$k' field" \
    || ko "hook-quiz.md reads the '$k' field"
done

undocumented=''
while IFS= read -r k; do
  [ -n "$k" ] || continue
  grep -qF "\`$k\`" "$REFS/hook-quiz.md" || undocumented="$undocumented $k"
done <<EOF
$(printf '%s' "$trigger" | grep -oE '[a-z]+:' | tr -d ':' | sort -u)
EOF
[ -z "$undocumented" ] \
  && ok "every field the trigger emits is documented in hook-quiz.md" \
  || ko "every field the trigger emits is documented in hook-quiz.md (missing:$undocumented)"

# The `fill` style edits real source files, so its protocol is the load-bearing
# part of hook-quiz.md: read the section itself, not the file as a whole.
fill=$(awk '/^## The `fill` protocol/{f=1;next} /^## /{f=0} f' "$REFS/hook-quiz.md")
[ -n "$fill" ] \
  && ok "hook-quiz.md carries the fill protocol" \
  || ko "hook-quiz.md carries the fill protocol"

printf '%s' "$fill" | grep -qF '`blanks`' \
  && ok "the fill protocol cuts as many holes as blanks says" \
  || ko "the fill protocol cuts as many holes as blanks says"

printf '%s' "$fill" | grep -qi 'restore' \
  && ok "the fill protocol restores the correct implementation" \
  || ko "the fill protocol restores the correct implementation"

{ printf '%s' "$fill" | grep -qi 'never end a turn' \
  && printf '%s' "$fill" | grep -qF 'LEARNER-TODO'; } \
  && ok "the fill protocol forbids ending a turn with a leftover marker" \
  || ko "the fill protocol forbids ending a turn with a leftover marker"

{ grep -qi 'multiple-choice' "$PLUG/skills/quiz/SKILL.md" && grep -qi 'multiple-choice' "$REFS/hook-quiz.md"; } \
  && ok "both quiz protocols prefer plain chat over multiple choice" \
  || ko "both quiz protocols prefer plain chat over multiple choice"

# A question that quotes both sides of a hunk and then asks what the change does has
# already been answered. The rule that forbids it has to live in both protocols: the
# Stop hook reads one, `learner quiz` reads the other, and neither reads the other one.
for f in "$PLUG/skills/quiz/SKILL.md" "$REFS/hook-quiz.md"; do
  leak=$(awk '/^## Never hand the answer over/{f=1;next} /^## /{f=0} f' "$f")
  { printf '%s' "$leak" | grep -qi 'both sides' \
    && printf '%s' "$leak" | grep -qi 'feedback'; } \
    && ok "$f forbids a question that carries its own answer" \
    || ko "$f forbids a question that carries its own answer"
done

# --- docs -------------------------------------------------------------------
RM="$ROOT/README.md"
SITE="$ROOT/docs/index.html"
STYLE="$ROOT/docs/assets/style.css"

SITE_INSTALL="$ROOT/docs/install.html"
SITE_USAGE="$ROOT/docs/usage.html"
SITE_CONFIG="$ROOT/docs/config.html"
SITE_SAFETY="$ROOT/docs/safety.html"

# Every published page, by basename. Per-page loops iterate this list, so a page
# added to the site cannot quietly skip the structural checks below.
PAGES="index install usage config safety"

page_path() { printf '%s/docs/%s.html' "$ROOT" "$1"; }

# Boundary-aware on trackGlobs (untrackGlobs must not self-trip this). Only
# `intermediaire` is banned: `junior` and `senior` are supported level aliases, so
# a legitimate "aliases accepted" line must not trip this.
grep -qE 'recapEvery|trouBlanks|(^|[^A-Za-z])trackGlobs|"language"|intermediaire' "$RM" \
  && ko "README mentions no removed key or old level" \
  || ok "README mentions no removed key or old level"

grep -qF 'bootstrap.sh' "$RM" \
  && ok "README documents the one-line install" \
  || ko "README documents the one-line install"

grep -qF 'LEARNER_REF' "$RM" \
  && ok "README documents pinning a ref" \
  || ko "README documents pinning a ref"

grep -qF 'sh -s --' "$RM" \
  && ok "README documents the non-interactive one-liner form" \
  || ko "README documents the non-interactive one-liner form"

# Named and pinned to the bullet it was kept for, not to the bare word: the README no
# longer mentions Windows/WSL/Git Bash at all (that moved to the site), but a bare
# `grep -qiF 'posix'` still passed after a reviewer deleted every prose mention of it —
# the shields.io badge on line 6 (`shell-POSIX%20sh`) kept it green for the wrong reason.
grep -qE '^- [*][*]A POSIX-compliant shell to run the hooks[*][*]' "$RM" \
  && ok "README's Requirements list keeps the POSIX-shell bullet" \
  || ko "README's Requirements list keeps the POSIX-shell bullet"

# bootstrap.sh preflights `bash`, so it is a hard install-time dependency on both
# paths (install.sh is a bash script) and Requirements has to say so. A bare
# `grep -qF 'bash'` would be worthless here: every fenced code block in this
# README opens with ```bash, and "Git Bash" appears on the site's platform
# table, so it would pass against a README that never mentions the dependency.
# Pinned to the bullet's shape instead, including "to install" — the claim that
# distinguishes it from the POSIX-shell bullet, which is about running the
# hooks. Bracket expressions, not backslashes, before the ordinary backtick
# character.
grep -qE '^- [*][*][`]bash[`][*][*] on [`]PATH[`] to install' "$RM" \
  && ok "README requires bash to install, separately from the hooks' shell" \
  || ko "README requires bash to install, separately from the hooks' shell"

# The Development section's shellcheck line must match what CI actually runs. A fixed
# substring here only ever proved the README mentions bootstrap.sh, never that it matches
# .github/workflows/ci.yml — so read the real command out of the workflow file and compare
# against it, rather than trusting a copy of a copy.
CI_YML="$ROOT/.github/workflows/ci.yml"
CI_SHELLCHECK=$(awk '/name: shellcheck/{getline; sub(/^[[:space:]]*run:[[:space:]]*/, ""); print; exit}' "$CI_YML")
[ -n "$CI_SHELLCHECK" ] \
  && grep -qF "$CI_SHELLCHECK" "$RM" \
  && ok "README's Development shellcheck line matches .github/workflows/ci.yml" \
  || ko "README's Development shellcheck line matches .github/workflows/ci.yml"

grep -qE "tags:[[:space:]]*\['?v\*'?\]" "$CI_YML" \
  && ok "CI triggers on version tags, for the VERSION-vs-tag guard" \
  || ko "CI triggers on version tags, for the VERSION-vs-tag guard"

grep -qF 'startsWith(github.ref' "$CI_YML" \
  && grep -qF 'TAG="${GITHUB_REF_NAME#v}"' "$CI_YML" \
  && grep -qF 'FILE="$(cat VERSION)"' "$CI_YML" \
  && grep -qF '[ "$TAG" != "$FILE" ]' "$CI_YML" \
  && grep -qF 'exit 1' "$CI_YML" \
  && ok "CI guards a tag push against the VERSION file" \
  || ko "CI guards a tag push against the VERSION file"

grep -qF 'contents: write' "$CI_YML" \
  && ok "CI grants contents:write, needed to publish a release asset" \
  || ko "CI grants contents:write, needed to publish a release asset"

grep -qF 'run: bash packaging/deb/build.sh' "$CI_YML" \
  && ok "CI builds the .deb on a tag push" \
  || ko "CI builds the .deb on a tag push"

grep -qF 'softprops/action-gh-release' "$CI_YML" \
  && grep -qF 'learner_*_all.deb' "$CI_YML" \
  && ok "CI publishes the .deb as a release asset" \
  || ko "CI publishes the .deb as a release asset"

grep -qF 'deploy-pages:' "$CI_YML" \
  && ok "CI defines a deploy-pages job" \
  || ko "CI defines a deploy-pages job"

grep -qF 'run: bash packaging/apt-repo/assemble-site.sh' "$CI_YML" \
  && ok "deploy-pages runs the site assembler" \
  || ko "deploy-pages runs the site assembler"

grep -qF 'actions/upload-pages-artifact' "$CI_YML" \
  && grep -qF 'actions/deploy-pages' "$CI_YML" \
  && ok "deploy-pages uploads and deploys the Pages artifact" \
  || ko "deploy-pages uploads and deploys the Pages artifact"

grep -qF 'pages: write' "$CI_YML" \
  && grep -qF 'id-token: write' "$CI_YML" \
  && ok "deploy-pages grants pages:write and id-token:write" \
  || ko "deploy-pages grants pages:write and id-token:write"

grep -qF 'needs: [ci, release]' "$CI_YML" \
  && ok "deploy-pages runs after both ci and release" \
  || ko "deploy-pages runs after both ci and release"

grep -qF 'plugin.json version matches VERSION' "$CI_YML" \
  && ok "CI guards plugin.json's version against the VERSION file" \
  || ko "CI guards plugin.json's version against the VERSION file"

{ grep -qF 'claude plugin validate . --strict' "$CI_YML" \
  && grep -qF 'claude plugin validate ./plugins/learner --strict' "$CI_YML"; } \
  && ok "CI validates both the marketplace and the plugin manifest" \
  || ko "CI validates both the marketplace and the plugin manifest"

grep -qF "jq -r '.version' plugins/learner/.claude-plugin/plugin.json" "$CI_YML" \
  && ok "the plugin.json version guard reads the real field" \
  || ko "the plugin.json version guard reads the real field"

grep -qF 'update-check hook' "$RM" \
  && ok "README notes curl as a soft run-time dependency for the update-check hook" \
  || ko "README notes curl as a soft run-time dependency for the update-check hook"

# The install one-liner appears in two files by design. Pin them to each other so
# they cannot drift: this is the whole reason the split is acceptable.
ONELINER='curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh'
{ grep -qF "$ONELINER" "$RM" && grep -qF "$ONELINER" "$SITE_INSTALL"; } \
  && ok "the install one-liner is identical in the README and on install.html" \
  || ko "the install one-liner is identical in the README and on install.html"

apt_h2=$(grep -n '<h2 id="apt">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
homebrew_h2=$(grep -n '<h2 id="homebrew">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
clone_h2=$(grep -n '<h2 id="clone">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
alt_h2=$(grep -n '<h2 id="alternative">' "$SITE_INSTALL" | head -1 | cut -d: -f1)

{ [ -n "$apt_h2" ] && [ -n "$homebrew_h2" ] && [ -n "$clone_h2" ] && [ -n "$alt_h2" ] \
  && [ "$apt_h2" -lt "$homebrew_h2" ] \
  && [ "$homebrew_h2" -lt "$clone_h2" ] \
  && [ "$clone_h2" -lt "$alt_h2" ]; } \
  && ok "install.html orders sections as apt, Homebrew, clone, then the curl alternative" \
  || ko "install.html orders sections as apt, Homebrew, clone, then the curl alternative"

plugin_h2=$(grep -n '<h2 id="plugin">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
apt_h2=$(grep -n '<h2 id="apt">' "$SITE_INSTALL" | head -1 | cut -d: -f1)

{ [ -n "$plugin_h2" ] && [ -n "$apt_h2" ] && [ "$plugin_h2" -lt "$apt_h2" ]; } \
  && ok "install.html lists the plugin section before apt" \
  || ko "install.html lists the plugin section before apt"

grep -qF 'claude plugin install learner@learning-with-claude' "$SITE_INSTALL" \
  && ok "install.html installs the plugin by its marketplace-qualified name" \
  || ko "install.html installs the plugin by its marketplace-qualified name"

grep -qF 'sudo apt install learner' "$SITE_INSTALL" \
  && ok "install.html documents installing directly from the apt repository" \
  || ko "install.html documents installing directly from the apt repository"

grep -qF '<h2 id="packages">' "$SITE_INSTALL" \
  && ko "install.html no longer has the old combined packages section" \
  || ok "install.html no longer has the old combined packages section"

{ grep -qF 'docs/index.html' "$RM" || grep -qiF 'github.io' "$RM"; } \
  && ok "the README links to the site" \
  || ko "the README links to the site"

grep -qF 'brew install learner' "$RM" \
  && ok "README documents the Homebrew install path" \
  || ko "README documents the Homebrew install path"

grep -qF 'sudo apt install ./learner_' "$RM" \
  && ok "README documents the apt/.deb install path" \
  || ko "README documents the apt/.deb install path"

grep -qF 'learner-install --level' "$RM" \
  && ok "README documents the learner-install activation command" \
  || ko "README documents the learner-install activation command"

apt_line=$(grep -n '^### apt (Debian/Ubuntu)$' "$RM" | head -1 | cut -d: -f1)
brew_line=$(grep -n '^### Homebrew' "$RM" | head -1 | cut -d: -f1)
clone_line=$(grep -n '^### Clone and run$' "$RM" | head -1 | cut -d: -f1)
alt_line=$(grep -n '^### Alternative: the curl one-liner$' "$RM" | head -1 | cut -d: -f1)

{ [ -n "$apt_line" ] && [ -n "$brew_line" ] && [ -n "$clone_line" ] && [ -n "$alt_line" ] \
  && [ "$apt_line" -lt "$brew_line" ] \
  && [ "$brew_line" -lt "$clone_line" ] \
  && [ "$clone_line" -lt "$alt_line" ]; } \
  && ok "README orders Install as apt, Homebrew, clone, then the curl alternative" \
  || ko "README orders Install as apt, Homebrew, clone, then the curl alternative"

grep -qF 'sudo apt install learner' "$RM" \
  && ok "README documents installing directly from the apt repository" \
  || ko "README documents installing directly from the apt repository"

grep -qF 'learner.gpg' "$RM" \
  && ok "README documents the apt repo's signing key setup" \
  || ko "README documents the apt repo's signing key setup"

plugin_line=$(grep -n '^### Claude Code plugin$' "$RM" | head -1 | cut -d: -f1)
apt_line=$(grep -n '^### apt (Debian/Ubuntu)$' "$RM" | head -1 | cut -d: -f1)

{ [ -n "$plugin_line" ] && [ -n "$apt_line" ] && [ "$plugin_line" -lt "$apt_line" ]; } \
  && ok "README lists the Claude Code plugin before apt" \
  || ko "README lists the Claude Code plugin before apt"

# Qualified with the marketplace, not bare: a bare `learner` is ambiguous the moment
# the user has another marketplace registered that also ships one.
grep -qF 'claude plugin install learner@learning-with-claude' "$RM" \
  && ok "README installs the plugin by its marketplace-qualified name" \
  || ko "README installs the plugin by its marketplace-qualified name"

grep -qF 'claude plugin marketplace add Tykok/learning-with-claude' "$RM" \
  && ok "README documents adding the self-hosted marketplace" \
  || ko "README documents adding the self-hosted marketplace"

grep -qF 'wires every hook twice' "$RM" \
  && ok "README warns against installing both the plugin and a traditional install" \
  || ko "README warns against installing both the plugin and a traditional install"

grep -qF 'wires every hook twice' "$SITE_INSTALL" \
  && ok "install.html warns against installing both the plugin and a traditional install" \
  || ko "install.html warns against installing both the plugin and a traditional install"

# --- bootstrap --------------------------------------------------------------
BOOT="$ROOT/bootstrap.sh"

# A tarball of the working tree, not `git archive`: the change under test must be
# covered before it is committed. Exactly one top-level directory, because the
# bootstrap strips one component.
TARBALL="$WORK/payload.tgz"
tar -czf "$TARBALL" -C "$(dirname "$ROOT")" "$(basename "$ROOT")"

boot() { CLAUDE_CONFIG_DIR="$1" LEARNER_URL="file://$TARBALL" sh "$BOOT" "${@:2}"; }

B1="$WORK/boot1"; mkdir -p "$B1"
boot "$B1" --level S >/dev/null 2>&1
{ [ -f "$B1/hooks/learner-config.sh" ] \
  && [ -f "$B1/hooks/learner-quiz.sh" ] \
  && [ -f "$B1/skills/learner/SKILL.md" ] \
  && [ -f "$B1/skills/learner/references/data.md" ] \
  && [ -f "$B1/learner.json" ]; } \
  && ok "bootstrap installs the payload from the tarball" \
  || ko "bootstrap installs the payload from the tarball"

B2="$WORK/boot2"; mkdir -p "$B2"
boot "$B2" --level senior --synthesis often --blanks 3 >/dev/null 2>&1
jq -e '.level == "S" and .synthesisFrequency == "often" and .blanksPerExercise == 3' \
  "$B2/learner.json" >/dev/null 2>&1 \
  && ok "bootstrap passes every flag through to install.sh" \
  || ko "bootstrap passes every flag through to install.sh"

B3="$WORK/boot3"; mkdir -p "$B3"
boot "$B3" --level S --dry-run >/dev/null 2>&1
[ ! -e "$B3/learner.json" ] \
  && ok "bootstrap honours --dry-run (nothing written)" \
  || ko "bootstrap honours --dry-run (nothing written)"

# Temp dirs must not accumulate: count what the bootstrap leaves behind.
before=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
B4="$WORK/boot4"; mkdir -p "$B4"
TMPDIR="$WORK/tmp" boot "$B4" --level S >/dev/null 2>&1
after=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$before" = "$after" ] \
  && ok "bootstrap removes its temp dir on success" \
  || ko "bootstrap removes its temp dir on success (before=$before after=$after)"

before=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
mkdir -p "$WORK/boot5"
CLAUDE_CONFIG_DIR="$WORK/boot5" LEARNER_URL="file://$WORK/nope.tgz" \
  TMPDIR="$WORK/tmp" sh "$BOOT" --level S >/dev/null 2>&1
after=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$before" = "$after" ] \
  && ok "bootstrap removes its temp dir on a failed fetch" \
  || ko "bootstrap removes its temp dir on a failed fetch (before=$before after=$after)"

mkdir -p "$WORK/boot6"
out=$(CLAUDE_CONFIG_DIR="$WORK/boot6" LEARNER_URL="file://$WORK/nope.tgz" \
  sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap fails on an unreachable URL" \
  || ok "bootstrap fails on an unreachable URL"

# Every die() message is prefixed "error: ", so a bare 'error' grep would pass
# against ANY failure path, not specifically this one — the wording unique to a
# fetch that delivered nothing is "could not fetch". This assertion belongs on
# the *missing* URL and nowhere else, and it is assertable only because the
# bootstrap downloads to a file and reads curl's own exit status (37 here, on
# both curl builds). Under the earlier `curl | tar` pipeline it was unreachable
# on macOS: POSIX sh has no pipefail, so the pipeline's status was tar's, and
# bsdtar accepts curl's zero bytes as a valid empty archive and exits 0 (GNU
# tar exits 2) — every 404, DNS or proxy failure was reported there as
# "has no install.sh (bad ref?)", naming a branch problem for a network one.
printf '%s' "$out" | grep -qF 'could not fetch' \
  && ok "the failed-fetch message names the failed fetch" \
  || ko "the failed-fetch message names the failed fetch"

# A fetch that *succeeds* and hands back bytes that are not a gzip stream is a
# different fault with a different cause, and must not be reported as a failed
# fetch. An existing non-gzip file, not a missing one: curl returns 0 for it
# everywhere, and both bsdtar and GNU tar then reject the bytes identically
# (confirmed by running both directly), so this fixture is deterministic where
# a missing file would exercise the branch above instead.
GARBAGE="$WORK/garbage.tgz"
printf 'not a gzip archive at all, just plain bytes\n' > "$GARBAGE"
mkdir -p "$WORK/boot6b"
out=$(CLAUDE_CONFIG_DIR="$WORK/boot6b" LEARNER_URL="file://$GARBAGE" \
  sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap fails when the fetch yields no usable archive" \
  || ok "bootstrap fails when the fetch yields no usable archive"
printf '%s' "$out" | grep -qF 'not a readable tar.gz' \
  && ok "the unusable-archive message blames the archive, not the fetch" \
  || ko "the unusable-archive message blames the archive, not the fetch"

# An archive without install.sh must be named as such, not fail deep inside bash.
BADTAR="$WORK/bad.tgz"; mkdir -p "$WORK/badsrc/inner"; echo x > "$WORK/badsrc/inner/f"
tar -czf "$BADTAR" -C "$WORK" badsrc
mkdir -p "$WORK/boot7"
out=$(CLAUDE_CONFIG_DIR="$WORK/boot7" LEARNER_URL="file://$BADTAR" \
  sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap rejects an archive with no install.sh" \
  || ok "bootstrap rejects an archive with no install.sh"
# -F on the whole phrase, not a bare 'install.sh': the path bash prints when it
# cannot find the file ("No such file or directory: …/install.sh") also contains
# that substring, so a bare pattern stayed green with the guard deleted.
printf '%s' "$out" | grep -qF 'has no install.sh' \
  && ok "the bad-archive message names install.sh" \
  || ko "the bad-archive message names install.sh"

# Claude Code absent: must abort BEFORE fetching. A fake curl proves no fetch ran.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\ntouch "%s/curl-ran"\nexit 1\n' "$WORK" > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"
rm -f "$WORK/curl-ran"
out=$(PATH="$FAKEBIN:/usr/bin:/bin" HOME="$WORK/nohome" \
  CLAUDE_CONFIG_DIR="$WORK/no-such-cfg" sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap aborts when Claude Code is absent" \
  || ok "bootstrap aborts when Claude Code is absent"
printf '%s' "$out" | grep -qi 'claude' \
  && ok "the abort message names Claude Code" \
  || ko "the abort message names Claude Code"
[ ! -e "$WORK/curl-ran" ] \
  && ok "the Claude Code check runs before any fetch" \
  || ko "the Claude Code check runs before any fetch"

# LEARNER_REF must reach the URL. A fake curl records the URL it was handed.
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in http*|file*) echo "$a" > "%s/curl-url" ;; esac; done\nexit 1\n' \
  "$WORK" > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"
rm -f "$WORK/curl-url"
PATH="$FAKEBIN:/usr/bin:/bin" LEARNER_REF=v9.9.9 \
  CLAUDE_CONFIG_DIR="$B1" sh "$BOOT" --level S >/dev/null 2>&1
{ [ -f "$WORK/curl-url" ] && grep -q 'v9.9.9' "$WORK/curl-url"; } \
  && ok "LEARNER_REF reaches the fetch URL" \
  || ko "LEARNER_REF reaches the fetch URL"
grep -q 'Tykok/learning-with-claude' "$WORK/curl-url" 2>/dev/null \
  && ok "the fetch URL names the repo" \
  || ko "the fetch URL names the repo"

# No terminal and no --level: install.sh could neither prompt nor proceed, so the
# bootstrap must say so itself — the user typed a URL, not a script with flags.
# `-r /dev/tty` only checks permissions, and a redirection failure on the `:`
# special built-in kills a POSIX shell (dash) outright, so this guard opens the
# terminal in a subshell to agree with bootstrap.sh. Only assertable where that
# open fails; skipped where it succeeds.
if (exec 3< /dev/tty) 2>/dev/null; then
  skip "no-tty guidance and its existing-config exemption (a terminal is available here)"
else
  # A config directory that exists but holds no learner.json. It has to exist,
  # or the Claude Code preflight fires first where no `claude` binary is on PATH
  # (CI); and it must have no learner.json, or the guard's exemption applies and
  # this exercises the pass-through below instead of the refusal it names — the
  # reason $B1 cannot be reused here now that the exemption exists.
  B8="$WORK/boot8"; mkdir -p "$B8"
  out=$(CLAUDE_CONFIG_DIR="$B8" LEARNER_URL="file://$TARBALL" sh "$BOOT" 2>&1) \
    && ko "bootstrap refuses with no terminal and no --level" \
    || ok "bootstrap refuses with no terminal and no --level"
  printf '%s' "$out" | grep -q -- '--level' \
    && ok "the no-tty message shows the --level re-run" \
    || ko "the no-tty message shows the --level re-run"

  # The other half of the guard: install.sh gates its whole prompt block on the
  # config NOT existing, so with a learner.json already there it needs no
  # answers and refusing would break a legitimate non-interactive re-install
  # (re-copying hooks after an update). $B1 has one, from the first bootstrap
  # test above. Deleting a hook first proves the run reached install.sh, rather
  # than merely getting past the guard and failing somewhere later.
  rm -f "$B1/hooks/learner-quiz.sh"
  { CLAUDE_CONFIG_DIR="$B1" LEARNER_URL="file://$TARBALL" sh "$BOOT" >/dev/null 2>&1 \
    && [ -f "$B1/hooks/learner-quiz.sh" ]; } \
    && ok "bootstrap proceeds with no terminal and no --level once a config exists" \
    || ko "bootstrap proceeds with no terminal and no --level once a config exists"
fi

# --- site -------------------------------------------------------------------
# SITE is set in the docs section above; the README and site checks share it so
# the one-liner and link assertions there can compare the two files.

[ -f "$SITE" ] && ok "the site exists at docs/index.html" \
               || ko "the site exists at docs/index.html"

[ -f "$ROOT/docs/.nojekyll" ] \
  && ok "docs/.nojekyll stops GitHub running the page through Jekyll" \
  || ko "docs/.nojekyll stops GitHub running the page through Jekyll"

# The published root must hold the site, and nothing else. The design records it
# once had to be kept apart from now live in the wiki, so there is no in-tree
# counterpart left to assert.
[ ! -d "$ROOT/docs/superpowers" ] \
  && ok "the published root carries no internal design records" \
  || ko "the published root carries no internal design records"

# No external request at load. <a href> navigation is fine; fetching tags/properties are
# not. The original three (script/link-href/@import) missed a whole class of fetch: an
# `@font-face { src: url(https://…) }` needs none of them, so a reviewer added one and the
# suite stayed green. img/iframe/embed/object/srcset cover the other tags that fetch;
# url(...) is scoped to an http(s) scheme so a local url(#fragment) or a data: URI (no
# request either) is not a false positive.
#
# The <link> branch is scoped to a scheme rather than banning href outright: the pages
# share one local stylesheet, which issues no external request. `//` is included because a
# protocol-relative URL fetches off-origin exactly like an absolute one.
EXTERNAL='<script|<link[^>]+href="(https?:|//)|@import|<img|<iframe|<embed|<object|srcset|url\([^)]*https?:'

for p in $PAGES; do
  f=$(page_path "$p")

  grep -qiE "$EXTERNAL" "$f" \
    && ko "$p.html issues no external request at load" \
    || ok "$p.html issues no external request at load"

  grep -qF '<link rel="stylesheet" href="assets/style.css">' "$f" \
    && ok "$p.html links the shared stylesheet" \
    || ko "$p.html links the shared stylesheet"

  # -o counts occurrences, not matching lines: two <h1> on one line must still fail.
  n=$(grep -oiE '<h1[ >]' "$f" | wc -l | tr -d ' ')
  [ "$n" = 1 ] && ok "$p.html has exactly one h1" \
               || ko "$p.html has exactly one h1 (found $n)"
done

# The stylesheet is scanned too, and it is the likelier place for a web font to appear.
grep -qiE "$EXTERNAL" "$STYLE" \
  && ko "the stylesheet issues no external request" \
  || ok "the stylesheet issues no external request"

grep -qiF 'prefers-color-scheme' "$STYLE" \
  && ok "the stylesheet styles both light and dark" \
  || ko "the stylesheet styles both light and dark"

# --- the shared chrome ------------------------------------------------------
# The menu is copied into every page by hand, so the thing to assert is not that
# copying happened but that the copies agree.

nav_links() {
  # The menu's ordered "href|label" list, one per line. aria-current sits between
  # the href and the '>' and is deliberately dropped: it differs by page on
  # purpose, so comparing raw bytes would report every page as divergent.
  awk '/<nav class="site"/,/<\/nav>/' "$1" \
    | grep -oE '<li><a href="[^"]+"[^>]*>[^<]+</a></li>' \
    | sed -e 's/^<li><a href="//' -e 's/"[^>]*>/|/' -e 's|</a></li>$||'
}

nav_ref=$(nav_links "$(page_path index)")

[ -n "$nav_ref" ] \
  && ok "index.html carries a menu" \
  || ko "index.html carries a menu"

for p in $PAGES; do
  [ "$(nav_links "$(page_path "$p")")" = "$nav_ref" ] \
    && ok "$p.html's menu matches index.html's" \
    || ko "$p.html's menu matches index.html's"
done

# The menu lists every page and nothing else. Without this, five pages could agree
# on a menu that omits one of them.
nav_n=$(printf '%s\n' "$nav_ref" | grep -c '|')
# shellcheck disable=SC2086  # word splitting is how the page list is iterated
page_n=$(printf '%s\n' $PAGES | wc -l | tr -d ' ')
[ "$nav_n" = "$page_n" ] \
  && ok "the menu lists every page ($page_n)" \
  || ko "the menu lists every page (menu $nav_n, pages $page_n)"

# Each page marks itself, and only itself. Two matches make $cur two lines and fail
# the comparison, so this covers "exactly one" without a separate count.
for p in $PAGES; do
  cur=$(awk '/<nav class="site"/,/<\/nav>/' "$(page_path "$p")" \
        | grep -oE 'href="[^"]+" aria-current="page"' \
        | sed -e 's/^href="//' -e 's/" aria-current="page"$//')
  [ "$cur" = "$p.html" ] \
    && ok "$p.html marks itself current in the menu" \
    || ko "$p.html marks itself current in the menu (got '$cur')"
done

# Every local href resolves: the file exists, and a fragment exists as an id in it.
# This is what guards the cross-page links the split creates, and the only check
# that catches an id deleted later. Hrefs on this site carry no spaces, so word
# splitting over the grep output is safe.
link_bad=0
for f in "$ROOT"/docs/*.html; do
  for h in $(grep -oE 'href="[^"]+"' "$f" | sed -e 's/^href="//' -e 's/"$//'); do
    case "$h" in http:*|https:*|//*|mailto:*) continue ;; esac
    target=${h%%#*}
    [ -n "$target" ] || target=$(basename "$f")
    if [ ! -f "$ROOT/docs/$target" ]; then
      link_bad=$((link_bad + 1))
      echo "    dangling file: $h  (in $(basename "$f"))"
      continue
    fi
    case "$h" in
      *[#]*)
        frag=${h#*#}
        grep -qF "id=\"$frag\"" "$ROOT/docs/$target" || {
          link_bad=$((link_bad + 1))
          echo "    dangling anchor: $h  (in $(basename "$f"))"
        } ;;
    esac
  done
done
[ "$link_bad" = 0 ] \
  && ok "every internal link resolves to a file and an id" \
  || ko "every internal link resolves to a file and an id ($link_bad dangling)"

# A page with four or more sections gets an "On this page" list; a shorter page does
# not, because a two-entry table of contents is decoration rather than navigation.
# Where the list exists, its entries must be the page's h2 ids in document order.
for p in $PAGES; do
  f=$(page_path "$p")
  h2_ids=$(grep -oE '<h2 id="[^"]+"' "$f" | sed -e 's/^<h2 id="//' -e 's/"$//')
  h2_n=$(printf '%s\n' "$h2_ids" | grep -c .)
  toc_ids=$(awk '/<nav class="toc"/,/<\/nav>/' "$f" \
            | grep -oE 'href="#[^"]+"' | sed -e 's/^href="#//' -e 's/"$//')
  if [ "$h2_n" -ge 4 ]; then
    [ "$toc_ids" = "$h2_ids" ] \
      && ok "$p.html's table of contents matches its $h2_n sections" \
      || ko "$p.html's table of contents matches its $h2_n sections"
  else
    [ -z "$toc_ids" ] \
      && ok "$p.html has $h2_n sections and needs no table of contents" \
      || ko "$p.html has $h2_n sections and needs no table of contents"
  fi
done

# Every page ends with a link onward, so no page is a dead end.
for p in $PAGES; do
  grep -qF '<p class="next">' "$(page_path "$p")" \
    && ok "$p.html links onward" \
    || ko "$p.html links onward"
done

# The reference content that moves off the README lives here now, pinned to the page
# that owns each fact rather than to anywhere on the site.
for s in untrackGlobs disabledPaths synthesisFrequency blanksPerExercise 'learner off'; do
  grep -qF "$s" "$SITE_CONFIG" \
    && ok "config.html documents $s" \
    || ko "config.html documents $s"
done

for s in CLAUDE_CONFIG_DIR 'learner-config.sh'; do
  grep -qF "$s" "$SITE_INSTALL" \
    && ok "install.html documents $s" \
    || ko "install.html documents $s"
done

# The check above only pins the config keys' *names*. The seven defaults are a
# hand-copy of LEARNER_DEFAULTS in hooks/learner-config.sh, and now a THIRD copy
# after skills/learner/SKILL.md and, until this task, the README — so
# blanksPerExercise could drift from 2 to 3 in the code and every copy would
# desync while this suite stayed green. Read the real defaults from the source
# of truth via jq instead of hard-coding them here, so a changed default with a
# stale page turns this red. (`level` is the one key with no default and is
# correctly absent from LEARNER_DEFAULTS, so it is skipped automatically.)
defaults_line=$(grep -m1 '^LEARNER_DEFAULTS=' "$PLUG/hooks/learner-config.sh")
defaults_json=${defaults_line#LEARNER_DEFAULTS=\'}
defaults_json=${defaults_json%\'}
for key in $(printf '%s' "$defaults_json" | jq -r 'keys[]'); do
  val=$(printf '%s' "$defaults_json" | jq -c --arg k "$key" '.[$k]')
  # A string default may appear quoted or bare in the page's prose (e.g.
  # "auto" vs normal), so accept either rendering.
  bare=${val#\"}; bare=${bare%\"}
  row=$(grep -F "<tr><td><code>$key</code></td>" "$SITE_CONFIG")
  # Scoped to the Default *column*, not the whole row: the table has four <td>
  # cells per row (Key, Values, Default, Effect) each closed with exactly one
  # "</td>", so splitting on that literal string isolates cell 3. A row-wide
  # search here previously passed with the wrong default documented, because the
  # correct value still existed somewhere else in the same row (the Values
  # cell) — this rescopes the read, not just the pattern.
  cell=$(printf '%s' "$row" | awk -F'</td>' '{print $3}')
  { printf '%s' "$cell" | grep -qF "<td><code>${val}</code>" \
    || printf '%s' "$cell" | grep -qF "<td><code>${bare}</code>"; } \
    && ok "config.html's default for $key matches LEARNER_DEFAULTS ($val)" \
    || ko "config.html's default for $key matches LEARNER_DEFAULTS ($val)"
done

# The site is both the pitch and the full reference (locked decision #3) — that covers
# more than the automatic quiz. Derive the subcommand list from the skill's own dispatch
# table instead of hard-coding it here, so a seventh subcommand added later is caught by
# this check automatically rather than silently shipping undocumented, the way
# `status`/`improve`/`help` and `quiz`'s syntax did the first time around.
DISPATCH=$(awk '/^## Dispatch/{f=1;next} /^## /{f=0} f' "$PLUG/skills/learner/SKILL.md")
SUBCOMMANDS=$(printf '%s\n' "$DISPATCH" | awk -F'|' '/^\|/{print $2}' \
  | grep -oE '`[^`]*`' | tr -d '`' | awk '{print $1}' | grep -vE '^-' | sort -u)
for sub in $SUBCOMMANDS; do
  # Bounded on the right: an unanchored `grep -F "learner $sub"` passes on any prose
  # that happens to contain the substring — "the learner once told me…" satisfies
  # "learner on" with no `on` subcommand in sight. Space or punctuation (a closing
  # `<`, in practice) after the word; end of line covers a subcommand as the last
  # word on its line.
  grep -qE "learner ${sub}([[:space:][:punct:]]|\$)" "$SITE_USAGE" \
    && ok "usage.html documents the 'learner $sub' subcommand" \
    || ko "usage.html documents the 'learner $sub' subcommand"
done

# --- coach docs -------------------------------------------------------------
grep -qi 'coach' "$RM" && ok "README covers coach mode" || ko "README covers coach mode"
grep -q 'learner coach on' "$RM" \
  && ok "README shows how to turn coach on" || ko "README shows how to turn coach on"
grep -q 'coach delegate' "$RM" \
  && ok "README shows delegation" || ko "README shows delegation"
# Anchored to the section heading itself, not a bare 'coach' grep: merge-base
# usage.html already said "Coaches one weak spot… to mastery" under `learner
# improve`, so a loose grep passed before this feature existed and would stay
# green with the entire coach section deleted. id="coach" only exists once the
# section itself does.
grep -qF 'id="coach"' "$SITE_USAGE" && ok "usage.html covers coach mode" \
  || ko "usage.html covers coach mode"
for k in coachPollSeconds coachQuietPolls coachMinLines coachCooldownMinutes coachMaxWaitMinutes coachIdleMinutes; do
  grep -q "$k" "$SITE_CONFIG" && ok "config.html documents $k" \
    || ko "config.html documents $k"
done
# The v1 keys must be gone from the config page, not merely joined by the new
# ones: a dev reading a stale table would tune a key nothing reads.
for k in coachCadence coachWorkMinutes coachChallengeMinutes coachIdleCycles; do
  grep -q "$k" "$SITE_CONFIG" && ko "config.html no longer documents $k" \
    || ok "config.html no longer documents $k"
done
for k in coachCadence coachWorkMinutes coachIdleCycles; do
  grep -q "$k" "$RM" && ko "README no longer documents $k" || ok "README no longer documents $k"
done
# The interactive-session-only limitation must be stated where a dev will hit it,
# not only in the design doc they will never read. Anchored to 'claude -p' rather
# than the bare word "interactive": line 38's "The interactive exercise above…"
# (about the fill question style) has satisfied a looser grep since long before
# this branch, and would stay green even with the whole limitation paragraph
# deleted — this is the third instance of that non-discriminating-grep defect
# in this plan.
grep -qF 'claude -p' "$SITE_USAGE" \
  && ok "usage.html states the interactive-session limitation" \
  || ko "usage.html states the interactive-session limitation"

# --- pilot docs ---------------------------------------------------------------
# The four keys already ship in config.html's table (checked earlier, further up,
# against LEARNER_DEFAULTS itself for their values); this pins the config page to
# actually mentioning all four by name, the same standard the coach key-presence
# loop above holds config.html to for the coach keys.
for k in pilotEnabled pilotCadenceDays pilotJudgeIntervalHours pilotNudge; do
  grep -q "$k" "$SITE_CONFIG" && ok "config.html documents $k" \
    || ko "config.html documents $k"
done

# Anchored to the section heading, not a bare 'pilot' grep: the "learner pilot …"
# forwarding line already in the On-demand list satisfies a loose grep before this
# section exists at all — the same non-discriminating-grep defect the coach docs
# comment above already names once on this branch. id="pilot" only exists once the
# section itself does.
grep -qE '^## Pilot' "$RM" && ok "README covers Pilot" \
  || ko "README covers Pilot"
grep -qF 'id="pilot"' "$SITE_USAGE" && ok "usage.html covers Pilot" \
  || ko "usage.html covers Pilot"

grep -qF 'learner pilot on' "$RM" \
  && ok "README shows how to turn Pilot on" \
  || ko "README shows how to turn Pilot on"

# The one thing a reader must not be able to miss, in both places a dev actually
# reads before flipping the switch (brief for task 11) — not just one of them.
for f in "$RM" "$SITE_USAGE"; do
  n=$(basename "$f")
  grep -qiE 'off by default|opt-in' "$f" \
    && ok "$n states Pilot is opt-in / off by default" \
    || ko "$n states Pilot is opt-in / off by default"
  grep -qF 'disabledPaths' "$f" \
    && ok "$n says disabledPaths is honoured for Pilot" \
    || ko "$n says disabledPaths is honoured for Pilot"
  grep -qF 'pilot forget' "$f" \
    && ok "$n points at pilot forget to purge kept quotes" \
    || ko "$n points at pilot forget to purge kept quotes"
  grep -qiF 'not a measure of intelligence' "$f" \
    && ok "$n disclaims Pilot is not a measure of intelligence" \
    || ko "$n disclaims Pilot is not a measure of intelligence"
  grep -qiF 'cognitive health' "$f" \
    && ok "$n disclaims Pilot is not a measure of cognitive health" \
    || ko "$n disclaims Pilot is not a measure of cognitive health"
done

# The four axes, as the same markup shape SKILL.md's own dispatch table uses
# (`<dt><code>axis</code></dt>`) — fixed by the locked spec (§4.2), so hardcoded
# here the same way the level letters D/J/C/S/E are hardcoded below, rather than
# derived from a file that has no single canonical list to parse.
for axis in direction verification contradiction writing; do
  grep -qF "<dt><code>$axis</code></dt>" "$SITE_USAGE" \
    && ok "usage.html documents the $axis axis" \
    || ko "usage.html documents the $axis axis"
done

grep -qi 'weekly brief' "$SITE_USAGE" \
  && ok "usage.html covers the weekly brief" \
  || ko "usage.html covers the weekly brief"

grep -qi 'manoeuvre' "$SITE_USAGE" \
  && ok "usage.html covers the counter-manoeuvres" \
  || ko "usage.html covers the counter-manoeuvres"

# Pilot's own subcommands. Not derived from skills/pilot/SKILL.md's Dispatch table
# the way the learner subcommand loop above is: that table's first row is the bare
# `pilot` invocation itself, so parsing it the same way would check for the
# nonsensical "pilot pilot" and corrupt the list. Hardcoded instead, against the
# six named subcommands in that table.
for sub in on off brief score why forget; do
  grep -qE "pilot ${sub}([[:space:][:punct:]]|\$)" "$SITE_USAGE" \
    && ok "usage.html documents the 'pilot $sub' subcommand" \
    || ko "usage.html documents the 'pilot $sub' subcommand"
done

# The six profile names, derived from plugins/learner/skills/pilot/references/rubric.md's own
# numbered table rather than hardcoded — a profile renamed or added there turns
# this red automatically instead of leaving the site's list stale, the same
# reasoning as the hook-count and LEARNER_DEFAULTS derivations elsewhere in this
# file.
PROFILES=$(grep -E '^\| [0-9]+ \|' "$PLUG/skills/pilot/references/rubric.md" \
  | grep -oE '`[^`]+`' | tr -d '`')
for p in $PROFILES; do
  grep -qF "$p" "$SITE_USAGE" \
    && ok "usage.html names the $p profile" \
    || ko "usage.html names the $p profile"
done
# --- agent salvo docs --------------------------------------------------------
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

# --- hook count drift guard ---------------------------------------------------
# Prose spots across README and docs/*.html each state how many hook files
# ship, and none of them turned red when coach-gate.sh and coach-watch.sh
# joined the original six — "six" quietly went stale everywhere at once, and
# it happened again with a ninth hook: config.html and usage.html's shared
# footer sentence, and index.html's stat-badge number, were never checked and
# went stale to "eight" while README/index.html's own prose/safety.html/
# install.html were fixed. Ground truth is read from the filesystem and from
# hooks/settings.snippet.json, the same style as the LEARNER_DEFAULTS check
# above (test.sh:1837-1854) and the coach-key prose-count check further up
# (search "docs/config.html: coach* keys prose count"), so a new hook (or a
# wiring change) turns every stale copy red automatically instead of leaving
# a plausible-sounding number wrong forever.
hook_files=$(find "$PLUG/hooks" -maxdepth 1 -name '*.sh' | sort)
hook_n=$(printf '%s\n' "$hook_files" | grep -c .)
case "$hook_n" in
  6) hook_word=six ;;
  7) hook_word=seven ;;
  8) hook_word=eight ;;
  9) hook_word=nine ;;
  10) hook_word=ten ;;
  11) hook_word=eleven ;;
  12) hook_word=twelve ;;
  13) hook_word=thirteen ;;
  14) hook_word=fourteen ;;
  15) hook_word=fifteen ;;
  *) hook_word='__no-word-mapped__' ;;
esac

wired_n=$(jq '[.. | .command? // empty] | length' "$PLUG/hooks/settings.snippet.json")
case "$wired_n" in
  5) wired_word=five ;;
  6) wired_word=six ;;
  7) wired_word=seven ;;
  8) wired_word=eight ;;
  9) wired_word=nine ;;
  10) wired_word=ten ;;
  11) wired_word=eleven ;;
  12) wired_word=twelve ;;
  13) wired_word=thirteen ;;
  *) wired_word='__no-word-mapped__' ;;
esac

# The strongest guard: every shipped hook file must be named in install.html's
# "what gets installed" table, the one place that lists them individually
# rather than as a bare count — this is what would have caught coach-watch.sh
# missing from that table entirely, which no count-matching check below can.
for hf in $hook_files; do
  base=$(basename "$hf")
  grep -qF "hooks/$base" "$SITE_INSTALL" \
    && ok "install.html's table lists $base" \
    || ko "install.html's table lists $base"
done

skill_n=$(find "$PLUG/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
case "$skill_n" in
  6) skill_word=six ;; 7) skill_word=seven ;; 8) skill_word=eight ;;
  9) skill_word=nine ;; 10) skill_word=ten ;; 11) skill_word=eleven ;;
  *) skill_word="$skill_n" ;;
esac
grep -qiF "$hook_word POSIX \`sh\` hooks plus $skill_word skills" "$RM" \
  && ok "README's intro matches the $hook_n hooks and $skill_n skills on disk" \
  || ko "README's intro matches the $hook_n hooks and $skill_n skills on disk"

grep -qiF "covers all $hook_word shipped hook files" "$RM" \
  && ok "README's hooks/*.sh gloss matches the $hook_n files on disk" \
  || ko "README's hooks/*.sh gloss matches the $hook_n files on disk"

# The "One skill and N POSIX <code>sh</code> hooks that quiz you…" sentence is
# shared footer boilerplate copy-pasted onto every docs page, not just
# index.html's — checked on whichever pages actually carry it, so a page that
# drops the footer someday does not silently stop being checked, and a page
# that keeps it can never again go stale unnoticed the way config.html and
# usage.html just did.
for docf in "$ROOT"/docs/*.html; do
  grep -qF 'POSIX <code>sh</code> hooks that quiz you' "$docf" || continue
  grep -qiF "$hook_word POSIX <code>sh</code> hooks that quiz you" "$docf" \
    && ok "$(basename "$docf")'s footer hook count matches the $hook_n files on disk" \
    || ko "$(basename "$docf")'s footer hook count matches the $hook_n files on disk"
done

# index.html's stat-band badge states the same count as a bare digit, in a
# different sentence entirely from the footer above — checked separately
# because a fix to one does not imply the other is fixed.
badge_n=$(grep -oE '<b>[0-9]+</b><span>POSIX <code>sh</code> hook files</span>' "$SITE" \
  | grep -oE '[0-9]+')
[ "$badge_n" = "$hook_n" ] \
  && ok "index.html's stat badge matches the $hook_n files on disk" \
  || ko "index.html's stat badge matches the $hook_n files on disk"

grep -qiF "the $hook_word hook files, the skills" "$SITE_SAFETY" \
  && ok "safety.html's hook count matches the $hook_n files on disk" \
  || ko "safety.html's hook count matches the $hook_n files on disk"

grep -qiF "$hook_word hook files ship and $wired_word are wired" "$SITE_INSTALL" \
  && ok "install.html's ship/wired counts match disk ($hook_n ship, $wired_n wired)" \
  || ko "install.html's ship/wired counts match disk ($hook_n ship, $wired_n wired)"

# The pilot skill ships its own directory, and its runtime data files are as
# privacy-sensitive as anything the install table lists — both belong in the
# "what lands on disk" inventory, not just the learner skill and its own data.
grep -qF 'skills/pilot/' "$SITE_INSTALL" \
  && ok "install.html's table lists skills/pilot/" \
  || ko "install.html's table lists skills/pilot/"
for f in pilot-queue pilot.md pilot-evidence.md pilot-stamps pilot-devlines; do
  grep -qF "learner/$f" "$SITE_INSTALL" \
    && ok "install.html's table lists \$CFG/learner/$f" \
    || ko "install.html's table lists \$CFG/learner/$f"
done

# On a feature this privacy-sensitive (Pilot reads every prompt typed), the page
# covering data and uninstall must say so, name where its data lives, and say
# how to purge it — not leave a reader to infer it from the quiz's own section.
grep -qF 'id="pilot"' "$SITE_SAFETY" \
  && ok "safety.html covers Pilot's data" \
  || ko "safety.html covers Pilot's data"
grep -qF 'pilot-evidence.md' "$SITE_SAFETY" \
  && ok "safety.html names where Pilot's data lives" \
  || ko "safety.html names where Pilot's data lives"
grep -qF 'pilot forget' "$SITE_SAFETY" \
  && ok "safety.html points at pilot forget to purge kept quotes" \
  || ko "safety.html points at pilot forget to purge kept quotes"

grep -qF -- '--project' "$SITE_SAFETY" \
  && ok "safety.html documents the legacy cleanup flag" \
  || ko "safety.html documents the legacy cleanup flag"

grep -qF -- '--purge' "$SITE_SAFETY" \
  && ok "safety.html documents --purge" \
  || ko "safety.html documents --purge"

grep -qF 'learner-uninstall' "$SITE_SAFETY" \
  && ok "safety.html's Uninstall section covers the brew/apt path" \
  || ko "safety.html's Uninstall section covers the brew/apt path"

grep -qF 'apt remove learner' "$SITE_SAFETY" \
  && ok "safety.html's Uninstall section names apt remove specifically" \
  || ko "safety.html's Uninstall section names apt remove specifically"

# Letter levels, as real table cells rather than prose. The markup shape is fixed by
# the plan (`<td><code>D</code></td>`) so this can be a fixed-string match — a bracket
# expression trying to allow several shapes is how the `\`` ERE bug got in last time.
for l in D J C S E; do
  grep -qF "<td><code>$l</code></td>" "$SITE_CONFIG" \
    && ok "config.html documents level $l as a table cell" \
    || ko "config.html documents level $l as a table cell"
done

for p in WSL 'Git Bash'; do
  grep -qF "$p" "$SITE_INSTALL" \
    && ok "install.html covers $p" \
    || ko "install.html covers $p"
done

grep -qiE 'native windows|windows, native' "$SITE_INSTALL" \
  && ok "install.html states native Windows is unsupported" \
  || ko "install.html states native Windows is unsupported"

grep -qiF 'posix' "$SITE_INSTALL" \
  && ok "install.html gives the reason native Windows cannot work" \
  || ko "install.html gives the reason native Windows cannot work"

# The three checks above are satisfied by prose alone (the Requirements list
# also says "POSIX", independent of the table), so deleting the platform table
# itself would not turn them red. Row-shaped patterns pin the table
# specifically — the same reasoning that used to pin the README's markdown
# table, now pinning the site's HTML one instead.
grep -qF '<tr><td>Windows via WSL</td><td>yes</td>' "$SITE_INSTALL" \
  && ok "the platform table has a WSL row" \
  || ko "the platform table has a WSL row"

grep -qF '<tr><td>Windows, native</td><td>no</td>' "$SITE_INSTALL" \
  && ok "the platform table has a native-Windows row" \
  || ko "the platform table has a native-Windows row"

grep -qiE '<tr><td>Windows, native</td><td>no</td><td>[^<]*posix' "$SITE_INSTALL" \
  && ok "the native-Windows row itself states the POSIX reason" \
  || ko "the native-Windows row itself states the POSIX reason"

grep -qF 'do not exist yet' "$SITE_INSTALL" \
  && ko "install.html no longer claims Homebrew/apt packages don't exist" \
  || ok "install.html no longer claims Homebrew/apt packages don't exist"

grep -qF 'brew install learner' "$SITE_INSTALL" \
  && ok "install.html documents the Homebrew install path" \
  || ko "install.html documents the Homebrew install path"

grep -qF 'sudo apt install ./learner_' "$SITE_INSTALL" \
  && ok "install.html documents the apt/.deb install path" \
  || ko "install.html documents the apt/.deb install path"

grep -qF 'INSTALL_ORIGIN' "$SITE_INSTALL" \
  && ok "install.html's file table documents INSTALL_ORIGIN" \
  || ko "install.html's file table documents INSTALL_ORIGIN"

grep -qF 'LEARNER-TODO' "$SITE_SAFETY" \
  && ok "safety.html shows the fill markers" \
  || ko "safety.html shows the fill markers"

# Case-SENSITIVE, and a phrase rather than the bare word: `grep -i HEAD` would match
# the page's own <head> tag and pass without the guardrail being explained at all.
grep -qF 'working tree' "$SITE_SAFETY" && grep -qF 'HEAD' "$SITE_SAFETY" \
  && ok "safety.html explains the guardrail counts leftovers only" \
  || ko "safety.html explains the guardrail counts leftovers only"

# The markdown relaxation is a hole in a safety net, so the page that documents the
# net has to document the hole — and say how narrow it is.
{ grep -qF 'inline code span' "$SITE_SAFETY" && grep -qF 'fenced block' "$SITE_SAFETY"; } \
  && ok "safety.html documents the markdown inline-span exemption and its limit" \
  || ko "safety.html documents the markdown inline-span exemption and its limit"

for p in $PAGES; do
  grep -qE 'recapEvery|trouBlanks|(^|[^A-Za-z])trackGlobs|"language"|intermediaire' "$(page_path "$p")" \
    && ko "$p.html mentions no removed key or old level" \
    || ok "$p.html mentions no removed key or old level"
done

# --- licence ----------------------------------------------------------------
# The licence name lives in four places — LICENSE, the README badge, the README
# footer and the site footer — so it is exactly the shape that drifts. Anchoring
# matters here: the README badge URL contains "GPLv3", so a bare `grep GPL`
# would pass on the badge alone even with the prose still saying MIT. That is
# how the old "README gives the reason native Windows cannot work" check went
# green off a shields.io URL.
LIC="$ROOT/LICENSE"

{ grep -qF 'GNU GENERAL PUBLIC LICENSE' "$LIC" \
  && grep -qF 'Version 3, 29 June 2007' "$LIC"; } \
  && ok "LICENSE carries the GPL-3.0 text" \
  || ko "LICENSE carries the GPL-3.0 text"

grep -qF 'Copyright (C) 2026 Tykok' "$LIC" \
  && ok "LICENSE carries the copyright line the GPL appendix asks for" \
  || ko "LICENSE carries the copyright line the GPL appendix asks for"

grep -qE '^[[]GPL-3[.]0-or-later[]][(][.]/LICENSE[)]' "$RM" \
  && ok "the README footer names the licence, not just the badge" \
  || ko "the README footer names the licence, not just the badge"

grep -qF 'License-GPLv3' "$RM" \
  && ok "the README badge shows GPLv3" \
  || ko "the README badge shows GPLv3"

# Footer text, so it holds on every page or on none.
for p in $PAGES; do
  f=$(page_path "$p")
  grep -qF '>GPL-3.0-or-later</a>' "$f" \
    && ok "$p.html's footer links the licence by name" \
    || ko "$p.html's footer links the licence by name"
  grep -qiF 'copyleft' "$f" \
    && ok "$p.html states the licence is copyleft" \
    || ko "$p.html states the licence is copyleft"
done

# Copyleft is the point of the change, so say so where a reader will look.
grep -qiF 'copyleft' "$RM" \
  && ok "README.md states the licence is copyleft" \
  || ko "README.md states the licence is copyleft"

# `[^A-Z]` guards the substring: LIMITED, SUBMIT and TRANSMIT all contain those
# three letters.
#
# The scanned set is what ships or is read by a user: the README, the site, and
# every script that ships or a user runs. test.sh is deliberately NOT
# in it — this file names the old licence in the pattern and in its own pass/fail
# messages, so scanning itself could never pass, and it is neither shipped nor
# documentation. design/ is excluded too: those plans record what was decided at
# the time, and rewriting them would falsify the record.
#
# HOOK_SH is derived from hooks/*.sh rather than named one by one: a
# hand-maintained list here covered only the original six learner-*.sh hooks
# and silently stopped scanning coach-gate.sh, coach-watch.sh and the three
# pilot-*.sh hooks once those shipped — the licence and SPDX guards below
# never actually looked at the files this branch added. A new hook needs no
# edit to either list that follows.
HOOK_SH=$(cd "$PLUG/hooks" && ls -- *.sh | sort)
LIC_SCAN="README.md docs/"
for hf in $HOOK_SH; do LIC_SCAN="$LIC_SCAN plugins/learner/hooks/$hf"; done
LIC_SCAN="$LIC_SCAN install.sh uninstall.sh bootstrap.sh
Formula/learner.rb scripts/bump-formula.sh packaging/deb/build.sh
packaging/apt-repo/assemble-site.sh"
# shellcheck disable=SC2086  # word splitting is how the path list is passed
if git -C "$ROOT" grep -qE '(^|[^A-Z])MIT([^A-Z]|$)' -- $LIC_SCAN; then
  ko "no shipped or user-facing file still claims MIT"
else
  ok "no shipped or user-facing file still claims MIT"
fi

# install.sh copies the hooks into the user's config directory, so they leave
# this repository and land somewhere with no LICENSE beside them. A one-line
# SPDX tag is what tells a reader over there what they are holding.
SPDX_SCAN=""
for hf in $HOOK_SH; do SPDX_SCAN="$SPDX_SCAN plugins/learner/hooks/$hf"; done
SPDX_SCAN="$SPDX_SCAN install.sh uninstall.sh bootstrap.sh test.sh Formula/learner.rb
scripts/bump-formula.sh packaging/deb/build.sh packaging/apt-repo/assemble-site.sh"
for f in $SPDX_SCAN; do
  grep -qF 'SPDX-License-Identifier: GPL-3.0-or-later' "$ROOT/$f" \
    && ok "$f carries an SPDX licence tag" \
    || ko "$f carries an SPDX licence tag"
done

# --- Homebrew formula --------------------------------------------------------
FORMULA="$ROOT/Formula/learner.rb"

[ -f "$FORMULA" ] && ok "Formula/learner.rb exists" || ko "Formula/learner.rb exists"

grep -qF 'depends_on "jq"' "$FORMULA" \
  && ok "the formula depends on jq" \
  || ko "the formula depends on jq"

grep -qF '"#{pkgshare}/install.sh" --origin brew' "$FORMULA" \
  && ok "the formula's learner-install wrapper passes --origin brew" \
  || ko "the formula's learner-install wrapper passes --origin brew"

grep -qE 'sha256 "[0-9a-f]{64}"' "$FORMULA" \
  && ok "the formula's sha256 is a real 64-hex-char digest, not a placeholder" \
  || ko "the formula's sha256 is a real 64-hex-char digest, not a placeholder"

[ -x "$ROOT/scripts/bump-formula.sh" ] \
  && ok "scripts/bump-formula.sh is executable" \
  || ko "scripts/bump-formula.sh is executable"

# --- Debian package -----------------------------------------------------------
DEBBUILD="$ROOT/packaging/deb/build.sh"

[ -f "$DEBBUILD" ] && ok "packaging/deb/build.sh exists" || ko "packaging/deb/build.sh exists"

if command -v dpkg-deb >/dev/null 2>&1; then
  DEBWORK="$(mktemp -d)"
  ( cd "$DEBWORK" && bash "$DEBBUILD" ) >/dev/null 2>&1
  DEBFILE="$DEBWORK/learner_$(cat "$ROOT/VERSION")_all.deb"
  [ -f "$DEBFILE" ] \
    && ok "build.sh produces learner_<VERSION>_all.deb" \
    || ko "build.sh produces learner_<VERSION>_all.deb"
  dpkg-deb -I "$DEBFILE" 2>/dev/null | grep -qF 'Depends: bash, jq' \
    && ok "the .deb declares bash and jq as Depends" \
    || ko "the .deb declares bash and jq as Depends"

  dpkg-deb -x "$DEBFILE" "$DEBWORK/extracted" 2>/dev/null

  for p in usr/share/learner/hooks usr/share/learner/skills \
           usr/share/learner/install.sh usr/share/learner/uninstall.sh \
           usr/share/learner/VERSION usr/share/learner/LICENSE \
           usr/bin/learner-install usr/bin/learner-uninstall; do
    [ -e "$DEBWORK/extracted/$p" ] \
      && ok "the .deb's payload contains $p" \
      || ko "the .deb's payload contains $p"
  done

  grep -qF -- '--origin apt' "$DEBWORK/extracted/usr/bin/learner-install" \
    && ok "learner-install passes --origin apt" \
    || ko "learner-install passes --origin apt"

  grep -qF 'exec /usr/share/learner/uninstall.sh' "$DEBWORK/extracted/usr/bin/learner-uninstall" \
    && ok "learner-uninstall execs uninstall.sh" \
    || ko "learner-uninstall execs uninstall.sh"

  rm -rf "$DEBWORK"
else
  skip "packaging/deb/build.sh smoke test (dpkg-deb not on PATH)"
fi

# --- apt repo assembler --------------------------------------------------------
ASSEMBLE="$ROOT/packaging/apt-repo/assemble-site.sh"

[ -f "$ASSEMBLE" ] && ok "packaging/apt-repo/assemble-site.sh exists" || ko "packaging/apt-repo/assemble-site.sh exists"

grep -qE "gh release download --pattern 'learner_\\*_all\\.deb' --dir \"\\\$TMPDL\"[[:space:]]*2>/dev/null" "$ASSEMBLE" \
  && ok "assemble-site.sh's gh release download has no trailing literal tag argument" \
  || ko "assemble-site.sh's gh release download has no trailing literal tag argument"

# A throwaway signing key, generated fresh for this test run only — never the
# real APT_SIGNING_KEY secret, which this file never has access to.
TESTGNUPGHOME="$(mktemp -d)"
chmod 700 "$TESTGNUPGHOME"
GNUPGHOME="$TESTGNUPGHOME" gpg --batch --gen-key <<'EOF' >/dev/null 2>&1
%no-protection
Key-Type: RSA
Key-Length: 2048
Key-Usage: sign
Name-Real: test key
Name-Email: test@example.invalid
Expire-Date: 0
EOF
TESTKEYID=$(GNUPGHOME="$TESTGNUPGHOME" gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5; exit}')
TESTSIGNINGKEY=$(GNUPGHOME="$TESTGNUPGHOME" gpg --armor --export-secret-keys "$TESTKEYID")

if command -v dpkg-scanpackages >/dev/null 2>&1 && command -v apt-ftparchive >/dev/null 2>&1; then
  ASMOUT="$(mktemp -d)"

  # No APT_DEB_SOURCE, and APT_SKIP_RELEASE_FETCH=1 tells the script to treat
  # this as "no release found" without ever invoking `gh` — keeps this test
  # fully off the network (the same offline-fixture pattern bootstrap.sh's
  # and the update-check hook's tests already use), rather than relying on a
  # `gh` call against a nonexistent repo that merely fails fast and harmlessly.
  # Must still assemble the hand-written site and must not fail the whole
  # build over a missing package.
  ( APT_SIGNING_KEY="$TESTSIGNINGKEY" APT_SKIP_RELEASE_FETCH=1 \
    bash "$ASSEMBLE" "$ASMOUT/no-release" )
  rc=$?
  { [ "$rc" = 0 ] && [ -f "$ASMOUT/no-release/index.html" ] && [ ! -d "$ASMOUT/no-release/apt" ]; } \
    && ok "assemble-site.sh ships the site with no apt/ tree when no release is available" \
    || ko "assemble-site.sh ships the site with no apt/ tree when no release is available (rc=$rc)"

  # A fixture .deb via APT_DEB_SOURCE, mirroring how test.sh keeps every other
  # network-touching script (bootstrap.sh, the update-check hook) offline.
  FIXDEB="$(mktemp -d)/learner_9.9.9_all.deb"
  FIXROOT="$(mktemp -d)"
  mkdir -p "$FIXROOT/DEBIAN"
  printf 'Package: learner\nVersion: 9.9.9\nArchitecture: all\nMaintainer: test\nDescription: test fixture\n' \
    > "$FIXROOT/DEBIAN/control"
  dpkg-deb --build --root-owner-group "$FIXROOT" "$FIXDEB" >/dev/null 2>&1

  APT_SIGNING_KEY="$TESTSIGNINGKEY" APT_DEB_SOURCE="$FIXDEB" bash "$ASSEMBLE" "$ASMOUT/with-release"
  rc=$?
  { [ "$rc" = 0 ] \
    && [ -f "$ASMOUT/with-release/index.html" ] \
    && [ -f "$ASMOUT/with-release/apt/pool/main/l/learner/learner_9.9.9_all.deb" ] \
    && [ -f "$ASMOUT/with-release/apt/dists/stable/main/binary-all/Packages" ] \
    && [ -f "$ASMOUT/with-release/apt/dists/stable/InRelease" ] \
    && [ -f "$ASMOUT/with-release/apt/learner.gpg" ]; } \
    && ok "assemble-site.sh builds the full apt tree from a fixture .deb" \
    || ko "assemble-site.sh builds the full apt tree from a fixture .deb (rc=$rc)"

  grep -qF 'learner_9.9.9_all.deb' "$ASMOUT/with-release/apt/dists/stable/main/binary-all/Packages" \
    && ok "the generated Packages file names the fixture package" \
    || ko "the generated Packages file names the fixture package"

  GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; chmod 700 "$GNUPGHOME"
  gpg --batch --import <(printf '%s' "$TESTSIGNINGKEY") >/dev/null 2>&1
  gpg --verify "$ASMOUT/with-release/apt/dists/stable/InRelease" >/dev/null 2>&1 \
    && ok "InRelease's signature verifies against the exported public key" \
    || ko "InRelease's signature verifies against the exported public key"
  unset GNUPGHOME

  # The private key text must never appear in what got written to disk.
  if grep -rqF "$TESTSIGNINGKEY" "$ASMOUT" 2>/dev/null; then
    ko "the private signing key never leaks into the assembled output"
  else
    ok "the private signing key never leaks into the assembled output"
  fi
else
  skip "packaging/apt-repo/assemble-site.sh tests (dpkg-scanpackages/apt-ftparchive not on PATH)"
fi
rm -rf "$TESTGNUPGHOME"

# --- Claude Code plugin ------------------------------------------------------
PLUGIN_JSON="$PLUG/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$ROOT/.claude-plugin/marketplace.json"
PLUGIN_HOOKS="$PLUG/hooks/hooks.json"

[ -f "$PLUGIN_JSON" ] && ok ".claude-plugin/plugin.json exists" || ko ".claude-plugin/plugin.json exists"
[ -f "$MARKETPLACE_JSON" ] && ok ".claude-plugin/marketplace.json exists" || ko ".claude-plugin/marketplace.json exists"
[ -f "$PLUGIN_HOOKS" ] && ok "hooks/hooks.json exists" || ko "hooks/hooks.json exists"

jq -e . "$PLUGIN_JSON" >/dev/null 2>&1 \
  && ok "plugin.json is valid JSON" \
  || ko "plugin.json is valid JSON"

jq -e . "$MARKETPLACE_JSON" >/dev/null 2>&1 \
  && ok "marketplace.json is valid JSON" \
  || ko "marketplace.json is valid JSON"

jq -e . "$PLUGIN_HOOKS" >/dev/null 2>&1 \
  && ok "hooks/hooks.json is valid JSON" \
  || ko "hooks/hooks.json is valid JSON"

# Discovery metadata: keywords are what the community catalogue searches, and the
# $schema lines are what an editor validates against. Both are cheap to lose in a
# hand-edit and silent when lost.
jq -e 'has("$schema") and has("displayName") and (.keywords | type == "array" and length > 0)' \
  "$PLUGIN_JSON" >/dev/null 2>&1 \
  && ok "plugin.json carries \$schema, displayName and keywords" \
  || ko "plugin.json carries \$schema, displayName and keywords"

[ "$(jq -r '."$schema"' "$MARKETPLACE_JSON")" = "https://code.claude.com/schemas/marketplace.json" ] \
  && ok "marketplace.json points at the documented schema URL" \
  || ko "marketplace.json points at the documented schema URL"

# The payload is a plugin root, and a plugin root must hold nothing but its own
# components — no installer, no packaging, no site. Keeping the marketplace at the
# repository root and the plugin one level down is what buys that.
{ [ ! -e "$PLUG/install.sh" ] && [ ! -e "$PLUG/bootstrap.sh" ] \
  && [ ! -d "$PLUG/docs" ] && [ ! -d "$PLUG/packaging" ] && [ ! -d "$PLUG/bin" ]; } \
  && ok "the plugin root ships components only" \
  || ko "the plugin root ships components only"

[ "$(jq -r '.name' "$PLUGIN_JSON")" = "learner" ] \
  && ok "plugin.json names the plugin learner" \
  || ko "plugin.json names the plugin learner"

# --- the root fallback plugin -------------------------------------------------
# The community marketplace pins an approved plugin to a commit SHA and bumps that
# pin automatically as commits land. This repository was submitted while its plugin
# root WAS the repository root, so the catalogue entry may well name the repository
# and nothing else — and moving the payload to plugins/learner/ would then bump the
# pin onto a commit with no manifest at the root at all, breaking the plugin for
# everyone who installed it from @claude-community.
#
# So the root stays a valid plugin too: a manifest that delegates its skills to the
# payload, and a wiring file whose commands carry the extra path segment, since
# ${CLAUDE_PLUGIN_ROOT} means the repository root for this one. Both are derived
# from the payload's own files below rather than maintained beside them.
ROOT_PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
ROOT_HOOKS="$ROOT/hooks/hooks.json"

[ -f "$ROOT_PLUGIN_JSON" ] && ok "the root fallback manifest exists" \
  || ko "the root fallback manifest exists"
[ -f "$ROOT_HOOKS" ] && ok "the root fallback wiring exists" \
  || ko "the root fallback wiring exists"

# Identical but for the path segment: derive one from the other and compare, so the
# two can never drift the way two hand-maintained copies would.
if jq -e . "$ROOT_HOOKS" >/dev/null 2>&1 && jq -e . "$PLUGIN_HOOKS" >/dev/null 2>&1; then
  derived=$(jq -S '(.. | objects | select(has("command")) | .command)
              |= sub("\\$\\{CLAUDE_PLUGIN_ROOT\\}/hooks/"; "${CLAUDE_PLUGIN_ROOT}/plugins/learner/hooks/")' \
            "$PLUGIN_HOOKS")
  [ "$derived" = "$(jq -S . "$ROOT_HOOKS")" ] \
    && ok "the root wiring is the payload wiring, re-rooted" \
    || ko "the root wiring is the payload wiring, re-rooted"
else
  ko "the root wiring is the payload wiring, re-rooted"
fi

# Every root command must carry the extra segment, or it resolves to a path that
# does not exist and the hook silently never runs.
n_root=$(jq '[.. | .command? // empty] | length' "$ROOT_HOOKS" 2>/dev/null)
n_seg=$(jq '[.. | .command? // empty] | map(select(test("/plugins/learner/hooks/"))) | length' "$ROOT_HOOKS" 2>/dev/null)
{ [ -n "$n_root" ] && [ "$n_root" = "$n_seg" ] && [ "$n_root" -gt 0 ]; } \
  && ok "every root fallback command points into plugins/learner/hooks/" \
  || ko "every root fallback command points into plugins/learner/hooks/ ($n_seg/$n_root)"

# Wholesale, not field by field. Checking only name and version left description,
# keywords, displayName, author, homepage, repository, license and $schema unguarded —
# and the root manifest is the one a root-pinned catalogue entry renders and searches,
# so a stale description there is a stale listing in front of real users. `skills` is
# the single field that is meant to differ: the payload has none, the root delegates.
{ [ "$(jq -S 'del(.skills)' "$ROOT_PLUGIN_JSON")" = "$(jq -S 'del(.skills)' "$PLUGIN_JSON")" ]; } \
  && ok "the root fallback manifest is the payload's, but for the skills delegation" \
  || ko "the root fallback manifest is the payload's, but for the skills delegation"

[ "$(jq -r '.skills' "$ROOT_PLUGIN_JSON")" = "./plugins/learner/skills" ] \
  && ok "the root fallback manifest delegates its skills to the payload" \
  || ko "the root fallback manifest delegates its skills to the payload"

# Two skills ship under this plugin now; the description should not describe
# only the older one.
jq -r '.description' "$PLUGIN_JSON" | grep -qi 'pilot\|delegat' \
  && ok "plugin.json's description mentions the pilot skill, not just the quiz loop" \
  || ko "plugin.json's description mentions the pilot skill, not just the quiz loop"

[ "$(jq -r '.plugins[0].name' "$MARKETPLACE_JSON")" = "learner" ] \
  && [ "$(jq -r '.plugins[0].source' "$MARKETPLACE_JSON")" = "./plugins/learner" ] \
  && ok "marketplace.json lists learner with source ./plugins/learner" \
  || ko "marketplace.json lists learner with source ./plugins/learner"

for h in SessionStart PostToolUse Stop SessionEnd; do
  jq -e --arg h "$h" '.hooks[$h]' "$PLUGIN_HOOKS" >/dev/null 2>&1 \
    && ok "hooks/hooks.json wires $h" \
    || ko "hooks/hooks.json wires $h"
done

for script in learner-onboard.sh learner-record-edit.sh learner-quiz.sh learner-cleanup.sh; do
  grep -qF "$script" "$PLUGIN_HOOKS" \
    && ok "hooks/hooks.json references $script" \
    || ko "hooks/hooks.json references $script"
done

grep -qF 'CLAUDE_PLUGIN_ROOT' "$PLUGIN_HOOKS" \
  && ok "hooks/hooks.json commands use \${CLAUDE_PLUGIN_ROOT}" \
  || ko "hooks/hooks.json commands use \${CLAUDE_PLUGIN_ROOT}"

# Derived rather than counted by hand. A literal number here conflicts on every
# branch that adds a hook — it did so three times over — and the number was never
# the thing worth pinning. What matters is that every wired command goes through
# the plugin root, and that every script it names is one this payload actually
# ships: a typo in a path is otherwise a hook that silently never runs.
n_cmds=$(jq '[.hooks[][].hooks[]] | length' "$PLUGIN_HOOKS")
n_root=$(jq '[.hooks[][].hooks[].command | select(contains("CLAUDE_PLUGIN_ROOT"))] | length' "$PLUGIN_HOOKS")
unknown_hook=""
for sc in $(jq -r '.hooks[][].hooks[].command' "$PLUGIN_HOOKS" \
            | sed -n 's#.*/hooks/\([A-Za-z0-9_.-]*\.sh\).*#\1#p' | sort -u); do
  [ -f "$PLUG/hooks/$sc" ] || unknown_hook="$unknown_hook $sc"
done
{ [ "$n_cmds" -gt 0 ] && [ "$n_cmds" = "$n_root" ] && [ -z "$unknown_hook" ]; } \
  && ok "hooks.json wires $n_cmds commands, every one via \${CLAUDE_PLUGIN_ROOT} and shipped" \
  || ko "hooks.json wiring is off (commands=$n_cmds via-root=$n_root unknown:$unknown_hook)"

grep -qF 'learner-update-check.sh' "$PLUGIN_HOOKS" \
  && ko "hooks/hooks.json does not wire learner-update-check.sh" \
  || ok "hooks/hooks.json does not wire learner-update-check.sh"

[ "$(jq -r '.version' "$PLUGIN_JSON")" = "$(cat "$ROOT/VERSION")" ] \
  && ok "plugin.json's version matches the VERSION file" \
  || ko "plugin.json's version matches the VERSION file"

# A marketplace pins this plugin to plugins/learner as a git-subdir, so an install
# receives that directory and nothing above it: the licence text and the README have
# to live inside it, not only at the repository root.
[ -f "$PLUG/LICENSE" ] \
  && ok "the plugin directory ships its own LICENSE" \
  || ko "the plugin directory ships its own LICENSE"

cmp -s "$PLUG/LICENSE" "$ROOT/LICENSE" \
  && ok "the plugin's LICENSE is identical to the repository's" \
  || ko "the plugin's LICENSE is identical to the repository's"

# plugin.json declares GPL-3.0-or-later; the shipped text has to be that licence.
{ [ "$(jq -r '.license' "$PLUGIN_JSON")" = "GPL-3.0-or-later" ] \
  && grep -q 'GNU GENERAL PUBLIC LICENSE' "$PLUG/LICENSE" \
  && grep -q 'Version 3' "$PLUG/LICENSE"; } \
  && ok "the plugin's LICENSE carries the licence plugin.json declares" \
  || ko "the plugin's LICENSE carries the licence plugin.json declares"

[ -f "$PLUG/README.md" ] \
  && ok "the plugin directory ships its own README" \
  || ko "the plugin directory ships its own README"

grep -qF 'claude plugin install learner@learning-with-claude' "$PLUG/README.md" \
  && ok "the plugin README gives the plugin install command" \
  || ko "the plugin README gives the plugin install command"

# The README must not promise skills the plugin does not ship.
README_SKILLS=0
for d in "$PLUG"/skills/*/; do
  name="$(basename "$d")"
  grep -qF "\`$name\`" "$PLUG/README.md" && README_SKILLS=$((README_SKILLS + 1))
done
[ "$README_SKILLS" = "$(find "$PLUG/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" ] \
  && ok "the plugin README names every skill the plugin ships" \
  || ko "the plugin README names every skill the plugin ships"

# --- coach gate -------------------------------------------------------------
GATE="$PLUG/hooks/coach-gate.sh"
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

# Regression (fix round 1, Finding 2): `read` delivers a final line with no
# trailing newline but returns non-zero, so a bare `while read` loop drops it
# silently. The scope file below ends without a trailing newline on its last
# glob, which must still match.
printf 'src/**/repository/**\nsrc/**/mapper/**' > "$(scope "$SID_G")"
[ -z "$(gate "$SID_G" "$WORK/proj/src/main/mapper/UserMapper2.kt")" ] \
  && ok "delegated glob with no trailing newline on the last line still matches" \
  || ko "delegated glob with no trailing newline on the last line still matches"
rm -f "$(scope "$SID_G")"

# Outside the repo: Claude's own config and the scratchpad are never coach material.
[ -z "$(gate "$SID_G" "$WORK/cfg/learner.json")" ] \
  && ok "path outside the repo is allowed" || ko "path outside the repo is allowed"

# Regression (fix round 1, Finding 1): a PreToolUse hook fires before the write,
# so the immediate parent of a brand-new file in a not-yet-created subdirectory
# legitimately does not exist yet. Reached through a symlinked repo path, the
# slow outside-the-repo resolution must walk up to the deepest EXISTING
# ancestor rather than giving up at the first missing directory and silently
# allowing an in-repo, undelegated write.
ln -sf "$WORK/proj" "$WORK/proj-link"
out=$(gate "$SID_G" "$WORK/proj-link/src/coachbrandnew/NewFile.kt")
denied "$out" && ok "symlinked path into a not-yet-created directory is still denied" \
  || ko "symlinked path into a not-yet-created directory is still denied"
# Companion: a genuinely outside path through a not-yet-created directory chain
# must still be allowed, so the walk-up fix cannot pass by denying everything.
[ -z "$(gate "$SID_G" "$WORK/cfg/brandnew/sub/F.kt")" ] \
  && ok "genuinely outside path into a not-yet-created directory is still allowed" \
  || ko "genuinely outside path into a not-yet-created directory is still allowed"

# Regression (task-3b / fix round 2): REL was derived from the RAW file_path,
# not the resolved one, so on a repo reached through a symlink no delegated
# glob could ever match — ROOT is physical but the stripped prefix wasn't, so
# REL stayed an absolute path that no relative glob could match. Reproduces
# through the same $WORK/proj-link symlink used above, this time with a glob
# actually delegated.
printf 'src/**/repository/**\n' > "$(scope "$SID_G")"
[ -z "$(gate "$SID_G" "$WORK/proj-link/src/main/repository/UserRepo.kt")" ] \
  && ok "delegated glob matches through a symlinked repo path" \
  || ko "delegated glob matches through a symlinked repo path"
out=$(gate "$SID_G" "$WORK/proj-link/src/main/service/Service.kt")
denied "$out" && ok "undelegated sibling through a symlinked repo path is still denied" \
  || ko "undelegated sibling through a symlinked repo path is still denied"

# The sharpest case: PreToolUse fires before the write, so the target
# directory reached through the symlink may not exist on disk yet either.
printf 'src/newmodule/**\n' > "$(scope "$SID_G")"
[ -z "$(gate "$SID_G" "$WORK/proj-link/src/newmodule/NewRepo.kt")" ] \
  && ok "delegated glob matches a not-yet-created directory through a symlink" \
  || ko "delegated glob matches a not-yet-created directory through a symlink"
rm -f "$(scope "$SID_G")"

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

# --- coach watcher: candidates and metric -----------------------------------
WATCH="$PLUG/hooks/coach-watch.sh"
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

# The exclusion is scoped to one review window, not to the whole session.
# .session is append-only and never cleared (the quiz's synthesis question reads
# all of it), so v1's "is this path anywhere in .session" test excluded a file
# for good: ask Claude one question about the file you are working on and it
# left your candidate set permanently, which — if it emptied the set — ran the
# idle counter out and killed the watcher.
SID_WIN=watchwin
rm -rf "$(basedir "$SID_WIN")"; rm -f "$(sess "$SID_WIN")"
git -C "$CREPO" add -A >/dev/null 2>&1; git -C "$CREPO" commit -q -m winbase 2>/dev/null

lines 12 > "$CREPO/src/Shared.kt"
echo "$CREPO/src/Shared.kt" > "$(sess "$SID_WIN")"      # Claude wrote it
out=$(material "$SID_WIN")
[ -z "$(printf '%s' "$out" | awk -F'\t' '$2=="src/Shared.kt"{print $1}')" ] \
  && ok "a file Claude wrote is excluded inside the current window" \
  || ko "a file Claude wrote is excluded inside the current window"

# A review fires: the baseline advances and records how far .session had got.
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_WIN" --once --advance >/dev/null
lines 9 | sed 's/^/dev /' >> "$CREPO/src/Shared.kt"     # now the DEV works on it
out=$(material "$SID_WIN")
[ "$(printf '%s' "$out" | awk -F'\t' '$2=="src/Shared.kt"{print $1}')" = "9" ] \
  && ok "the dev's later work on that same file is coach material again" \
  || ko "the dev's later work on that same file is coach material again (got: $out)"

# Claude writing it again re-excludes it, for that window only.
echo "$CREPO/src/Shared.kt" >> "$(sess "$SID_WIN")"
lines 4 | sed 's/^/claude /' >> "$CREPO/src/Shared.kt"
out=$(material "$SID_WIN")
[ -z "$(printf '%s' "$out" | awk -F'\t' '$2=="src/Shared.kt"{print $1}')" ] \
  && ok "a fresh write by Claude re-excludes the file for the new window" \
  || ko "a fresh write by Claude re-excludes the file for the new window"

# No .session at all: the mark is 0 and nothing is excluded.
rm -f "$(sess "$SID_WIN")"
out=$(material "$SID_WIN")
[ -n "$(printf '%s' "$out" | awk -F'\t' '$2=="src/Shared.kt"{print $1}')" ] \
  && ok "no .session means nothing is excluded" || ko "no .session means nothing is excluded"

# A stale mark can outlive the file it indexes: learner-cleanup.sh always
# removes .session and .coach-base together, but a tmp reaper on a long-lived
# machine can delete .session on its own timer while .coach-base (and its
# mark) survives. If .session then comes back shorter than the stored mark,
# `tail -n +N` would start past its own EOF and match nothing for every path —
# silently turning the exclusion off entirely. The mark must be clamped to 0
# rather than trusted past .session's own length.
echo "$CREPO/src/Shared.kt" > "$(sess "$SID_WIN")"      # .session: 1 line
printf '4' > "$(basedir "$SID_WIN")/.sessionmark"       # a mark beyond that
out=$(material "$SID_WIN")
[ -z "$(printf '%s' "$out" | awk -F'\t' '$2=="src/Shared.kt"{print $1}')" ] \
  && ok "a mark beyond .session's current length is clamped, not trusted" \
  || ko "a mark beyond .session's current length is clamped, not trusted"

rm -f "$(sess "$SID_WIN")" "$CREPO/src/Shared.kt"

# Regression (Finding 2): learner-record-edit.sh wrote the RAW file_path into
# .session, but coach-watch.sh compares candidates (built from the always-
# physical ROOT) against .session with a plain string match. On a repo
# reached through a symlink the two representations never agreed, so a file
# Claude wrote sailed past the "already in .session" check and was reviewed
# as if the dev had written it — the one direction the coach spec rules out.
ln -sfn "$CREPO" "$WORK/crepo-link"
CLINK="$WORK/crepo-link"
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_W" --once --advance >/dev/null
lines 15 > "$CREPO/src/ClaudeWrote.kt"
printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$SID_W" "$CLINK/src/ClaudeWrote.kt" \
  | CLAUDE_PROJECT_DIR="$CLINK" sh "$REC"
lines 10 > "$CREPO/src/DevWrote.kt"
out=$(material "$SID_W")
[ -z "$(printf '%s' "$out" | awk -F'\t' '$2=="src/ClaudeWrote.kt"{print $1}')" ] \
  && ok "a path Claude wrote through a symlinked repo is still excluded from coach material" \
  || ko "a path Claude wrote through a symlinked repo is still excluded from coach material"
[ "$(printf '%s' "$out" | awk -F'\t' '$2=="src/DevWrote.kt"{print $1}')" = "10" ] \
  && ok "control: a path only the dev touched still appears as coach material" \
  || ko "control: a path only the dev touched still appears as coach material"
rm -f "$(sess "$SID_W")" "$CREPO/src/ClaudeWrote.kt" "$CREPO/src/DevWrote.kt"

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

# Regression: the empty-tree fallback in coach_advance (for a baseline taken
# before any commit exists) must resolve under either of git's object
# formats. A hardcoded SHA-1 empty-tree id silently fails to resolve in a
# SHA-256 repo, reproducing the exact "work committed since the baseline
# still counts" bug for that format. `--object-format=sha256` needs a git
# recent enough to support it, so probe first and skip cleanly rather than
# fail the suite on an older git.
if git init --object-format=sha256 -q "$WORK/sha256-probe" >/dev/null 2>&1; then
  rm -rf "$WORK/sha256-probe"
  SREPO="$WORK/srepo"
  mkdir -p "$SREPO/.claude"
  git -C "$SREPO" init --object-format=sha256 -q
  git -C "$SREPO" config user.email t@t.t
  git -C "$SREPO" config user.name t
  SREPO="$(cd "$SREPO" && pwd -P)"
  SID_S=watch-sha256

  # Baseline taken while the repo has zero commits.
  lines 5 > "$SREPO/Sha.kt"
  CLAUDE_PROJECT_DIR="$SREPO" sh "$WATCH" "$SID_S" --once --advance >/dev/null
  # The dev appends 6 lines and commits them.
  lines 6 | sed 's/^/committed /' >> "$SREPO/Sha.kt"
  git -C "$SREPO" add -A >/dev/null 2>&1
  git -C "$SREPO" commit -q -m "dev commits mid-block in a sha256 repo"
  out=$(CLAUDE_PROJECT_DIR="$SREPO" sh "$WATCH" "$SID_S" --once --print-material)
  [ "$(printf '%s' "$out" | awk -F'\t' '$2=="Sha.kt"{print $1}')" = "6" ] \
    && ok "work committed since the baseline still counts in a sha256 repo" \
    || ko "work committed since the baseline still counts in a sha256 repo"
  rm -rf "$(basedir "$SID_S")"
else
  skip "sha256-repo regression test (git lacks --object-format=sha256 support)"
fi

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
cycle_out "$SID_C" 3 >/dev/null                 # first sighting: only observes, per the pause cadence
out=$(cycle_out "$SID_C" 3)                     # unchanged since: quiet -> fires

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

# Baseline advance only copies content per-SID; it never touches git, so
# A.kt/B.kt are still untracked. Commit them so a brand-new SID below starts
# from a clean tree instead of seeing this test's own leftovers as material.
git -C "$CREPO" add -A >/dev/null 2>&1; git -C "$CREPO" commit -q -m clean2 2>/dev/null

# --- coach cadence: the pause in the typing ---------------------------------
# cycle_out already exists above: it runs one --once cycle and prints its stdout.
# The clock is controlled by writing epochs into the state files rather than by
# sleeping, so the whole cadence is testable in milliseconds.
qf()    { echo "$TMPDIR/claude-learner-$1.coach-quiet"; }
fpf()   { echo "$TMPDIR/claude-learner-$1.coach-fp"; }
idlef() { echo "$TMPDIR/claude-learner-$1.coach-idle"; }
pendf() { echo "$TMPDIR/claude-learner-$1.coach-pending"; }
lastf() { echo "$TMPDIR/claude-learner-$1.coach-last"; }
cstate() { rm -f "$(qf "$1")" "$(fpf "$1")" "$(idlef "$1")" "$(pendf "$1")" "$(lastf "$1")"; }

# coachQuietPolls 2 so the first poll observes and the second fires.
echo '{"level":"C","coach":true,"coachQuietPolls":2,"coachMinLines":5,"coachCooldownMinutes":0,"coachMaxWaitMinutes":0,"coachPollSeconds":30,"coachIdleMinutes":45}' > "$GCFG"
rm -f "$PCFG"

SID_P=pause1
rm -rf "$(basedir "$SID_P")"; cstate "$SID_P"
git -C "$CREPO" add -A >/dev/null 2>&1; git -C "$CREPO" commit -q -m pausebase 2>/dev/null
lines 12 > "$CREPO/src/Pause.kt"
out=$(cycle_out "$SID_P" 1)                     # first sighting: fingerprint is new
[ -z "$out" ] && ok "a first poll on new material only observes" \
  || ko "a first poll on new material only observes"

lines 6 | sed 's/^/more /' >> "$CREPO/src/Pause.kt"
out=$(cycle_out "$SID_P" 1)                     # still typing: fingerprint changed
[ -z "$out" ] && ok "a changed fingerprint resets the quiet counter" \
  || ko "a changed fingerprint resets the quiet counter"

out=$(cycle_out "$SID_P" 1)                     # quiet 1
[ -z "$out" ] && ok "one quiet poll is not enough at coachQuietPolls 2" \
  || ko "one quiet poll is not enough at coachQuietPolls 2"

out=$(cycle_out "$SID_P" 1)                     # quiet 2 -> fire
printf '%s' "$out" | grep -q '🧑‍🏫 Coach (level: C' \
  && ok "the review fires on the pause" || ko "the review fires on the pause"
printf '%s' "$out" | grep -q 'lines: 18' \
  && ok "the trigger reports the delta since the last review" \
  || ko "the trigger reports the delta since the last review (got: $out)"

# The emission advanced the baseline, so the next poll has nothing.
out=$(cycle_out "$SID_P" 2)
[ -z "$out" ] && ok "an emission advances the baseline" || ko "an emission advances the baseline"

# Material below coachMinLines never fires, and a dev still TYPING below it must
# NOT count as idle. Cutting them off mid-work is the regression, and what rules
# it out is the fingerprint changing every poll — so the file is edited between
# the polls here, which is what "the dev is writing, just under the floor"
# actually looks like. (The static case, the dev who stopped below the floor, is
# the block right after this one and reaches the cut-off on purpose.)
SID_F=pause2
rm -rf "$(basedir "$SID_F")"; cstate "$SID_F"
echo '{"level":"C","coach":true,"coachQuietPolls":1,"coachMinLines":50,"coachCooldownMinutes":0,"coachMaxWaitMinutes":0,"coachPollSeconds":1800,"coachIdleMinutes":45}' > "$GCFG"
lines 4 > "$CREPO/src/Small.kt"
out=$(cycle_out "$SID_F" 1); rc1=$?
echo 'still typing 1' >> "$CREPO/src/Small.kt"
out2=$(cycle_out "$SID_F" 1); rc2=$?
echo 'still typing 2' >> "$CREPO/src/Small.kt"
out3=$(cycle_out "$SID_F" 1); rc3=$?
{ [ -z "$out" ] && [ -z "$out2" ] && [ -z "$out3" ] \
  && [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$rc3" = 0 ]; } \
  && ok "material under coachMinLines never fires" \
  || ko "material under coachMinLines never fires (rc=$rc1/$rc2/$rc3)"
printf '%s%s%s' "$out" "$out2" "$out3" | grep -q 'watcher has stopped' \
  && ko "a dev typing under the floor must not trigger the idle cut-off" \
  || ok "a dev typing under the floor must not trigger the idle cut-off"

# ...and the other half: a dev who STOPS, leaving sub-floor material behind,
# must eventually reach the cut-off. Material is a STATIC diff against the
# baseline, not activity, so clearing .coach-idle on its mere presence pinned
# the counter at 0 whenever anything at all was pending: four lines written
# before the laptop closed bought no review (under the floor) AND no cut-off,
# and the watcher polled a dead session for the rest of it. Small.kt is left
# exactly as the block above left it and simply not touched again; at 1800s a
# poll and a 45-minute limit the third unchanged poll crosses the line.
SID_FS=pause2b
rm -rf "$(basedir "$SID_FS")"; cstate "$SID_FS"
out1=$(cycle_out "$SID_FS" 1)                  # first sighting: the fingerprint is new
out2=$(cycle_out "$SID_FS" 1)                  # unchanged: 30 min of idle
out3=$(cycle_out "$SID_FS" 1); rc=$?           # unchanged: 60 min >= 45
{ [ -z "$out1" ] && [ -z "$out2" ] && [ "$rc" = 0 ] \
  && printf '%s' "$out3" | grep -q 'watcher has stopped'; } \
  && ok "sub-floor material the dev has stopped touching still reaches the idle cut-off" \
  || ko "sub-floor material the dev has stopped touching still reaches the idle cut-off (rc=$rc out=$out3)"
rm -f "$CREPO/src/Small.kt"

# .coach-pending times the wait coachMaxWaitMinutes owes the material, so it may
# only start once there IS a review to wait for. Stamped on the first poll with
# ANY material, sub-floor included, it aged through a stretch in which no review
# could fire: three lines before lunch, eight more an hour later, and the guard
# fired on the dev's very first keystroke back, with .coach-quiet still at 0.
SID_PL=pause2c
rm -rf "$(basedir "$SID_PL")"; cstate "$SID_PL"
# Settle every earlier block's leftovers into HEAD first: a fresh SID has no
# baseline .head, so the committed-since-baseline term is skipped and Lunch.kt
# below is the only material this block measures.
git -C "$CREPO" add -A >/dev/null 2>&1; git -C "$CREPO" commit -q -m lunchbase 2>/dev/null
echo '{"level":"C","coach":true,"coachQuietPolls":1,"coachMinLines":10,"coachCooldownMinutes":0,"coachMaxWaitMinutes":15,"coachPollSeconds":1800,"coachIdleMinutes":600}' > "$GCFG"
lines 3 > "$CREPO/src/Lunch.kt"
cycle_out "$SID_PL" 1 >/dev/null                # three lines: nothing a review can fire on
[ ! -f "$(pendf "$SID_PL")" ] \
  && ok "sub-floor material does not stamp .coach-pending" \
  || ko "sub-floor material does not stamp .coach-pending"
# Lunch. Ageing whatever stamp exists by an hour is exactly what the hour does.
if [ -f "$(pendf "$SID_PL")" ]; then
  printf '%s' "$(( $(date +%s) - 3600 ))" > "$(pendf "$SID_PL")"
fi
lines 8 | sed 's/^/back /' >> "$CREPO/src/Lunch.kt"   # first keystrokes back: 11 lines
out=$(cycle_out "$SID_PL" 1); rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } \
  && ok "the max-wait guard does not fire on the first keystroke after a break" \
  || ko "the max-wait guard does not fire on the first keystroke after a break (rc=$rc out=$out)"
rm -f "$CREPO/src/Lunch.kt"

# The file list is capped at 20 names while `files:` reports the true count, and
# the ladder sizes the review off `files` — with the structure question defined
# as "the split across the files in the trigger". Unannounced, the cap left
# Claude reasoning about files it was never shown.
SID_T=pause2d
rm -rf "$(basedir "$SID_T")"; cstate "$SID_T"
git -C "$CREPO" add -A >/dev/null 2>&1; git -C "$CREPO" commit -q -m manybase 2>/dev/null
echo '{"level":"C","coach":true,"coachQuietPolls":1,"coachMinLines":1,"coachCooldownMinutes":0,"coachMaxWaitMinutes":0,"coachPollSeconds":1800,"coachIdleMinutes":600}' > "$GCFG"
mkdir -p "$CREPO/src/many"
mi=1; while [ "$mi" -le 22 ]; do lines 1 > "$CREPO/src/many/F$mi.kt"; mi=$((mi + 1)); done
cycle_out "$SID_T" 1 >/dev/null                 # first sighting
out=$(cycle_out "$SID_T" 1); rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'files: 22' \
  && printf '%s' "$out" | grep -qF '(+2 more not listed)'; } \
  && ok "the trigger names how many files its capped list leaves out" \
  || ko "the trigger names how many files its capped list leaves out (rc=$rc out=$out)"
rm -rf "$CREPO/src/many"

# Equal line counts, different content: three lines removed and three added
# leaves the total unchanged while the dev is very much still typing. Comparing
# totals instead of a fingerprint would read this as a pause.
SID_FP=pause3
rm -rf "$(basedir "$SID_FP")"; cstate "$SID_FP"
echo '{"level":"C","coach":true,"coachQuietPolls":1,"coachMinLines":1,"coachCooldownMinutes":0,"coachMaxWaitMinutes":0,"coachPollSeconds":1800,"coachIdleMinutes":45}' > "$GCFG"
lines 9 > "$CREPO/src/Churn.kt"
cycle_out "$SID_FP" 1 >/dev/null                # observe, quiet 0
sed -i.bak 's/^line 1$/CHANGED 1/' "$CREPO/src/Churn.kt"; rm -f "$CREPO/src/Churn.kt.bak"
out=$(cycle_out "$SID_FP" 1)
[ -z "$out" ] && ok "an edit with an unchanged line total still counts as activity" \
  || ko "an edit with an unchanged line total still counts as activity"
rm -f "$CREPO/src/Churn.kt"

# The cooldown blocks a fire without resetting quiet: the next poll after it
# expires must fire, instead of demanding a second pause from the dev.
SID_CD=pause4
rm -rf "$(basedir "$SID_CD")"; cstate "$SID_CD"
echo '{"level":"C","coach":true,"coachQuietPolls":1,"coachMinLines":1,"coachCooldownMinutes":10,"coachMaxWaitMinutes":0,"coachPollSeconds":1800,"coachIdleMinutes":45}' > "$GCFG"
lines 7 > "$CREPO/src/Cool.kt"
cycle_out "$SID_CD" 1 >/dev/null                 # observe
printf '%s' "$(( $(date +%s) - 120 ))" > "$(lastf "$SID_CD")"   # a review 2 min ago
out=$(cycle_out "$SID_CD" 1)
[ -z "$out" ] && ok "the cooldown blocks a fire" || ko "the cooldown blocks a fire"
printf '%s' "$(( $(date +%s) - 1200 ))" > "$(lastf "$SID_CD")"  # now 20 min ago
out=$(cycle_out "$SID_CD" 1)
printf '%s' "$out" | grep -q '🧑‍🏫 Coach (' \
  && ok "a fire blocked by the cooldown is served at the next poll" \
  || ko "a fire blocked by the cooldown is served at the next poll"
rm -f "$CREPO/src/Cool.kt"

# The guard: a dev in continuous flow never pauses, so the pause alone would
# never fire. coachMaxWaitMinutes emits anyway.
SID_G=pause5
rm -rf "$(basedir "$SID_G")"; cstate "$SID_G"
echo '{"level":"C","coach":true,"coachQuietPolls":99,"coachMinLines":1,"coachCooldownMinutes":0,"coachMaxWaitMinutes":15,"coachPollSeconds":1800,"coachIdleMinutes":45}' > "$GCFG"
lines 8 > "$CREPO/src/Flow.kt"
cycle_out "$SID_G" 1 >/dev/null                 # material is now pending
printf '%s' "$(( $(date +%s) - 1200 ))" > "$(pendf "$SID_G")"  # pending for 20 min
out=$(cycle_out "$SID_G" 1)
printf '%s' "$out" | grep -q '🧑‍🏫 Coach (' \
  && ok "coachMaxWaitMinutes fires without a pause" || ko "coachMaxWaitMinutes fires without a pause"

# ...and 0 disables it.
SID_G0=pause6
rm -rf "$(basedir "$SID_G0")"; cstate "$SID_G0"
echo '{"level":"C","coach":true,"coachQuietPolls":99,"coachMinLines":1,"coachCooldownMinutes":0,"coachMaxWaitMinutes":0,"coachPollSeconds":1800,"coachIdleMinutes":45}' > "$GCFG"
cycle_out "$SID_G0" 1 >/dev/null
printf '%s' "$(( $(date +%s) - 36000 ))" > "$(pendf "$SID_G0")"
out=$(cycle_out "$SID_G0" 1)
[ -z "$out" ] && ok "coachMaxWaitMinutes 0 disables the guard" \
  || ko "coachMaxWaitMinutes 0 disables the guard"
rm -f "$CREPO/src/Flow.kt"

# Idle is now a duration: idle_polls * coachPollSeconds >= coachIdleMinutes * 60.
# 1800s per poll and 45 min of idle means the second empty poll crosses it.
SID_I=pause7
rm -rf "$(basedir "$SID_I")"; cstate "$SID_I"
echo '{"level":"C","coach":true,"coachQuietPolls":1,"coachMinLines":1,"coachCooldownMinutes":0,"coachMaxWaitMinutes":0,"coachPollSeconds":1800,"coachIdleMinutes":45}' > "$GCFG"
git -C "$CREPO" add -A >/dev/null 2>&1; git -C "$CREPO" commit -q -m idlebase 2>/dev/null
out1=$(cycle_out "$SID_I" 1)
[ -z "$out1" ] && ok "the first empty poll says nothing" || ko "the first empty poll says nothing"
out2=$(cycle_out "$SID_I" 1)
printf '%s' "$out2" | grep -q 'the watcher has stopped' \
  && ok "the idle line is emitted once coachIdleMinutes has elapsed" \
  || ko "the idle line is emitted once coachIdleMinutes has elapsed"
printf '%s' "$out2" | grep -q '45 minutes' \
  && ok "the idle line names the duration, not a cycle count" \
  || ko "the idle line names the duration, not a cycle count"
printf '%s' "$out2" | grep -qi 'continue' \
  && ok "the idle line asks about continuing the session" \
  || ko "the idle line asks about continuing the session"
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_I" --once --cycle 1 >/dev/null 2>&1
[ "$?" = "0" ] && ok "the watcher exits 0 on idle" || ko "the watcher exits 0 on idle"

# Material resets the idle counter: the empty periods have to be consecutive.
SID_R=pause8
rm -rf "$(basedir "$SID_R")"; cstate "$SID_R"
cycle_out "$SID_R" 1 >/dev/null                 # empty 1
lines 3 > "$CREPO/src/Back.kt"
cycle_out "$SID_R" 1 >/dev/null                 # material -> reset
rm -f "$CREPO/src/Back.kt"
out=$(cycle_out "$SID_R" 1)                     # empty 1 again, not 2
[ -z "$out" ] && ok "material resets the idle counter" || ko "material resets the idle counter"

# The writing axis is only exact if the watcher's own measurement outlives the
# session. Its TMPDIR state does not: learner-cleanup.sh deletes it at the same
# SessionEnd that pilot-record.sh runs at, in parallel.
CW_TMP="$WORK/coach-devlines"
rm -rf "$CW_TMP"; mkdir -p "$CW_TMP/cfg/learner" "$CW_TMP/repo"
git -C "$CW_TMP/repo" init -q
printf 'a\nb\nc\n' > "$CW_TMP/repo/f.txt"
git -C "$CW_TMP/repo" add f.txt
git -C "$CW_TMP/repo" -c user.email=t@t -c user.name=t commit -qm init
printf '{"level":"C","coach":true,"pilotEnabled":true,"coachMinLines":1,"coachQuietPolls":1,"coachCooldownMinutes":0,"coachMaxWaitMinutes":0}' > "$CW_TMP/cfg/learner.json"
printf 'a\nb\nc\nd\ne\n' > "$CW_TMP/repo/f.txt"
(cd "$CW_TMP/repo" && CLAUDE_CONFIG_DIR="$CW_TMP/cfg" CLAUDE_PROJECT_DIR="$CW_TMP/repo" \
  sh "$PLUG/hooks/coach-watch.sh" CW1 --once >/dev/null 2>&1)   # first sighting: only observes
(cd "$CW_TMP/repo" && CLAUDE_CONFIG_DIR="$CW_TMP/cfg" CLAUDE_PROJECT_DIR="$CW_TMP/repo" \
  sh "$PLUG/hooks/coach-watch.sh" CW1 --once >/dev/null 2>&1)   # unchanged since: quiet -> fires
if [ -f "$CW_TMP/cfg/learner/pilot-devlines" ] \
   && grep -q '^CW1 5$' "$CW_TMP/cfg/learner/pilot-devlines"; then
  ok "coach-watch persists the dev's line count for the writing axis"
else
  ko "coach-watch persists the dev's line count for the writing axis"
fi

# The tally must be added-only, not added-plus-removed: coach_delta (which
# drives the console line above, correctly) counts both sides of a hunk, but
# rubric.md's writing axis compares dev_lines against cl_lines, and cl_lines
# (hooks/pilot-record.sh) counts added lines only. Persisting the +/- count
# here would let an ordinary edit-in-place count twice and a pure deletion
# count as writing at all. Two cycles: the first (no prior baseline for the
# file) establishes one, unable by itself to discriminate the two counts —
# the second cycle edits one line in place (c -> C, one add, one remove) and
# drops another (z, a pure removal) against that baseline, so the two counts
# genuinely diverge (+/- total: 3; added-only: 1) and only the added-only
# count may appear in what gets persisted for that second cycle.
CW2_TMP="$WORK/coach-devlines-added-only"
rm -rf "$CW2_TMP"; mkdir -p "$CW2_TMP/cfg/learner" "$CW2_TMP/repo"
git -C "$CW2_TMP/repo" init -q
printf 'a\nb\nc\nd\ne\n' > "$CW2_TMP/repo/f.txt"
git -C "$CW2_TMP/repo" add f.txt
git -C "$CW2_TMP/repo" -c user.email=t@t -c user.name=t commit -qm init
printf '{"level":"C","coach":true,"pilotEnabled":true,"coachMinLines":1,"coachQuietPolls":1,"coachCooldownMinutes":0,"coachMaxWaitMinutes":0}' > "$CW2_TMP/cfg/learner.json"
printf 'a\nb\nc\nd\ne\nz\n' > "$CW2_TMP/repo/f.txt"
(cd "$CW2_TMP/repo" && CLAUDE_CONFIG_DIR="$CW2_TMP/cfg" CLAUDE_PROJECT_DIR="$CW2_TMP/repo" \
  sh "$PLUG/hooks/coach-watch.sh" CW2 --once >/dev/null 2>&1)   # first sighting: only observes
(cd "$CW2_TMP/repo" && CLAUDE_CONFIG_DIR="$CW2_TMP/cfg" CLAUDE_PROJECT_DIR="$CW2_TMP/repo" \
  sh "$PLUG/hooks/coach-watch.sh" CW2 --once >/dev/null 2>&1)   # unchanged: fires, establishing a baseline
printf 'a\nb\nC\nd\ne\n' > "$CW2_TMP/repo/f.txt"
(cd "$CW2_TMP/repo" && CLAUDE_CONFIG_DIR="$CW2_TMP/cfg" CLAUDE_PROJECT_DIR="$CW2_TMP/repo" \
  sh "$PLUG/hooks/coach-watch.sh" CW2 --once >/dev/null 2>&1)   # first sighting of the edit: only observes
(cd "$CW2_TMP/repo" && CLAUDE_CONFIG_DIR="$CW2_TMP/cfg" CLAUDE_PROJECT_DIR="$CW2_TMP/repo" \
  sh "$PLUG/hooks/coach-watch.sh" CW2 --once >/dev/null 2>&1)   # unchanged since: quiet -> fires, against the baseline above
CW2_LAST=$(grep '^CW2 ' "$CW2_TMP/cfg/learner/pilot-devlines" 2>/dev/null | tail -1)
[ "$CW2_LAST" = "CW2 1" ] \
  && ok "coach-watch's writing tally counts only added lines, never the removed side of an edit or a pure deletion" \
  || ko "coach-watch's writing tally counts only added lines (got: $CW2_LAST)"

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
SID_X="clean-coach"   # quoted: shellcheck reads clean-coach as arithmetic (SC2100)
mkdir -p "$TMPDIR/claude-learner-${SID_X}.coach-base"
touch "$TMPDIR/claude-learner-${SID_X}.coach-base/.head" \
      "$TMPDIR/claude-learner-${SID_X}.coach-scope" \
      "$TMPDIR/claude-learner-${SID_X}.coach-fp" \
      "$TMPDIR/claude-learner-${SID_X}.coach-quiet" \
      "$TMPDIR/claude-learner-${SID_X}.coach-idle" \
      "$TMPDIR/claude-learner-${SID_X}.coach-pending" \
      "$TMPDIR/claude-learner-${SID_X}.coach-last" \
      "$TMPDIR/claude-learner-${SID_X}.coach-stopped" \
      "$TMPDIR/claude-learner-${SID_X}.edits" \
      "$TMPDIR/claude-learner-${SID_X}.pilot-nudged"
printf '{"session_id":"%s"}' "$SID_X" | sh "$CLEAN"
{ [ ! -d "$TMPDIR/claude-learner-${SID_X}.coach-base" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.coach-scope" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.coach-fp" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.coach-quiet" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.coach-idle" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.coach-pending" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.coach-last" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.coach-stopped" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.edits" ] \
  && [ ! -f "$TMPDIR/claude-learner-${SID_X}.pilot-nudged" ]; } \
  && ok "cleanup removes the coach scratch files" || ko "cleanup removes the coach scratch files"

# Both install paths must be wired, or half the users get half the feature.
{ jq -e '.hooks.PreToolUse[] | select(.matcher == "Write|Edit|NotebookEdit")
         | .hooks[0].command | contains("coach-gate.sh")' "$PLUG/hooks/hooks.json" >/dev/null 2>&1; } \
  && ok "hooks.json wires coach-gate.sh" || ko "hooks.json wires coach-gate.sh"
{ jq -e '.hooks.PreToolUse[] | select(.matcher == "Write|Edit|NotebookEdit")
         | .hooks[0].command | contains("coach-gate.sh")' "$PLUG/hooks/settings.snippet.json" >/dev/null 2>&1; } \
  && ok "settings.snippet.json wires coach-gate.sh" || ko "settings.snippet.json wires coach-gate.sh"

# coach-watch.sh is not a hook and must never be wired as one.
grep -q 'coach-watch' "$PLUG/hooks/hooks.json" \
  && ko "coach-watch.sh is not wired as a hook" || ok "coach-watch.sh is not wired as a hook"
grep -q 'coach-watch' "$PLUG/hooks/settings.snippet.json" \
  && ko "coach-watch.sh is not wired in the snippet either" \
  || ok "coach-watch.sh is not wired in the snippet either"

# Item 1 sweep regression: coach_advance's `: > "$_canew"` writes a brand-new
# file inside $BASEDIR, so unlike a missing TMPDIR (already caught by the
# `mkdir -p … || return 0` guard above it in the source), a $BASEDIR that
# already EXISTS but is not writable reaches this line unguarded. `:` is a
# POSIX special built-in, so an unguarded redirection failure on it aborts a
# non-interactive shell outright under dash — here that kills only the forked
# subshell running this function (the right side of `coach_candidates |
# coach_advance`), so `--advance`'s own hardcoded `exit 0` still runs, but the
# abort still leaks the raw dash diagnostic to the real stderr and leaves the
# baseline stuck re-offering the same material. Exercised under both this
# suite's own /bin/sh and, when available, dash itself.
echo '{"level":"C","coach":true}' > "$GCFG"
SID_W2=watch-ro
rm -rf "$(basedir "$SID_W2")"
mkdir -p "$(basedir "$SID_W2")"; chmod 555 "$(basedir "$SID_W2")"
out=$(CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_W2" --advance 2>&1); rc=$?
chmod 755 "$(basedir "$SID_W2")"
{ [ -z "$out" ] && [ "$rc" = 0 ]; } \
  && ok "coach-watch --advance exits 0 with no output when its baseline dir is read-only" \
  || ko "coach-watch --advance exits 0 with no output when its baseline dir is read-only (rc=$rc out=$out)"
if command -v dash >/dev/null 2>&1; then
  rm -rf "$(basedir "$SID_W2")"
  mkdir -p "$(basedir "$SID_W2")"; chmod 555 "$(basedir "$SID_W2")"
  out=$(CLAUDE_PROJECT_DIR="$CREPO" dash "$WATCH" "$SID_W2" --advance 2>&1); rc=$?
  chmod 755 "$(basedir "$SID_W2")"
  { [ -z "$out" ] && [ "$rc" = 0 ]; } \
    && ok "coach-watch --advance exits 0 with no output under dash when its baseline dir is read-only" \
    || ko "coach-watch --advance exits 0 with no output under dash when its baseline dir is read-only (rc=$rc out=$out)"
else
  echo "  (dash not found on this machine — the dash-specific read-only-baseline check was skipped, coverage not claimed)"
fi
chmod 755 "$(basedir "$SID_W2")" 2>/dev/null
rm -rf "$(basedir "$SID_W2")"

# --- coach-armed-check.sh ---------------------------------------------------
ARMCHK="$PLUG/hooks/coach-armed-check.sh"
armed()   { echo "$TMPDIR/claude-learner-$1.coach-armed"; }
armwarn() { echo "$TMPDIR/claude-learner-$1.coach-armwarn"; }
armseen() { echo "$TMPDIR/claude-learner-$1.coach-armseen"; }
stopped() { echo "$TMPDIR/claude-learner-$1.coach-stopped"; }
armin()   { printf '{"session_id":"%s"}' "$1"; }

SID_A=arm1
rm -f "$(armed "$SID_A")" "$(armwarn "$SID_A")" "$(armseen "$SID_A")"

# Coach off: the hook is a silent no-op, like every other learner hook — exit
# 0 AND no output, not output alone. A crash also produces no stdout, which is
# exactly how Critical 1 (an unguarded `:` redirection killing the hook with
# exit 2 under dash) hid behind a green "silent" assertion the first time
# around: capture and check the exit status in every assertion below that
# claims silence.
echo '{"level":"C","coach":false}' > "$GCFG"
rm -f "$PCFG"
out=$(armin "$SID_A" | CLAUDE_PROJECT_DIR="$CREPO" sh "$ARMCHK"); rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } && ok "armed-check is silent with the coach off" \
  || ko "armed-check is silent with the coach off (rc=$rc)"

# Coach on, first prompt of the session: the watcher cannot possibly be armed
# yet — learner-onboard.sh only ASKS Claude to arm it during turn 1, which
# happens after this very UserPromptSubmit already fired and returned. This is
# a grace window, not a report: stay silent, and remember a prompt was seen.
echo '{"level":"C","coach":true}' > "$GCFG"
out=$(armin "$SID_A" | CLAUDE_PROJECT_DIR="$CREPO" sh "$ARMCHK"); rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } \
  && ok "the first prompt of a coach session is a silent grace window" \
  || ko "the first prompt of a coach session is a silent grace window (rc=$rc)"
[ -f "$(armseen "$SID_A")" ] && ok "the first prompt records that a prompt was seen" \
  || ko "the first prompt records that a prompt was seen"
[ ! -f "$(armwarn "$SID_A")" ] && ok "the grace window does not also spend the once-per-session warning" \
  || ko "the grace window does not also spend the once-per-session warning"

# Second prompt, still not armed: now the absence of the marker is a real
# report — one line of additionalContext, and it is valid JSON.
out=$(armin "$SID_A" | CLAUDE_PROJECT_DIR="$CREPO" sh "$ARMCHK"); rc=$?
{ [ "$rc" = 0 ] \
  && printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1; } \
  && ok "armed-check emits a valid UserPromptSubmit payload" \
  || ko "armed-check emits a valid UserPromptSubmit payload (rc=$rc)"
printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'coach-watch.sh' \
  && ok "the warning names the command that arms the watcher" \
  || ko "the warning names the command that arms the watcher"
printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "$SID_A" \
  && ok "the warning carries the session id" || ko "the warning carries the session id"

# Third prompt: once per session, not once per still-absent marker.
out=$(armin "$SID_A" | CLAUDE_PROJECT_DIR="$CREPO" sh "$ARMCHK"); rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } && ok "armed-check warns at most once per session" \
  || ko "armed-check warns at most once per session (rc=$rc)"

# Marker present: nothing to warn about, at any point — even on what would
# otherwise be the "first prompt" grace window, since the marker check now
# runs before that logic (see the reordering below).
SID_A2=arm2
rm -f "$(armwarn "$SID_A2")" "$(armseen "$SID_A2")"
: > "$(armed "$SID_A2")"
out=$(armin "$SID_A2" | CLAUDE_PROJECT_DIR="$CREPO" sh "$ARMCHK"); rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } && ok "armed-check is silent once the watcher is armed" \
  || ko "armed-check is silent once the watcher is armed (rc=$rc)"

# The idle cut-off removes .coach-armed on purpose and leaves .coach-stopped in
# its place. Without reading that second marker the dev is told "coach mode is
# on but the watcher is not armed, so no review will ever fire" one turn after
# the cut-off line itself asked them whether they want to continue — the
# product's own deliberate state reported as a broken install. The grace window
# is already spent here (armseen planted), so only the stop marker can explain
# silence; the one-shot warning must also still be unspent afterwards.
SID_A5=arm5
rm -f "$(armed "$SID_A5")" "$(armwarn "$SID_A5")"
: > "$(armseen "$SID_A5")"
: > "$(stopped "$SID_A5")"
out=$(armin "$SID_A5" | CLAUDE_PROJECT_DIR="$CREPO" sh "$ARMCHK"); rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ] && [ ! -f "$(armwarn "$SID_A5")" ]; } \
  && ok "armed-check stays silent once the idle cut-off has deliberately stopped the watcher" \
  || ko "armed-check stays silent once the idle cut-off has deliberately stopped the watcher (rc=$rc out=$out)"
# ...and the same session with the marker gone is warned, so the assertion above
# is about the marker and not about some other reason for silence.
rm -f "$(stopped "$SID_A5")"
out=$(armin "$SID_A5" | CLAUDE_PROJECT_DIR="$CREPO" sh "$ARMCHK"); rc=$?
{ [ "$rc" = 0 ] \
  && printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1; } \
  && ok "the same unarmed session without the stop marker is still warned" \
  || ko "the same unarmed session without the stop marker is still warned (rc=$rc out=$out)"
rm -f "$(armseen "$SID_A5")" "$(armwarn "$SID_A5")"

# The watcher's own modes: --once and friends are test/off-cadence entry points
# and must not claim the session is armed.
SID_A3=arm3
rm -f "$(armed "$SID_A3")"
rm -rf "$(basedir "$SID_A3")"
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_A3" --once >/dev/null 2>&1
[ ! -e "$(armed "$SID_A3")" ] \
  && ok "--once does not write the armed marker" || ko "--once does not write the armed marker"

# Critical 1 regression guard: a TMPDIR the hook cannot write into at all (here,
# one that does not exist) must never surface as a nonzero exit. `:` is a
# POSIX special built-in, so an unguarded redirection failure on it aborts a
# non-interactive shell outright instead of just failing the command — under
# dash that turned into exit 2 on UserPromptSubmit, which blocks and erases
# the dev's prompt. Exercised under both this suite's own /bin/sh and, when
# available, dash itself — the shell actually behind /bin/sh on Debian/Ubuntu,
# the apt package's own target, and the one the bash-based macOS /bin/sh does
# not reproduce the bug under at all.
SID_A4=arm4
NOTMP="/nonexistent-tmpdir-for-learner-tests-$$"
out=$(armin "$SID_A4" | CLAUDE_PROJECT_DIR="$CREPO" TMPDIR="$NOTMP" sh "$ARMCHK"); rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } \
  && ok "armed-check exits 0 with no output when TMPDIR does not exist" \
  || ko "armed-check exits 0 with no output when TMPDIR does not exist (rc=$rc)"
if command -v dash >/dev/null 2>&1; then
  out=$(armin "$SID_A4" | CLAUDE_PROJECT_DIR="$CREPO" TMPDIR="$NOTMP" dash "$ARMCHK"); rc=$?
  { [ -z "$out" ] && [ "$rc" = 0 ]; } \
    && ok "armed-check exits 0 with no output under dash when TMPDIR does not exist" \
    || ko "armed-check exits 0 with no output under dash when TMPDIR does not exist (rc=$rc)"
else
  echo "  (dash not found on this machine — the dash-specific TMPDIR-missing check was skipped, coverage not claimed)"
fi

# Wiring: the new hook runs on UserPromptSubmit in both install paths.
jq -e '.hooks.UserPromptSubmit[0].hooks | map(.command) | any(contains("coach-armed-check.sh"))' \
  "$PLUG/hooks/hooks.json" >/dev/null 2>&1 \
  && ok "coach-armed-check.sh is wired on UserPromptSubmit" \
  || ko "coach-armed-check.sh is wired on UserPromptSubmit"
grep -q 'coach-armed-check' "$PLUG/hooks/settings.snippet.json" \
  && ok "coach-armed-check.sh is wired in the snippet too" \
  || ko "coach-armed-check.sh is wired in the snippet too"

# --- pilot wiring -------------------------------------------------------------
# Wiring drift is the failure mode that silently disables a whole feature, so
# assert both manifests hold the same three, and the timeout that the
# SessionEnd budget depends on.
for H in pilot-record pilot-brief pilot-nudge; do
  jq -e --arg h "$H" '[.. | strings] | map(select(test($h))) | length > 0' "$PLUG/hooks/hooks.json" >/dev/null \
    && ok "hooks.json wires $H" || ko "hooks.json wires $H"
  jq -e --arg h "$H" '[.. | strings] | map(select(test($h))) | length > 0' "$PLUG/hooks/settings.snippet.json" >/dev/null \
    && ok "settings.snippet.json wires $H" || ko "settings.snippet.json wires $H"
done

# SessionEnd hooks share 1.5s unless the wired timeout raises the budget.
# pilot-record.sh reads a whole transcript; at the default it would be killed.
jq -e '.hooks.SessionEnd[].hooks[] | select(.command | test("pilot-record")) | .timeout >= 15' \
  "$PLUG/hooks/hooks.json" >/dev/null \
  && ok "pilot-record is wired with a raised SessionEnd budget" \
  || ko "pilot-record is wired with a raised SessionEnd budget"

# UserPromptSubmit is a new event for this repo; a typo in the key is silent.
jq -e '.hooks.UserPromptSubmit | length > 0' "$PLUG/hooks/hooks.json" >/dev/null \
  && ok "hooks.json declares the UserPromptSubmit event" \
  || ko "hooks.json declares the UserPromptSubmit event"

# Every hook is named in uninstall.sh's global removal list — one loop over
# HOOK_SH (already derived above for the licence guards) rather than a
# hand-named check per script. Three literal checks used to live here and at
# uninstall.sh's other coach-gate.sh/coach-watch.sh assertion (one hand-named
# entry per script, added one at a time): that is the exact defect this task
# closes, relocated into the test suite — a twelfth hook could ship, get
# copied by install.sh and wired in both manifests, and never be added here,
# and the suite would stay green while the file survived every uninstall.
#
# Only the GLOBAL list ($CFG_DIR/hooks/...) is asserted, deliberately not the
# legacy --project list: that list is frozen on purpose (see its own comment)
# and does not name every current hook — learner-update-check.sh postdates
# that layout and never belonged in it, so a "named in both lists" assertion
# would be false about a file that is correctly absent.
for hf in $HOOK_SH; do
  grep -qF '$CFG_DIR/hooks/'"$hf" "$ROOT/uninstall.sh" \
    && ok "uninstall.sh's global removal list names $hf" \
    || ko "uninstall.sh's global removal list names $hf"
done

# Reinstall must not double-wire, and uninstall must leave nothing behind.
IW="$WORK/install-pilot"
rm -rf "$IW"; mkdir -p "$IW"
CLAUDE_CONFIG_DIR="$IW" bash "$ROOT/install.sh" --level S >/dev/null 2>&1
CLAUDE_CONFIG_DIR="$IW" bash "$ROOT/install.sh" --level S >/dev/null 2>&1
[ "$(jq '[.. | strings] | map(select(test("pilot-record"))) | length' "$IW/settings.json")" = "1" ] \
  && ok "reinstall does not double-wire pilot-record" \
  || ko "reinstall does not double-wire pilot-record"
[ -f "$IW/hooks/pilot-record.sh" ] && [ -f "$IW/hooks/pilot-brief.sh" ] && [ -f "$IW/hooks/pilot-nudge.sh" ] \
  && ok "install copies all three pilot hook scripts" \
  || ko "install copies all three pilot hook scripts"
CLAUDE_CONFIG_DIR="$IW" bash "$ROOT/uninstall.sh" >/dev/null 2>&1
if [ -f "$IW/settings.json" ] \
   && jq -e '[.. | strings] | map(select(test("pilot-"))) | length > 0' "$IW/settings.json" >/dev/null; then
  ko "uninstall strips the pilot wiring"
else
  ok "uninstall strips the pilot wiring"
fi
[ ! -f "$IW/hooks/pilot-record.sh" ] && [ ! -f "$IW/hooks/pilot-brief.sh" ] && [ ! -f "$IW/hooks/pilot-nudge.sh" ] \
  && ok "uninstall removes the pilot scripts" \
  || ko "uninstall removes the pilot scripts"

# --- coach off stops a running watcher (Finding 3) --------------------------
# The real loop used to read CFG and check learner_coach_active exactly once,
# before `while :`, and never again — `learner coach off` unblocked writes
# immediately (the gate re-reads per invocation) but the watcher itself kept
# polling and emitting for the rest of the session. This needs an actual
# backgrounded loop, not --once: --once is a fresh process per call and
# already re-reads config at the top of the script regardless of this bug, so
# it cannot exercise the loop's own (previously missing) re-check.
# coachCadence/coachLines/coachFiles used to hold this config's floor; all three
# are v2-removed keys and were inert here, so the test passed for a reason it did
# not document. coachMinLines is the live key that does the same job: put the
# floor out of reach so this loop only ever exercises the config re-check.
echo '{"level":"C","coach":true,"coachPollSeconds":5,"coachMinLines":999999,"coachCooldownMinutes":0}' > "$GCFG"
SID_LOOP=watch-loop-off
rm -rf "$(basedir "$SID_LOOP")"
# A watcher starting now supersedes any earlier one's deliberate stop: planted
# here, the marker must be gone once this loop has started, or coach-armed-check
# would stay silenced for the rest of the session behind a live watcher.
: > "$(stopped "$SID_LOOP")"
CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_LOOP" > "$WORK/loop-off.out" 2>&1 &
LOOP_PID=$!
sleep 1
echo '{"level":"C","coach":false}' > "$GCFG"
sleep 7
if kill -0 "$LOOP_PID" 2>/dev/null; then
  ko "learner coach off stops a running watcher within one poll"
  skip "the armed marker does not outlive a watcher that never stopped"
  kill -9 "$LOOP_PID" 2>/dev/null
  wait "$LOOP_PID" 2>/dev/null
else
  wait "$LOOP_PID" 2>/dev/null
  ok "learner coach off stops a running watcher within one poll"
  [ ! -e "$(stopped "$SID_LOOP")" ] \
    && ok "arming the watcher clears an earlier session's deliberate-stop marker" \
    || ko "arming the watcher clears an earlier session's deliberate-stop marker"
  # Item 4: the loop's own exit path used to leave the armed marker behind, so
  # coach-armed-check.sh's `[ -f "$ARMED" ]` test — and skills/status/SKILL.md's
  # status line — would go on reporting a watcher that had already quit.
  [ ! -e "$(armed "$SID_LOOP")" ] \
    && ok "the armed marker does not outlive a watcher stopped by coach off" \
    || ko "the armed marker does not outlive a watcher stopped by coach off"
fi
echo '{"level":"C","coach":true,"untrackGlobs":["*.md"]}' > "$GCFG"

# Minor 1 (R11 fix round): the idle cut-off is the loop's OTHER exit path, and
# it shares the same stale-marker risk as the coach-off exit just above — but
# had no test pinning its own `rm -f "$ARMED"`. A fake, no-op `sleep` drives
# the real loop through `coachIdleMinutes` in wall-clock milliseconds instead
# of minutes, without touching the cadence math itself: coachPollSeconds and
# coachIdleMinutes stay at their real floors (5s, 1 minute), so the loop still
# needs its true 12 empty cycles (12 * 5s >= 60s) to trip the cut-off — the
# fake sleep just makes each of those cycles take microseconds instead of five
# real seconds.
git -C "$CREPO" add -A >/dev/null 2>&1
git -C "$CREPO" commit -q -m "settle before idle-cutoff test" >/dev/null 2>&1
FAKESLEEP="$WORK/fakesleep"; mkdir -p "$FAKESLEEP"
printf '#!/bin/sh\nexit 0\n' > "$FAKESLEEP/sleep"
chmod +x "$FAKESLEEP/sleep"
echo '{"level":"C","coach":true,"coachPollSeconds":5,"coachIdleMinutes":1,"coachCooldownMinutes":0}' > "$GCFG"
SID_IDLE=watch-idle-cutoff
rm -rf "$(basedir "$SID_IDLE")"
PATH="$FAKESLEEP:$PATH" CLAUDE_PROJECT_DIR="$CREPO" sh "$WATCH" "$SID_IDLE" > "$WORK/loop-idle.out" 2>&1 &
IDLE_PID=$!
i=0
while kill -0 "$IDLE_PID" 2>/dev/null && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
kill -0 "$IDLE_PID" 2>/dev/null && kill -9 "$IDLE_PID" 2>/dev/null
wait "$IDLE_PID" 2>/dev/null
{ grep -q 'no tracked changes' "$WORK/loop-idle.out" \
  && [ ! -e "$(armed "$SID_IDLE")" ]; } \
  && ok "the idle cut-off both fires and removes the armed marker" \
  || ko "the idle cut-off both fires and removes the armed marker ($(cat "$WORK/loop-idle.out"))"
# ...and leaves the deliberate-stop marker behind in its place, which is the
# whole reason coach-armed-check.sh does not then call this a broken install.
[ -f "$(stopped "$SID_IDLE")" ] \
  && ok "the idle cut-off leaves a deliberate-stop marker for coach-armed-check.sh" \
  || ko "the idle cut-off leaves a deliberate-stop marker for coach-armed-check.sh"
rm -f "$(stopped "$SID_IDLE")"
echo '{"level":"C","coach":true,"untrackGlobs":["*.md"]}' > "$GCFG"

# --- coach documentation ----------------------------------------------------
SK="$PLUG/skills/learner/SKILL.md"
CO="$PLUG/skills/coach/references/coach.md"

[ -f "$CO" ] && ok "the coach skill exists" || ko "the coach skill exists"

# Every config key the code reads must be documented, or a dev cannot discover it.
for k in coach coachPollSeconds coachQuietPolls coachMinLines coachCooldownMinutes \
         coachMaxWaitMinutes coachIdleMinutes; do
  grep -q "\`$k\`" "$SK" "$PLUG/skills/learner/references/config.md" && ok "the config key $k is documented" || ko "the config key $k is documented"
done

# The nine removed v1 keys are already listed as obsolete above. The two v1 keys
# RETAINED with new meanings are the more dangerous migration, because they are
# still read: a config carrying v1's `coachPollSeconds: 300` silently gets a
# five-minute pause cadence instead of an inert key. They must be named as
# CHANGED, and they were named nowhere at all.
# The migration note lives in references/config.md since main moved the config
# rules out of SKILL.md; the assertion follows it there rather than pinning the
# file it used to sit in.
CFGMD="$PLUG/skills/learner/references/config.md"
{ grep -qF 'kept with new meanings' "$CFGMD" \
  && grep -qF '`coachPollSeconds` (v1 default `45`)' "$CFGMD" \
  && grep -qF '`coachCooldownMinutes` (v1 default `5`)' "$CFGMD"; } \
  && ok "config.md names the two coach keys retained with new meanings" \
  || ko "config.md names the two coach keys retained with new meanings"

# CYCLE lives only in the running watcher's shell variable and no file holds it,
# so the status skill cannot report it however it is asked to.
grep -qF 'current cycle if a coach session is running' "$PLUG/skills/status/SKILL.md" \
  && ko "the status skill does not claim a cycle number no file holds" \
  || ok "the status skill does not claim a cycle number no file holds"

# The dispatch table must route every subcommand the skill claims to accept.
# A leading backtick with no closing one: `coach delegate <glob> …` and
# `coach review [base-ref]` carry arguments inside the code span, so an
# exactly-wrapped pattern would miss them. This also needs to be more than a bare
# substring match — the frontmatter description mentions all four strings in prose
# too ("coach on"/"off", "coach delegate", "coach review"), and separately "coach
# on" is a bare substring of the unrelated frontmatter phrase "coach one weak spot
# to mastery" — so an unanchored grep would stay green even with the entire
# dispatch table deleted.
for c in "coach on" "coach off" "coach delegate" "coach review"; do
  grep -q "\`$c" "$SK" && ok "SKILL.md dispatches \`$c\`" || ko "SKILL.md dispatches \`$c\`"
done

# The protocol reference must be reachable from the trigger line's pointer.
grep -qF 'the `coach` skill' "$SK" && ok "SKILL.md points at the coach skill" \
  || ko "SKILL.md points at the coach skill"

# The protocol must state its own ceiling and its own prohibition, since those
# are the two things that keep the dev in the driver's seat. Anchored to the
# exact "Challenge** (1, always)" block heading rather than a bare "challenge"
# grep, which the register table's own prose ("what the challenge attacks")
# would satisfy before this ceiling existed.
grep -qF 'Challenge** (1, always)' "$CO" && ok "the coach skill states the challenge is mandatory and singular" \
  || ko "the coach skill states the challenge is mandatory and singular"
grep -qi 'never write' "$CO" && ok "the coach skill forbids writing to source" \
  || ko "the coach skill forbids writing to source"
grep -q 'references/data.md' "$CO" && ok "the coach skill defers to data.md for the data rules" \
  || ko "the coach skill defers to data.md for the data rules"

# --- coach protocol ---------------------------------------------------------
CMD="$PLUG/skills/coach/references/coach.md"

# The ladder: a review's size follows the dev's diff, and the two criteria are
# read independently. Without the "higher tier wins" rule, 300 lines in one file
# would be classified as a small diff on the files criterion alone.
grep -qi 'higher tier wins' "$CMD" \
  && ok "coach.md states how the two ladder criteria combine" \
  || ko "coach.md states how the two ladder criteria combine"

# The tier boundaries and per-tier question/finding counts are the load-bearing
# part of this task's behaviour. An unanchored `grep -q "$t"` for the tier name
# alone would stay green if "< 40" silently became "< 400" — exactly the class
# of non-discriminating grep this repo has been bitten by three times already.
# Anchor on each row verbatim instead, so a changed boundary or count turns
# the suite red.
grep -qF '| Small | < 40 | 1 | 1 — the challenge | 0-2 |' "$CMD" \
  && ok "coach.md's ladder pins the Small tier's boundary and counts" \
  || ko "coach.md's ladder pins the Small tier's boundary and counts"
grep -qF '| Medium | 40-120 | 2-3 | up to 2 — challenge + library *if there is material* | 0-3 |' "$CMD" \
  && ok "coach.md's ladder pins the Medium tier's boundary and counts" \
  || ko "coach.md's ladder pins the Medium tier's boundary and counts"
grep -qF '| Large | > 120 | ≥ 4 | up to 3 — challenge + library + one on the split | 0-3 |' "$CMD" \
  && ok "coach.md's ladder pins the Large tier's boundary and counts" \
  || ko "coach.md's ladder pins the Large tier's boundary and counts"

# The coach skill DESCRIPTION is the first thing Claude reads when routing into
# the skill, and it flatly claimed the questions are "asked one at a time".
# coach.md is explicit that one or two share a message and only three are
# serialised; commit 6fd821f corrected that claim in README.md and
# docs/usage.html and missed this third, most load-bearing copy.
CSK="$PLUG/skills/coach/SKILL.md"
grep -qF 'sized to the diff, asked one at a time' "$CSK" \
  && ko "the coach skill description does not flatten the batching rule" \
  || ok "the coach skill description does not flatten the batching rule"
grep -qF 'three asked one at a time' "$CSK" \
  && ok "the coach skill description states the real batching rule" \
  || ko "the coach skill description states the real batching rule"

# Three questions must be asked one at a time. This is the rule most likely to
# be dropped in a rewrite, and the one that decides whether a large review is a
# conversation or an interrogation.
grep -qi 'one at a time' "$CMD" \
  && ok "coach.md requires three questions to be asked one at a time" \
  || ko "coach.md requires three questions to be asked one at a time"

# The library question is conditional and has NO fallback: v1's instinct was to
# always have something to ask.
grep -qi 'no fallback' "$CMD" \
  && ok "coach.md rules out a fallback library question" \
  || ko "coach.md rules out a fallback library question"

# The teaching phase and its ceiling. 'generic' alone tests vocabulary, not the
# rule — it would still match inside a negation of the rule. The substantive
# clause is the prohibition on the dev's own names, so assert that too.
grep -qi 'generic' "$CMD" && ok "coach.md bounds the teaching snippet to a generic one" \
  || ko "coach.md bounds the teaching snippet to a generic one"
grep -qiF "never a snippet using the dev's own class, function or file names" "$CMD" \
  && ok "coach.md forbids a teaching snippet that uses the dev's own names" \
  || ko "coach.md forbids a teaching snippet that uses the dev's own names"
grep -qF 'libs.md' "$CMD" && ok "coach.md reads libs.md before choosing a library" \
  || ko "coach.md reads libs.md before choosing a library"

# The confirmation must be allowed to be absent — an invented compliment is
# worse than none, and a protocol that mandates one guarantees invention.
# Anchored to the bolded "**say nothing**" rather than a bare 'say nothing':
# § On the idle line already says "say nothing further about it" about a
# different question entirely, and a loose grep would pass on that alone,
# before the confirmation block existed at all.
grep -qF '**say nothing**' "$CMD" \
  && ok "coach.md allows the confirmation to be skipped" \
  || ko "coach.md allows the confirmation to be skipped"

# The idle-line quote in § On the idle line must track what coach-watch.sh
# actually prints, not what it used to print: the watcher moved from a
# work-block count to a minutes duration, and coach.md's quoted string went
# stale silently because nothing tied the two together. Ground truth is read
# from coach-watch.sh itself, the same style as the hook-count and
# LEARNER_DEFAULTS derivations elsewhere in this file (search "hook count
# drift guard"), rather than restated by hand here where it could go stale
# again the same way. Full string equality is impractical — coach.md quotes
# the line with a literal "N" where the watcher interpolates $IDLE_MINUTES —
# so the two fixed fragments framing that variable are pulled out of the
# watcher's own printf and both are required verbatim in coach.md; either one
# missing means the two files disagree on what the dev will actually see.
IDLE_LINE=$(grep -o 'no tracked changes for \$IDLE_MINUTES minutes; the watcher has stopped\.' \
  "$PLUG/hooks/coach-watch.sh")
IDLE_PRE=$(printf '%s' "$IDLE_LINE" | sed 's/\$IDLE_MINUTES.*//')
IDLE_POST=$(printf '%s' "$IDLE_LINE" | sed 's/.*MINUTES //')
{ [ -n "$IDLE_PRE" ] && [ -n "$IDLE_POST" ] \
  && grep -qF "$IDLE_PRE" "$CMD" && grep -qF "$IDLE_POST" "$CMD"; } \
  && ok "coach.md's idle-line quote matches what coach-watch.sh actually emits" \
  || ko "coach.md's idle-line quote matches what coach-watch.sh actually emits"

# The SAME derivation for the trigger line's instruction sentence, which had no
# guard at all and duly went stale in the worst possible way: it kept ordering
# "One challenge, then wait for the dev's answer" for the whole of v2. That is
# not a parameter, it is an imperative, and it is the most proximate instruction
# Claude gets — it beat coach.md's 1/2/3 ladder outright, so a Large review asked
# one question and stopped and the branch shipped v1 behaviour under v2 docs.
# Two assertions, because either alone is insufficient:
#   1. coach.md quotes the watcher's sentence verbatim, pulled out of the hook's
#      own printf (backtick escapes undone) so the doc cannot drift from it;
#   2. the sentence itself prescribes no question count, which is the property
#      that actually matters — a matching pair of wrong sentences would satisfy
#      (1) alone.
TRIG_SENT=$(grep '^Invoke the .*references/coach\.md\.' "$PLUG/hooks/coach-watch.sh" \
  | head -n 1 | sed 's/"$//' | sed 's/\\`/`/g')
{ [ -n "$TRIG_SENT" ] && grep -qF "$TRIG_SENT" "$CMD"; } \
  && ok "coach.md quotes the trigger's instruction sentence as coach-watch.sh emits it" \
  || ko "coach.md quotes the trigger's instruction sentence as coach-watch.sh emits it (got: $TRIG_SENT)"
{ [ -n "$TRIG_SENT" ] \
  && ! printf '%s' "$TRIG_SENT" | grep -qiE '(one|two|three|a single|1|2|3) +(challenge|question)'; } \
  && ok "the trigger's instruction sentence prescribes no question count" \
  || ko "the trigger's instruction sentence prescribes no question count (got: $TRIG_SENT)"

# The diff command in step 3. coach_candidates serves three material sources and
# `git diff HEAD` can only see one of them: it returns empty for an untracked file
# and for anything committed since the last review — and on a pause cadence,
# "just committed" and "just created a file and stopped to think" are the two
# commonest triggers there are. The baseline HEAD is on disk; the protocol has to
# name it, or the review reads an empty diff and invents something.
grep -qF '.coach-base/.head' "$CMD" \
  && ok "coach.md names the baseline HEAD for material committed since the last review" \
  || ko "coach.md names the baseline HEAD for material committed since the last review"
grep -qi 'untracked' "$CMD" \
  && ok "coach.md says an untracked file is read, not diffed" \
  || ko "coach.md says an untracked file is read, not diffed"

# Resolving the session id off disk. `.session` is written only by
# learner-record-edit.sh, on a Write/Edit Claude made inside the repo — which
# coach mode forbids — so in an un-delegated coach session it never exists, and
# the old recipe pointed at a file that is absent exactly when the id is needed.
# The anchor must be one coach mode creates itself.
grep -qF 'claude-learner-*.coach-*' "$CMD" \
  && ok "coach.md resolves the session id from an anchor a coach session actually creates" \
  || ko "coach.md resolves the session id from an anchor a coach session actually creates"

# A single glob, not two required to both match: .coach-base/ is not created
# until the first emission, so an armed session with no review fired yet has
# .coach-armed on disk and nothing else coach-owned. Under zsh (this harness's
# own Bash-tool shell on macOS), `nomatch` aborts a glob with no match, so a
# recipe requiring two specific globs would abort — silently, behind its own
# `2>/dev/null` — in exactly that window. A single glob needs only one
# coach-owned file, of any kind, to exist.
! grep -qF 'claude-learner-*.coach-armed' "$CMD" \
  && ok "coach.md's session-id recipe no longer requires two globs to both match" \
  || ko "coach.md's session-id recipe no longer requires two globs to both match"
grep -qF 'ls -t "$TMPDIR"/claude-learner-*.session' "$CMD" \
  && ko "coach.md no longer resolves the session id through .session" \
  || ok "coach.md no longer resolves the session id through .session"

# The recipe itself, run for real, under zsh specifically — the shell the Bash
# tool actually uses on macOS. A two-glob version passed the text checks above
# yet still printed nothing here, because zsh's `nomatch` aborts a glob with no
# match and the recipe's own `2>/dev/null` hides why. The failing case is an
# armed watcher with no review fired yet: `.coach-base/` is not created until
# the first emission, so only `.coach-armed` exists on disk.
RECIPE=$(sed -n '/^```bash$/,/^```$/p' "$CMD" | sed '1d;$d')
if command -v zsh >/dev/null 2>&1; then
  SIDDIR=$(mktemp -d)
  : > "$SIDDIR/claude-learner-zshsid42.coach-armed"
  out=$(TMPDIR="$SIDDIR" zsh -c "$RECIPE")
  rm -rf "$SIDDIR"
  [ "$out" = "zshsid42" ] \
    && ok "coach.md's session-id recipe resolves the id under zsh when only .coach-armed exists" \
    || ko "coach.md's session-id recipe resolves the id under zsh when only .coach-armed exists (got: $out)"
else
  echo "  (zsh not found on this machine — the zsh session-id recipe check was skipped, coverage not claimed)"
fi

# --- learner sync: skeleton -------------------------------------------------
SYNC="$PLUG/hooks/learner-sync.sh"

# A fake gh, so no test ever reaches the network. It serves a "remote" gist out
# of $GH_REMOTE (one file per gist file) and logs its argv to $GH_LOG.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GHFAKE'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$1 $2" in
  "auth status") exit "${GH_AUTH:-0}" ;;
esac
exit 0
GHFAKE
chmod +x "$WORK/bin/gh"
export GH_LOG="$WORK/gh.log"
PATH="$WORK/bin:$PATH"; export PATH

out=$(sh "$SYNC" 2>/dev/null); rc=$?
{ [ "$rc" = 2 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "usage" ]; } \
  && ok "sync with no subcommand exits 2 with a usage error" \
  || ko "sync with no subcommand exits 2 with a usage error (rc=$rc out=$out)"

out=$(sh "$SYNC" frobnicate 2>/dev/null); rc=$?
{ [ "$rc" = 2 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "usage" ]; } \
  && ok "sync rejects an unknown subcommand" \
  || ko "sync rejects an unknown subcommand (rc=$rc out=$out)"

out=$(GH_AUTH=1 sh "$SYNC" status 2>/dev/null); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "gh-unauthenticated" ]; } \
  && ok "sync reports an unauthenticated gh instead of guessing" \
  || ko "sync reports an unauthenticated gh instead of guessing (rc=$rc out=$out)"

# Collision-proof gh-missing test: symlink only what status path needs,
# leave gh out. This prevents `gh auth status` real call even if jq and gh share a directory.
NOGH_PATH="$WORK/tmp/no-gh-path"; mkdir -p "$NOGH_PATH"
for b in jq grep date dirname; do
  bp=$(command -v "$b") && ln -sf "$bp" "$NOGH_PATH/$b"
done
out=$(PATH="$NOGH_PATH" /bin/sh "$SYNC" status 2>/dev/null); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "gh-missing" ]; } \
  && ok "sync reports a missing gh" \
  || ko "sync reports a missing gh (rc=$rc out=$out)"

# --- learner sync: memory.md three-way merge --------------------------------
M="$WORK/merge"; mkdir -p "$M"
mm() { sh "$SYNC" merge-memory "$M/base.md" "$M/local.md" "$M/remote.md"; }

# Row 1 of the spec's table: in the base, gone locally, still on the remote.
# The dev mastered it here; the merge must not resurrect it.
printf -- '- [Code][api] null handling — seen: 2026-09-01\n' > "$M/base.md"
: > "$M/local.md"
printf -- '- [Code][api] null handling — seen: 2026-09-01\n' > "$M/remote.md"
[ -z "$(mm)" ] \
  && ok "a line deleted locally stays deleted" \
  || ko "a line deleted locally stays deleted (got: $(mm))"

# Row 2: in the base, still local, gone from the remote.
printf -- '- [Code][api] null handling — seen: 2026-09-01\n' > "$M/base.md"
printf -- '- [Code][api] null handling — seen: 2026-09-01\n' > "$M/local.md"
: > "$M/remote.md"
[ -z "$(mm)" ] \
  && ok "a line deleted on the remote is dropped" \
  || ko "a line deleted on the remote is dropped (got: $(mm))"

# Rows 3 and 4: added on one side only, absent from the base — both survive.
: > "$M/base.md"
printf -- '- [Tests][api] fixture scope — seen: 2026-09-10\n' > "$M/local.md"
printf -- '- [CI/Build][web] cache keys — seen: 2026-09-12\n' > "$M/remote.md"
out=$(mm)
{ printf '%s' "$out" | grep -qF 'fixture scope' \
  && printf '%s' "$out" | grep -qF 'cache keys' \
  && [ "$(printf '%s\n' "$out" | grep -c .)" = 2 ]; } \
  && ok "additions from both sides are kept" \
  || ko "additions from both sides are kept (got: $out)"

# Row 5: both sides carry the line, different dates — the most recent wins, once.
printf -- '- [Code][api] retries — seen: 2026-09-01\n' > "$M/base.md"
printf -- '- [Code][api] retries — seen: 2026-09-05\n' > "$M/local.md"
printf -- '- [Code][api] retries — seen: 2026-09-14\n' > "$M/remote.md"
out=$(mm)
{ [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] \
  && printf '%s' "$out" | grep -qF 'seen: 2026-09-14'; } \
  && ok "the most recent date wins, and the line is not duplicated" \
  || ko "the most recent date wins, and the line is not duplicated (got: $out)"

# Whitespace must not fork one concept into two lines.
printf -- '- [Code][api] retries — seen: 2026-09-01\n' > "$M/base.md"
printf -- '-  [Code][api]  retries  — seen: 2026-09-05\n' > "$M/local.md"
printf -- '- [Code][api] retries — seen: 2026-09-14\n' > "$M/remote.md"
[ "$(mm | grep -c .)" = 1 ] \
  && ok "whitespace differences do not fork a concept in two" \
  || ko "whitespace differences do not fork a concept in two (got: $(mm))"

# No base at all (first pull on a new machine): union, nothing deleted.
rm -f "$M/base.md"
printf -- '- [Tests][api] fixture scope — seen: 2026-09-10\n' > "$M/local.md"
printf -- '- [Code][web] hydration — seen: 2026-09-11\n' > "$M/remote.md"
[ "$(mm | grep -c .)" = 2 ] \
  && ok "with no base the merge falls back to the union" \
  || ko "with no base the merge falls back to the union (got: $(mm))"
touch "$M/base.md"

# Non-entry lines come from the local file and stay at the top.
printf '# Working memory\n\n' > "$M/local.md"
printf -- '- [Code][web] hydration — seen: 2026-09-11\n' >> "$M/local.md"
: > "$M/remote.md"; : > "$M/base.md"
[ "$(mm | head -1)" = '# Working memory' ] \
  && ok "non-entry lines are preserved at the top" \
  || ko "non-entry lines are preserved at the top (got: $(mm | head -1))"

# --- learner sync: Session history union ------------------------------------
H="$WORK/hist"; mkdir -p "$H"
mh() { sh "$SYNC" merge-history "$H/local.md" "$H/remote.md"; }

cat > "$H/local.md" <<'EOF'
## Session history

| Date | Repo | Domain | Style | Verdict | Note | Theme |
|---|---|---|---|---|---|---|
| 2026-09-10 | api | Code | code | ✅ ok | clean | Error handling |
| 2026-09-12 | api | Tests | fill | ⚠️ revisit | fixtures | Test design |
EOF
cat > "$H/remote.md" <<'EOF'
| Date | Repo | Domain | Style | Verdict | Note | Theme |
|---|---|---|---|---|---|---|
| 2026-09-11 | web | Code | archi | ✅ ok | layering | Layering |
| 2026-09-12 | api | Tests | fill | ⚠️ revisit | fixtures | Test design |
EOF

out=$(mh)
[ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] \
  && ok "the history union drops the row both sides share" \
  || ko "the history union drops the row both sides share (got: $out)"

printf '%s\n' "$out" | grep -qE '^\|[^|]*Date' \
  && ko "the header row is not emitted" \
  || ok "the header row is not emitted"

printf '%s\n' "$out" | grep -qE '^\|[-| ]+\|$' \
  && ko "the separator row is not emitted" \
  || ok "the separator row is not emitted"

[ "$(printf '%s\n' "$out" | head -1 | cut -d'|' -f2 | tr -d ' ')" = "2026-09-10" ] \
  && [ "$(printf '%s\n' "$out" | tail -1 | cut -d'|' -f2 | tr -d ' ')" = "2026-09-12" ] \
  && ok "the merged history is sorted oldest first" \
  || ko "the merged history is sorted oldest first (got: $out)"

# Spacing inside the cells is cosmetic; it must not survive as a second row.
printf '|  2026-09-10 |  api | Code | code | ✅ ok | clean | Error handling |\n' > "$H/remote.md"
printf '| 2026-09-10 | api | Code | code | ✅ ok | clean | Error handling |\n' > "$H/local.md"
[ "$(mh | grep -c .)" = 1 ] \
  && ok "cell spacing does not duplicate a history row" \
  || ko "cell spacing does not duplicate a history row (got: $(mh))"

# --- learner sync: the snapshot ---------------------------------------------
SDATA="$WORK/cfg/learner"; mkdir -p "$SDATA"
snap() { rm -rf "$WORK/snap"; sh "$SYNC" snapshot "$WORK/snap"; }

rm -f "$SDATA/memory.md" "$SDATA/recap.md"
out=$(snap); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "empty-record" ] && [ ! -d "$WORK/snap" ]; } \
  && ok "an empty record is not snapshotted" \
  || ko "an empty record is not snapshotted (rc=$rc out=$out)"

printf '   \n\n' > "$SDATA/memory.md"
printf '\n' > "$SDATA/recap.md"
{ [ "$(snap | jq -r .error)" = "empty-record" ] && [ ! -d "$WORK/snap" ]; } \
  && ok "whitespace-only files still count as an empty record" \
  || ko "whitespace-only files still count as an empty record"

printf -- '- [Code][api] retries — seen: 2026-09-14\n' > "$SDATA/memory.md"
cat > "$SDATA/recap.md" <<'EOF'
## To improve

### Code
- Error and exception handling

## Session history

| Date | Repo | Domain | Style | Verdict | Note | Theme |
|---|---|---|---|---|---|---|
| 2026-09-14 | api | Code | code | ✅ ok | fine | Error and exception handling |
EOF
cat > "$SDATA/libs.md" <<'EOF'
# Libraries covered

| Library | Seen | Angle covered | Verdict |
|---------|------|---------------|---------|
| argon2 | 2026-09-18 | cost parameters (t, m) | ⚠️ revisit |
EOF
echo '{"level":"S"}' > "$GCFG"
out=$(snap)
man="$WORK/snap/manifest.json"
{ [ "$(printf '%s' "$out" | jq -r .ok)" = "true" ] \
  && [ -f "$WORK/snap/memory.md" ] && [ -f "$WORK/snap/recap.md" ] \
  && [ -f "$WORK/snap/libs.md" ] \
  && [ -f "$WORK/snap/learner.json" ] && [ -f "$man" ]; } \
  && ok "the snapshot holds the five files" \
  || ko "the snapshot holds the five files (out=$out)"

{ [ "$(jq -r .schemaVersion "$man")" = "1" ] \
  && [ "$(jq -r .counts.memoryLines "$man")" = "1" ] \
  && [ "$(jq -r .counts.themeLines "$man")" = "1" ] \
  && [ "$(jq -r .counts.historyRows "$man")" = "1" ] \
  && [ "$(jq -r .counts.libsRows "$man")" = "1" ] \
  && [ -n "$(jq -r .pushedAt "$man")" ]; } \
  && ok "the manifest counts lines, not meaning" \
  || ko "the manifest counts lines, not meaning ($(cat "$man"))"

diff -q "$SDATA/memory.md" "$WORK/snap/memory.md" >/dev/null \
  && ok "memory.md is snapshotted verbatim" \
  || ko "memory.md is snapshotted verbatim"

diff -q "$SDATA/libs.md" "$WORK/snap/libs.md" >/dev/null \
  && ok "libs.md is snapshotted verbatim" \
  || ko "libs.md is snapshotted verbatim"

printf 'This is a real file with content but no bullets\n' > "$SDATA/memory.md"
printf '## To improve\n\nNo bullets here, only the table.\n' > "$SDATA/recap.md"
out=$(snap)
man="$WORK/snap/manifest.json"
{ [ "$(printf '%s' "$out" | jq -r .ok)" = "true" ] \
  && [ "$(jq -r .counts.memoryLines "$man")" = "0" ] \
  && [ "$(jq -r .counts.themeLines "$man")" = "0" ]; } \
  && ok "files with real content but zero bullets snapshot successfully" \
  || ko "files with real content but zero bullets snapshot successfully (out=$out man=$(cat "$man"))"

# Item 1 sweep regression: three "else : > …" fallbacks in snapshot_into (one
# per gist file) each hit the same special-built-in abort as coach-watch.sh's
# above. `mkdir -p "$_sd"` only proves the destination exists, not that it is
# writable, and it succeeds unconditionally on one that already exists
# read-only. `:` is a POSIX special built-in, so a redirection failure on it
# aborts a non-interactive shell outright under dash — before this script's
# own fail() ever gets to print its one JSON object. memory.md and libs.md are
# both absent here (their two guarded lines run directly); recap.md's own cp
# (REC_FILE has content, satisfying has_content) fails ordinarily instead of
# aborting, and the manifest write further down still catches the underlying
# unwritable directory through fail() — proof the abort no longer escapes
# unguarded.
rm -f "$SDATA/memory.md" "$SDATA/libs.md"
printf '## To improve\n\n### Code\n- Error handling\n' > "$SDATA/recap.md"
SNAP_RO="$WORK/snap-ro"; rm -rf "$SNAP_RO"; mkdir -p "$SNAP_RO"; chmod 555 "$SNAP_RO"
out=$(sh "$SYNC" snapshot "$SNAP_RO" 2>/dev/null); rc=$?
chmod 755 "$SNAP_RO"
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "manifest" ]; } \
  && ok "a snapshot into a read-only destination fails cleanly through fail(), not a shell abort" \
  || ko "a snapshot into a read-only destination fails cleanly through fail(), not a shell abort (rc=$rc out=$out)"
if command -v dash >/dev/null 2>&1; then
  rm -rf "$SNAP_RO"; mkdir -p "$SNAP_RO"; chmod 555 "$SNAP_RO"
  out=$(dash "$SYNC" snapshot "$SNAP_RO" 2>/dev/null); rc=$?
  chmod 755 "$SNAP_RO"
  { [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "manifest" ]; } \
    && ok "a snapshot into a read-only destination fails cleanly through fail() under dash" \
    || ko "a snapshot into a read-only destination fails cleanly through fail() under dash (rc=$rc out=$out)"
else
  echo "  (dash not found on this machine — the dash-specific read-only-snapshot check was skipped, coverage not claimed)"
fi
rm -rf "$SNAP_RO"

# --- learner sync: push -----------------------------------------------------
# Replace Task 1's minimal fake gh with a fuller one that serves a "remote gist"
# out of $GH_REMOTE and logs argv to $GH_LOG, now that push needs create/patch/view.
cat > "$WORK/bin/gh" <<'GHFAKE'
#!/bin/sh
# Fake gh: serves a "remote gist" out of $GH_REMOTE, logs argv to $GH_LOG.
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$1 $2" in
  "auth status") exit "${GH_AUTH:-0}" ;;
  "gist create")
    mkdir -p "$GH_REMOTE"
    for f in "$@"; do [ -f "$f" ] && cp "$f" "$GH_REMOTE/$(basename "$f")"; done
    printf 'https://gist.github.com/%s\n' "${GH_GIST_ID:-abc123}"
    exit 0 ;;
  "gist list")
    cat "${GH_LIST:-/dev/null}" 2>/dev/null; exit 0 ;;
  "gist view")
    # gh gist view <id> -f <name> --raw
    shift 3; name=""
    while [ $# -gt 0 ]; do case "$1" in -f) name=$2; shift 2 ;; *) shift ;; esac; done
    [ -f "$GH_REMOTE/$name" ] || exit 1
    cat "$GH_REMOTE/$name"; exit 0 ;;
esac
if [ "$1" = "api" ]; then
  [ -n "${GH_FAIL_API:-}" ] && { cat >/dev/null; exit 1; }
  payload=$(cat)
  mkdir -p "$GH_REMOTE"
  printf '%s' "$payload" | jq -r '.files | keys[]' | while read -r k; do
    printf '%s' "$payload" | jq -r --arg k "$k" '.files[$k].content' > "$GH_REMOTE/$k"
  done
  printf '{"id":"%s"}\n' "${GH_GIST_ID:-abc123}"
  exit 0
fi
exit 0
GHFAKE
chmod +x "$WORK/bin/gh"
export GH_REMOTE="$WORK/remote"; export GH_GIST_ID="abc123"

rm -rf "$GH_REMOTE" "$SDATA/sync.json" "$SDATA/sync-base"
printf -- '- [Code][api] retries — seen: 2026-09-14\n' > "$SDATA/memory.md"
printf '## To improve\n\n### Code\n- Error and exception handling\n' > "$SDATA/recap.md"
printf '| Library | Seen | Angle covered | Verdict |\n|---|---|---|---|\n| argon2 | 2026-09-18 | cost parameters (t, m) | ⚠️ revisit |\n' > "$SDATA/libs.md"

out=$(sh "$SYNC" push); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "needs-create-ok" ] \
  && [ ! -d "$GH_REMOTE" ]; } \
  && ok "the first push refuses to create a gist without --create-ok" \
  || ko "the first push refuses to create a gist without --create-ok (rc=$rc out=$out)"

out=$(sh "$SYNC" push --create-ok)
{ [ "$(printf '%s' "$out" | jq -r .action)" = "created" ] \
  && [ "$(printf '%s' "$out" | jq -r .gistId)" = "abc123" ] \
  && [ -f "$GH_REMOTE/memory.md" ] && [ -f "$GH_REMOTE/manifest.json" ]; } \
  && ok "--create-ok creates the gist and uploads the five files" \
  || ko "--create-ok creates the gist and uploads the five files (out=$out)"

grep -qF 'argon2' "$GH_REMOTE/libs.md" \
  && ok "the created gist carries libs.md" \
  || ko "the created gist carries libs.md ($(cat "$GH_REMOTE/libs.md" 2>/dev/null))"

grep -q -- '--secret' "$GH_LOG" \
  && ok "the gist is created secret, never public" \
  || ko "the gist is created secret, never public"

{ [ "$(jq -r .github.gistId "$SDATA/sync.json")" = "abc123" ] \
  && [ -n "$(jq -r .github.lastPush "$SDATA/sync.json")" ] \
  && [ -f "$SDATA/sync-base/manifest.json" ]; } \
  && ok "a successful push records the gist and advances the base" \
  || ko "a successful push records the gist and advances the base"

printf -- '- [Tests][api] fixtures — seen: 2026-09-15\n' >> "$SDATA/memory.md"
printf '| zod | 2026-09-19 | refine vs superRefine | ✅ ok |\n' >> "$SDATA/libs.md"
out=$(sh "$SYNC" push)
{ [ "$(printf '%s' "$out" | jq -r .action)" = "updated" ] \
  && [ "$(grep -c 'fixtures' "$GH_REMOTE/memory.md")" = 1 ]; } \
  && ok "a later push updates the same gist without asking again" \
  || ko "a later push updates the same gist without asking again (out=$out)"

grep -qF 'zod' "$GH_REMOTE/libs.md" \
  && ok "a later push updates libs.md on the same gist too" \
  || ko "a later push updates libs.md on the same gist too ($(cat "$GH_REMOTE/libs.md"))"

# A remote pushedAt exactly equal to the base (the normal case right after a
# clean sync) must not trip the guard — only a remote strictly newer does.
_at=$(jq -r .pushedAt "$SDATA/sync-base/manifest.json")
jq --arg at "$_at" '.pushedAt = $at' "$GH_REMOTE/manifest.json" > "$WORK/m.tmp" \
  && mv "$WORK/m.tmp" "$GH_REMOTE/manifest.json"
out=$(sh "$SYNC" push); rc=$?
{ [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.error // empty')" = "" ] \
  && [ "$(printf '%s' "$out" | jq -r .action)" = "updated" ]; } \
  && ok "a remote pushedAt equal to the base does not trip remote-ahead" \
  || ko "a remote pushedAt equal to the base does not trip remote-ahead (rc=$rc out=$out)"

# The other machine pushed since our last sync: refuse rather than overwrite it.
jq '.pushedAt = "2099-01-01T00:00:00Z"' "$GH_REMOTE/manifest.json" > "$WORK/m.tmp" \
  && mv "$WORK/m.tmp" "$GH_REMOTE/manifest.json"
cp "$GH_REMOTE/memory.md" "$WORK/remote-memory-before"
out=$(sh "$SYNC" push); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "remote-ahead" ] \
  && diff -q "$WORK/remote-memory-before" "$GH_REMOTE/memory.md" >/dev/null; } \
  && ok "a push refuses to overwrite a remote that moved since the base" \
  || ko "a push refuses to overwrite a remote that moved since the base (rc=$rc out=$out)"

# A failed upload must leave the base where it was, or the next pull would read
# the remote as an ancestor and delete what the other machine added.
cp "$SDATA/sync-base/manifest.json" "$WORK/base-before"
jq '.pushedAt = "2000-01-01T00:00:00Z"' "$GH_REMOTE/manifest.json" > "$WORK/m.tmp" \
  && mv "$WORK/m.tmp" "$GH_REMOTE/manifest.json"
out=$(GH_FAIL_API=1 sh "$SYNC" push); rc=$?
{ [ "$rc" = 1 ] && diff -q "$WORK/base-before" "$SDATA/sync-base/manifest.json" >/dev/null; } \
  && ok "a failed push leaves the base untouched" \
  || ko "a failed push leaves the base untouched (rc=$rc out=$out)"

# A libs.md that has SHRUNK against the base must not be pushed. advance_base
# keeps no base copy of libs.md and cmd_status counts no unpushed libs rows, so
# nothing downstream can notice: machine A pushes five rows, machine B pulls,
# the model writes recap.md but skips sync.md's step 4 libs union (a documented
# model instruction with no code behind it), pull-finish adopts the work dir and
# equalises the timestamps — so remote-ahead cannot fire either — and B's next
# push replaces five rows with an empty file, ok:true, unrecoverably. The base
# manifest's counts.libsRows is the one record of what the last sync agreed on.
cp "$SDATA/libs.md" "$WORK/libs-local-before"
cp "$GH_REMOTE/libs.md" "$WORK/libs-remote-before"
: > "$SDATA/libs.md"
out=$(sh "$SYNC" push); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "needs-pull" ] \
  && diff -q "$WORK/libs-remote-before" "$GH_REMOTE/libs.md" >/dev/null; } \
  && ok "a push whose libs.md shrank against the base refuses instead of truncating the remote" \
  || ko "a push whose libs.md shrank against the base refuses instead of truncating the remote (rc=$rc out=$out)"

# The same push with the rows back must go through, so the guard is about the
# shrink and not about libs.md in general.
cp "$WORK/libs-local-before" "$SDATA/libs.md"
out=$(sh "$SYNC" push); rc=$?
{ [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r .action)" = "updated" ]; } \
  && ok "a push with libs.md intact still goes through" \
  || ko "a push with libs.md intact still goes through (rc=$rc out=$out)"

# --- learner sync: pull -----------------------------------------------------
setup_pull() {   # a remote that has moved, and a local that has moved differently
  rm -rf "$GH_REMOTE" "$SDATA/sync-base" "$SDATA/backups"; mkdir -p "$GH_REMOTE"
  printf -- '- [Code][api] retries — seen: 2026-09-14\n' > "$GH_REMOTE/memory.md"
  printf -- '- [Code][web] hydration — seen: 2026-09-15\n' >> "$GH_REMOTE/memory.md"
  printf '## To improve\n\n### Code\n- Error and exception handling\n' > "$GH_REMOTE/recap.md"
  echo '{"level":"E","disabledPaths":["/remote/only"]}' > "$GH_REMOTE/learner.json"
  jq -n '{schemaVersion:1,pushedAt:"2026-09-15T10:00:00Z",pushedFrom:"other",
          learnerVersion:"0.2.0",counts:{memoryLines:2,themeLines:1,historyRows:0}}' \
    > "$GH_REMOTE/manifest.json"
  printf -- '- [Code][api] retries — seen: 2026-09-14\n' > "$SDATA/memory.md"
  printf -- '- [Tests][api] fixtures — seen: 2026-09-16\n' >> "$SDATA/memory.md"
  printf '## To improve\n\n### Tests\n- Test design\n' > "$SDATA/recap.md"
  echo '{"level":"S","disabledPaths":["/local/only"]}' > "$GCFG"
  jq -n '{github:{gistId:"abc123"}}' > "$SDATA/sync.json"
}

setup_pull
out=$(sh "$SYNC" pull)
{ [ "$(printf '%s' "$out" | jq -r .ok)" = "true" ] \
  && [ "$(printf '%s' "$out" | jq -r .gistId)" = "abc123" ]; } \
  && ok "pull resolves the recorded gist" \
  || ko "pull resolves the recorded gist (out=$out)"

{ grep -qF 'hydration' "$SDATA/memory.md" \
  && grep -qF 'fixtures' "$SDATA/memory.md" \
  && grep -qF 'retries' "$SDATA/memory.md"; } \
  && ok "pull merges memory.md from both sides" \
  || ko "pull merges memory.md from both sides ($(cat "$SDATA/memory.md"))"

bk=$(printf '%s' "$out" | jq -r .backup)
{ [ -d "$bk" ] && grep -qF 'fixtures' "$bk/memory.md"; } \
  && ok "pull backs the local record up before writing" \
  || ko "pull backs the local record up before writing (bk=$bk)"

# Item 2: backup_local's loop already reads
# `for f in "$MEM_FILE" "$REC_FILE" "$LIBS_FILE" "$CFG_FILE"`, but nothing
# pinned $LIBS_FILE specifically — a mutation test found that dropping it from
# that loop changed nothing in this suite. Distinct, greppable content in
# libs.md before a pull, checked against the backup that same pull makes.
setup_pull
printf '| Library | Seen | Angle covered | Verdict |\n|---|---|---|---|\n| item2-pin | 2026-09-19 | mutation guard | ✅ ok |\n' > "$SDATA/libs.md"
out=$(sh "$SYNC" pull)
bk2=$(printf '%s' "$out" | jq -r .backup)
{ [ -d "$bk2" ] && grep -qF 'item2-pin' "$bk2/libs.md"; } \
  && ok "pull's backup carries libs.md too, not just memory.md" \
  || ko "pull's backup carries libs.md too, not just memory.md (bk=$bk2)"

grep -qF 'Test design' "$SDATA/recap.md" \
  && ok "pull leaves recap.md to the model" \
  || ko "pull leaves recap.md to the model"

{ [ "$(jq -r .level "$GCFG")" = "E" ] \
  && [ "$(jq -r '.disabledPaths | sort | join(",")' "$GCFG")" = "/local/only,/remote/only" ]; } \
  && ok "the remote config wins but disabledPaths union" \
  || ko "the remote config wins but disabledPaths union ($(cat "$GCFG"))"

[ ! -d "$SDATA/sync-base" ] \
  && ok "pull does not advance the base before the recap is written" \
  || ko "pull does not advance the base before the recap is written"

work=$(printf '%s' "$out" | jq -r .work)
out2=$(sh "$SYNC" pull-finish "$work")
{ [ "$(printf '%s' "$out2" | jq -r .ok)" = "true" ] \
  && diff -q "$GH_REMOTE/recap.md" "$SDATA/sync-base/recap.md" >/dev/null \
  && [ -n "$(jq -r .github.lastPull "$SDATA/sync.json")" ]; } \
  && ok "pull-finish adopts the remote snapshot as the base" \
  || ko "pull-finish adopts the remote snapshot as the base (out=$out2)"

# A snapshot from a newer learner is refused, not guessed at.
setup_pull
jq '.schemaVersion = 99' "$GH_REMOTE/manifest.json" > "$WORK/m.tmp" && mv "$WORK/m.tmp" "$GH_REMOTE/manifest.json"
cp "$SDATA/memory.md" "$WORK/mem-before"
out=$(sh "$SYNC" pull); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "schema-too-new" ] \
  && diff -q "$WORK/mem-before" "$SDATA/memory.md" >/dev/null; } \
  && ok "a newer schemaVersion stops the pull before any write" \
  || ko "a newer schemaVersion stops the pull before any write (rc=$rc out=$out)"

# New machine: no sync.json, exactly one gist carries the description.
setup_pull
rm -f "$SDATA/sync.json"
printf 'abc123\tclaude-learner-state\t4 files\n' > "$WORK/list.txt"
out=$(GH_LIST="$WORK/list.txt" sh "$SYNC" pull)
{ [ "$(printf '%s' "$out" | jq -r .gistId)" = "abc123" ] \
  && [ "$(jq -r .github.gistId "$SDATA/sync.json")" = "abc123" ]; } \
  && ok "pull adopts the single gist that carries the marker description" \
  || ko "pull adopts the single gist that carries the marker description (out=$out)"

setup_pull
rm -f "$SDATA/sync.json"
printf 'abc123\tclaude-learner-state\t4 files\ndef456\tclaude-learner-state\t4 files\n' > "$WORK/list.txt"
out=$(GH_LIST="$WORK/list.txt" sh "$SYNC" pull); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "ambiguous-gist" ]; } \
  && ok "two candidate gists stop the pull instead of a coin toss" \
  || ko "two candidate gists stop the pull instead of a coin toss (rc=$rc out=$out)"

setup_pull
rm -f "$SDATA/sync.json"
out=$(GH_LIST=/dev/null sh "$SYNC" pull); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "no-gist" ]; } \
  && ok "no recorded and no discoverable gist is a named error" \
  || ko "no recorded and no discoverable gist is a named error (rc=$rc out=$out)"

# First sync on this machine: no base, so nothing may be read as a deletion.
setup_pull
rm -rf "$SDATA/sync-base"
out=$(sh "$SYNC" pull)
{ [ "$(printf '%s' "$out" | jq -r .firstSync)" = "true" ] \
  && [ "$(grep -c '^- ' "$SDATA/memory.md")" = 3 ]; } \
  && ok "with no base the pull unions and says so" \
  || ko "with no base the pull unions and says so (out=$out)"

# --- learner sync: status and use -------------------------------------------
setup_pull
rm -rf "$SDATA/sync-base"
out=$(sh "$SYNC" status)
{ [ "$(printf '%s' "$out" | jq -r .gistId)" = "abc123" ] \
  && [ "$(printf '%s' "$out" | jq -r .hasBase)" = "false" ]; } \
  && ok "status reports a missing base instead of inventing drift" \
  || ko "status reports a missing base instead of inventing drift (out=$out)"

mkdir -p "$SDATA/sync-base"
printf -- '- [Code][api] retries — seen: 2026-09-14\n' > "$SDATA/sync-base/memory.md"
printf '## To improve\n' > "$SDATA/sync-base/recap.md"
jq -n '{schemaVersion:1,pushedAt:"2026-09-15T10:00:00Z"}' > "$SDATA/sync-base/manifest.json"
out=$(sh "$SYNC" status)
{ [ "$(printf '%s' "$out" | jq -r .unpushed.memoryLines)" = "1" ] \
  && [ "$(printf '%s' "$out" | jq -r .remoteAhead)" = "false" ]; } \
  && ok "status counts what the local side holds beyond the base" \
  || ko "status counts what the local side holds beyond the base (out=$out)"

jq '.pushedAt = "2099-01-01T00:00:00Z"' "$GH_REMOTE/manifest.json" > "$WORK/m.tmp" \
  && mv "$WORK/m.tmp" "$GH_REMOTE/manifest.json"
[ "$(sh "$SYNC" status | jq -r .remoteAhead)" = "true" ] \
  && ok "status sees a remote that has moved ahead of the base" \
  || ko "status sees a remote that has moved ahead of the base"

cp "$SDATA/memory.md" "$WORK/mem-before"
sh "$SYNC" status >/dev/null
diff -q "$WORK/mem-before" "$SDATA/memory.md" >/dev/null \
  && ok "status writes nothing" \
  || ko "status writes nothing"

out=$(sh "$SYNC" use https://gist.github.com/zzz999)
{ [ "$(printf '%s' "$out" | jq -r .gistId)" = "zzz999" ] \
  && [ "$(jq -r .github.gistId "$SDATA/sync.json")" = "zzz999" ] \
  && [ ! -d "$SDATA/sync-base" ]; } \
  && ok "use repoints the gist and clears the base" \
  || ko "use repoints the gist and clears the base (out=$out)"

out=$(sh "$SYNC" use 2>/dev/null); rc=$?
[ "$rc" = 2 ] \
  && ok "use with no argument is a usage error" \
  || ko "use with no argument is a usage error (rc=$rc)"

# --- learner sync: Critical 1 — a partial download must not read as a mass delete -----
# The fake gh's "gist view" exits 1 when the requested file is missing from $GH_REMOTE,
# which stands in for a network blip / rate limit on that one `gh gist view` call.
setup_pull
rm -f "$GH_REMOTE/memory.md"
cp "$SDATA/memory.md" "$WORK/mem-before"
out=$(sh "$SYNC" pull); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "gh-fetch" ] \
  && diff -q "$WORK/mem-before" "$SDATA/memory.md" >/dev/null; } \
  && ok "a failed memory.md fetch fails the pull instead of reading the remote as empty" \
  || ko "a failed memory.md fetch fails the pull instead of reading the remote as empty (rc=$rc out=$out)"

# The fetch itself can succeed while the gist still answers with less than its own
# manifest promises (a truncated upload, a stale CDN edge, ...). setup_pull's remote
# manifest declares counts.memoryLines: 2.
setup_pull
: > "$GH_REMOTE/memory.md"
cp "$SDATA/memory.md" "$WORK/mem-before"
out=$(sh "$SYNC" pull); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "gh-fetch" ] \
  && diff -q "$WORK/mem-before" "$SDATA/memory.md" >/dev/null; } \
  && ok "a remote memory.md truncated relative to its own manifest counts fails the pull" \
  || ko "a remote memory.md truncated relative to its own manifest counts fails the pull (rc=$rc out=$out)"

# --- learner sync: Critical 4 — a failed libs.md fetch must not silently empty a
# populated remote ledger --------------------------------------------------------------
# libs.md is fetched leniently (a gist from before this feature legitimately has none), so
# on its own a missing/failed fetch reads as "nothing to union" rather than an error. The
# manifest guard is what tells the two apart: setup_pull's remote here declares
# counts.libsRows: 1, so a fetch that comes back empty against that promise must fail the
# whole pull, exactly like Critical 1 does for memory.md.
setup_pull
jq '.counts.libsRows = 1' "$GH_REMOTE/manifest.json" > "$WORK/m.tmp" && mv "$WORK/m.tmp" "$GH_REMOTE/manifest.json"
# $GH_REMOTE/libs.md is deliberately absent: the fake gh's "gist view" exits 1 when the
# named file is missing, standing in for the network blip Critical 1 also models.
printf '' > "$SDATA/libs.md"
cp "$SDATA/libs.md" "$WORK/libs-before"
out=$(sh "$SYNC" pull); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "gh-fetch" ] \
  && diff -q "$WORK/libs-before" "$SDATA/libs.md" >/dev/null \
  && [ ! -d "$SDATA/sync-base" ]; } \
  && ok "a failed libs.md fetch on a populated remote fails the pull instead of emptying it" \
  || ko "a failed libs.md fetch on a populated remote fails the pull instead of emptying it (rc=$rc out=$out)"

# The same manifest-declared count also catches a truncated-but-present fetch (an
# empty file where content was promised), the same failure mode Critical 1 covers for
# memory.md with `: > "$GH_REMOTE/memory.md"`.
setup_pull
jq '.counts.libsRows = 1' "$GH_REMOTE/manifest.json" > "$WORK/m.tmp" && mv "$WORK/m.tmp" "$GH_REMOTE/manifest.json"
: > "$GH_REMOTE/libs.md"
printf '' > "$SDATA/libs.md"
cp "$SDATA/libs.md" "$WORK/libs-before"
out=$(sh "$SYNC" pull); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "gh-fetch" ] \
  && diff -q "$WORK/libs-before" "$SDATA/libs.md" >/dev/null; } \
  && ok "a remote libs.md truncated relative to its own manifest counts fails the pull" \
  || ko "a remote libs.md truncated relative to its own manifest counts fails the pull (rc=$rc out=$out)"

# The happy path: a gist that does carry a populated libs.md hands its content back for
# the model to union, exactly like recap's `local`/`remote` paths.
setup_pull
printf '| Library | Seen | Angle covered | Verdict |\n|---|---|---|---|\n| argon2 | 2026-09-18 | cost parameters (t, m) | ⚠️ revisit |\n' > "$GH_REMOTE/libs.md"
jq '.counts.libsRows = 1' "$GH_REMOTE/manifest.json" > "$WORK/m.tmp" && mv "$WORK/m.tmp" "$GH_REMOTE/manifest.json"
out=$(sh "$SYNC" pull)
lr=$(printf '%s' "$out" | jq -r .libs.remote)
{ [ -n "$lr" ] && grep -qF 'argon2' "$lr"; } \
  && ok "a pull hands back a non-empty libs.remote when the gist has one" \
  || ko "a pull hands back a non-empty libs.remote when the gist has one (out=$out)"

# A gist that predates this feature has no libs.md and no counts.libsRows at all: the
# lenient fetch reads that as "nothing to union", not an error — this is the case the
# manifest-declared-count guard above must not turn red.
setup_pull
out=$(sh "$SYNC" pull); rc=$?
lr=$(printf '%s' "$out" | jq -r .libs.remote)
{ [ "$rc" = 0 ] && [ -n "$lr" ] && [ ! -s "$lr" ]; } \
  && ok "a gist with no libs.md at all still pulls cleanly" \
  || ko "a gist with no libs.md at all still pulls cleanly (rc=$rc out=$out)"

# --- learner sync: Critical 2 — push refuses to clobber when there is no base ----------
# This is exactly the state `sync use` (and a fresh `pull <gist>`) creates: a gistId is
# recorded, sync-base/ is not.
setup_pull
cp "$GH_REMOTE/memory.md" "$WORK/remote-mem-before"
out=$(sh "$SYNC" push); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "needs-pull" ] \
  && diff -q "$WORK/remote-mem-before" "$GH_REMOTE/memory.md" >/dev/null; } \
  && ok "push with a recorded gist but no base refuses with needs-pull, remote untouched" \
  || ko "push with a recorded gist but no base refuses with needs-pull, remote untouched (rc=$rc out=$out)"

pull_out=$(sh "$SYNC" pull)
work=$(printf '%s' "$pull_out" | jq -r .work)
sh "$SYNC" pull-finish "$work" >/dev/null
out=$(sh "$SYNC" push); rc=$?
{ [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r .action)" = "updated" ]; } \
  && ok "after a pull and pull-finish, the same push succeeds" \
  || ko "after a pull and pull-finish, the same push succeeds (rc=$rc out=$out)"

grep -qF 'needs-pull' "$SYNCMD" \
  && ok "sync.md documents the needs-pull push error" \
  || ko "sync.md documents the needs-pull push error"

# --- learner sync: Critical 3 — a failed backup must stop the pull, not just its subshell ---
setup_pull
rm -rf "$SDATA/backups"
: > "$SDATA/backups"    # a plain file blocks mkdir -p "$SDATA/backups/<timestamp>"
cp "$SDATA/memory.md" "$WORK/mem-before"
out=$(sh "$SYNC" pull 2>/dev/null); rc=$?
lines=$(printf '%s\n' "$out" | grep -c .)
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "backup-dir" ] \
  && [ "$lines" = 1 ] && diff -q "$WORK/mem-before" "$SDATA/memory.md" >/dev/null; } \
  && ok "a pull whose backup dir cannot be created fails cleanly with one JSON object, no write" \
  || ko "a pull whose backup dir cannot be created fails cleanly with one JSON object, no write (rc=$rc out=$out)"
rm -f "$SDATA/backups"

# Item 1 sweep regression: cmd_pull's own lenient libs.md fallback (the guard
# right above "libs.md is fetched leniently") ends in the same special-built-in
# abort as the snapshot_into sites above. `:` is a POSIX special built-in, so a
# redirection failure on it aborts a non-interactive shell outright under dash
# — before this script's own fail() ever runs, and before the `||` on this
# very line. $_work is mktemp's own fresh directory, so it is always writable
# the instant cmd_pull gets it; reproducing "exists but cannot be written into"
# means intercepting mktemp itself here, standing in for a TMPDIR remounted
# read-only mid-session. The interceptor only touches `-d` calls, passing
# everything else straight to the real mktemp, so readable_or_empty's own
# single-file mktemp (a separate, pre-existing, explicitly out-of-scope leak)
# is untouched.
setup_pull
REAL_MKTEMP=$(command -v mktemp)
ROMKTEMP="$WORK/ro-mktemp-bin"; rm -rf "$ROMKTEMP"; mkdir -p "$ROMKTEMP"
cat > "$ROMKTEMP/mktemp" <<MKFAKE
#!/bin/sh
case " \$* " in
  *" -d "*)
    d=\$("$REAL_MKTEMP" "\$@") || exit 1
    # Same guard this whole batch exists to apply: \`:\` is a POSIX special
    # built-in, so an unguarded redirection failure on it would abort this
    # helper outright under dash. It cannot realistically fail here (\$d is a
    # mktemp -d fresh directory), but this script is itself #!/bin/sh, and
    # leaving the bare form in the test that exercises this exact defect
    # would be the one inconsistency in a batch about eliminating it.
    ( : > "\$d/libs.md" ) 2>/dev/null || :
    chmod 444 "\$d/libs.md" 2>/dev/null
    printf '%s\n' "\$d"
    ;;
  *)
    exec "$REAL_MKTEMP" "\$@"
    ;;
esac
MKFAKE
chmod +x "$ROMKTEMP/mktemp"
out=$(PATH="$ROMKTEMP:$PATH" sh "$SYNC" pull 2>/dev/null); rc=$?
lines=$(printf '%s\n' "$out" | grep -c .)
{ [ "$rc" = 0 ] && [ "$lines" = 1 ] && printf '%s' "$out" | jq -e .ok >/dev/null 2>&1; } \
  && ok "a pull whose lenient libs.md placeholder cannot be truncated still completes cleanly" \
  || ko "a pull whose lenient libs.md placeholder cannot be truncated still completes cleanly (rc=$rc out=$out)"
if command -v dash >/dev/null 2>&1; then
  setup_pull
  out=$(PATH="$ROMKTEMP:$PATH" dash "$SYNC" pull 2>/dev/null); rc=$?
  lines=$(printf '%s\n' "$out" | grep -c .)
  { [ "$rc" = 0 ] && [ "$lines" = 1 ] && printf '%s' "$out" | jq -e .ok >/dev/null 2>&1; } \
    && ok "a pull whose lenient libs.md placeholder cannot be truncated still completes cleanly under dash" \
    || ko "a pull whose lenient libs.md placeholder cannot be truncated still completes cleanly under dash (rc=$rc out=$out)"
else
  echo "  (dash not found on this machine — the dash-specific read-only-libs.md-placeholder check was skipped, coverage not claimed)"
fi
rm -rf "$ROMKTEMP"

# --- learner sync: Important 4 — pull <gist> drops a stale base from a different gist ---
setup_pull
jq -n '{github:{gistId:"gist-A"}}' > "$SDATA/sync.json"
mkdir -p "$SDATA/sync-base"
printf -- '- [Code][api] gistA-only — seen: 2026-09-10\n' > "$SDATA/sync-base/memory.md"
: > "$SDATA/sync-base/recap.md"
jq -n '{schemaVersion:1,pushedAt:"2026-09-10T00:00:00Z"}' > "$SDATA/sync-base/manifest.json"
printf -- '- [Code][api] gistA-only — seen: 2026-09-10\n' > "$SDATA/memory.md"
printf '## To improve\n' > "$SDATA/recap.md"
# GH_REMOTE now stands in for a *different* gist, which never held gistA-only.
sh "$SYNC" pull "https://gist.github.com/gist-B" >/dev/null
grep -qF 'gistA-only' "$SDATA/memory.md" \
  && ok "pull <gist> with a different id drops the stale base instead of reading it as an ancestor" \
  || ko "pull <gist> with a different id drops the stale base instead of reading it as an ancestor ($(cat "$SDATA/memory.md"))"

# --- learner sync: Important 6 — a two-machine round trip loses nothing from either side ---
A="$WORK/machineA"; B="$WORK/machineB"
rm -rf "$A" "$B" "$GH_REMOTE"; mkdir -p "$A/learner" "$B/learner"

printf -- '- [Code][api] A-weak-spot — seen: 2026-09-10\n' > "$A/learner/memory.md"
printf '## To improve\n\n### Code\n- A theme\n' > "$A/learner/recap.md"

out=$(CLAUDE_CONFIG_DIR="$A" sh "$SYNC" push --create-ok)
{ [ "$(printf '%s' "$out" | jq -r .action)" = "created" ]; } \
  && ok "round trip: machine A creates the gist" \
  || ko "round trip: machine A creates the gist (out=$out)"

printf -- '- [Tests][api] B-weak-spot — seen: 2026-09-11\n' > "$B/learner/memory.md"
printf '## To improve\n\n### Tests\n- B theme\n' > "$B/learner/recap.md"
pull_out=$(CLAUDE_CONFIG_DIR="$B" sh "$SYNC" pull "https://gist.github.com/$GH_GIST_ID")
work=$(printf '%s' "$pull_out" | jq -r .work)
CLAUDE_CONFIG_DIR="$B" sh "$SYNC" pull-finish "$work" >/dev/null
{ grep -qF 'A-weak-spot' "$B/learner/memory.md" && grep -qF 'B-weak-spot' "$B/learner/memory.md"; } \
  && ok "round trip: machine B's pull merges in A's line and keeps its own" \
  || ko "round trip: machine B's pull merges in A's line and keeps its own ($(cat "$B/learner/memory.md"))"

out=$(CLAUDE_CONFIG_DIR="$B" sh "$SYNC" push)
{ [ "$(printf '%s' "$out" | jq -r .action)" = "updated" ]; } \
  && ok "round trip: machine B pushes its merged state back" \
  || ko "round trip: machine B pushes its merged state back (out=$out)"

pull_out=$(CLAUDE_CONFIG_DIR="$A" sh "$SYNC" pull)
work=$(printf '%s' "$pull_out" | jq -r .work)
CLAUDE_CONFIG_DIR="$A" sh "$SYNC" pull-finish "$work" >/dev/null
{ grep -qF 'A-weak-spot' "$A/learner/memory.md" && grep -qF 'B-weak-spot' "$A/learner/memory.md"; } \
  && ok "round trip: neither machine loses a line after the full push/pull cycle" \
  || ko "round trip: neither machine loses a line after the full push/pull cycle ($(cat "$A/learner/memory.md"))"

# sync-base/ must only ever describe a state both sides actually held.
{ grep -qF 'A-weak-spot' "$A/learner/sync-base/memory.md" \
  && grep -qF 'B-weak-spot' "$A/learner/sync-base/memory.md"; } \
  && ok "round trip: the base after the cycle reflects only content both sides agreed on" \
  || ko "round trip: the base after the cycle reflects only content both sides agreed on ($(cat "$A/learner/sync-base/memory.md"))"

# --- learner sync: Important 5 — sync.md documents the rest of the pull error slugs -----
grep -qF 'no-work-dir' "$SYNCMD" \
  && ok "sync.md documents the no-work-dir pull-finish error" \
  || ko "sync.md documents the no-work-dir pull-finish error"

grep -qiF 'already be merged' "$SYNCMD" \
  && grep -qiF 'pull-finish' "$SYNCMD" \
  && ok "sync.md's pull table warns that a mid-merge failure leaves memory.md already changed" \
  || ko "sync.md's pull table warns that a mid-merge failure leaves memory.md already changed"

grep -qiF 'needs-pull' "$SYNCMD" && grep -qiE 'hasbase.*false|hasBase.*false' "$SYNCMD" \
  && ok "sync.md's status guidance ties hasBase:false to the needs-pull push refusal" \
  || ko "sync.md's status guidance ties hasBase:false to the needs-pull push refusal"

# --- learner sync: Minor 7 — jq builds the JSON, a quote in an argument can't break it ---
out=$(sh "$SYNC" use 'gist"id'); rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && [ "$(printf '%s' "$out" | jq -r .gistId)" = 'gist"id' ]; } \
  && ok "sync use emits valid JSON even when the gist id contains a quote" \
  || ko "sync use emits valid JSON even when the gist id contains a quote (rc=$rc out=$out)"

mkdir -p "$SDATA/sync-base"
printf -- '- [Code][api] retries — seen: 2026-09-14\n' > "$SDATA/sync-base/memory.md"
: > "$SDATA/sync-base/recap.md"
jq -n '{}' > "$SDATA/sync-base/learner.json"
jq -n '{schemaVersion:1}' > "$SDATA/sync-base/manifest.json"   # no pushedAt: skips the divergence guard
jq -n --arg id 'gist"id' '{github:{gistId:$id}}' > "$SDATA/sync.json"
printf -- '- [Code][api] retries — seen: 2026-09-14\n' > "$SDATA/memory.md"
printf '## To improve\n' > "$SDATA/recap.md"
out=$(sh "$SYNC" push); rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  && [ "$(printf '%s' "$out" | jq -r .gistId)" = 'gist"id' ]; } \
  && ok "sync push emits valid JSON even when the recorded gist id contains a quote" \
  || ko "sync push emits valid JSON even when the recorded gist id contains a quote (rc=$rc out=$out)"

# --- learner sync: Minor 8/11 — mktemp placeholders and work dirs, no guessable rm -rf ---
grep -q 'mktemp' "$SYNC" \
  && ok "sync builds its placeholder and work-dir paths with mktemp, not a \$\$-based guess" \
  || ko "sync builds its placeholder and work-dir paths with mktemp, not a \$\$-based guess"

mkdir -p "$WORK/not-a-work-dir"
: > "$WORK/not-a-work-dir/manifest.json"
: > "$WORK/not-a-work-dir/canary"
out=$(sh "$SYNC" pull-finish "$WORK/not-a-work-dir"); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "no-work-dir" ] \
  && [ -f "$WORK/not-a-work-dir/canary" ]; } \
  && ok "pull-finish refuses to rm -rf a directory that is not one of its own work dirs" \
  || ko "pull-finish refuses to rm -rf a directory that is not one of its own work dirs (rc=$rc out=$out)"

# --- learner sync: Minor 9 — the Session history sort is pinned to the C locale ---------
grep -qE 'LC_ALL=C sort .*-t' "$SYNC" \
  && ok "merge_history sorts under LC_ALL=C, like the push/status timestamp comparisons" \
  || ko "merge_history sorts under LC_ALL=C, like the push/status timestamp comparisons"

# --- learner sync: Minor 12 — documentation gaps ----------------------------------------
awk '/<h2 id="uninstall">/{f=1} f' "$ROOT/docs/safety.html" > "$WORK/uninstall-section.html"
grep -qi 'gist' "$WORK/uninstall-section.html" \
  && ok "docs/safety.html's uninstall section says the gist survives uninstall" \
  || ko "docs/safety.html's uninstall section says the gist survives uninstall"

for f in 'sync.json' 'sync-base' 'backups'; do
  grep -qF "$f" "$ROOT/docs/install.html" \
    && ok "docs/install.html's file table lists $f" \
    || ko "docs/install.html's file table lists $f"
done

for f in "$PLUG/skills/sync/references/sync.md" "$ROOT/README.md" "$ROOT/docs/safety.html" "$ROOT/docs/usage.html"; do
  grep -qF 'pushedFrom' "$f" \
    && ok "$(basename "$f")'s consent warning names pushedFrom" \
    || ko "$(basename "$f")'s consent warning names pushedFrom"
  grep -qF 'disabledPaths' "$f" \
    && ok "$(basename "$f")'s consent warning names disabledPaths" \
    || ko "$(basename "$f")'s consent warning names disabledPaths"
done

# --- events log: asked --------------------------------------------------------
EV="$PLUG/hooks/learner-event.sh"
EVLOG="$WORK/cfg/learner/events.jsonl"
# CLAUDE_CODE_SESSION_ID is pinned so the suite behaves the same inside and
# outside a Claude Code session.
ev() { CLAUDE_CODE_SESSION_ID="${EV_SID:-sess-A}" CLAUDE_PROJECT_DIR="$WORK/proj" sh "$EV" "$@"; }
evn() { wc -l < "$EVLOG" | tr -d ' '; }
rm -rf "$WORK/cfg/learner"

EVP='Say "hi" — then \ leave 🎓
second line'
id=$(ev asked --style fill --mode granular --level senior --domain Code \
       --anchor src/foo.ts:42 --files "src/foo.ts  src/bar.ts" --prompt "$EVP"); rc=$?
line=$(tail -n1 "$EVLOG" 2>/dev/null)
{ [ "$rc" = 0 ] && [ -f "$EVLOG" ] && [ "$(evn)" = 1 ]; } \
  && ok "the first event creates learner/ and events.jsonl, one physical line" \
  || ko "the first event creates learner/ and events.jsonl, one physical line (rc=$rc)"
printf '%s' "$id" | grep -Eq '^q_[0-9]{8}T[0-9]{6}Z_[0-9a-f]{8}$' \
  && [ "$(printf '%s' "$line" | jq -r .id)" = "$id" ] \
  && ok "asked prints the id it wrote, in the q_<UTC>_<hex> format" \
  || ko "asked prints the id it wrote, in the q_<UTC>_<hex> format (id=$id)"
{ [ "$(printf '%s' "$line" | jq -r '.v')" = 1 ] \
  && [ "$(printf '%s' "$line" | jq -r '.type')" = "question.asked" ] \
  && [ "$(printf '%s' "$line" | jq -r '.level')" = "S" ] \
  && [ "$(printf '%s' "$line" | jq -r '.session')" = "sess-A" ] \
  && [ "$(printf '%s' "$line" | jq -r '.root')" = "$WORK/proj" ] \
  && [ "$(printf '%s' "$line" | jq -r '.repo')" = "proj" ] \
  && [ "$(printf '%s' "$line" | jq -c '.files')" = '["src/foo.ts","src/bar.ts"]' ] \
  && [ "$(printf '%s' "$line" | jq -c '.anchor')" = '{"file":"src/foo.ts","line":42}' ] \
  && printf '%s' "$line" | jq -r .ts | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; } \
  && ok "asked records v, type, canonical level, session, root, repo, files, anchor, ts" \
  || ko "asked records v, type, canonical level, session, root, repo, files, anchor, ts (line=$line)"
[ "$(printf '%s' "$line" | jq -r .prompt)" = "$EVP" ] \
  && ok "a prompt with quotes, backslash, newline and emoji round-trips" \
  || ko "a prompt with quotes, backslash, newline and emoji round-trips"

long=$(awk 'BEGIN { for (i = 0; i < 3000; i++) printf "a" }')
ev asked --style code --mode granular --level J --domain Code --files a.ts --prompt "$long" >/dev/null
[ "$(tail -n1 "$EVLOG" | jq '.prompt | length')" = 800 ] \
  && ok "asked truncates the prompt to 800 characters" \
  || ko "asked truncates the prompt to 800 characters"
[ "$(tail -n1 "$EVLOG" | jq -c 'has("anchor")')" = false ] \
  && ok "asked without --anchor writes no anchor key" \
  || ko "asked without --anchor writes no anchor key"

mkdir -p "$WORK/tmp/nogit"
( cd "$WORK/tmp/nogit" && env -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$WORK/tmp/nogit" \
    sh "$EV" asked --style code --mode synthesis --level C --domain Tests --files x --prompt p >/dev/null )
line=$(tail -n1 "$EVLOG")
{ [ "$(printf '%s' "$line" | jq -c '[.root, .repo, .session]')" = '[null,null,"unknown"]' ]; } \
  && ok "outside git and with no session env: root/repo null, session unknown" \
  || ko "outside git and with no session env: root/repo null, session unknown (line=$line)"

EV_SID=sess-X ev asked --session sess-override --style code --mode granular --level J \
  --domain Code --files a --prompt p >/dev/null
[ "$(tail -n1 "$EVLOG" | jq -r .session)" = "sess-override" ] \
  && ok "--session wins over CLAUDE_CODE_SESSION_ID" \
  || ko "--session wins over CLAUDE_CODE_SESSION_ID"

n=$(evn)
for bad in "--style poem" "--mode fast" "--level Z" "--anchor src/foo.ts" "--anchor src/foo.ts:0" "--anchor src/foo.ts:x"; do
  # shellcheck disable=SC2086
  ev asked --style code --mode granular --level J --domain Code --files a --prompt p $bad >/dev/null 2>&1; rc=$?
  { [ "$rc" = 2 ] && [ "$(evn)" = "$n" ]; } \
    && ok "asked rejects $bad with exit 2 and writes nothing" \
    || ko "asked rejects $bad with exit 2 and writes nothing (rc=$rc)"
done
ev asked --style code --mode granular --level J --files a --prompt p >/dev/null 2>&1; rc=$?
{ [ "$rc" = 2 ] && [ "$(evn)" = "$n" ]; } \
  && ok "asked without --domain exits 2 and writes nothing" \
  || ko "asked without --domain exits 2 and writes nothing (rc=$rc)"

out=$(PATH="$NOJQ_PATH" /bin/sh "$EV" asked --style code --mode granular --level J --domain Code \
        --files a --prompt p 2>"$WORK/tmp/ev-nojq.err"); rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ] && grep -q 'jq' "$WORK/tmp/ev-nojq.err" && [ "$(evn)" = "$n" ]; } \
  && ok "without jq, learner-event.sh warns once, exits 0 and writes nothing" \
  || ko "without jq, learner-event.sh warns once, exits 0 and writes nothing (rc=$rc out=$out)"

# Schema check: opt-in, because npx fetches ajv-cli from the network. CI sets it.
if [ -n "${LEARNER_SCHEMA_CHECK:-}" ] && command -v npx >/dev/null 2>&1; then
  mkdir -p "$WORK/tmp/evjson"; i=0; bad=0
  while IFS= read -r l; do
    i=$((i + 1)); printf '%s\n' "$l" > "$WORK/tmp/evjson/$i.json"
    npx --yes ajv-cli@5 validate --spec=draft2020 --strict=false \
      -s "$ROOT/contract/events.schema.json" -d "$WORK/tmp/evjson/$i.json" >/dev/null 2>&1 || bad=$((bad + 1))
  done < "$EVLOG"
  [ "$bad" = 0 ] && ok "every asked line validates against contract/events.schema.json" \
    || ko "every asked line validates against contract/events.schema.json ($bad invalid)"
else
  skip "schema check (set LEARNER_SCHEMA_CHECK=1 with npx available)"
fi

# --- events log: answered, skipped, abandoned --------------------------------
rm -f "$EVLOG"
q1=$(ev asked --style code --mode granular --level S --domain Code --files a --prompt p1)
ev answered --id "$q1" --verdict revisit --domain Code --theme "Error and exception handling" --note "missed the retry" >/dev/null
line=$(tail -n1 "$EVLOG")
{ [ "$(printf '%s' "$line" | jq -c '[.type, .id, .verdict, .domain, .theme, .note, .v]')" \
      = "[\"question.answered\",\"$q1\",\"revisit\",\"Code\",\"Error and exception handling\",\"missed the retry\",1]" ]; } \
  && ok "answered records id, verdict, domain, theme and note" \
  || ko "answered records id, verdict, domain, theme and note (line=$line)"

ev answered --id "$q1" --verdict ok --domain Code --theme '' >/dev/null
[ "$(tail -n1 "$EVLOG" | jq -c '[.theme, has("note")]')" = '[null,false]' ] \
  && ok "an empty --theme is written as null, and no --note means no note key" \
  || ko "an empty --theme is written as null, and no --note means no note key"

n=$(evn)
for args in "--verdict ok --domain Code --theme t" "--id $q1 --verdict meh --domain Code --theme t" "--id $q1 --verdict ok --theme t"; do
  # shellcheck disable=SC2086
  ev answered $args >/dev/null 2>&1; rc=$?
  { [ "$rc" = 2 ] && [ "$(evn)" = "$n" ]; } \
    && ok "answered rejects '$args' with exit 2" \
    || ko "answered rejects '$args' with exit 2 (rc=$rc)"
done

q2=$(ev asked --style code --mode granular --level S --domain Code --files a --prompt p2)
ev skipped --id "$q2" >/dev/null
[ "$(tail -n1 "$EVLOG" | jq -c '[.type, .id]')" = "[\"question.skipped\",\"$q2\"]" ] \
  && ok "skipped records the id" || ko "skipped records the id"

# Session A: q1 answered, q2 skipped, q3 open. Session B: q4 open.
q3=$(ev asked --style fill --mode granular --level S --domain Code --files a --prompt p3)
# shellcheck disable=SC2034  # q4 only needs to exist, open, in session B; never read back
q4=$(EV_SID=sess-B ev asked --style code --mode granular --level S --domain Code --files a --prompt p4)
printf '{"v":1,"type":"question.asked","id":"q_torn' >> "$EVLOG"; printf '\n' >> "$EVLOG"
ev abandoned --session sess-A >/dev/null; rc=$?
ab=$(jq -Rr 'fromjson? | select(.type == "question.abandoned") | .id' "$EVLOG")
{ [ "$rc" = 0 ] && [ "$ab" = "$q3" ] \
  && [ "$(jq -Rr "fromjson? | select(.type == \"question.abandoned\") | .session" "$EVLOG")" = "sess-A" ]; } \
  && ok "abandoned closes only the session's still-open questions, past a torn line" \
  || ko "abandoned closes only the session's still-open questions, past a torn line (rc=$rc ab=$ab)"
n=$(evn); ev abandoned --session sess-A >/dev/null
[ "$(evn)" = "$n" ] && ok "abandoned is idempotent" || ko "abandoned is idempotent"
ev abandoned >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "abandoned without --session exits 2" || ko "abandoned without --session exits 2 (rc=$rc)"
rm -f "$EVLOG"; ev abandoned --session sess-A >/dev/null; rc=$?
{ [ "$rc" = 0 ] && [ ! -f "$EVLOG" ]; } \
  && ok "abandoned with no log is a no-op" || ko "abandoned with no log is a no-op (rc=$rc)"

q5=$(EV_SID=sess-C ev asked --style code --mode granular --level S --domain Code --files a --prompt p5)
printf '{"session_id":"sess-C"}' | sh "$CLEAN"; rc=$?
{ [ "$rc" = 0 ] && [ "$(tail -n1 "$EVLOG" | jq -c '[.type, .id]')" = "[\"question.abandoned\",\"$q5\"]" ]; } \
  && ok "the SessionEnd cleanup hook abandons the session's open questions" \
  || ko "the SessionEnd cleanup hook abandons the session's open questions (rc=$rc)"

# --- summary ----------------------------------------------------------------
echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
