#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The coach watcher. NOT a hook — a long-running script armed once per session
# as a persistent Monitor, whose stdout lines become conversation
# notifications.
#
# Why polling: no Claude Code hook fires when the *dev* saves a file in their
# editor — hooks observe Claude's own tool calls only. Polling the git working
# tree is the only mechanism that can see the dev's edits, which is what coach
# mode is entirely about.
#
# Usage: sh coach-watch.sh <session-id> [--once] [--print-material] [--advance] [--cycle N]
#   --once             run a single cycle without sleeping, then return (tests)
#   --print-material   print "<delta>\t<rel>" per changed file instead of a
#                      trigger line (tests)
#   --advance          advance the baseline and return, emitting nothing (tests)
#   --cycle N          inject the cycle number a real loop would hold at this
#                      point, for the trigger line's "cycle: N" field (tests)
#
# The session id is an argument, not stdin: a hook receives it in its payload
# but a Monitor command does not, so whoever arms the watcher substitutes it.

. "$(dirname "$0")/learner-config.sh"

SID="${1:-}"
[ -n "$SID" ] || exit 0
shift

ONCE=0; PRINT_MATERIAL=0; ADVANCE_ONLY=0; CYCLE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1 ;;
    --print-material) PRINT_MATERIAL=1; ONCE=1 ;;
    --advance) ADVANCE_ONLY=1; ONCE=1 ;;
    --cycle) shift; CYCLE="${1:-1}"; case "$CYCLE" in ''|*[!0-9]*) CYCLE=1 ;; esac ;;
    *) ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

CFG=$(learner_config)
ROOT=$(learner_repo_root)
learner_coach_active "$CFG" "$ROOT" || exit 0

TMPD="${TMPDIR:-/tmp}"
SESSION="$TMPD/claude-learner-${SID}.session"
BASEDIR="$TMPD/claude-learner-${SID}.coach-base"

# --- baseline ---------------------------------------------------------------
# The baseline is a content copy per candidate file, plus the HEAD it was taken
# at. Measuring against HEAD instead would recount the same lines every cycle:
# a file the dev revisits in three consecutive blocks would look like three
# times the work.
#
# <key> is `git hash-object --stdin` of the repo-relative path — hex
# characters, so any path becomes a safe filename.
coach_key() { printf '%s' "$1" | git hash-object --stdin; }

coach_baseline_head() { cat "$BASEDIR/.head" 2>/dev/null || printf ''; }

# Everything the dev touched, minus everything that is not theirs to be
# challenged on.
coach_candidates() {
  _cbh=$(coach_baseline_head)
  {
    git -C "$ROOT" diff --name-only HEAD 2>/dev/null
    git -C "$ROOT" ls-files -o --exclude-standard 2>/dev/null
    # Work the dev committed since the baseline. Without this term a dev who
    # commits at the end of a block empties their own candidate set and gets an
    # idle cut-off for the block they just worked hardest in.
    [ -n "$_cbh" ] && git -C "$ROOT" diff --name-only "$_cbh" HEAD 2>/dev/null
  } | sort -u | while IFS= read -r _cr; do
    [ -n "$_cr" ] || continue
    _ca="$ROOT/$_cr"
    learner_excluded "$_ca" "$CFG" && continue
    # What Claude wrote goes to the learner quiz; what the dev wrote goes to the
    # coach. Per-hunk authorship is not available to a shell script, so a file
    # both touched is attributed to Claude — reviewing Claude's own code as if
    # it were the dev's would produce a challenge the dev cannot answer.
    if [ -f "$SESSION" ] && grep -qxF "$_ca" "$SESSION" 2>/dev/null; then
      continue
    fi
    # A line count over a PNG is noise. Non-empty and no text line = binary; an
    # emptied file is a real change and must survive this test.
    if [ -s "$_ca" ] && ! grep -Iq . "$_ca" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$_cr"
  done
}

# Lines changed since the baseline, for one repo-relative path.
coach_delta() {
  _cdr="$1"
  _cda="$ROOT/$_cdr"
  _cdb="$BASEDIR/$(coach_key "$_cdr")"
  # `grep -c` prints its count AND exits 1 when that count is zero, so a
  # `grep -c … || printf '0'` would emit "00". Arithmetic reads "00" as zero, so
  # such a bug would survive review and only mislead whoever debugs the trigger
  # later. Capture once, normalise once, print once.
  if [ -f "$_cdb" ] && [ -f "$_cda" ]; then
    # `[^+-]|$` so an added or removed *blank* line still counts, while diff's
    # own `---`/`+++` headers (second character is - or +) do not.
    _cdn=$(diff -u "$_cdb" "$_cda" 2>/dev/null | grep -Ec '^[+-]([^+-]|$)')
  elif [ -f "$_cda" ]; then
    _cdn=$(grep -c '' "$_cda" 2>/dev/null)
  elif [ -f "$_cdb" ]; then
    _cdn=$(grep -c '' "$_cdb" 2>/dev/null)
  else
    _cdn=0
  fi
  case "$_cdn" in ''|*[!0-9]*) _cdn=0 ;; esac
  printf '%s' "$_cdn"
}

# Added-only lines changed since the baseline, for one repo-relative path —
# Pilot's writing-axis tally, deliberately narrower than coach_delta above.
# coach_delta counts BOTH sides of a hunk (`^[+-]`), which is right for
# coach's own purpose (how much of this file changed, to decide whether a
# review is due) but wrong as a count of what the dev WROTE: a modified line
# counts twice under it, and a pure deletion counts as writing at all. Pilot
# persists this count instead, so an ordinary refactor under coach mode does
# not inflate dev_lines against rubric.md's writing thresholds.
coach_delta_added() {
  _cwr="$1"
  _cwa="$ROOT/$_cwr"
  _cwb="$BASEDIR/$(coach_key "$_cwr")"
  if [ -f "$_cwb" ] && [ -f "$_cwa" ]; then
    _cwn=$(diff -u "$_cwb" "$_cwa" 2>/dev/null | grep -Ec '^[+]([^+-]|$)')
  elif [ -f "$_cwa" ]; then
    # No baseline: the whole file is new, so the whole file is added.
    _cwn=$(grep -c '' "$_cwa" 2>/dev/null)
  else
    # Baseline only: the file was deleted. Deleting code is not writing it.
    _cwn=0
  fi
  case "$_cwn" in ''|*[!0-9]*) _cwn=0 ;; esac
  printf '%s' "$_cwn"
}

# "<delta>\t<rel>" per file with a non-zero delta.
coach_material() {
  coach_candidates | while IFS= read -r _cmr; do
    [ -n "$_cmr" ] || continue
    _cmd=$(coach_delta "$_cmr")
    case "$_cmd" in ''|*[!0-9]*) _cmd=0 ;; esac
    [ "$_cmd" -gt 0 ] && printf '%s\t%s\n' "$_cmd" "$_cmr"
  done
}

# Rewrite the baseline from the repo-relative paths on stdin. Called at emission
# time, immediately after a line is printed — never after the review finishes: a
# review Claude never runs must not re-fire the same material one cycle later.
# Crash window: the content copies below are written before the pointers
# (.manifest, .head) advance, so a kill between them costs at most one cycle
# of under-reported deltas next time — never a lost or duplicated file.
coach_advance() {
  mkdir -p "$BASEDIR" 2>/dev/null || return 0
  _canew="$BASEDIR/.manifest.new"
  : > "$_canew"
  while IFS= read -r _car; do
    [ -n "$_car" ] || continue
    _cak=$(coach_key "$_car")
    if [ -f "$ROOT/$_car" ]; then
      cp "$ROOT/$_car" "$BASEDIR/$_cak" 2>/dev/null || continue
    else
      rm -f "$BASEDIR/$_cak"
    fi
    printf '%s %s\n' "$_cak" "$_car" >> "$_canew"
  done
  # Drop content copies for files that are no longer candidates, so the baseline
  # directory tracks the working set instead of growing all session.
  if [ -f "$BASEDIR/.manifest" ]; then
    while read -r _cao _caorel; do
      [ -n "$_cao" ] || continue
      grep -q "^$_cao " "$_canew" 2>/dev/null || rm -f "$BASEDIR/$_cao"
    done < "$BASEDIR/.manifest"
  fi
  mv "$_canew" "$BASEDIR/.manifest" 2>/dev/null
  # A repo with zero commits yet has no HEAD to record. Falling back to the
  # empty-tree object id (rather than an empty string) keeps the
  # <baseline-HEAD>..HEAD diff term in coach_candidates meaningful once the
  # dev's first commit lands: diffing the empty tree against HEAD lists every
  # file HEAD now contains, which is exactly the committed-since-baseline set.
  # An empty string would make that term silently skip forever, cutting a dev
  # off right after the block where they committed for the first time.
  #
  # The empty-tree id is derived with `hash-object -t tree /dev/null` rather
  # than hardcoded: its value depends on the repo's hash algorithm (SHA-1 vs
  # SHA-256, `git init --object-format`), and a SHA-1 constant silently fails
  # to resolve in a SHA-256 repo — reproducing this exact bug for that format.
  # If the derivation itself yields nothing, leave `.head` empty rather than
  # writing a value that would make every later `git diff` on it fail.
  if ! git -C "$ROOT" rev-parse HEAD > "$BASEDIR/.head" 2>/dev/null; then
    _caempty=$(git -C "$ROOT" hash-object -t tree /dev/null 2>/dev/null)
    printf '%s' "$_caempty" > "$BASEDIR/.head"
  fi
}

if [ "$ADVANCE_ONLY" = 1 ]; then
  coach_candidates | coach_advance
  exit 0
fi

if [ "$PRINT_MATERIAL" = 1 ]; then
  coach_material
  exit 0
fi

# --- cadence ----------------------------------------------------------------
# All of this is re-derived from $CFG by coach_load_cadence, called once here
# and again at the top of every loop iteration below: `learner coach off`
# (or a cadence retune) is a config-file edit the dev makes mid-session, and
# nothing else re-reads it once the watcher is armed as a Monitor.
coach_load_cadence() {
  LEVEL=$(learner_level "$(printf '%s' "$CFG" | jq -r '.level // empty')")
  CADENCE=$(printf '%s' "$CFG" | jq -r '.coachCadence // "pomodoro"')
  case "$CADENCE" in threshold) ;; *) CADENCE=pomodoro ;; esac

  IDLE_MAX=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachIdleCycles // empty')" 2 1)
  CHALLENGE=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachChallengeMinutes // empty')" 8 0)
  POLL=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachPollSeconds // empty')" 45 5)
  THR_LINES=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachLines // empty')" 40 1)
  THR_FILES=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachFiles // empty')" 3 1)
  THR_EVERY=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachEveryMinutes // empty')" 0 0)
  COOLDOWN=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachCooldownMinutes // empty')" 5 0)
  WORK_MINUTES=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachWorkMinutes // empty')" 25 1)

  # coachIdleCycles is documented (spec §2.4) as idle periods of one
  # work-block-equivalent (coachWorkMinutes), in both cadences. In pomodoro,
  # coach_cycle already runs once per work block, so one poll == one period. In
  # threshold, coach_cycle runs once per coachPollSeconds — many times faster —
  # so IDLE_MAX must be scaled into polls-per-period, or "2 idle cycles" becomes
  # two 45-second polls instead of two work blocks. The division is guarded to
  # never yield less than 1: a coachPollSeconds larger than the work block would
  # otherwise floor to 0 and make the very first empty poll look like a whole
  # elapsed period.
  if [ "$CADENCE" = threshold ]; then
    POLLS_PER_PERIOD=$(( WORK_MINUTES * 60 / POLL ))
    [ "$POLLS_PER_PERIOD" -lt 1 ] && POLLS_PER_PERIOD=1
  else
    POLLS_PER_PERIOD=1
  fi
  IDLE_LIMIT=$((IDLE_MAX * POLLS_PER_PERIOD))
}
coach_load_cadence

# The empty-cycle counter has to survive `--once`, which is a fresh process per
# cycle in tests and the only way the idle path is testable at all.
EMPTYF="$TMPD/claude-learner-${SID}.coach-empty"
LASTF="$TMPD/claude-learner-${SID}.coach-last"

coach_read_int() { _cri=$(cat "$1" 2>/dev/null); case "$_cri" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$_cri" ;; esac; }

# One measurement + decision + emission. Three-way result, deliberately not
# inferred by the caller from any file's presence:
#   0 = emitted            1 = stop (idle cut-off)      2 = no emission, keep going
# The threshold branch has two paths — cooldown-blocked, and material present
# but under every trigger — that are neither "emitted" nor "genuinely empty".
# Folding those into 0 (as file-presence inference used to) inflates CYCLE with
# no notification sent; folding them into "empty" tells a dev who is actively
# writing, just below the threshold, that the session went idle. Both are
# real 2s. CYCLE is read from the environment so --once can inject it.
coach_cycle() {
  _ccm=$(coach_material)

  if [ -z "$_ccm" ]; then
    _cce=$(coach_read_int "$EMPTYF" 0)
    _cce=$((_cce + 1))
    printf '%s' "$_cce" > "$EMPTYF"
    if [ "$_cce" -ge "$IDLE_LIMIT" ]; then
      # One line, then stop. The watcher costs nothing while it waits, but every
      # notification opens a turn — so an abandoned session must not keep
      # producing them.
      printf '%s\n' "🧑‍🏫 Coach — no tracked changes for $IDLE_MAX work blocks; the watcher has stopped.
Ask the dev whether they want to continue the coaching session. If they do, re-arm the watcher."
      rm -f "$EMPTYF"
      return 1
    fi
    return 2
  fi

  # Material existed this cycle. The dev has not gone idle, whether or not
  # this cycle actually fires — a cooldown gate and an under-threshold cycle
  # both mean "keep pacing", not "abandoned". Reset now, before either check
  # can short-circuit the reset away.
  rm -f "$EMPTYF"

  _ccn=$(printf '%s\n' "$_ccm" | grep -c '')
  _ccl=$(printf '%s\n' "$_ccm" | awk -F'\t' '{s += $1} END {print s + 0}')
  # Pilot's tally: added-only lines, recomputed per file with coach_delta_added
  # rather than reused from _ccl above — _ccl stays exactly what it was, for
  # coach's own display and trigger thresholds, which is correct there.
  _ccw=$(printf '%s\n' "$_ccm" | cut -f2 | while IFS= read -r _ccwf; do
    [ -n "$_ccwf" ] || continue
    coach_delta_added "$_ccwf"
    printf '\n'
  done | awk '{s += $1} END {print s + 0}')
  _ccnow=$(date +%s)
  _cclast=$(coach_read_int "$LASTF" 0)
  _ccelapsed=$(( (_ccnow - _cclast) / 60 ))
  [ "$_cclast" = 0 ] && _ccelapsed=$((COOLDOWN + THR_EVERY + 1))

  if [ "$CADENCE" = threshold ]; then
    [ "$_ccelapsed" -lt "$COOLDOWN" ] && return 2
    _ccfire=0
    [ "$_ccl" -ge "$THR_LINES" ] && _ccfire=1
    [ "$_ccn" -ge "$THR_FILES" ] && _ccfire=1
    [ "$THR_EVERY" -gt 0 ] && [ "$_ccelapsed" -ge "$THR_EVERY" ] && _ccfire=1
    [ "$_ccfire" = 1 ] || return 2
  fi

  _ccfiles=$(printf '%s\n' "$_ccm" | cut -f2 | head -n 20 | tr '\n' ' ')

  # Persist what this cycle measured, durably. pilot-record.sh needs it at
  # SessionEnd, and it cannot read this watcher's TMPDIR state: hooks for one
  # event run in parallel and learner-cleanup.sh deletes those files at the
  # same event. Best-effort — a coach cycle must never fail over Pilot's
  # bookkeeping, so every failure here is swallowed.
  #
  # $_ccw, not $_ccl: the writing axis compares against cl_lines, which
  # `hooks/pilot-record.sh` counts as added lines only (and so does its git-
  # estimate fallback) — persisting $_ccl's added-AND-removed count here would
  # compare two different units and double-tax an ordinary edited line.
  if pilot_enabled "$CFG" 2>/dev/null; then
    mkdir -p "$LEARNER_CFG_DIR/learner" 2>/dev/null \
      && printf '%s %s\n' "$SID" "$_ccw" >> "$LEARNER_CFG_DIR/learner/pilot-devlines" 2>/dev/null
  fi

  # Same contract as the quiz trigger: parameters and a pointer to the protocol,
  # never the protocol itself. Rendered in the console, so it stays one screen.
  printf '%s\n' "🧑‍🏫 Coach (level: $LEVEL, cycle: ${CYCLE:-1}, files: $_ccn, lines: $_ccl) — $_ccfiles
Invoke the \`learner\` skill and follow references/coach.md. One challenge, then wait for the dev's answer."

  coach_candidates | coach_advance
  printf '%s' "$_ccnow" > "$LASTF"
  return 0
}

if [ "$ONCE" = 1 ]; then
  coach_cycle
  exit 0
fi

# The real loop. Pomodoro sleeps the whole work block and measures once at the
# end — no polling at all; coachPollSeconds exists only for the threshold
# cadence. An empty block does NOT advance CYCLE: the work block grows as a
# reward for writing code, not for leaving the editor open.
CYCLE=1
rm -f "$EMPTYF" "$LASTF"
while :; do
  # `learner coach off` (or a retune) is a config-file edit made mid-session,
  # with nothing else to re-read it once this loop is running as a Monitor —
  # re-check on every iteration so it takes effect within one cycle instead of
  # only at the next re-arm.
  CFG=$(learner_config)
  learner_coach_active "$CFG" "$ROOT" || exit 0
  coach_load_cadence

  if [ "$CADENCE" = threshold ]; then
    sleep "$POLL"
  else
    sleep $(( $(learner_coach_work_minutes "$CYCLE" "$CFG") * 60 ))
  fi

  coach_cycle
  # Dispatch on coach_cycle's own return code, never on a file's presence —
  # that inference is exactly what let a cooldown-blocked or under-threshold
  # cycle (return 2) get mistaken for an emission (0) or folded into "empty".
  case $? in
    1) exit 0 ;;
    0)
      # Only an actual emission sleeps the challenge window and grows the work
      # block. The script stays silent at the end of that window — the
      # challenge ends when the dev answers and goes back to coding, and a
      # "back to work" line would cost a full turn per cycle for no
      # information.
      [ "$CADENCE" = pomodoro ] && [ "$CHALLENGE" -gt 0 ] && sleep $((CHALLENGE * 60))
      CYCLE=$((CYCLE + 1))
      ;;
    *) ;; # 2: no emission, keep going at the same CYCLE
  esac
done
