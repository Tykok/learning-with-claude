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
# Keyed by session id so the once-per-session nudge cap below can be bounded
# and cleaned up (see learner-cleanup.sh), same pattern as learner-quiz.sh.
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""' 2>/dev/null)
TMPD="${TMPDIR:-/tmp}"

CFG=$(learner_config) || exit 0
pilot_enabled "$CFG" || exit 0
[ "$(printf '%s' "$CFG" | jq -r '.pilotNudge')" = "false" ] && exit 0

PMD="$LEARNER_CFG_DIR/learner/pilot.md"
[ -f "$PMD" ] || exit 0

# The exact shape this parses, owned by this file for Task 9 to write to:
#   - live: <axis> | <one-line constraint> | until YYYY-MM-DD
# The axis is everything before the FIRST pipe and the expiry is the LAST
# pipe-delimited field; the constraint is everything in between, rejoined with
# " | " so a pipe inside the constraint text (a later task has Claude writing
# that sentence in natural language) shifts neither the axis nor the expiry.
LIVE=$(sed -n 's/^- live: *//p' "$PMD" 2>/dev/null | head -1)
[ -n "$LIVE" ] || exit 0

AXIS=$(printf '%s' "$LIVE" | awk -F' *\\| *' '{print $1}')
RULE=$(printf '%s' "$LIVE" | awk -F' *\\| *' '{
  out = $2
  for (i = 3; i < NF; i++) out = out " | " $i
  print out
}')
UNTIL=$(printf '%s' "$LIVE" | awk -F' *\\| *' '{print $NF}' | sed -n 's/^until *//p')

# A manoeuvre is, by spec, "negotiated, with an expiry" — an expiry is not an
# optional detail, it is constitutive. So a line whose last field is not
# `until <YYYY-MM-DD>` (missing entirely, missing the `until` keyword, or an
# unparseable date) is malformed, and a malformed manoeuvre is not live: stay
# silent. This is the opposite of "never expires" — nudging forever on a typo
# is exactly the failure that gets the whole feature switched off by the dev,
# so every malformed shape below fails toward silence, never toward speaking.
[ -n "$AXIS" ] && [ -n "$RULE" ] && [ -n "$UNTIL" ] || exit 0

# Compared as an integer with the dashes stripped, not with test's `\<`: that
# lexicographic operator is a non-POSIX ksh/bash extension shellcheck rejects
# under --severity=warning, and reaching for `date -d` instead is not portable
# between GNU and BSD. Digit count matches (YYYYMMDD) so numeric order agrees
# with date order; a value that fails the digit-and-length guard is malformed
# (see above) and the manoeuvre is treated as not live, never as evergreen.
TODAY=$(date +%Y%m%d)
UNTIL_N=$(printf '%s' "$UNTIL" | tr -d '-')
case "$UNTIL_N" in ''|*[!0-9]*) exit 0 ;; esac
[ "${#UNTIL_N}" -eq 8 ] || exit 0
if [ "$UNTIL_N" -lt "$TODAY" ]; then exit 0; fi

PROMPT=$(printf '%s' "$DATA" | jq -r '.prompt // ""' 2>/dev/null)

# The direction manoeuvre is the only one that reacts to the prompt itself, so
# it is the only one that needs a vagueness test. Deliberately crude and
# documented as such: short, no code span, no path, no question. A question is
# the opposite of offloading the thinking — a dev asking "why is CI failing"
# or "what does this error mean" has nothing for a direction manoeuvre to
# correct — so any interrogative prompt is exempt before the length check even
# runs. A false negative costs one missed reminder; a false positive costs the
# dev's patience, which is the expensive one.
if [ "$AXIS" = "direction" ] && [ -n "$PROMPT" ]; then
  case "$PROMPT" in
    *'?'*) exit 0 ;;
  esac
  FIRST_WORD=$(printf '%s' "$PROMPT" | awk '{print tolower($1)}')
  case "$FIRST_WORD" in
    why|what|how|when|where|who|is|are|does|do|can|should) exit 0 ;;
  esac
  WORDS=$(printf '%s' "$PROMPT" | wc -w | tr -d ' ')
  case "$PROMPT" in
    *'`'*|*/*) exit 0 ;;
  esac
  [ "$WORDS" -ge 8 ] && exit 0
fi

# Once per session: the context below already asks Claude not to repeat
# itself, but that is a request, not a guarantee. A marker file in TMPDIR,
# keyed by session id (same style as learner-quiz.sh's per-session state, and
# removed by learner-cleanup.sh at SessionEnd), turns every remaining false
# positive into one line the dev can ignore instead of a recurring irritation.
if [ -n "$SID" ]; then
  MARKER="$TMPD/claude-learner-${SID}.pilot-nudged"
  [ -e "$MARKER" ] && exit 0
  : > "$MARKER" 2>/dev/null
fi

CTX="Pilot manoeuvre in force (axis: $AXIS): $RULE.
Before answering, ask the dev for the one thing the manoeuvre is missing from this prompt — the
result they want, or the constraint that rules an approach out. One line, then get on with the
work. Do not repeat this if you have already asked in this session."

jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}'
exit 0
