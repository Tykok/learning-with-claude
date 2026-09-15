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

# Flatten a description to one bounded line (a newline in it would otherwise
# read as a second agent in flight) and report whether — after stripping
# leading blanks — it carries the learner-prep: contract prefix. Both --start
# and --end need the same test: --start must never record the preparation
# agent, and --end must never drain a REAL agent's in-flight count for the
# preparation agent's own return. An absent or unreadable description yields
# "", which never matches and therefore drains on --end — the safe default.
DESC=$(printf '%s' "$DATA" | jq -r '.tool_input.description // ""' \
  | tr '\n' ' ' | tr '\t' ' ')
# jq emits a trailing newline that the tr above turns into a trailing space;
# $( ) strips trailing newlines but not that space, so strip it by hand or
# every trigger reads "task: …  — files: …" with a double space.
DESC=${DESC%"${DESC##*[! ]}"}
DESC=$(printf '%s' "$DESC" | cut -c1-200)
TRIM=${DESC#"${DESC%%[! ]*}"}
IS_PREP=0
case "$TRIM" in learner-prep:*) IS_PREP=1 ;; esac

if [ "$MODE" = "--end" ]; then
  [ "$IS_PREP" = 1 ] && exit 0
  # Deliberately NOT gated on learner_salvo_active: a key switched off mid-session
  # must still drain the counters rather than freeze them at a stale value that
  # would serve salvos again the moment it is switched back on.
  if [ -s "$AGENTS" ]; then
    # read-modify-write, not append-only, so two --end calls landing at once
    # can both read the same $AGENTS and each drop only one line where two
    # returned — leaving the in-flight count one too high. That is acceptable:
    # it only over-reports (never under-reports, so a real agent's line is
    # never lost), stays bounded by $DISPATCHED, and the whole batch is reaped
    # at SessionEnd regardless. Unlike $DISPATCHED (FINDING 2), there is no
    # append-only equivalent for "remove the oldest line", so this race is
    # left rather than chasing it with locking this project otherwise avoids.
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

# Strip leading blanks before the prefix test — "  learner-prep: …" is the same
# contract as "learner-prep: …", and an agent that slips through it is the one
# failure in this feature with no bottom.
[ "$IS_PREP" = 1 ] && exit 0

printf '%s\t%s\n' "$(date +%s)" "$DESC" >> "$AGENTS"

# Append-only, exactly like $AGENTS above: an append is atomic even when
# several --start calls land at once (a batch of parallel Task dispatches),
# while the previous "cat, add one, overwrite" counter silently lost
# increments under that race. hooks/learner-quiz.sh counts this file with
# grep -c ., the same way it already counts $AGENTS.
date +%s >> "$DISPATCHED"
exit 0
