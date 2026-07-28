#!/bin/sh
# Stop hook, two jobs.
#
# 1. Guardrail — runs unconditionally, even with no config or enabled=false:
#    while any `// LEARNER-TODO` marker survives in the repo, block and force a
#    restore, so a crashed fill-in exercise can never leave source broken.
# 2. Quiz trigger — when the session edited tracked files, block once with a
#    SHORT trigger. The protocol lives in the skill (references/hook-quiz.md),
#    never here: this reason is rendered in the console.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

ROOT=$(learner_repo_root)

if [ -n "$ROOT" ]; then
  HOLES=$(git -C "$ROOT" grep -l 'LEARNER-TODO' 2>/dev/null | head -n 20 | tr '\n' ' ')
  if [ -n "$HOLES" ]; then
    GR="🎓 Learner — an unfinished fill-in exercise left // LEARNER-TODO markers in: $HOLES
Before anything else: restore the correct implementation, remove every // LEARNER-TODO, and verify it compiles/lints/tests. Do not finish while a marker remains."
    jq -n --arg r "$GR" '{decision:"block", reason:$r}'
    exit 0
  fi
fi

CFG=$(learner_config)
learner_active "$CFG" "$ROOT" || exit 0

DATA=$(cat)

# Don't re-block while already continuing from this hook, else Claude never waits
# for the dev and we risk an infinite stop loop.
ACTIVE=$(printf '%s' "$DATA" | jq -r '.stop_hook_active // false')
[ "$ACTIVE" = "true" ] && exit 0

SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""')
[ -n "$SID" ] || exit 0

STATE="${TMPDIR:-/tmp}/claude-learner-${SID}.edits"
[ -s "$STATE" ] || exit 0
SESSION="${TMPDIR:-/tmp}/claude-learner-${SID}.session"
COUNT="${TMPDIR:-/tmp}/claude-learner-${SID}.count"

LEVEL=$(learner_level "$(printf '%s' "$CFG" | jq -r '.level // empty')")
STYLES=$(printf '%s' "$CFG" | jq -r '
  if (.questionStyles | type) == "array"
  then (.questionStyles | join(","))
  else (.questionStyles // "auto") end')
case "$STYLES" in ''|null) STYLES=auto ;; esac
BLANKS=$(printf '%s' "$CFG" | jq -r '.blanksPerExercise // 2')
case "$BLANKS" in ''|*[!0-9]*) BLANKS=2 ;; esac
[ "$BLANKS" -lt 1 ] && BLANKS=1
EVERY=$(learner_synthesis_n "$(printf '%s' "$CFG" | jq -r '.synthesisFrequency // "normal"')")

# Per-session question counter drives the synthesis cadence.
N=$(cat "$COUNT" 2>/dev/null); case "$N" in ''|*[!0-9]*) N=0 ;; esac
N=$((N + 1)); echo "$N" > "$COUNT"

MODE=granular
FILES=$(sort -u "$STATE" | head -n 20 | tr '\n' ' ')
if [ "$EVERY" -gt 0 ] && [ $((N % EVERY)) -eq 0 ] && [ -s "$SESSION" ]; then
  MODE=synthesis
  FILES=$(sort -u "$SESSION" | head -n 40 | tr '\n' ' ')
fi

REASON="🎓 Learner (level: $LEVEL, mode: $MODE, styles: $STYLES, blanks: $BLANKS) — files: $FILES
Invoke the \`learner\` skill, follow references/hook-quiz.md for this mode. Ask ONE question, then wait for the dev's answer."

# Consume the pending edits: one granular question per batch, not per stop.
: > "$STATE"

jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
