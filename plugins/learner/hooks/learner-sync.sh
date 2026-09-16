#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# learner sync — carry the learning record between machines through a private gist.
#
# Mechanical half of the feature (see design/superpowers/specs/2026-09-16-sync-design.md):
# every `gh` call, the snapshot, the backup, the memory.md three-way merge and the
# Session history union live here. The theme merge lives in the skill, because it
# needs judgement this script must not fake.
#
# Prints exactly one compact JSON object on stdout. skills/learner/references/sync.md
# turns it into a sentence in the dev's language; nothing here is user-facing prose.
#
#   sh learner-sync.sh push [--create-ok]
#   sh learner-sync.sh pull [<gist-id-or-url>]
#   sh learner-sync.sh pull-finish <work-dir>
#   sh learner-sync.sh status
#   sh learner-sync.sh use <gist-id-or-url>
#   sh learner-sync.sh merge-memory  <base> <local> <remote>
#   sh learner-sync.sh merge-history <local> <remote>

# shellcheck source=hooks/learner-config.sh
. "$(dirname "$0")/learner-config.sh"

# shellcheck disable=SC2034
SYNC_SCHEMA=1
# shellcheck disable=SC2034
SYNC_DESC="claude-learner-state"

DATA_DIR="$LEARNER_CFG_DIR/learner"
# shellcheck disable=SC2034
MEM_FILE="$DATA_DIR/memory.md"
# shellcheck disable=SC2034
REC_FILE="$DATA_DIR/recap.md"
# shellcheck disable=SC2034
CFG_FILE="$LEARNER_CFG_DIR/learner.json"
# shellcheck disable=SC2034
SYNC_JSON="$DATA_DIR/sync.json"
# shellcheck disable=SC2034
BASE_DIR="$DATA_DIR/sync-base"
# shellcheck disable=SC2034
BACKUP_DIR="$DATA_DIR/backups"

# Every failure leaves stdout with one machine-readable object and nothing else.
fail() { printf '{"ok":false,"error":"%s"}\n' "$1"; exit 1; }

usage() { printf '{"ok":false,"error":"usage"}\n'; exit 2; }

need_jq() { command -v jq >/dev/null 2>&1 || fail jq-missing; }

need_gh() {
  command -v gh >/dev/null 2>&1 || fail gh-missing
  gh auth status >/dev/null 2>&1 || fail gh-unauthenticated
}

# True when the file exists and holds something other than whitespace. An empty
# memory.md is a real state (a dev who has mastered everything open), so "exists"
# alone would push a snapshot of nothing over a good remote one.
has_content() { [ -f "$1" ] && grep -q '[^[:space:]]' "$1"; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cmd=${1:-}
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  push|pull|pull-finish|status|use|merge-memory|merge-history) ;;
  *) usage ;;
esac

need_jq

case "$cmd" in
  merge-memory|merge-history) ;;   # pure text, no network
  *) need_gh ;;
esac

# A readable path for a file that may be missing, so awk always gets three
# distinct filenames. Distinct matters: the merge tells the three inputs apart
# by FILENAME, and two identical names would fold two inputs into one.
_empty_seq=0
readable_or_empty() {
  if [ -f "$1" ]; then
    printf '%s' "$1"
    return 0
  fi
  _empty_seq=$((_empty_seq + 1))
  _e="${TMPDIR:-/tmp}/learner-sync-empty.$$.$_empty_seq"
  : > "$_e"
  printf '%s' "$_e"
}

merge_memory() {  # BASE LOCAL REMOTE -> merged markdown on stdout
  _mb=$(readable_or_empty "$1")
  _ml=$(readable_or_empty "$2")
  _mr=$(readable_or_empty "$3")
  awk -v BASEF="$_mb" -v REMF="$_mr" '
    # The key is the concept, not the line: the date changes every time the dev
    # is asked again, so keying on the whole line would make every refresh look
    # like a brand-new weak spot.
    function key(l,   p, k) {
      p = index(l, " — seen:")
      k = (p > 0) ? substr(l, 1, p - 1) : l
      gsub(/[ \t]+/, " ", k); sub(/^ +/, "", k); sub(/ +$/, "", k)
      return k
    }
    function dt(l,   p, d) {
      p = index(l, "seen:")
      if (p == 0) return ""
      d = substr(l, p + 5)
      gsub(/[^0-9-]/, "", d)
      return substr(d, 1, 10)
    }
    FILENAME == BASEF { if (/^-[ \t]/) B[key($0)] = 1; next }
    FILENAME == REMF  {
      if (!/^-[ \t]/) next
      k = key($0); R[k] = $0; RD[k] = dt($0)
      if (!(k in RSEEN)) { RSEEN[k] = 1; ro[++rn] = k }
      next
    }
    {
      if (!/^-[ \t]/) { head[++hn] = $0; next }
      k = key($0); L[k] = $0; LD[k] = dt($0)
      if (!(k in LSEEN)) { LSEEN[k] = 1; lo[++ln] = k }
    }
    END {
      for (i = 1; i <= hn; i++) print head[i]
      for (i = 1; i <= ln; i++) {
        k = lo[i]
        if (k in R) { print (RD[k] > LD[k]) ? R[k] : L[k]; continue }
        if (k in B) continue          # present in the base, gone remotely: deleted there
        print L[k]                    # not in the base: added here since the last sync
      }
      for (i = 1; i <= rn; i++) {
        k = ro[i]
        if (k in L) continue          # already emitted by the loop above
        if (k in B) continue          # present in the base, gone locally: deleted here
        print R[k]                    # added on the other machine since the last sync
      }
    }
  ' "$_mb" "$_mr" "$_ml"
}

merge_history() {  # LOCAL REMOTE -> merged body rows on stdout, oldest first
  _hl=$(readable_or_empty "$1")
  _hr=$(readable_or_empty "$2")
  awk '
    /^[ \t]*\|/ {
      line = $0
      norm = line
      gsub(/[ \t]+/, " ", norm)
      gsub(/ *\| */, "|", norm)
      sub(/^ +/, "", norm); sub(/ +$/, "", norm)
      if (norm ~ /^\|[-|]+\|$/) next        # separator row
      if (norm ~ /^\|Date\|/) next          # header row
      if (seen[norm]++) next
      split(norm, c, "|")
      printf "%s\t%s\n", c[2], line
    }
  ' "$_hl" "$_hr" | sort -s -t "$(printf '\t')" -k1,1 | cut -f2-
}

case "$cmd" in
  merge-memory)
    [ $# -eq 3 ] || usage
    merge_memory "$1" "$2" "$3"
    exit 0
    ;;
  merge-history)
    [ $# -eq 2 ] || usage
    merge_history "$1" "$2"
    exit 0
    ;;
  *) fail not-implemented ;;
esac
