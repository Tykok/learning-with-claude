#!/bin/sh
# Part of the learner hooks (see learner-quiz.sh / learner-record-edit.sh).
#
# SessionEnd hook: remove this session's scratch files from TMPDIR so they don't
# accumulate over time. Best-effort; a no-op if jq or the session id is missing.
# Wired as a SessionEnd hook; see $CLAUDE_CONFIG_DIR/settings.json.

DATA=$(cat)
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$SID" ] || exit 0

DIR="${TMPDIR:-/tmp}"
rm -f "$DIR/claude-learner-${SID}.edits" \
      "$DIR/claude-learner-${SID}.session" \
      "$DIR/claude-learner-${SID}.count" \
      "$DIR/claude-learner-${SID}.guard"
exit 0
