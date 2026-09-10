#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# UserPromptSubmit hook: the only place Pilot speaks unprompted, and only while
# a manoeuvre the dev agreed to is still live.
#
# THIS SCRIPT MUST NEVER EXIT 2. On UserPromptSubmit, exit 2 blocks the prompt
# and erases it. Pilot exists to make the dev think more, not to delete what
# they wrote. Every path here exits 0; the reminder rides additionalContext.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

DATA=$(cat 2>/dev/null)
CFG=$(learner_config) || exit 0
pilot_enabled "$CFG" || exit 0
[ "$(printf '%s' "$CFG" | jq -r '.pilotNudge')" = "false" ] && exit 0

PMD="$LEARNER_CFG_DIR/learner/pilot.md"
[ -f "$PMD" ] || exit 0

# The exact shape this parses, owned by this file for Task 9 to write to:
#   - live: <axis> | <one-line constraint> | until YYYY-MM-DD
# Field separator is a pipe with optional surrounding spaces; a date that is
# not exactly four-digit-year/two-digit-month/two-digit-day, dash-separated,
# fails the digit guard below and the manoeuvre is treated as not expired
# (never as silently inert) — a mismatch here must fail loud in review, not
# make an active manoeuvre vanish from the dashboard's own telling.
LIVE=$(sed -n 's/^- live: *//p' "$PMD" 2>/dev/null | head -1)
[ -n "$LIVE" ] || exit 0

AXIS=$(printf '%s' "$LIVE"  | awk -F' *\\| *' '{print $1}')
RULE=$(printf '%s' "$LIVE"  | awk -F' *\\| *' '{print $2}')
UNTIL=$(printf '%s' "$LIVE" | awk -F' *\\| *' '{print $3}' | sed -n 's/^until *//p')
[ -n "$AXIS" ] && [ -n "$RULE" ] || exit 0

# Compared as an integer with the dashes stripped, not with test's `\<`: that
# lexicographic operator is a non-POSIX ksh/bash extension shellcheck rejects
# under --severity=warning, and reaching for `date -d` instead is not portable
# between GNU and BSD. Digit count matches (YYYYMMDD) so numeric order agrees
# with date order; a value that fails the digit guard is left blank and never
# expires the manoeuvre.
TODAY=$(date +%Y%m%d)
UNTIL_N=$(printf '%s' "$UNTIL" | tr -d '-')
case "$UNTIL_N" in ''|*[!0-9]*) UNTIL_N='' ;; esac
if [ -n "$UNTIL_N" ] && [ "$UNTIL_N" -lt "$TODAY" ]; then exit 0; fi

PROMPT=$(printf '%s' "$DATA" | jq -r '.prompt // ""' 2>/dev/null)

# The direction manoeuvre is the only one that reacts to the prompt itself, so
# it is the only one that needs a vagueness test. Deliberately crude and
# documented as such: short, no code span, no path. A false negative costs one
# missed reminder; a false positive costs the dev's patience, which is the
# expensive one.
if [ "$AXIS" = "direction" ] && [ -n "$PROMPT" ]; then
  WORDS=$(printf '%s' "$PROMPT" | wc -w | tr -d ' ')
  case "$PROMPT" in
    *'`'*|*/*) exit 0 ;;
  esac
  [ "$WORDS" -ge 8 ] && exit 0
fi

CTX="Pilot manoeuvre in force (axis: $AXIS): $RULE.
Before answering, ask the dev for the one thing the manoeuvre is missing from this prompt — the
result they want, or the constraint that rules an approach out. One line, then get on with the
work. Do not repeat this if you have already asked in this session."

jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}'
exit 0
