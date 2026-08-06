#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SessionStart: notify when a newer Learner version is available. Never blocks
# and never updates on its own — `learner update` (references/update.md) does
# the actual re-install.
#
# Throttled to once per 24h, and the stamp is written on every *attempt*, not
# only on success: an offline machine must not pay a curl timeout every
# session for days on end.
#
# No `jq` dependency, unlike every other hook here — this must still work on
# the machine `learner-onboard.sh` is already telling to go install jq. Every
# value that reaches the hand-built JSON below is a version string already
# validated by learner_version_valid, so there is no escaping risk to justify
# pulling jq in for one line of output.

# CFG is computed directly here rather than by sourcing learner-config.sh up front:
# the throttle check just below is the fast path on most sessions (it exits before
# doing anything else), so it must not pay the cost of sourcing a file it may not
# even need. learner-config.sh is only sourced further down, once the throttle has
# already let this run past 24h.
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STAMP="$CFG/learner/.last-update-check"
NOW=$(date +%s)

if [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null)
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  [ $((NOW - LAST)) -lt 86400 ] && exit 0
fi

mkdir -p "$CFG/learner" 2>/dev/null
printf '%s' "$NOW" > "$STAMP" 2>/dev/null

command -v curl >/dev/null 2>&1 || exit 0

URL="${LEARNER_VERSION_URL:-https://raw.githubusercontent.com/Tykok/learning-with-claude/main/VERSION}"
REMOTE=$(curl -fsSL --max-time 2 "$URL" 2>/dev/null) || exit 0

. "$(dirname "$0")/learner-config.sh"
learner_version_valid "$REMOTE" || exit 0

LOCAL=$(cat "$CFG/skills/learner/VERSION" 2>/dev/null)

if [ -n "$LOCAL" ]; then
  learner_version_valid "$LOCAL" || exit 0
  learner_version_gt "$REMOTE" "$LOCAL" || exit 0
  INSTALLED="v$LOCAL"
else
  INSTALLED="none installed"
fi

CTX="Learner v$REMOTE is available ($INSTALLED) - run \`learner update\`."
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$CTX"
