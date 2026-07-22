#!/bin/sh
# Part of "learning mode" (see learner-record-edit.sh / learner-quiz.sh).
#
# SessionStart hook: if the learner has not declared a level yet, inject context
# asking Claude to prompt the user for it at the start of the conversation and to
# create .claude/learner.local.json once answered. No-op once a valid level exists.
# Wired as a SessionStart hook; see .claude/settings.json.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
LEVEL_FILE="$PROJECT_DIR/.claude/learner.local.json"

# jq is required by every learning-mode hook. Without it they are silently inert,
# so warn once per session (this is the only user-facing hook). Hand-rolled JSON
# so it works even though jq is missing; the string is fixed (no interpolation).
if ! command -v jq >/dev/null 2>&1; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Learning mode is installed but `jq` is not on PATH, so its hooks are inert. Tell the user to install jq (brew install jq / apt-get install jq) to enable it, then continue."}}\n'
  exit 0
fi

# Already configured with a valid level -> nothing to do.
if [ -f "$LEVEL_FILE" ]; then
  LEVEL=$(jq -r '.level // empty' "$LEVEL_FILE" 2>/dev/null)
  [ -n "$LEVEL" ] && exit 0
fi

CTX="This project's \"learning mode\" is not configured yet (no level declared in .claude/learner.local.json). \
At the very start of your next reply to the user, BEFORE handling their request, set it up by asking them (ideally via the multiple-choice question tool), in the user's language: \
1) their LEVEL on this codebase — junior, intermediaire or senior (required); \
2) whether to customise the options or keep the defaults. Options and defaults: \
enabled (default true) = turn the quizzes on; \
recapEvery (default 3) = a synthesis question every N quizzes; \
questionStyles (default \"auto\") = allowed formats among code / trou / archi, or \"auto\" (you choose); \
language (default \"fr\") = language the questions are asked in, fr or en; \
trouBlanks (default 2) = number of // LEARNER-TODO holes left for the dev in a trou (fill-in) exercise; \
trackGlobs (default: common source globs, see learner.local.json.example) = which edited file types count for questions. \
Two gitignored files are kept automatically: .claude/learner-memory.md (quiz working memory, weak spots) and .claude/learner-recap.md (readable dashboard: to improve, mastered, session history). \
As soon as they answer, create .claude/learner.local.json with a JSON containing level + the options (defaults for those they don't customise), e.g. \
{\"level\":\"junior\",\"enabled\":true,\"recapEvery\":3,\"questionStyles\":\"auto\",\"language\":\"fr\"}. \
Confirm briefly then continue with their original request. \
If they decline or say to skip, don't insist and don't create the file — but warn them that no question will trigger until a level is set."

jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
