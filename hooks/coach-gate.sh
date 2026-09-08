#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# PreToolUse Write|Edit|NotebookEdit: in the coach regime, the dev writes the
# code. Claude may only write inside the slice the dev explicitly delegated
# (`learner coach delegate <glob>`), and is denied everywhere else in the repo.
#
# This exists because a skill instruction cannot hold over fifty turns. Drifting
# back into implementing is the one failure coach mode must not have, so the
# refusal is a hook, not a paragraph.
#
# Silent no-op unless the coach regime is active here. Every non-deny path exits
# 0 with no output: a learner hook must never fail a tool call because jq is
# missing or a config file is malformed.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

CFG=$(learner_config)
ROOT=$(learner_repo_root)
learner_coach_active "$CFG" "$ROOT" || exit 0

DATA=$(cat)
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""' 2>/dev/null)
# Verified against the hooks reference: Write, Edit and NotebookEdit all pass the
# path as .tool_input.file_path. The notebook_path fallback costs one jq
# alternative and covers the day that stops being true.
FP=$(printf '%s' "$DATA" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
[ -n "$SID" ] || exit 0
[ -n "$FP" ] || exit 0

# Outside the repo is always allowed: Claude's own config, the scratchpad,
# another project. Coach mode is about the code the dev is learning to write
# here. ROOT is physical (git rev-parse --show-toplevel) while file_path is
# whatever path the session used, so a repo reached through a symlink has to be
# resolved before it can be called "outside" — the same slow path
# learner-record-edit.sh already takes, and only when the cheap match fails.
case "$FP" in
  "$ROOT"/*) ;;
  *)
    _rd=$(cd "${FP%/*}" 2>/dev/null && pwd -P) || _rd=''
    case "${_rd:-/dev/null}/" in
      "$ROOT"/*) ;;
      *) exit 0 ;;
    esac ;;
esac

# Docs, JSON, lock files, generated output: not the learning target. Blocking a
# README write would be friction with no pedagogical payoff.
learner_excluded "$FP" "$CFG" && exit 0

REL=${FP#"$ROOT"/}
SCOPE="${TMPDIR:-/tmp}/claude-learner-${SID}.coach-scope"

# Delegated globs, one per line. Matched with `case`, in which `*` crosses `/` —
# so `src/**/repository/**` and `src/*/repository/*` behave identically. That
# permissive reading is what a dev writing such a glob intends.
if [ -f "$SCOPE" ]; then
  while IFS= read -r _g; do
    [ -n "$_g" ] || continue
    case "$_g" in \#*) continue ;; esac
    # shellcheck disable=SC2254  # $_g is a glob pattern on purpose
    case "$REL" in $_g) exit 0 ;; esac
  done < "$SCOPE"
fi

# The suggested glob must never widen to the whole repo. `sed 's:[^/]*$:**:'` on a
# top-level file like `Foo.kt` yields the bare glob `**`, which would invite the
# dev to delegate the entire repository — the exact opposite of the point. Only a
# path with a directory component gets a directory glob; anything else suggests
# itself.
case "$REL" in
  */*) SUGGEST=$(printf '%s' "$REL" | sed 's:[^/]*$:**:') ;;
  *)   SUGGEST="$REL" ;;
esac

REASON="🧑‍🏫 Coach mode — $REL is not delegated to you.
The dev writes this code. Describe the approach, name the file and the lead, and point at the
lines you would change — do not write them. If this slice really is yours, the dev can delegate
it: learner coach delegate '$SUGGEST'"

jq -n --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
