#!/usr/bin/env bash
# Install "learning mode" (learner skill + hooks) into a target repository.
#
# Usage:
#   ./install.sh [--level junior|intermediaire|senior] [TARGET_REPO]
#
#   --level L   Write .claude/learner.local.json immediately with level L (skips the
#               interactive SessionStart prompt). Omit to let the first session ask.
#   TARGET_REPO Defaults to the current directory.
#
# Idempotent: re-running re-copies files and re-merges the hook config without
# creating duplicate hook entries. Requires: jq.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
LEVEL=""
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --level) LEVEL="${2:-}"; shift 2 ;;
    --level=*) LEVEL="${1#*=}"; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done
TARGET="${TARGET:-$PWD}"
TARGET="$(cd "$TARGET" && pwd)"

if [ -n "$LEVEL" ]; then
  case "$LEVEL" in
    junior|intermediaire|senior) ;;
    *) echo "error: --level must be junior | intermediaire | senior"; exit 1 ;;
  esac
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq / apt install jq)"; exit 1; }

echo "→ Installing learning mode into: $TARGET"

if [ ! -d "$TARGET/.git" ]; then
  echo "  ⚠  $TARGET is not a git repo root (continuing anyway)."
fi

CLAUDE_DIR="$TARGET/.claude"
mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills/learner"

# 1) Hooks
for h in learner-onboard.sh learner-record-edit.sh learner-quiz.sh learner-cleanup.sh; do
  cp "$SRC_DIR/hooks/$h" "$CLAUDE_DIR/hooks/$h"
  chmod +x "$CLAUDE_DIR/hooks/$h"
done
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

# 4) Config: write it now if --level was given, else drop the example for reference.
CONFIG="$CLAUDE_DIR/learner.local.json"
if [ -n "$LEVEL" ]; then
  if [ -f "$CONFIG" ]; then
    echo "  • .claude/learner.local.json already present — left untouched (ignoring --level)"
  else
    jq -n --arg lvl "$LEVEL" \
      '{level:$lvl, enabled:true, recapEvery:3, questionStyles:"auto", language:"fr", trouBlanks:2}' \
      > "$CONFIG"
    echo "  ✓ config written → .claude/learner.local.json (level=$LEVEL)"
  fi
elif [ -f "$CONFIG" ]; then
  echo "  • .claude/learner.local.json already present — left untouched"
else
  cp "$SRC_DIR/learner.local.json.example" "$CLAUDE_DIR/learner.local.json.example"
  echo "  • no config yet — the SessionStart hook will prompt you on the next session"
  echo "    (or: re-run with --level, or copy .claude/learner.local.json.example)"
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
if [ -n "$LEVEL" ] || [ -f "$CONFIG" ]; then
  echo "Done. Learning mode is active — start coding, or run: learner status"
else
  echo "Done. Start a new Claude Code session in $TARGET — the SessionStart hook will"
  echo "prompt for your level, or run: learner config"
fi
