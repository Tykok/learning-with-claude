#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# UserPromptSubmit: coach mode is only half a mechanism without its watcher, and
# nothing else notices when the other half is missing.
#
# learner-onboard.sh can only ASK Claude to arm the watcher with the Monitor
# tool; it cannot start a long-running process itself. If Claude does not comply
# — a loaded context, a more urgent instruction, a harness without Monitor at
# all — coach mode is silently inert: the write gate still refuses, so the dev
# is held to the regime while never being coached. This hook makes that state
# audible, exactly once per session.
#
# Silent no-op on every other path. A learner hook must never fail a tool call.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

# Read stdin before anything else, same convention as pilot-nudge.sh: the
# payload is drained on the common path regardless of what follows.
DATA=$(cat 2>/dev/null)
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$SID" ] || exit 0

TMPD="${TMPDIR:-/tmp}"
ARMED="$TMPD/claude-learner-${SID}.coach-armed"
WARNED="$TMPD/claude-learner-${SID}.coach-armwarn"
SEEN="$TMPD/claude-learner-${SID}.coach-armseen"

# Marker checks before learner_config/learner_repo_root, not after: once the
# watcher is armed (the common case for the rest of the session) or once this
# session has already been warned, every later prompt bails on a plain file
# test, never paying for learner_config's jq calls or learner_repo_root's git
# rev-parse. A repo with coach off never creates either marker, so that path
# still costs exactly what it did before this reordering.
[ -f "$ARMED" ] && exit 0
[ -f "$WARNED" ] && exit 0

CFG=$(learner_config)
ROOT=$(learner_repo_root)
learner_coach_active "$CFG" "$ROOT" || exit 0

# The watcher cannot possibly be armed yet on the FIRST prompt of a session:
# learner-onboard.sh only ASKS Claude to arm it during turn 1, and Claude can
# only act on that after this very UserPromptSubmit has already fired and
# returned. Without this grace window every session, healthy or not, would be
# warned once for free before Claude had any chance to comply. Record that a
# prompt was seen and stay silent; only from the SECOND prompt onward does an
# absent $ARMED mean anything.
if [ ! -f "$SEEN" ]; then
  # `:`'s own redirection is what is guarded here, not the write's success: `:`
  # is a POSIX special built-in, so a redirection failure on it (nonexistent or
  # read-only TMPDIR) aborts a non-interactive shell outright — under dash this
  # hook would exit 2 and erase the dev's prompt, instead of degrading to
  # silence. Wrapping the write in a subshell confines that abort to the
  # subshell: the parent script only sees a nonzero status and takes the `||`
  # branch. The `2>/dev/null` must sit OUTSIDE the parens: redirections on a
  # compound command are installed before the command runs, so it silences the
  # dash error message that the failing `>` would otherwise print to the real
  # stderr; placed inside, the `>` would already have failed before its own
  # `2>/dev/null` was applied. Do not "simplify" this back to a bare `:` line.
  ( : > "$SEEN" ) 2>/dev/null || exit 0
  exit 0
fi

# One warning per session. Without this marker the line would ride along with
# every prompt of a session where Monitor does not exist at all (claude -p, a
# subagent, a cloud session), which is noise, not information.
( : > "$WARNED" ) 2>/dev/null || exit 0

WATCH="$(dirname "$0")/coach-watch.sh"
CTX="🧑‍🏫 Coach mode is on in this repo but the change watcher is not armed, so no review will
ever fire. Arm it now with the Monitor tool:
  command: sh \"$WATCH\" \"$SID\"
  description: coach: the dev's changes
  persistent: true
If the Monitor tool does not exist in this session (claude -p, a subagent, a cloud session),
tell the dev in one line that coach mode is inert here — the write gate still applies — and
continue with their request."

jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}'
exit 0
