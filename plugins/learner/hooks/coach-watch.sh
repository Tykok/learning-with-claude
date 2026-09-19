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
  # Claude's writes belong to the quiz, the dev's to the coach — but only for
  # the CURRENT window. .session is append-only and never cleared, so testing
  # the whole file excluded a shared file for the rest of the session: one
  # question to Claude about the file you are working on and the coach never
  # looked at it again. The mark is how far .session had grown when the last
  # review fired; only what Claude appended after it still belongs to Claude.
  _cbmark=$(cat "$BASEDIR/.sessionmark" 2>/dev/null)
  case "$_cbmark" in ''|*[!0-9]*) _cbmark=0 ;; esac
  # learner-cleanup.sh always removes .session and .coach-base together, so
  # the product's own code can never desync them — but a tmp reaper on a
  # long-lived machine can delete .session on its own timer while .coach-base
  # (and its mark) survives. If .session then comes back shorter than the
  # stored mark, `tail -n +$((_cbmark + 1))` below would start past its own
  # EOF and print nothing for every path, silently turning the exclusion off
  # entirely — every file Claude ever wrote would be offered as the dev's own
  # material, full delta included. A stale cursor can never be trusted past
  # the length of the file it indexes.
  if [ -f "$SESSION" ]; then
    _cblines=$(grep -c '' "$SESSION" 2>/dev/null)
    case "$_cblines" in ''|*[!0-9]*) _cblines=0 ;; esac
    [ "$_cbmark" -gt "$_cblines" ] && _cbmark=0
  fi
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
    if [ -f "$SESSION" ] \
      && tail -n +$((_cbmark + 1)) "$SESSION" 2>/dev/null | grep -qxF "$_ca" 2>/dev/null; then
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
  # The `mkdir -p` above only catches a MISSING $BASEDIR (or a TMPDIR gone
  # entirely) — it succeeds unconditionally on a $BASEDIR that already exists,
  # unwritable or not. `:` is a POSIX special built-in, so a redirection
  # failure on it aborts a non-interactive shell outright under dash, before
  # the `||` below ever runs. This function runs as the right side of a pipe
  # (`coach_candidates | coach_advance`), so the abort only kills that forked
  # subshell rather than the whole watcher — but it still leaks the raw dash
  # error straight to the real stderr (unguarded, no `2>/dev/null` ahead of
  # it) and it still skips every line below, leaving the baseline stuck and
  # the same material re-offered forever. `2>/dev/null` sits outside the
  # parens because a compound command's redirections are installed before it
  # runs, so it also swallows that diagnostic. Do not "simplify" the parens
  # away.
  ( : > "$_canew" ) 2>/dev/null || return 0
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
  # coach_candidates just excluded everything Claude appended to .session this
  # window from the stdin this function read above, so those paths got no
  # content copy. Without one, the moment the dev inherits such a file its
  # WHOLE current content — Claude's lines included — reads as delta the
  # instant it becomes a candidate again, defeating the very split .session
  # exists to make. Snapshot exactly the slice of .session this window closes
  # over (old mark, read before we overwrite it below, up to now) so next
  # window's diff starts from what the dev actually inherited.
  if [ -f "$SESSION" ]; then
    _caoldmark=$(cat "$BASEDIR/.sessionmark" 2>/dev/null)
    case "$_caoldmark" in ''|*[!0-9]*) _caoldmark=0 ;; esac
    tail -n +$((_caoldmark + 1)) "$SESSION" 2>/dev/null | sort -u | while IFS= read -r _cap; do
      [ -n "$_cap" ] && [ -f "$_cap" ] || continue
      case "$_cap" in
        "$ROOT"/*) cp "$_cap" "$BASEDIR/$(coach_key "${_cap#"$ROOT"/}")" 2>/dev/null ;;
      esac
    done
  fi
  # How far .session had grown when this baseline was taken. Everything Claude
  # appended before this line belongs to a window that is now closed, and the
  # dev's later edits to those same files are theirs to be challenged on.
  if [ -f "$SESSION" ]; then
    grep -c '' "$SESSION" > "$BASEDIR/.sessionmark" 2>/dev/null
  else
    printf '0' > "$BASEDIR/.sessionmark"
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
# One cadence: the dev's pause. Re-derived from $CFG here and again at the top
# of every loop iteration below, because `learner coach off` (or a retune) is a
# config-file edit made mid-session and nothing else re-reads it once the
# watcher is armed as a Monitor.
coach_load_cadence() {
  LEVEL=$(learner_level "$(printf '%s' "$CFG" | jq -r '.level // empty')")
  POLL=$(learner_int         "$(printf '%s' "$CFG" | jq -r '.coachPollSeconds // empty')"     30 5)
  QUIET_POLLS=$(learner_int  "$(printf '%s' "$CFG" | jq -r '.coachQuietPolls // empty')"       1 1)
  MIN_LINES=$(learner_int    "$(printf '%s' "$CFG" | jq -r '.coachMinLines // empty')"        10 1)
  COOLDOWN=$(learner_int     "$(printf '%s' "$CFG" | jq -r '.coachCooldownMinutes // empty')"  3 0)
  MAXWAIT=$(learner_int      "$(printf '%s' "$CFG" | jq -r '.coachMaxWaitMinutes // empty')"  15 0)
  IDLE_MINUTES=$(learner_int "$(printf '%s' "$CFG" | jq -r '.coachIdleMinutes // empty')"     45 1)
}
coach_load_cadence

# All cadence state is on disk, not in shell variables: `--once` is a fresh
# process per cycle in the tests, and it is the only way this logic is testable
# without sleeping through a real work session.
FPF="$TMPD/claude-learner-${SID}.coach-fp"
QUIETF="$TMPD/claude-learner-${SID}.coach-quiet"
IDLEF="$TMPD/claude-learner-${SID}.coach-idle"
PENDF="$TMPD/claude-learner-${SID}.coach-pending"
LASTF="$TMPD/claude-learner-${SID}.coach-last"

coach_read_int() { _cri=$(cat "$1" 2>/dev/null); case "$_cri" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$_cri" ;; esac; }

# The idle cut-off, reached from both of coach_cycle's branches. One line, then
# stop: the watcher costs nothing while it waits, but every notification opens a
# turn, so an abandoned session must not keep producing them. Factored into one
# function rather than printed at both call sites because coach.md quotes this
# exact sentence and test.sh derives that quote from this printf — two copies
# would make that derivation ambiguous, and let the two copies drift apart.
coach_cutoff() {
  printf '%s\n' "🧑‍🏫 Coach — no tracked changes for $IDLE_MINUTES minutes; the watcher has stopped.
Ask the dev whether they want to continue the coaching session. If they do, re-arm the watcher."
  rm -f "$IDLEF"
}

# True once the idle counter's polls add up to coachIdleMinutes.
coach_idle_due() { [ $(( $1 * POLL )) -ge $(( IDLE_MINUTES * 60 )) ]; }

# One measurement + decision + emission. Three-way result, deliberately not
# inferred by the caller from any file's presence:
#   0 = emitted            1 = stop (idle cut-off)      2 = no emission, keep going
# "No emission" is a real, distinct outcome: material under the floor, a fire
# blocked by the cooldown, and a dev still typing are none of them an emission,
# and none of them a stop while the dev keeps touching the repo. Idle is
# measured on the fingerprint, not on the presence of material, so "stop" is
# reachable from BOTH branches: an empty tree and a tree nobody has typed into
# for coachIdleMinutes are the same abandoned session. CYCLE is read from the
# environment so --once can inject it.
coach_cycle() {
  _ccm=$(coach_material)
  _ccnow=$(date +%s)

  if [ -z "$_ccm" ]; then
    # Nothing pending: drop the pause state so a dev who reverts everything and
    # comes back later starts a clean observation, not mid-count.
    rm -f "$PENDF" "$FPF"
    printf '0' > "$QUIETF"
    _cci=$(coach_read_int "$IDLEF" 0)
    _cci=$((_cci + 1))
    printf '%s' "$_cci" > "$IDLEF"
    if coach_idle_due "$_cci"; then
      coach_cutoff
      return 1
    fi
    return 2
  fi

  _ccn=$(printf '%s\n' "$_ccm" | grep -c '')
  _ccl=$(printf '%s\n' "$_ccm" | awk -F'\t' '{s += $1} END {print s + 0}')

  # .coach-pending times how long material has waited for the review
  # coachMaxWaitMinutes owes it, so it may only start once there IS a review to
  # wait for. Stamped on the first poll with ANY material, sub-floor included,
  # it accumulated through a stretch in which no review could possibly fire:
  # three lines written before lunch and eight more an hour later made the
  # guard fire on the dev's very first keystroke back, with no pause at all.
  # Cleared rather than left stale below the floor, so a dev who reverts back
  # under it does not keep an hour-old stamp waiting to ambush them.
  if [ "$_ccl" -ge "$MIN_LINES" ]; then
    [ -f "$PENDF" ] || printf '%s' "$_ccnow" > "$PENDF"
  else
    rm -f "$PENDF"
  fi

  # The fingerprint, not the line total, is what detects activity: a dev who
  # removes three lines and writes three others leaves $_ccl unchanged while
  # very much still typing, and a total-based comparison would call that a pause.
  # Hashed over the candidates' own content rather than over $_ccm (the
  # delta+path summary): before a baseline exists for a file, coach_delta's
  # own no-baseline fallback is the file's whole-file line COUNT, which an
  # in-place edit (same total, different bytes) leaves unchanged — a
  # count-based fingerprint would misread that edit as a pause. The path is
  # printed into the stream ahead of each file's content, not just its bytes:
  # without it, a pure rename of an untracked file, or a block moved out of
  # file A into the head of file B (A sorting first), reproduces the same
  # byte stream across two genuinely different states.
  _ccfp=$(printf '%s\n' "$_ccm" | cut -f2 | while IFS= read -r _ccpf; do
    [ -n "$_ccpf" ] || continue
    printf '%s\n' "$_ccpf"
    cat "$ROOT/$_ccpf" 2>/dev/null
  done | cksum | awk '{print $1 "-" $2}')
  _ccprev=$(cat "$FPF" 2>/dev/null || printf '')
  # The idle counter follows the fingerprint, never the mere presence of
  # material. Material is a STATIC diff against the baseline, not activity: four
  # lines written before the laptop closed sit in the tree unchanged all
  # evening. Clearing .coach-idle on any non-empty material pinned it at 0 for
  # the rest of the session, so a dev below coachMinLines got neither a review
  # (under the floor) nor a cut-off (idle never grew) and the watcher polled a
  # dead session forever. An unchanged fingerprint means nobody typed, whatever
  # is sitting in the tree — that poll is idle time exactly like a poll with no
  # material at all. A CHANGED one means the dev is at the keyboard, below the
  # floor or not, which is what keeps the cut-off off an active dev.
  if [ "$_ccfp" = "$_ccprev" ]; then
    _ccq=$(coach_read_int "$QUIETF" 0)
    _ccq=$((_ccq + 1))
    _cci=$(coach_read_int "$IDLEF" 0)
    _cci=$((_cci + 1))
  else
    _ccq=0
    printf '%s' "$_ccfp" > "$FPF"
    _cci=0
  fi
  printf '%s' "$_ccq" > "$QUIETF"
  printf '%s' "$_cci" > "$IDLEF"

  _cclast=$(coach_read_int "$LASTF" 0)
  _ccpend=$(coach_read_int "$PENDF" "$_ccnow")
  _ccelapsed=$(( (_ccnow - _cclast) / 60 ))
  [ "$_cclast" = 0 ] && _ccelapsed=$((COOLDOWN + MAXWAIT + 1))
  _ccwaited=$(( (_ccnow - _ccpend) / 60 ))

  # The floor gates BOTH paths: coachMaxWaitMinutes exists for the dev in
  # continuous flow, not to force a review of four lines.
  _ccfire=0
  if [ "$_ccl" -ge "$MIN_LINES" ]; then
    [ "$_ccq" -ge "$QUIET_POLLS" ] && _ccfire=1
    [ "$MAXWAIT" -gt 0 ] && [ "$_ccwaited" -ge "$MAXWAIT" ] && _ccfire=1
  fi
  # A cooldown-blocked fire does NOT reset $_ccq (it was already persisted
  # above): the pause the dev already took is still valid, so the first poll
  # after the cooldown expires emits, instead of demanding a second pause.
  [ "$_ccelapsed" -lt "$COOLDOWN" ] && _ccfire=0
  if [ "$_ccfire" = 0 ]; then
    # Nothing to review and nobody typing: the same cut-off the no-material
    # branch applies. Tested AFTER the fire decision on purpose — material that
    # is owed a review gets its review; only material no review will ever be
    # served for is allowed to time the session out.
    if coach_idle_due "$_cci"; then
      coach_cutoff
      return 1
    fi
    return 2
  fi

  _ccfiles=$(printf '%s\n' "$_ccm" | cut -f2 | head -n 20 | tr '\n' ' ')
  # The list is capped at 20 while `files:` reports the true count, and the
  # ladder sizes the review off `files` while the structure question is defined
  # as "the split across the files in the trigger". Unannounced, the cap left
  # Claude reasoning about files it was never shown; naming what is missing
  # keeps the two numbers honest.
  [ "$_ccn" -gt 20 ] && _ccfiles="$_ccfiles(+$((_ccn - 20)) more not listed) "

  # Pilot's tally: added-only lines, recomputed per file with coach_delta_added
  # rather than reused from _ccl above — _ccl stays exactly what it was, for
  # coach's own display and trigger thresholds, which is correct there.
  _ccw=$(printf '%s\n' "$_ccm" | cut -f2 | while IFS= read -r _ccwf; do
    [ -n "$_ccwf" ] || continue
    coach_delta_added "$_ccwf"
    printf '\n'
  done | awk '{s += $1} END {print s + 0}')
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
  # never the protocol itself. `files` and `lines` are what the protocol's
  # ladder reads to size the review, so they must keep meaning "since the last
  # review" — not "since HEAD".
  #
  # The second line must never prescribe a question count. It is the most
  # proximate instruction Claude receives, so "One challenge, then wait" beat
  # coach.md's whole 1/2/3 ladder outright: a Large review asked one question
  # and stopped, shipping v1 behaviour under v2 documentation. It points at the
  # protocol and names the two parameters that size it, nothing more. coach.md
  # quotes this sentence and test.sh derives that quote from this very printf,
  # so the two cannot drift again.
  printf '%s\n' "🧑‍🏫 Coach (level: $LEVEL, cycle: ${CYCLE:-1}, files: $_ccn, lines: $_ccl) — $_ccfiles
Invoke the \`learner\` skill and follow references/coach.md. Size the review from \`files\` and \`lines\`, then wait for the dev's answer."

  coach_candidates | coach_advance
  printf '%s' "$_ccnow" > "$LASTF"
  printf '0' > "$QUIETF"
  rm -f "$PENDF"
  CYCLE=$(( ${CYCLE:-1} + 1 ))
  return 0
}

if [ "$ONCE" = 1 ]; then
  coach_cycle
  exit 0
fi

# The real loop. One poll every coachPollSeconds; coach_cycle decides. The
# post-emission sleep of v1 is gone — coachCooldownMinutes is now the only
# floor between two reviews, and it is enforced inside coach_cycle where the
# clock is already being read.
#
# The armed marker. coach-armed-check.sh warns the dev when it is missing, so it
# must be written by the real loop only — --once and --advance are test and
# off-cadence entry points, not a running cadence.
#
# The subshell is load-bearing, not decorative: `:` is a POSIX special
# built-in, so a redirection failure on it (nonexistent or read-only TMPDIR)
# aborts a non-interactive shell outright, under dash, before the trailing
# `|| :` ever runs. Unguarded, that would kill the watcher with a nonzero exit
# right here, before the loop even starts — coach mode silently dead while the
# gate keeps refusing writes, the exact failure this marker exists to report,
# caused by the line meant to report it. The `2>/dev/null` sits outside the
# parens on purpose: a compound command's redirections are installed before it
# runs, so this also swallows the dash error text the failing `>` would
# otherwise print to the real stderr. Do not "simplify" the parens away.
ARMED="$TMPD/claude-learner-${SID}.coach-armed"
( : > "$ARMED" ) 2>/dev/null || :
# The idle cut-off leaves this behind instead of $ARMED, and coach-armed-check.sh
# reads it as "deliberately stopped, do not report a broken install". A watcher
# starting now supersedes any earlier one's stop, so clear it here — otherwise a
# re-armed watcher would keep the check silenced for the rest of the session.
STOPPED="$TMPD/claude-learner-${SID}.coach-stopped"
CYCLE=1
rm -f "$FPF" "$QUIETF" "$IDLEF" "$PENDF" "$LASTF" "$STOPPED"
while :; do
  # `learner coach off` (or a retune) is a config-file edit made mid-session,
  # with nothing else to re-read it once this loop is running as a Monitor —
  # re-check on every iteration so it takes effect within one poll.
  CFG=$(learner_config)
  # The marker must not outlive the loop that earns it: coach-armed-check.sh's
  # own `[ -f "$ARMED" ]` test, and skills/status/SKILL.md's status line, both
  # read its presence as "the watcher is running". Leaving it behind here
  # would report an armed watcher for the rest of the session even though
  # this process is about to exit — and coach-armed-check.sh, seeing it,
  # would never warn the dev that coach mode has gone silently inert.
  learner_coach_active "$CFG" "$ROOT" || { rm -f "$ARMED"; exit 0; }
  coach_load_cadence

  sleep "$POLL"
  coach_cycle
  # Dispatch on coach_cycle's own return code, never on a file's presence —
  # that inference is exactly what let a blocked cycle get mistaken for an
  # emission in v1.
  case $? in
    # The idle cut-off exits the loop too, same stale-marker risk as the
    # coach-off path above. It also leaves $STOPPED behind: without it,
    # coach-armed-check.sh sees only a missing $ARMED and tells the dev, one
    # turn after the cut-off line already asked them whether to continue, that
    # coach mode is on but no review will ever fire — a deliberate state
    # reported as a broken install. The subshell and the outside-the-parens
    # `2>/dev/null` are the same special-built-in guard as the $ARMED write
    # above: `:` is a POSIX special built-in, so an unguarded redirection
    # failure on it aborts a non-interactive shell outright under dash, killing
    # the watcher with a nonzero exit and a raw dash error on stderr instead of
    # exiting 0 quietly. Do not "simplify" the parens away.
    1) ( : > "$STOPPED" ) 2>/dev/null || :; rm -f "$ARMED"; exit 0 ;;
    *) ;;
  esac
done
