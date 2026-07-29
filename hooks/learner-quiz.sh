#!/bin/sh
# Stop hook, two jobs.
#
# 1. Guardrail — while a `// LEARNER-TODO` marker left behind by a crashed
#    fill-in exercise survives in the working tree, block and force a restore, so
#    the exercise can never leave source broken. Deliberately independent of
#    `enabled` and of a valid `level`: an abandoned exercise must be caught even
#    in a repo where the quiz is switched off. Only `disabledPaths` (or a missing
#    jq / git repo / session id) silences it, and it blocks at most twice per
#    outstanding exercise so a session can always end.
# 2. Quiz trigger — when the session edited tracked files, block once with a
#    SHORT trigger. The protocol lives in the skill (references/hook-quiz.md),
#    never here: this reason is rendered in the console.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

CFG=$(learner_config)
ROOT=$(learner_repo_root)

DATA=$(cat)
# Both jobs are per session: the guardrail budget and the pending-edit list are
# keyed by session id, so without one neither can be bounded or cleaned up.
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""')
[ -n "$SID" ] || exit 0

TMPD="${TMPDIR:-/tmp}"
STATE="$TMPD/claude-learner-${SID}.edits"
SESSION="$TMPD/claude-learner-${SID}.session"
COUNT="$TMPD/claude-learner-${SID}.count"
GUARD="$TMPD/claude-learner-${SID}.guard"

# --- 1) LEARNER-TODO guardrail ----------------------------------------------
# A marker that is already in HEAD is repo content, not a leftover (this project
# documents the string in its own docs and tests), so only working-tree markers
# missing from HEAD count. Untracked files are included: a file the session just
# created with Write is the guardrail's primary case.
GUARD_MAX=2
if [ -n "$ROOT" ] && ! learner_path_disabled "$ROOT" "$CFG"; then
  WORKTREE=$(git -C "$ROOT" grep --untracked -lF '// LEARNER-TODO' 2>/dev/null)
  # Empty in a repo with no commits yet, where `git grep … HEAD` fails: then
  # every working-tree marker is a leftover, which is the right answer.
  COMMITTED=$(git -C "$ROOT" grep -lF '// LEARNER-TODO' HEAD 2>/dev/null \
    | while IFS= read -r _gl; do printf '%s\n' "${_gl#HEAD:}"; done)

  # Set difference, POSIX-only: no process substitution, no `comm`. The heredoc
  # keeps the loop in this shell, so the counter survives it.
  HOLES=''
  NHOLES=0
  while IFS= read -r _gf; do
    [ -n "$_gf" ] || continue
    printf '%s\n' "$COMMITTED" | grep -qxF -e "$_gf" && continue
    NHOLES=$((NHOLES + 1))
    [ "$NHOLES" -le 20 ] && HOLES="$HOLES $_gf"
  done <<EOF
$WORKTREE
EOF

  if [ "$NHOLES" -gt 0 ]; then
    NB=$(cat "$GUARD" 2>/dev/null); case "$NB" in ''|*[!0-9]*) NB=0 ;; esac
    if [ "$NB" -lt "$GUARD_MAX" ]; then
      echo $((NB + 1)) > "$GUARD"
      MORE=''
      [ "$NHOLES" -gt 20 ] && MORE=" (and $((NHOLES - 20)) more)"
      GR="🎓 Learner — an unfinished fill-in exercise left // LEARNER-TODO markers in:$HOLES$MORE
Before anything else: restore the correct implementation, remove every // LEARNER-TODO it left, and verify it compiles/lints/tests. Do not finish while a marker remains."
      jq -n --arg r "$GR" '{decision:"block", reason:$r}'
      exit 0
    fi
    # Budget spent: say nothing rather than hang the session on a marker Claude
    # cannot or will not clear.
  else
    # Tree is clean again: a later exercise gets a fresh budget.
    rm -f "$GUARD"
  fi
fi

# --- 2) Quiz trigger --------------------------------------------------------
learner_active "$CFG" "$ROOT" || exit 0

# Don't re-block while already continuing from this hook, else Claude never waits
# for the dev and we risk an infinite stop loop.
ACTIVE=$(printf '%s' "$DATA" | jq -r '.stop_hook_active // false')
[ "$ACTIVE" = "true" ] && exit 0

[ -s "$STATE" ] || exit 0

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
