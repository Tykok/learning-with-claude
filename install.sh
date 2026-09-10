#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install the learner skill + hooks at Claude Code user level (all repos).
#
# Usage:
#   ./install.sh [--level D|J|C|S|E] [--synthesis off|rare|normal|often]
#                [--blanks N] [--origin curl|brew|apt] [--dry-run] [--yes]
#
#   --level L      Your level. Full words (junior, senior, …) are accepted.
#   --synthesis W  How often a synthesis question replaces a granular one.
#   --blanks N     Holes left in a fill-in exercise.
#   --origin O     Who is installing: curl, brew or apt. Set by the brew/apt
#                  wrapper scripts — pass it by hand only if you know why.
#                  Default: curl.
#   --dry-run      Print what would be written, write nothing.
#   --yes          Never prompt; defaults for anything not passed — but --level
#                  has no default, so pass it too or the install aborts.
#
# Idempotent: re-running re-copies the files and re-merges the hook wiring
# without duplicating entries, and never overwrites an existing config.
# Requires: Claude Code, and jq (the hook-wiring merge cannot run without it).
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# shellcheck source=hooks/learner-config.sh
. "$SRC_DIR/hooks/learner-config.sh"

LEVEL=""; SYNTH=""; BLANKS=""; ORIGIN=""; DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --level)     LEVEL="${2:-}"; shift 2 ;;
    --level=*)   LEVEL="${1#*=}"; shift ;;
    --synthesis) SYNTH="${2:-}"; shift 2 ;;
    --synthesis=*) SYNTH="${1#*=}"; shift ;;
    --blanks)    BLANKS="${2:-}"; shift 2 ;;
    --blanks=*)  BLANKS="${1#*=}"; shift ;;
    --origin)    ORIGIN="${2:-}"; shift 2 ;;
    --origin=*)  ORIGIN="${1#*=}"; shift ;;
    --dry-run)   DRY=1; shift ;;
    --yes|-y)    YES=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unexpected argument '$1' (learner installs globally, not per repo)"; exit 1 ;;
  esac
done

ORIGIN="${ORIGIN:-curl}"
case "$ORIGIN" in
  curl|brew|apt) ;;
  *) echo "error: --origin must be curl | brew | apt"; exit 1 ;;
esac

# 1) Claude Code must exist — installing without it does nothing useful.
if ! command -v claude >/dev/null 2>&1 && [ ! -d "$CFG_DIR" ]; then
  echo "error: Claude Code not found (no 'claude' on PATH and no $CFG_DIR)."
  echo "       Install it first: https://claude.com/claude-code"
  exit 1
fi

# 2) jq is required: every hook needs it at run time, and the wiring merge below
#    cannot happen without it. Checked here, aborted at (3) once a settings.json
#    we might have been able to validate has been looked at.
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
  # Counted from disk, not hardcoded — see the copy loop and the snippet below.
  N_HOOKS=$(find "$SRC_DIR/hooks" -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')
  N_WIRED=$(jq '[.. | .command? // empty] | length' "$SRC_DIR/hooks/settings.snippet.json")
  echo "  (dry run — nothing will be written)"
  echo "  would copy $N_HOOKS hooks   → $CFG_DIR/hooks/"
  echo "  would copy the skill  → $CFG_DIR/skills/learner/"
  echo "  would merge $N_WIRED hooks   → $SETTINGS"
  if [ "$CONFIG_EXISTS" = 1 ]; then
    echo "  would keep existing   → $CONFIG"
  else
    echo "  would write config    → $CONFIG (level=$NORM, synthesis=$SYNTH, blanks=$BLANKS)"
  fi
  exit 0
fi

mkdir -p "$CFG_DIR/hooks" "$CFG_DIR/skills/learner/references" "$CFG_DIR/learner"

# Copy every hook script this repo ships, derived from what is actually in
# hooks/ rather than named one by one — a hand-maintained list here is exactly
# what let three Pilot hooks ship uncopied even after Tasks 2/4/5 wrote them.
# A new hook needs no edit to this loop, only a file in hooks/.
for h in "$SRC_DIR"/hooks/*.sh; do
  base="$(basename "$h")"
  cp "$h" "$CFG_DIR/hooks/$base"
  chmod +x "$CFG_DIR/hooks/$base"
done
echo "  ✓ hooks → $CFG_DIR/hooks/"

cp "$SRC_DIR/skills/learner/SKILL.md" "$CFG_DIR/skills/learner/SKILL.md"
cp "$SRC_DIR"/skills/learner/references/*.md "$CFG_DIR/skills/learner/references/"
# Always refresh — unlike learner.json below, this must match what's on disk.
cp "$SRC_DIR/VERSION" "$CFG_DIR/skills/learner/VERSION"
printf '%s' "$ORIGIN" > "$CFG_DIR/skills/learner/INSTALL_ORIGIN"
echo "  ✓ skill → $CFG_DIR/skills/learner/"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
# Keep the pristine, pre-learner backup: a second install must not overwrite it
# with the already-merged file.
[ -f "$SETTINGS.bak" ] || cp "$SETTINGS" "$SETTINGS.bak"
TMP="$(mktemp)"
jq -n \
  --argjson base "$(cat "$SETTINGS")" \
  --argjson add "$(cat "$SRC_DIR/hooks/settings.snippet.json")" '
  # For each event the snippet defines, drop existing entries this project
  # installed, then append the fresh ones, so re-running never duplicates.
  #
  # Matched by naming convention, not by an exhaustive per-script list: every
  # hook script this project ships is named "learner-*.sh", "coach-*.sh" or
  # "pilot-*.sh" (see install.sh'"'"'s copy loop and
  # hooks/settings.snippet.json). A convention-based match keeps pace with
  # new scripts on its own — no list to remember to update here — which is
  # exactly what a literal-name or single-prefix match cannot do (a
  # coach-*.sh hook once slipped past a "learner-"-only match this same way,
  # and the three pilot-*.sh hooks shipped uncopied by install.sh'"'"'s old
  # per-script list for the same reason).
  #
  # The name match alone is not enough: a bare "/hooks/(learner|coach)-*.sh"
  # matches that path shape anywhere on disk, so a sibling tool that also
  # ships a "hooks/" directory with a same-prefixed script (plausible —
  # "coach" is a generic word, and $CLAUDE_CONFIG_DIR/hooks is a directory
  # other tools can also write into) would get silently swept up. Anchoring
  # on a literal ".claude" segment (with an optional trailing "}", closing
  # the "${VAR:-default}" this project'"'"'s own commands are always wrapped
  # in) immediately before "/hooks/" requires the match to run through a
  # Claude Code config tree specifically — every shape this project has ever
  # wired does: today'"'"'s "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/", the
  # old per-project "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/", and the legacy
  # bare ".claude/hooks/" — while a path with no ".claude" segment at all,
  # like /opt/otherteam/hooks/coach-lint.sh, is rejected outright. Anchoring
  # tighter, to today'"'"'s exact "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/"
  # literal, was considered and rejected: it would stop recognising the older
  # forms above, leaving that wiring behind forever on an uninstall — the
  # same kind of leak this predicate exists to prevent. Residual risk
  # accepted: another tool that specifically nests its own hook under a
  # ".claude/hooks/" tree with a learner-/coach-/pilot-prefixed name would
  # still collide; that requires deliberately mimicking this project'"'"'s install
  # location and naming convention together, which is a much narrower target
  # than the bare path-shape match this predicate replaces.
  #
  # This is intentionally the same predicate as strip_wiring() in
  # uninstall.sh — keep the two in sync if either changes.
  reduce ($add.hooks | keys[]) as $ev (
    $base;
    .hooks[$ev] = (
      ((.hooks[$ev] // [])
        | map(select(any(.hooks[]; .command | test("\\.claude\\}?/hooks/(learner|coach|pilot)-[A-Za-z0-9_.-]+\\.sh")) | not)))
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
