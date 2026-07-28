#!/usr/bin/env bash
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
    --project) PROJECT="${2:-}"; shift 2 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unexpected argument '$1'"; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required"; exit 1; }

# Strip every learner hook entry from a settings.json, dropping events left empty.
strip_wiring() {
  local settings="$1"
  [ -f "$settings" ] || return 0
  local tmp
  tmp="$(mktemp)"
  jq '
    if .hooks then
      .hooks |= (
        (with_entries(.value |= map(select(any(.hooks[]?; .command | contains("learner-")) | not))))
        | with_entries(select(.value | length > 0))
      )
      | (if (.hooks | length) == 0 then del(.hooks) else . end)
    else . end
  ' "$settings" > "$tmp"
  mv "$tmp" "$settings"
}

if [ -n "$PROJECT" ]; then
  TARGET="$(cd "$PROJECT" && pwd)"
  echo "→ Cleaning the legacy per-project install in: $TARGET"
  rm -f "$TARGET/.claude/hooks/learner-onboard.sh" \
        "$TARGET/.claude/hooks/learner-record-edit.sh" \
        "$TARGET/.claude/hooks/learner-quiz.sh" \
        "$TARGET/.claude/hooks/learner-cleanup.sh" \
        "$TARGET/.claude/hooks/learner-config.sh"
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
echo "→ Removing learner from: $CFG_DIR"

rm -f "$CFG_DIR/hooks/learner-config.sh" \
      "$CFG_DIR/hooks/learner-onboard.sh" \
      "$CFG_DIR/hooks/learner-record-edit.sh" \
      "$CFG_DIR/hooks/learner-quiz.sh" \
      "$CFG_DIR/hooks/learner-cleanup.sh"
rm -rf "$CFG_DIR/skills/learner"
echo "  ✓ hooks + skill removed"

strip_wiring "$CFG_DIR/settings.json"
echo "  ✓ hook wiring stripped from settings.json"

if [ "$PURGE" -eq 1 ]; then
  rm -f "$CFG_DIR/learner.json"
  rm -rf "$CFG_DIR/learner"
  echo "  ✓ config + progress data purged"
else
  echo "  • config and progress data kept ($CFG_DIR/learner.json, $CFG_DIR/learner/) — pass --purge to delete"
fi

echo "  • per-repo overrides (.claude/learner.local.json) are not enumerable — remove them yourself,"
echo "    or run: ./uninstall.sh --project <repo>"
echo
echo "Done."
