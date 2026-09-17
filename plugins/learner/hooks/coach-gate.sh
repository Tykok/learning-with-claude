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
#
# This is a PreToolUse hook: it fires before the write, so the immediate parent
# of a brand-new file in a not-yet-created subdirectory legitimately does not
# exist yet, and `cd` on it fails. Walking up to the deepest EXISTING ancestor
# (terminating at "/", which always exists) gives a definite answer either way
# instead of silently allowing. A resolution that somehow still comes back
# empty fails CLOSED — treated as in-repo, falling through to the deny path —
# so a future edit here cannot reintroduce a silent allow.
#
# RESOLVED_FP starts as FP itself (the fast-path case: FP already shares
# ROOT's physical prefix, nothing to resolve) and is only overwritten below
# when the slow path actually resolves a symlinked ancestor. REL, further
# down, is derived from RESOLVED_FP rather than FP — this is the one place
# that resolution happens, reused by both the outside-the-repo check and the
# delegation match, so the two can never disagree about what "in the repo"
# means. Deriving REL from the raw FP instead (this hook's earlier bug) left
# delegation permanently unmatchable on any repo reached through a symlink —
# ROOT is physical but the stripped prefix wasn't, so REL stayed an absolute
# path that no relative glob could ever match.
RESOLVED_FP="$FP"

case "$FP" in
  "$ROOT"/*) ;;
  *)
    _gd="${FP%/*}"
    _gs=''
    while [ -n "$_gd" ] && [ ! -d "$_gd" ]; do
      case "$_gd" in
        */*) _gs="${_gd##*/}${_gs:+/$_gs}"; _gd="${_gd%/*}" ;;
        *)   _gs="$_gd${_gs:+/$_gs}"; _gd='' ;;
      esac
    done
    _gd=$(cd "${_gd:-/}" 2>/dev/null && pwd -P)
    case "${_gd:+$_gd/}" in
      "$ROOT"/*)
        # _gs is the tail that doesn't exist on disk yet (expected: PreToolUse
        # fires before the write). It can't itself hide a symlink to resolve,
        # so it is reattached to the resolved ancestor as plain text, along
        # with the file's own basename (never part of the ancestor walk).
        RESOLVED_FP="$_gd${_gs:+/$_gs}/${FP##*/}" ;;
      '') ;;      # resolution failed: fail closed, treat as in-repo
      *) exit 0 ;;
    esac ;;
esac

# Docs, JSON, lock files, generated output: not the learning target. Blocking a
# README write would be friction with no pedagogical payoff.
learner_excluded "$FP" "$CFG" && exit 0

REL=${RESOLVED_FP#"$ROOT"/}
SCOPE="${TMPDIR:-/tmp}/claude-learner-${SID}.coach-scope"

# Delegated globs, one per line. Matched with `case`, in which `*` crosses `/` —
# so `src/**/repository/**` and `src/*/repository/*` behave identically. That
# permissive reading is what a dev writing such a glob intends.
if [ -f "$SCOPE" ]; then
  # `|| [ -n "$_g" ]` covers a final line with no trailing newline: `read`
  # still delivers it in $_g but returns non-zero, so a bare `while read` loop
  # would drop it silently — the writer's most recently delegated glob, the
  # one most likely to matter. The redirect (not a pipe) keeps this loop in
  # the current shell, so `exit 0` below still exits the whole hook.
  while IFS= read -r _g || [ -n "$_g" ]; do
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
