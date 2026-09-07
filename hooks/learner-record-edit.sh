#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
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

# Quiz material is repo material. An edit outside the repo (~/.zshrc, another
# project) is never quizzed on: a `fill` exercise there would cut a hole the
# Stop hook's repo-scoped guardrail could never see, so a crash would leave it
# broken for good.
#
# ROOT is physical (git rev-parse --show-toplevel) while file_path is whatever path
# the session used, so a repo opened through a symlink fails the cheap string match
# and must be resolved before it can be dropped. One subshell, and only on that
# slow path: the common case stays a pattern match.
case "$FP" in
  "$ROOT"/*) ;;
  *)
    _rd=$(cd "${FP%/*}" 2>/dev/null && pwd -P) || _rd=''
    case "${_rd:-/dev/null}/" in
      "$ROOT"/*) ;;
      *) exit 0 ;;
    esac ;;
esac

# Exclusions live in learner-config.sh so the coach watcher applies the exact
# same list (see learner_excluded).
learner_excluded "$FP" "$CFG" && exit 0

# Pending edits since the last quiz, plus a session-wide log that is never
# cleared (the synthesis question uses it).
STATE="${TMPDIR:-/tmp}/claude-learner-${SID}.edits"
SESSION="${TMPDIR:-/tmp}/claude-learner-${SID}.session"
echo "$FP" >> "$STATE"
echo "$FP" >> "$SESSION"
exit 0
