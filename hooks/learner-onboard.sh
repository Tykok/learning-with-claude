#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SessionStart: report a broken learner install and nothing else.
#
# install.sh does the onboarding for a traditional install; a plugin install has no
# install.sh at all, so this hook is the only place either kind of first-run gets a nudge.
# Output goes to additionalContext, which is not rendered in the console.

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Learner is installed but `jq` is not on PATH, so all of its hooks are inert. Tell the user, in one line, to install jq (brew install jq / apt-get install jq), then continue with their request."}}'
  exit 0
fi

. "$(dirname "$0")/learner-config.sh"

ROOT=$(learner_repo_root)
[ -n "$ROOT" ] || exit 0

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
