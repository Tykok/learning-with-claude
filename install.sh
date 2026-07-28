#!/usr/bin/env bash
# Install the learner skill + hooks at Claude Code user level (all repos).
#
# Usage:
#   ./install.sh [--level D|J|C|S|E] [--synthesis off|rare|normal|often]
#                [--blanks N] [--dry-run] [--yes]
#
#   --level L      Your level. Full words (junior, senior, …) are accepted.
#   --synthesis W  How often a synthesis question replaces a granular one.
#   --blanks N     Holes left in a fill-in exercise.
#   --dry-run      Print what would be written, write nothing.
#   --yes          Never prompt; use defaults for anything not passed.
#
# Idempotent: re-running re-copies the files and re-merges the hook wiring
# without duplicating entries, and never overwrites an existing config.
# Requires: Claude Code. Strongly recommends: jq.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# shellcheck source=hooks/learner-config.sh
. "$SRC_DIR/hooks/learner-config.sh"

LEVEL=""; SYNTH=""; BLANKS=""; DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --level)     LEVEL="${2:-}"; shift 2 ;;
    --level=*)   LEVEL="${1#*=}"; shift ;;
    --synthesis) SYNTH="${2:-}"; shift 2 ;;
    --synthesis=*) SYNTH="${1#*=}"; shift ;;
    --blanks)    BLANKS="${2:-}"; shift 2 ;;
    --blanks=*)  BLANKS="${1#*=}"; shift ;;
    --dry-run)   DRY=1; shift ;;
    --yes|-y)    YES=1; shift ;;
    -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unexpected argument '$1' (learner installs globally, not per repo)"; exit 1 ;;
  esac
done

# 1) Claude Code must exist — installing without it does nothing useful.
if ! command -v claude >/dev/null 2>&1 && [ ! -d "$CFG_DIR" ]; then
  echo "error: Claude Code not found (no 'claude' on PATH and no $CFG_DIR)."
  echo "       Install it first: https://claude.com/claude-code"
  exit 1
fi

# 2) jq is required by every hook, but its absence is recoverable.
HAVE_JQ=1
command -v jq >/dev/null 2>&1 || HAVE_JQ=0

# 3) A settings.json we cannot parse is a hard stop, before touching anything.
SETTINGS="$CFG_DIR/settings.json"
if [ -f "$SETTINGS" ] && [ "$HAVE_JQ" = 1 ]; then
  jq -e . "$SETTINGS" >/dev/null 2>&1 || {
    echo "error: $SETTINGS is not valid JSON — fix or move it, then re-run."
    exit 1
  }
fi
if [ "$HAVE_JQ" = 0 ]; then
  echo "error: jq is required to merge the hook wiring (brew install jq / apt install jq)."
  exit 1
fi

CONFIG="$CFG_DIR/learner.json"
CONFIG_EXISTS=0
[ -f "$CONFIG" ] && CONFIG_EXISTS=1

# 4) Onboarding — only for values not passed as flags, only when we have a TTY.
if [ "$CONFIG_EXISTS" = 0 ]; then
  if [ -z "$LEVEL" ] && [ -t 0 ] && [ "$YES" = 0 ]; then
    echo "Your level on the code you will be writing:"
    echo "  D Discovering   J Junior   C Competent   S Senior   E Expert"
    printf 'level [C]: '; read -r LEVEL || LEVEL=""
    LEVEL="${LEVEL:-C}"
  fi
  if [ -z "$SYNTH" ] && [ -t 0 ] && [ "$YES" = 0 ]; then
    printf 'synthesis question every … (off / rare / normal / often) [normal]: '
    read -r SYNTH || SYNTH=""
  fi
  if [ -z "$BLANKS" ] && [ -t 0 ] && [ "$YES" = 0 ]; then
    printf 'holes per fill-in exercise [2]: '
    read -r BLANKS || BLANKS=""
  fi
  SYNTH="${SYNTH:-normal}"
  BLANKS="${BLANKS:-2}"
  [ -n "$LEVEL" ] || { echo "error: --level is required (D|J|C|S|E)"; exit 1; }
fi

# 5) Validate.
if [ "$CONFIG_EXISTS" = 0 ]; then
  NORM="$(learner_level "$LEVEL")"
  [ -n "$NORM" ] || { echo "error: --level must be D|J|C|S|E (or the full word)"; exit 1; }
  case "$SYNTH" in off|rare|normal|often) ;;
    *) echo "error: --synthesis must be off | rare | normal | often"; exit 1 ;;
  esac
  case "$BLANKS" in ''|*[!0-9]*) echo "error: --blanks must be an integer >= 1"; exit 1 ;; esac
  [ "$BLANKS" -ge 1 ] || { echo "error: --blanks must be an integer >= 1"; exit 1; }
fi

echo "→ Installing learner into: $CFG_DIR"
if [ "$DRY" = 1 ]; then
  echo "  (dry run — nothing will be written)"
  echo "  would copy 5 hooks    → $CFG_DIR/hooks/"
  echo "  would copy the skill  → $CFG_DIR/skills/learner/"
  echo "  would merge 4 hooks   → $SETTINGS"
  if [ "$CONFIG_EXISTS" = 1 ]; then
    echo "  would keep existing   → $CONFIG"
  else
    echo "  would write config    → $CONFIG (level=$NORM, synthesis=$SYNTH, blanks=$BLANKS)"
  fi
  exit 0
fi

mkdir -p "$CFG_DIR/hooks" "$CFG_DIR/skills/learner/references" "$CFG_DIR/learner"

for h in learner-config.sh learner-onboard.sh learner-record-edit.sh \
         learner-quiz.sh learner-cleanup.sh; do
  cp "$SRC_DIR/hooks/$h" "$CFG_DIR/hooks/$h"
  chmod +x "$CFG_DIR/hooks/$h"
done
echo "  ✓ hooks → $CFG_DIR/hooks/"

cp "$SRC_DIR/skills/learner/SKILL.md" "$CFG_DIR/skills/learner/SKILL.md"
cp "$SRC_DIR"/skills/learner/references/*.md "$CFG_DIR/skills/learner/references/"
echo "  ✓ skill → $CFG_DIR/skills/learner/"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak"
TMP="$(mktemp)"
jq -n \
  --argjson base "$(cat "$SETTINGS")" \
  --argjson add "$(cat "$SRC_DIR/hooks/settings.snippet.json")" '
  # For each event the snippet defines, drop existing "learner-" entries then
  # append the fresh ones, so re-running never duplicates.
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
echo "  ✓ hook wiring merged → $SETTINGS (backup: settings.json.bak)"

if [ "$CONFIG_EXISTS" = 1 ]; then
  echo "  • $CONFIG already exists — left untouched"
else
  jq -n --arg lvl "$NORM" --arg syn "$SYNTH" --argjson bl "$BLANKS" '{
    level: $lvl, enabled: true, questionStyles: "auto",
    synthesisFrequency: $syn, blanksPerExercise: $bl,
    untrackGlobs: [], disabledPaths: []
  }' > "$CONFIG"
  echo "  ✓ config → $CONFIG (level=$NORM, synthesis=$SYNTH, blanks=$BLANKS)"
fi

echo
echo "Done. Learner is active in every git repo you open with Claude Code."
echo "  learner status        what to improve"
echo "  learner quiz          quiz me on this branch"
echo "  learner off           silence it in the current repo"
