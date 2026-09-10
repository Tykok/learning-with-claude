#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SessionEnd hook: turn one finished transcript into one line of counters.
#
# Deterministic only. Nothing here judges anything — the semantic pass runs
# later, in a subagent, from skills/pilot/references/score.md. This split is
# what makes the score defensible: these numbers are reproducible from the
# transcript by anyone, and the judgement is separately auditable against the
# quotes it must cite.
#
# Two constraints shape the whole file:
#
#  - SessionEnd hooks share a 1.5s budget, raised to the wired `timeout` (15).
#    So: one jq pass over the transcript, at most two cheap git calls, and no
#    second read of the file.
#  - Hooks for one event run in parallel, and learner-cleanup.sh deletes
#    $TMPDIR/claude-learner-<sid>.* at this same event. So nothing here may read
#    those files; every counter is recomputed from the transcript, which holds
#    every Write/Edit Claude made anyway.
#
# Unlike every other learner hook, this one does NOT require a git repo: a
# delegation habit does not stop at a repo boundary, and a session held in a
# plain directory is precisely the kind that used to go unmeasured.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

DATA=$(cat 2>/dev/null)
CFG=$(learner_config) || exit 0
pilot_enabled "$CFG" || exit 0

SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""' 2>/dev/null)
TP=$(printf '%s' "$DATA" | jq -r '.transcript_path // ""' 2>/dev/null)
[ -n "$SID" ] || exit 0
[ -n "$TP" ] && [ -f "$TP" ] || exit 0

# Empty when this is not a repo — deliberate, see the header. When it IS a repo
# and the dev switched learner off there, honour that: disabledPaths is a
# privacy setting, and Pilot reads more than the quiz does, not less.
ROOT=$(learner_repo_root)
if [ -n "$ROOT" ] && learner_path_disabled "$ROOT" "$CFG"; then exit 0; fi

REPO='-'
[ -n "$ROOT" ] && REPO=$(basename "$ROOT")

QDIR="$LEARNER_CFG_DIR/learner"
mkdir -p "$QDIR" 2>/dev/null || exit 0
Q="$QDIR/pilot-queue"

# SessionEnd can fire more than once for one session id (clear, then resume).
# A second line would double-count the session in every rolling mean.
if [ -f "$Q" ] && grep -q "^sid=$SID " "$Q" 2>/dev/null; then exit 0; fi

# --- the single jq pass -------------------------------------------------------
# Medians are computed here rather than by piping to `sort -n`: we are already
# inside jq with the list in hand, and it saves a subprocess against the budget.
COUNTS=$(jq -rn '
  # A genuine prompt can legitimately BEGIN with a <system-reminder> block the
  # harness prepends ahead of the actual text in the same message, so this
  # cannot be a prefix test. Strip every wrapper the harness or a slash command
  # can inject, then classify on what is left: a slash-command echo or a bare
  # caveat/stdout wrapper strips to nothing and is still rejected, but a real
  # prompt that merely carries a reminder ahead of it is not lost with it.
  def strip:
    gsub("(?s)<system-reminder>.*?</system-reminder>"; "")
    | gsub("(?s)<local-command-[^>]*>.*?</local-command-[^>]*>"; "")
    | gsub("(?s)<command-name>.*?</command-name>"; "")
    | gsub("(?s)<command-message>.*?</command-message>"; "")
    | gsub("(?s)<command-args>.*?</command-args>"; "")
    | gsub("^[[:space:]]+|[[:space:]]+$"; "");

  def isprompt:
    .type == "user"
    and ((.isMeta // false) | not)
    and ((.message.content // null) | type == "string")
    and ((.message.content | strip | length) > 0);

  # Claude Code stamps milliseconds, which fromdateiso8601 rejects.
  def ts:
    (.timestamp // "") as $t
    | if $t == "" then null
      else ($t | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) end;

  # The trailing element of a content ending in a newline is counted. Exactness
  # is not the point; comparability across sessions is, and this is uniform.
  def nlines: if . == null then 0 else (split("\n") | length) end;

  def words: [splits("[[:space:]]+")] | map(select(length > 0)) | length;

  [inputs] as $all
  | [ $all[] | select(isprompt) ]                       as $p
  # Word counts are taken on the STRIPPED text: reminder boilerplate ahead of
  # a real prompt must not inflate pw_med/pw_min for the sessions that carry it.
  | [ $p[] | .message.content | strip | words ]         as $w
  | [ $all[] | ts | select(. != null) ]                 as $t
  | [ $p[]   | ts | select(. != null) ]                 as $pt
  | [ $all[] | select(.type == "assistant")
             | (.message.content // [])
             | select(type == "array")
             | .[] | select(.type == "tool_use") ]      as $tu
  | [ $tu[] | select(.name == "Write" or .name == "Edit" or .name == "NotebookEdit") ] as $wt
  | {
      date:      (if ($t | length) == 0 then "-" else (($t | min) | strftime("%Y-%m-%d")) end),
      dur_min:   (if ($t | length) < 2 then 0 else (((($t | max) - ($t | min)) / 60) | floor) end),
      prompts:   ($p | length),
      pw_med:    (if ($w | length) == 0 then 0 else ($w | sort | .[((length / 2) | floor)]) end),
      pw_min:    (if ($w | length) == 0 then 0 else ($w | min) end),
      burst:     (if ($pt | length) == 0 then 0
                  else ([ $pt[] as $s | [ $pt[] | select(. >= $s and . <= ($s + 300)) ] | length ] | max) end),
      tools:     ($tu | length),
      cl_writes: ($wt | length),
      cl_lines:  ([ $wt[] | (.input // {}) | (.content // .new_string // .new_source // null) | nlines ] | add // 0)
    }
  | to_entries | map("\(.key)=\(.value)") | join(" ")
' "$TP" 2>/dev/null)

[ -n "$COUNTS" ] || exit 0

DATE=$(printf '%s' "$COUNTS" | sed -n 's/^date=\([^ ]*\).*/\1/p')
CL_LINES=$(printf '%s' "$COUNTS" | sed -n 's/.*cl_lines=\([0-9]*\).*/\1/p')
case "$CL_LINES" in ''|*[!0-9]*) CL_LINES=0 ;; esac
[ -n "$DATE" ] && [ "$DATE" != "-" ] || DATE=$(date +%F)

# --- the writing axis ---------------------------------------------------------
# Exact when the coach watcher measured the dev's own lines this session and
# persisted them (hooks/coach-watch.sh, Task 3); estimated from the working tree
# when there is a repo to diff; unavailable otherwise. Estimated and unavailable
# are marked, never dressed up: `~` in the dashboard, `-` not assessable.
#
# A coach tally alone is a lower bound, not a true count: the default pomodoro
# cadence measures only at the end of a completed work block, so a session that
# ends mid-block never runs a cycle for that block and its lines are never
# tallied. Trusting the tally as exact regardless would then label a session
# `est=0` while silently missing its tail — understating what the dev wrote,
# which is the one direction this score must not be wrong in. The git estimate
# (uncommitted insertions minus Claude's own lines) sees exactly that untallied
# tail, so taking the LARGER of the two is never worse than either alone: it
# recovers most of what the mid-block ending loses. `est=0` only when the tree
# holds nothing beyond the tally already counted (estimate <= tally) — that is
# the case where nothing untallied is sitting in the working tree; otherwise
# the estimate wins and the line is marked `est=1`, same as when there is no
# tally at all.
COACH=0
[ -n "$ROOT" ] && learner_coach_active "$CFG" "$ROOT" && COACH=1
DEVF="$QDIR/pilot-devlines"
DEV='-'
EST='-'
TALLY=''
if [ -f "$DEVF" ] && grep -q "^$SID " "$DEVF" 2>/dev/null; then
  TALLY=$(awk -v s="$SID" '$1 == s { n += $2 } END { print n + 0 }' "$DEVF")
fi
if [ -n "$ROOT" ]; then
  # --shortstat over HEAD so staged work counts too. This measures the working
  # tree now, not this session's delta — needed even when a tally exists, to
  # catch the untallied tail described above.
  INS=$(git -C "$ROOT" diff --shortstat HEAD 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^insertion/) print $(i - 1) }')
  case "$INS" in ''|*[!0-9]*) INS=0 ;; esac
  ESTIMATE=$((INS - CL_LINES))
  [ "$ESTIMATE" -lt 0 ] && ESTIMATE=0
  if [ -n "$TALLY" ] && [ "$ESTIMATE" -le "$TALLY" ]; then
    DEV=$TALLY
    EST=0
  else
    DEV=$ESTIMATE
    EST=1
  fi
elif [ -n "$TALLY" ]; then
  DEV=$TALLY
  EST=0
fi

REST=$(printf '%s' "$COUNTS" | sed 's/^date=[^ ]* *//')
printf 'sid=%s date=%s repo=%s %s dev_lines=%s est=%s coach=%s jsonl=%s\n' \
  "$SID" "$DATE" "$REPO" "$REST" "$DEV" "$EST" "$COACH" "$TP" >> "$Q"
exit 0
