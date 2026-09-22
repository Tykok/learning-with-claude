#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# learner-event.sh — the only writer of $CLAUDE_CONFIG_DIR/learner/events.jsonl,
# the append-only log the Learner IDE extensions read (contract/events.schema.json).
#
# The model calls this with arguments and never hand-writes a line: every value
# goes through jq --arg, so quotes and newlines in a prompt cannot break the JSON.
#
#   sh learner-event.sh asked     --style code|architecture|fill --mode granular|synthesis
#                                 --level D|J|C|S|E --domain D --files "a b" --prompt P
#                                 [--anchor FILE:LINE] [--session SID]      -> prints the id
#   sh learner-event.sh answered  --id ID --verdict ok|revisit --domain D --theme T [--note N]
#   sh learner-event.sh skipped   --id ID
#   sh learner-event.sh abandoned --session SID
#   sh learner-event.sh import                                               -> prints a JSON summary
#
# Exit 0 on success, 2 on a usage error (nothing written). A missing jq is not an
# error: an event log must never break a quiz, so it warns once and exits 0.

command -v jq >/dev/null 2>&1 || {
  echo "learner-event: jq not found, event not recorded" >&2
  exit 0
}

# ${0%/*}, not dirname: this must still load when PATH holds nothing but jq's absence.
# shellcheck source=hooks/learner-config.sh
. "${0%/*}/learner-config.sh"

LOG="$LEARNER_CFG_DIR/learner/events.jsonl"
PROMPT_MAX=800

usage() { echo "learner-event: $1" >&2; exit 2; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

new_id() {
  printf 'q_%s_%s' "$(date -u +%Y%m%dT%H%M%SZ)" \
    "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
}

# One printf, one >>: each event is a single write to an O_APPEND file.
append() {
  mkdir -p "${LOG%/*}" || exit 1
  printf '%s\n' "$1" >> "$LOG"
}

# Every parseable event as one JSON array; torn or hand-edited lines are dropped.
read_log() {
  if [ -f "$LOG" ]; then
    jq -Rn '[inputs | fromjson? | select(type == "object")]' "$LOG"
  else
    printf '[]'
  fi
}

cmd_asked() {
  style=''; mode=''; level=''; domain=''; files=''; prompt=''; anchor=''; session=''
  have_prompt=0
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage "missing value for $1"
    case "$1" in
      --style)   style=$2 ;;
      --mode)    mode=$2 ;;
      --level)   level=$2 ;;
      --domain)  domain=$2 ;;
      --files)   files=$2 ;;
      --prompt)  prompt=$2; have_prompt=1 ;;
      --anchor)  anchor=$2 ;;
      --session) session=$2 ;;
      *) usage "unknown option $1" ;;
    esac
    shift 2
  done

  case "$style" in code|architecture|fill) ;; *) usage "--style must be code, architecture or fill" ;; esac
  case "$mode" in granular|synthesis) ;; *) usage "--mode must be granular or synthesis" ;; esac
  lvl=$(learner_level "$level"); [ -n "$lvl" ] || usage "--level must be D, J, C, S or E"
  [ -n "$domain" ] || usage "--domain is required"
  [ -n "$files" ] || usage "--files is required"
  [ "$have_prompt" = 1 ] || usage "--prompt is required"

  afile=''; aline=''
  if [ -n "$anchor" ]; then
    afile=${anchor%:*}; aline=${anchor##*:}
    [ "$afile" != "$anchor" ] && [ -n "$afile" ] || usage "--anchor must be FILE:LINE"
    case "$aline" in ''|*[!0-9]*) usage "--anchor line must be a positive integer" ;; esac
    [ "$aline" -ge 1 ] || usage "--anchor line must be a positive integer"
  fi

  [ -n "$session" ] || session=${CLAUDE_CODE_SESSION_ID:-unknown}
  root=$(learner_repo_root)
  id=$(new_id)

  line=$(jq -nc \
    --arg id "$id" --arg ts "$(now_utc)" --arg session "$session" --arg root "$root" \
    --arg style "$style" --arg mode "$mode" --arg level "$lvl" --arg domain "$domain" \
    --arg files "$files" --arg prompt "$prompt" --argjson max "$PROMPT_MAX" \
    --arg afile "$afile" --arg aline "$aline" '
    {v: 1, type: "question.asked", id: $id, ts: $ts, session: $session,
     repo: (if $root == "" then null else ($root | split("/") | last) end),
     root: (if $root == "" then null else $root end),
     style: $style, mode: $mode, level: $level, domain: $domain,
     files: ($files | split(" ") | map(select(. != ""))),
     prompt: ($prompt | .[0:$max])}
    + (if $afile == "" then {} else {anchor: {file: $afile, line: ($aline | tonumber)}} end)') \
    || exit 1
  append "$line"
  printf '%s\n' "$id"
}

sub=${1:-}
[ -n "$sub" ] || usage "missing subcommand"
shift
case "$sub" in
  asked) cmd_asked "$@" ;;
  *) usage "unknown subcommand $sub" ;;
esac
