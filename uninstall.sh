#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Remove learner from Claude Code (reverse of install.sh).
#
# Usage:
#   ./uninstall.sh [--purge]
#   ./uninstall.sh --project REPO
#
#   --purge          Also delete your config and progress data
#                    ($CLAUDE_CONFIG_DIR/learner.json and learner/).
#                    Without it they survive a reinstall.
#   --project REPO   Clean a repo that still carries the old per-project layout
#                    (learner hooks, skill, settings entries and .gitignore lines).
#
# Requires: jq.
set -euo pipefail

PURGE=0
PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    # An empty value must never fall through to the global uninstall: `--project=`
    # is a typo for "clean one repo", not permission to wipe every repo's data.
    --project)
      PROJECT="${2:-}"
      [ -n "$PROJECT" ] || { echo "error: --project needs a repo path (usage: ./uninstall.sh --project /path/to/repo)"; exit 1; }
      shift 2 ;;
    --project=*)
      PROJECT="${1#*=}"
      [ -n "$PROJECT" ] || { echo "error: --project needs a repo path (usage: ./uninstall.sh --project /path/to/repo)"; exit 1; }
      shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unexpected argument '$1'"; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required"; exit 1; }

# A settings.json we cannot parse is a hard stop, checked before anything is
# deleted (install.sh does the same). Otherwise jq fails half-way and leaves the
# wiring pointing at hooks that no longer exist — at user level, that breaks
# every session in every project.
require_parsable() {
  [ -f "$1" ] || return 0
  jq -e . "$1" >/dev/null 2>&1 || {
    echo "error: $1 is not valid JSON — fix or move it, then re-run."
    exit 1
  }
}

# Strip every hook entry this project wires from a settings.json, dropping
# events left empty.
#
# Matched by naming convention, not by an exhaustive per-script list: every
# hook script this project ships is named "learner-*.sh", "coach-*.sh" or
# "pilot-*.sh" (see install.sh's copy loop and hooks/settings.snippet.json). A
# convention-based match keeps pace with new scripts on its own — no list to
# remember to update here — which is exactly what a literal-name or
# single-prefix match cannot do (a coach-*.sh hook once slipped past a
# "learner-"-only match this same way, and the three pilot-*.sh hooks shipped
# uncopied by install.sh's old per-script list for the same reason).
#
# The name match alone is not enough: a bare "/hooks/(learner|coach)-*.sh"
# matches that path shape anywhere on disk, so a sibling tool that also ships
# a "hooks/" directory with a same-prefixed script (plausible — "coach" is a
# generic word, and $CLAUDE_CONFIG_DIR/hooks is a directory other tools can
# also write into) would get silently swept up. Anchoring on a literal
# ".claude" segment (with an optional trailing "}", closing the
# "${VAR:-default}" this project's own commands are always wrapped in)
# immediately before "/hooks/" requires the match to run through a Claude
# Code config tree specifically — every shape this project has ever wired
# does: today's "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/", the old
# per-project "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/", and the legacy bare
# ".claude/hooks/" — while a path with no ".claude" segment at all, like
# /opt/otherteam/hooks/coach-lint.sh, is rejected outright. Anchoring tighter,
# to today's exact "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/" literal, was
# considered and rejected: it would stop recognising the older forms above,
# leaving that wiring behind forever on an uninstall — the same kind of leak
# this predicate exists to prevent. Residual risk accepted: another tool that
# specifically nests its own hook under a ".claude/hooks/" tree with a
# learner-/coach-/pilot-prefixed name would still collide; that requires
# deliberately mimicking this project's install location and naming
# convention together, which is a much narrower target than the bare
# path-shape match this predicate replaces.
#
# This is intentionally the same predicate as the reinstall-dedup in
# install.sh — keep the two in sync if either changes.
strip_wiring() {
  local settings="$1"
  [ -f "$settings" ] || return 0
  local tmp
  tmp="$(mktemp)"
  jq '
    if .hooks then
      .hooks |= (
        (with_entries(.value |= map(select(
          any(.hooks[]?; .command | test("\\.claude\\}?/hooks/(learner|coach|pilot)-[A-Za-z0-9_.-]+\\.sh")) | not
        ))))
        | with_entries(select(.value | length > 0))
      )
      | (if (.hooks | length) == 0 then del(.hooks) else . end)
    else . end
  ' "$settings" > "$tmp"
  mv "$tmp" "$settings"
}

if [ -n "$PROJECT" ]; then
  TARGET="$(cd "$PROJECT" && pwd)"
  require_parsable "$TARGET/.claude/settings.json"
  echo "→ Cleaning the legacy per-project install in: $TARGET"
  rm -f "$TARGET/.claude/hooks/learner-onboard.sh" \
        "$TARGET/.claude/hooks/learner-record-edit.sh" \
        "$TARGET/.claude/hooks/learner-quiz.sh" \
        "$TARGET/.claude/hooks/learner-cleanup.sh" \
        "$TARGET/.claude/hooks/learner-config.sh" \
        "$TARGET/.claude/hooks/coach-gate.sh" \
        "$TARGET/.claude/hooks/coach-watch.sh" \
        "$TARGET/.claude/hooks/pilot-record.sh" \
        "$TARGET/.claude/hooks/pilot-brief.sh" \
        "$TARGET/.claude/hooks/pilot-nudge.sh"
  rm -rf "$TARGET/.claude/skills/learner"
  strip_wiring "$TARGET/.claude/settings.json"
  GI="$TARGET/.gitignore"
  if [ -f "$GI" ]; then
    TMP="$(mktemp)"
    grep -vE '^\.claude/(learner\.local\.json|learner-memory\.md|learner-recap\.md)$' "$GI" > "$TMP" || true
    mv "$TMP" "$GI"
  fi
  echo "  ✓ hooks, skill, wiring and .gitignore entries removed"
  echo "  • .claude/learner.local.json (if any) left in place — delete it by hand if you want it gone"
  echo
  echo "Done."
  exit 0
fi

CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
require_parsable "$CFG_DIR/settings.json"
echo "→ Removing learner from: $CFG_DIR"

rm -f "$CFG_DIR/hooks/learner-config.sh" \
      "$CFG_DIR/hooks/learner-onboard.sh" \
      "$CFG_DIR/hooks/learner-record-edit.sh" \
      "$CFG_DIR/hooks/learner-quiz.sh" \
      "$CFG_DIR/hooks/learner-cleanup.sh" \
      "$CFG_DIR/hooks/learner-update-check.sh" \
      "$CFG_DIR/hooks/coach-gate.sh" \
      "$CFG_DIR/hooks/coach-watch.sh" \
      "$CFG_DIR/hooks/pilot-record.sh" \
      "$CFG_DIR/hooks/pilot-brief.sh" \
      "$CFG_DIR/hooks/pilot-nudge.sh"
rm -rf "$CFG_DIR/skills/learner"
echo "  ✓ hooks + skill removed"

strip_wiring "$CFG_DIR/settings.json"
echo "  ✓ hook wiring stripped from settings.json"

if [ "$PURGE" -eq 1 ]; then
  rm -f "$CFG_DIR/learner.json"
  rm -rf "$CFG_DIR/learner"
  echo "  ✓ config + progress data purged"
else
  # Throttle-cache state, not progress data: unlike memory.md/recap.md, losing this
  # stamp costs nothing but one extra version check, so it doesn't need --purge to
  # go. Otherwise a plain uninstall/reinstall stays silent for up to 24h even though
  # the notifier hook was just removed and put back.
  rm -f "$CFG_DIR/learner/.last-update-check"
  echo "  • config and progress data kept ($CFG_DIR/learner.json, $CFG_DIR/learner/) — pass --purge to delete"
fi

echo "  • per-repo overrides (.claude/learner.local.json) are not enumerable — remove them yourself,"
echo "    or run: ./uninstall.sh --project <repo>"
echo
echo "Done."
