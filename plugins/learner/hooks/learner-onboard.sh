#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SessionStart: report a broken learner install and nothing else.
#
# install.sh does the onboarding for a traditional install; a plugin install has no
# install.sh at all, so this hook is the only place either kind of first-run gets a nudge.
# Output goes to additionalContext, which is not rendered in the console.

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Learner is installed but `jq` is not on PATH, so all of its hooks are inert. Tell the user, in one line, to install jq (brew install jq / apt-get install jq), then continue with their request."}}'
  exit 0
fi

. "$(dirname "$0")/learner-config.sh"

# Read once, up front: both the duplicate check and the coach arming below need the
# session id, and stdin can only be drained the one time.
DATA=$(cat 2>/dev/null)
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""' 2>/dev/null)

# --- installed twice ---------------------------------------------------------
# The plugin wiring (hooks/hooks.json) and the traditional wiring
# ($CLAUDE_CONFIG_DIR/settings.json) are independent, and neither can see the other.
# Installed both ways, every learner hook runs twice: the Stop hook blocks twice and
# the dev is quizzed twice per turn. Nothing else in the system is in a position to
# notice, so this hook checks.
#
# The test is "am I running from somewhere other than the traditional install's own
# hooks directory, while that install is still there" — exact regardless of whether
# this copy came from the plugin cache, --plugin-dir or a skills-directory plugin,
# and it needs no CLAUDE_PLUGIN_ROOT (substituted into hook *commands*, not
# guaranteed in the hook process's environment).
_lo_self=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || _lo_self=''
_lo_legacy=$(cd "$LEARNER_CFG_DIR/hooks" 2>/dev/null && pwd -P) || _lo_legacy=''
if [ -n "$_lo_self" ] && [ -n "$_lo_legacy" ] && [ "$_lo_self" != "$_lo_legacy" ] \
   && [ -f "$_lo_legacy/learner-quiz.sh" ]; then
  CTX="Learner is installed twice — as a Claude Code plugin and as a traditional install in $LEARNER_CFG_DIR — so every learner hook runs twice this session and the dev will be quizzed twice per turn. Tell the user, in one line, to remove the traditional install (\`uninstall.sh\` from a clone, or \`learner-uninstall\` if it came from Homebrew or apt) and keep the plugin. Then continue with their request."
  jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
  exit 0
fi

# Two PLUGIN copies are the other way to end up wired twice, and the check above cannot
# see it: neither copy is the traditional install, so both pass. It became possible the
# moment the repository root became a plugin in its own right beside plugins/learner —
# `learner@claude-community` and `learner@learning-with-claude` are different plugins by
# Claude Code's name@marketplace rule, so both can be installed and enabled at once, and
# then every hook fires twice exactly as above.
#
# Detected by the only thing that distinguishes the two: their directories. SessionStart
# runs this hook once per wired copy, so each appends its own resolved path to one
# per-session file and the second one along finds a stranger already there. First in
# stays silent — it has nothing to compare against yet — which is why this reports on
# the second run rather than the first.
if [ -n "$_lo_self" ] && [ -n "$SID" ]; then
  _lo_seen="${TMPDIR:-/tmp}/claude-learner-${SID}.onboard-roots"
  if [ -f "$_lo_seen" ] && ! grep -qxF -e "$_lo_self" "$_lo_seen" 2>/dev/null; then
    _lo_other=$(grep -vxF -e "$_lo_self" "$_lo_seen" 2>/dev/null | head -n 1)
    printf '%s\n' "$_lo_self" >> "$_lo_seen" 2>/dev/null
    CTX="Learner is wired twice as a plugin this session — one copy in $_lo_self, another in $_lo_other — so every learner hook runs twice and the dev will be quizzed twice per turn. Tell the user, in one line, to disable one of the two with \`/plugin\` (they are the same plugin from two marketplaces). Then continue with their request."
    jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
    exit 0
  fi
  grep -qxF -e "$_lo_self" "$_lo_seen" 2>/dev/null || printf '%s\n' "$_lo_self" >> "$_lo_seen" 2>/dev/null
fi

ROOT=$(learner_repo_root)
[ -n "$ROOT" ] || exit 0

CFG=$(learner_config)
LEVEL=$(learner_level "$(printf '%s' "$CFG" | jq -r '.level // empty')")
if [ -z "$LEVEL" ]; then
  CTX="Learner is installed but has no valid level, so it will never ask a question. Tell the user, in one line, to run \`learner config level=<D|J|C|S|E>\`, then continue with their request."
  jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
  exit 0
fi

# Coach mode needs a long-running watcher, and nothing in the hook system can
# start one: no hook fires when the *dev* saves a file, so the watcher has to
# poll, and polling means a process that outlives this hook. The one thing this
# hook can do is tell Claude to arm it — which costs the dev no ceremony at
# session start.
learner_coach_active "$CFG" "$ROOT" || exit 0

[ -n "$SID" ] || exit 0

# SessionStart fires on `startup`, `resume`, `clear`, `compact` and `fork`. Only
# `startup` and `resume` may arm: a context compaction mid-session would
# otherwise arm a *second* watcher on the same session id, and the dev would get
# every review twice, on two drifting cadences.
SOURCE=$(printf '%s' "$DATA" | jq -r '.source // "startup"' 2>/dev/null)
case "$SOURCE" in startup|resume) ;; *) exit 0 ;; esac

WATCH="$(dirname "$0")/coach-watch.sh"
CTX="Coach mode is on in this repo: the dev writes the code, you challenge it.
Arm the change watcher now, before anything else, with the Monitor tool:
  command: sh \"$WATCH\" \"$SID\"
  description: coach: the dev's changes
  persistent: true
Then read the \`learner\` skill's references/coach.md so you know the review protocol before the
first notification arrives. Do not implement anything the dev has not delegated with
\`learner coach delegate\` — a PreToolUse hook will refuse it anyway. Then continue with the
dev's request."
jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
