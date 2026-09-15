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
