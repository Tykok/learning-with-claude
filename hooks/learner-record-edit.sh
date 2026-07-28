#!/bin/sh
# PostToolUse Write|Edit: record the files edited this session so the Stop hook
# can quiz on them.
#
# Exclusion-list model: everything the dev edits is quiz material, minus a
# built-in floor (generated / vendored / lock artefacts) and the user's
# `untrackGlobs`. No-op unless the learner is active here.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

CFG=$(learner_config)
ROOT=$(learner_repo_root)
learner_active "$CFG" "$ROOT" || exit 0

DATA=$(cat)
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""')
FP=$(printf '%s' "$DATA" | jq -r '.tool_input.file_path // ""')
[ -n "$SID" ] || exit 0
[ -n "$FP" ] || exit 0

# Built-in floor, not overridable through config: without it, every
# package-lock.json and generated file would become quiz material.
case "$FP" in
  */node_modules/*|*/build/*|*/dist/*|*/out/*|*/target/*|*/vendor/*) exit 0 ;;
  */.git/*|*/.gradle/*|*/__pycache__/*|*/.venv/*|*/coverage/*|*/__snapshots__/*) exit 0 ;;
esac
case "$FP" in
  *.lock|*-lock.*|*.min.*|*.generated.*|*.snap) exit 0 ;;
esac

# User exclusions on top of the floor. Globs are whitespace-separated, so a glob
# containing a space is not supported (documented in README).
GLOBS=$(printf '%s' "$CFG" | jq -r '(.untrackGlobs // [])[]' 2>/dev/null)
set -f
# shellcheck disable=SC2086,SC2254  # intentional word splitting + glob patterns
for g in $GLOBS; do
  [ -n "$g" ] || continue
  case "$FP" in $g) exit 0 ;; esac
done
set +f

# Pending edits since the last quiz, plus a session-wide log that is never
# cleared (the synthesis question uses it).
STATE="${TMPDIR:-/tmp}/claude-learner-${SID}.edits"
SESSION="${TMPDIR:-/tmp}/claude-learner-${SID}.session"
echo "$FP" >> "$STATE"
echo "$FP" >> "$SESSION"
exit 0
