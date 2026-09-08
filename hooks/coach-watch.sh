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
# Usage: sh coach-watch.sh <session-id> [--once] [--print-material] [--advance]
#   --once             run a single cycle without sleeping, then return (tests)
#   --print-material   print "<delta>\t<rel>" per changed file instead of a
#                      trigger line (tests)
#   --advance          advance the baseline and return, emitting nothing (tests)
#
# The session id is an argument, not stdin: a hook receives it in its payload
# but a Monitor command does not, so whoever arms the watcher substitutes it.

. "$(dirname "$0")/learner-config.sh"

SID="${1:-}"
[ -n "$SID" ] || exit 0
shift

ONCE=0; PRINT_MATERIAL=0; ADVANCE_ONLY=0
# ONCE is read by Task 5's cadence loop, not yet by this measurement-only stub.
# shellcheck disable=SC2034
while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1 ;;
    --print-material) PRINT_MATERIAL=1; ONCE=1 ;;
    --advance) ADVANCE_ONLY=1; ONCE=1 ;;
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
# <key> is `git hash-object --stdin` of the repo-relative path — 40 hex
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
  # A repo with zero commits yet has no HEAD to record. Falling back to git's
  # well-known empty-tree object id (rather than an empty string) keeps the
  # <baseline-HEAD>..HEAD diff term in coach_candidates meaningful once the
  # dev's first commit lands: diffing the empty tree against HEAD lists every
  # file HEAD now contains, which is exactly the committed-since-baseline set.
  # An empty string would make that term silently skip forever, cutting a dev
  # off right after the block where they committed for the first time.
  git -C "$ROOT" rev-parse HEAD > "$BASEDIR/.head" 2>/dev/null \
    || printf '%s' '4b825dc642cb6eb9a060e54bf8d69288fbee4904' > "$BASEDIR/.head"
}

if [ "$ADVANCE_ONLY" = 1 ]; then
  coach_candidates | coach_advance
  exit 0
fi

if [ "$PRINT_MATERIAL" = 1 ]; then
  coach_material
  exit 0
fi

# Task 5 replaces this with the cadence loop.
exit 0
