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
[ -n "$LEVEL" ] && exit 0

CTX="Learner is installed but has no valid level, so it will never ask a question. Tell the user, in one line, to run \`learner config level=<D|J|C|S|E>\`, then continue with their request."
jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
