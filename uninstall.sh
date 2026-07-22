#!/usr/bin/env bash
# Remove "learning mode" from a target repository (reverse of install.sh).
#
# Usage:
#   ./uninstall.sh [--purge] [TARGET_REPO]
#
#   --purge     Also delete the per-developer data (learner.local.json,
#               learner-memory.md, learner-recap.md, the example file). Without it,
#               those are kept so your progress survives a reinstall.
#   TARGET_REPO Defaults to the current directory.
#
# Requires: jq.
set -euo pipefail

PURGE=0
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done
TARGET="${TARGET:-$PWD}"
TARGET="$(cd "$TARGET" && pwd)"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required"; exit 1; }

CLAUDE_DIR="$TARGET/.claude"
echo "→ Removing learning mode from: $TARGET"

# 1) Hooks + skill
rm -f "$CLAUDE_DIR/hooks/learner-onboard.sh" \
      "$CLAUDE_DIR/hooks/learner-record-edit.sh" \
      "$CLAUDE_DIR/hooks/learner-quiz.sh" \
      "$CLAUDE_DIR/hooks/learner-cleanup.sh"
rm -rf "$CLAUDE_DIR/skills/learner"
echo "  ✓ hooks + skill removed"

# 2) Strip learner entries from settings.json; drop events / .hooks left empty.
SETTINGS="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS" ]; then
  TMP="$(mktemp)"
  jq '
    if .hooks then
      .hooks |= (
        (with_entries(.value |= map(select(any(.hooks[]?; .command | contains("learner-")) | not))))
        | with_entries(select(.value | length > 0))
      )
      | (if (.hooks | length) == 0 then del(.hooks) else . end)
    else . end
  ' "$SETTINGS" > "$TMP"
  mv "$TMP" "$SETTINGS"
  echo "  ✓ learner hook wiring stripped from settings.json"
fi

# 3) .gitignore lines
GI="$TARGET/.gitignore"
if [ -f "$GI" ]; then
  TMP="$(mktemp)"
  grep -vE '^\.claude/(learner\.local\.json|learner-memory\.md|learner-recap\.md)$' "$GI" > "$TMP" || true
  mv "$TMP" "$GI"
  echo "  ✓ .gitignore entries removed"
fi

# 4) Per-dev data (only with --purge)
if [ "$PURGE" -eq 1 ]; then
  rm -f "$CLAUDE_DIR/learner.local.json" \
        "$CLAUDE_DIR/learner.local.json.example" \
        "$CLAUDE_DIR/learner-memory.md" \
        "$CLAUDE_DIR/learner-recap.md"
  echo "  ✓ per-dev data purged"
else
  echo "  • per-dev data kept (learner.local.json / memory / recap) — pass --purge to delete"
fi

echo
echo "Done."
