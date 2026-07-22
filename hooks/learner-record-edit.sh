#!/bin/sh
# Part of "learning mode" (paired with learner-quiz.sh).
#
# PostToolUse/Write|Edit hook: records source files edited during this session
# into a per-session state file. learner-quiz.sh reads that file on Stop to decide
# whether to quiz the user on what was just built.
#
# Opt-in: no-op unless .claude/learner.local.json exists (it holds the learner's
# level). Wired as a PostToolUse/Write|Edit hook; see .claude/settings.json.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# Feature is opt-in: do nothing unless the learner has declared a level.
[ -f "$PROJECT_DIR/.claude/learner.local.json" ] || exit 0

DATA=$(cat)
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""')
FP=$(printf '%s' "$DATA" | jq -r '.tool_input.file_path // ""')

[ -n "$SID" ] || exit 0
[ -n "$FP" ] || exit 0

# Which files are worth learning from — configurable via `trackGlobs` in
# learner.local.json (array of shell globs). Default: common source files across
# languages. Generated / vendored directories are always ignored.
LEVEL_FILE="$PROJECT_DIR/.claude/learner.local.json"
GLOBS=$(jq -r 'if (.trackGlobs|type)=="array" then (.trackGlobs|join(" ")) else empty end' "$LEVEL_FILE" 2>/dev/null)
[ -n "$GLOBS" ] || GLOBS="*.kt *.java *.scala *.py *.rb *.go *.rs *.php *.cs *.swift *.ts *.tsx *.js *.jsx *.vue *.sql *.graphql *.proto *.properties *.yaml *.yml"

# Skip generated / dependency / VCS directories regardless of glob match.
case "$FP" in
  */build/*|*/dist/*|*/out/*|*/target/*|*/node_modules/*|*/vendor/*|*/.git/*|*/.gradle/*|*/__pycache__/*|*/.venv/*|*/coverage/*) exit 0 ;;
esac

matched=0
for g in $GLOBS; do
  # shellcheck disable=SC2254 -- $g is a glob pattern on purpose
  case "$FP" in $g) matched=1; break ;; esac
done
[ "$matched" = 1 ] || exit 0

# Pending edits since the last quiz (granular question), and a session-wide log
# that is never cleared (used for the periodic synthesis question).
STATE="${TMPDIR:-/tmp}/claude-learner-${SID}.edits"
SESSION="${TMPDIR:-/tmp}/claude-learner-${SID}.session"
echo "$FP" >> "$STATE"
echo "$FP" >> "$SESSION"
exit 0
