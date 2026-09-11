#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SessionStart hook: decide whether Pilot has anything to do, and say so once.
#
# Two things can be due, and the order between them is not cosmetic: the scorer
# drains finished sessions into pilot.md, and a brief opened before that drain
# would quote the dev last week's numbers. So when both are due the scorer is
# named first and the brief waits for the next session start.
#
# Emits additionalContext, which is not rendered in the console — Claude acts on
# it after serving the dev's first request, never instead of it.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

DATA=$(cat 2>/dev/null)
CFG=$(learner_config) || exit 0
pilot_enabled "$CFG" || exit 0

# disabledPaths is a privacy setting, honoured for Pilot exactly as it is for
# pilot-record.sh: a session started inside a disabled repo gets neither a
# scoring dispatch nor a brief — both would surface evidence gathered from
# other repositories into a repo the dev asked Pilot to stay out of. Empty
# ROOT (not a repo) is not a disabled path and must not gate anything below.
ROOT=$(learner_repo_root)
if [ -n "$ROOT" ] && learner_path_disabled "$ROOT" "$CFG"; then exit 0; fi

# SessionStart fires on startup, resume, clear, compact and fork. Only the first
# two may act: a compaction mid-session would otherwise re-offer a brief the dev
# has already been given, on the same day.
SOURCE=$(printf '%s' "$DATA" | jq -r '.source // "startup"' 2>/dev/null)
case "$SOURCE" in startup|resume) ;; *) exit 0 ;; esac

PDIR="$LEARNER_CFG_DIR/learner"
Q="$PDIR/pilot-queue"
STAMPS="$PDIR/pilot-stamps"

pb_stamp() {  # pb_stamp KEY FALLBACK
  _pbs=$(sed -n "s/^$1=\\([0-9]*\\)$/\\1/p" "$STAMPS" 2>/dev/null | tail -1)
  case "$_pbs" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$_pbs" ;; esac
}

NOW=$(date +%s)
GAP_H=$(pilot_int "$(printf '%s' "$CFG" | jq -r '.pilotJudgeIntervalHours // empty')" 24 1)
CAD_D=$(pilot_int "$(printf '%s' "$CFG" | jq -r '.pilotCadenceDays // empty')" 7 1)
LAST_SCORE=$(pb_stamp score 0)
LAST_BRIEF=$(pb_stamp brief 0)
DECLINED=$(pb_stamp declined 0)

SCORE_DUE=0
if [ -s "$Q" ] && [ $((NOW - LAST_SCORE)) -ge $((GAP_H * 3600)) ]; then SCORE_DUE=1; fi

# A brief needs something to argue from — and one or two scored sessions is not
# enough of one. rubric.md is explicit that naming anything off two or three
# sessions "is the fastest way to make the whole number look like guesswork",
# so the same floor applies here, before the conversation even opens: at least
# four scored rows in the Sessions table. Counting is a cheap grep on the row
# shape (a real date starts the row; the header and any separator do not), not
# a jq parse of the whole file.
SESSIONS_N=$(grep -c '^| [0-9][0-9][0-9][0-9]-' "$PDIR/pilot.md" 2>/dev/null)
case "$SESSIONS_N" in ''|*[!0-9]*) SESSIONS_N=0 ;; esac

BRIEF_DUE=0
if [ "$DECLINED" -lt 2 ] && [ -s "$PDIR/pilot.md" ] && [ "$SESSIONS_N" -ge 4 ] \
   && [ $((NOW - LAST_BRIEF)) -ge $((CAD_D * 86400)) ]; then
  BRIEF_DUE=1
fi

[ "$SCORE_DUE" = 0 ] && [ "$BRIEF_DUE" = 0 ] && exit 0

CTX=''
if [ "$SCORE_DUE" = 1 ]; then
  CTX="Pilot has $(grep -c '' "$Q" 2>/dev/null) finished session(s) waiting to be scored.
Dispatch ONE subagent, with no other context from this session, to read the \`pilot\` skill's
references/score.md and follow it: drain $Q, append to $PDIR/pilot.md and
$PDIR/pilot-evidence.md, and record the drain by writing \`score=$NOW\` into $STAMPS.
A subagent, not this session: scoring whether the dev pushed back on you is not something you
can judge from inside the conversation it happened in."
fi
if [ "$BRIEF_DUE" = 1 ]; then
  if [ "$SCORE_DUE" = 1 ]; then
    CTX="$CTX

A weekly brief is also due. Do NOT open it in this session — it would argue from an index the
scoring pass above has not written yet. It will be offered again at the next session start."
  else
    CTX="Pilot's weekly brief is due. Read the \`pilot\` skill's references/brief.md and follow
it after serving the dev's request — never instead of it. If the dev defers, that is not a
failure: increment \`declined\` in $STAMPS and move on."
  fi
fi

jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
