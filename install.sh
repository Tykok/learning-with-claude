#!/usr/bin/env bash
# Install "learning mode" (learner skill + hooks) into a target repository.
#
# Usage:
#   ./install.sh [TARGET_REPO]     # default: current directory
#
# Idempotent: re-running re-copies files and re-merges the hook config without
# creating duplicate hook entries. Requires: jq.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$PWD}"
TARGET="$(cd "$TARGET" && pwd)"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq / apt install jq)"; exit 1; }

echo "→ Installing learning mode into: $TARGET"

if [ ! -d "$TARGET/.git" ]; then
  echo "  ⚠  $TARGET is not a git repo root (continuing anyway)."
fi

CLAUDE_DIR="$TARGET/.claude"
mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills/learner"

# 1) Hooks
cp "$SRC_DIR/hooks/learner-onboard.sh"      "$CLAUDE_DIR/hooks/"
cp "$SRC_DIR/hooks/learner-record-edit.sh"  "$CLAUDE_DIR/hooks/"
cp "$SRC_DIR/hooks/learner-quiz.sh"         "$CLAUDE_DIR/hooks/"
chmod +x "$CLAUDE_DIR/hooks/learner-onboard.sh" \
         "$CLAUDE_DIR/hooks/learner-record-edit.sh" \
         "$CLAUDE_DIR/hooks/learner-quiz.sh"
echo "  ✓ hooks → .claude/hooks/"

# 2) Skill
cp "$SRC_DIR/skills/learner/SKILL.md" "$CLAUDE_DIR/skills/learner/SKILL.md"
echo "  ✓ skill → .claude/skills/learner/SKILL.md"

# 3) Merge hook config into .claude/settings.json (idempotent).
SETTINGS="$CLAUDE_DIR/settings.json"
SNIPPET="$SRC_DIR/hooks/settings.snippet.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

TMP="$(mktemp)"
jq -n \
  --argjson base "$(cat "$SETTINGS")" \
  --argjson add "$(cat "$SNIPPET")" '
  # For each event the snippet defines, drop any existing "learner-" hook
  # entries then append the fresh ones — so re-running never duplicates.
  reduce ($add.hooks | keys[]) as $ev (
    $base;
    .hooks[$ev] = (
      ((.hooks[$ev] // [])
        | map(select(any(.hooks[]; .command | contains("learner-")) | not)))
      + $add.hooks[$ev]
    )
  )
' > "$TMP"
mv "$TMP" "$SETTINGS"
echo "  ✓ hook config merged → .claude/settings.json"

# 4) Example config (do not overwrite a real one).
if [ ! -f "$CLAUDE_DIR/learner.local.json" ]; then
  cp "$SRC_DIR/learner.local.json.example" "$CLAUDE_DIR/learner.local.json.example"
  echo "  ✓ example config → .claude/learner.local.json.example (rename to activate, or let the SessionStart hook prompt you)"
else
  echo "  • .claude/learner.local.json already present — left untouched"
fi

# 5) Gitignore the per-developer files.
GI="$TARGET/.gitignore"
add_ignore() {
  local pat="$1"
  grep -qxF "$pat" "$GI" 2>/dev/null || echo "$pat" >> "$GI"
}
touch "$GI"
add_ignore ".claude/learner.local.json"
add_ignore ".claude/learner-memory.md"
add_ignore ".claude/learner-recap.md"
echo "  ✓ .gitignore updated (per-dev files ignored)"

echo
echo "Done. Start a new Claude Code session in $TARGET — the SessionStart hook will"
echo "prompt for your level, or run: learner config"
