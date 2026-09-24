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
#   asked adds commit (HEAD's full hash) and dirty (any of --files differs from
#   that commit) when the project is a git repo with a commit; neither otherwise.
#   sh learner-event.sh answered  --id ID --verdict ok|revisit --domain D --theme T [--note N]
#   sh learner-event.sh skipped   --id ID
#   sh learner-event.sh abandoned --session SID
#   sh learner-event.sh import                                               -> prints a JSON summary
#
# import backfills recap.md's Session history as answered/skipped events with
# q_imp_<cksum>_<bytes> ids, so byte-identical rows collapse to one imported
# event. Once live events exist, only rows dated strictly before the earliest
# live (non-q_imp_) event go in: from that day on the log already holds those
# answers under their live ids. Summary: {"ok":true,"imported":N,"already":M,
# "invalid":K,"live":L}, where live counts the rows left out for that reason.
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

# One printf, one >>: each event is a single write to an O_APPEND file. A torn
# last line (a crash mid-append, a hand edit) gets its newline first, or this
# event would be glued onto it and lost to every reader with it.
append() {
  mkdir -p "${LOG%/*}" || exit 1
  if [ -s "$LOG" ] && [ -n "$(tail -c 1 "$LOG")" ]; then
    printf '\n%s\n' "$1" >> "$LOG"
  else
    printf '%s\n' "$1" >> "$LOG"
  fi
}

# Every parseable event as one JSON array; torn or hand-edited lines are dropped.
read_log() {
  if [ -f "$LOG" ]; then
    jq -Rn '[inputs | fromjson? | select(type == "object")]' "$LOG"
  else
    printf '[]'
  fi
}

# git with every lever a repo could pull to run a program turned off: no lazy
# fetch from a promisor remote, no transport, no prompt, no optional index write.
# Only read commands go through it; nothing writes the index or the object store.
safe_git() {
  GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL='' GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 \
    git -C "$root" -c protocol.allow=never "$@" </dev/null 2>/dev/null
}

# The commit HEAD points at, or nothing: unborn branch, git error, odd output.
head_commit() {
  _c=$(safe_git rev-parse --verify -q --end-of-options 'HEAD^{commit}') || return 0
  printf '%s' "$_c" | grep -Eqx '[0-9a-f]{40}([0-9a-f]{24})?' && printf '%s' "$_c"
  return 0
}

# "true" when any of $files differs from its blob at commit $1 or cannot be
# checked, "false" otherwise. Blob against blob, never git status: status runs
# the repo's fsmonitor and clean filters. --no-filters makes a filtered, LFS or
# eol-converted file read dirty, which only hides the panel's revision actions.
files_dirty() {
  printf '%s\n' "$files" | tr ' ' '\n' | {
    while IFS= read -r _f; do
      [ -n "$_f" ] || continue
      case "/$_f/" in //*|*/../*) echo true; exit 0 ;; esac
      _p="$root/$_f"
      { [ -f "$_p" ] && [ ! -L "$_p" ] && [ -r "$_p" ]; } || { echo true; exit 0; }
      _want=$(safe_git rev-parse --verify -q --end-of-options "$1:$_f") || { echo true; exit 0; }
      _got=$(GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL='' GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 \
        git -C "$root" -c protocol.allow=never hash-object --no-filters --stdin <"$_p" 2>/dev/null) \
        || { echo true; exit 0; }
      [ "$_want" = "$_got" ] || { echo true; exit 0; }
    done
    echo false
  }
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

  commit=''; dirty=''
  if [ -n "$root" ]; then
    commit=$(head_commit)
    [ -z "$commit" ] || dirty=$(files_dirty "$commit")
  fi

  line=$(jq -nc \
    --arg id "$id" --arg ts "$(now_utc)" --arg session "$session" --arg root "$root" \
    --arg style "$style" --arg mode "$mode" --arg level "$lvl" --arg domain "$domain" \
    --arg files "$files" --arg prompt "$prompt" --argjson max "$PROMPT_MAX" \
    --arg afile "$afile" --arg aline "$aline" \
    --arg commit "$commit" --arg dirty "$dirty" '
    {v: 1, type: "question.asked", id: $id, ts: $ts, session: $session,
     repo: (if $root == "" then null else ($root | split("/") | last) end),
     root: (if $root == "" then null else $root end),
     style: $style, mode: $mode, level: $level, domain: $domain,
     files: ($files | split(" ") | map(select(. != ""))),
     prompt: ($prompt | .[0:$max])}
    + (if $afile == "" then {} else {anchor: {file: $afile, line: ($aline | tonumber)}} end)
    + (if $commit == "" then {} else {commit: $commit, dirty: ($dirty != "false")} end)') \
    || exit 1
  append "$line"
  printf '%s\n' "$id"
}

cmd_answered() {
  id=''; verdict=''; domain=''; theme=''; note=''; repo=''; style=''; ts=''
  have_domain=0; have_theme=0; have_note=0
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage "missing value for $1"
    case "$1" in
      --id)      id=$2 ;;
      --verdict) verdict=$2 ;;
      --domain)  domain=$2; have_domain=1 ;;
      --theme)   theme=$2; have_theme=1 ;;
      --note)    note=$2; have_note=1 ;;
      --repo)    repo=$2 ;;
      --style)   style=$2 ;;
      --ts)      ts=$2 ;;
      *) usage "unknown option $1" ;;
    esac
    shift 2
  done
  [ -n "$id" ] || usage "--id is required"
  case "$verdict" in ok|revisit) ;; *) usage "--verdict must be ok or revisit" ;; esac
  [ "$have_domain" = 1 ] && [ -n "$domain" ] || usage "--domain is required"
  [ "$have_theme" = 1 ] || usage "--theme is required (use '' for untagged)"
  [ -n "$ts" ] || ts=$(now_utc)

  line=$(jq -nc --arg id "$id" --arg ts "$ts" --arg verdict "$verdict" --arg domain "$domain" \
    --arg theme "$theme" --arg note "$note" \
    --argjson hn "$([ "$have_note" = 1 ] && [ -n "$note" ] && echo 1 || echo 0)" \
    --arg repo "$repo" --arg style "$style" '
    {v: 1, type: "question.answered", id: $id, ts: $ts, verdict: $verdict, domain: $domain,
     theme: (if $theme == "" then null else $theme end)}
    + (if $hn == 1 then {note: $note} else {} end)
    + (if $repo == "" then {} else {repo: $repo} end)
    + (if $style == "" then {} else {style: $style} end)') || exit 1
  append "$line"
}

cmd_skipped() {
  id=''; domain=''; repo=''; style=''; ts=''
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage "missing value for $1"
    case "$1" in
      --id) id=$2 ;; --domain) domain=$2 ;; --repo) repo=$2 ;; --style) style=$2 ;; --ts) ts=$2 ;;
      *) usage "unknown option $1" ;;
    esac
    shift 2
  done
  [ -n "$id" ] || usage "--id is required"
  [ -n "$ts" ] || ts=$(now_utc)
  line=$(jq -nc --arg id "$id" --arg ts "$ts" --arg domain "$domain" --arg repo "$repo" --arg style "$style" '
    {v: 1, type: "question.skipped", id: $id, ts: $ts}
    + (if $domain == "" then {} else {domain: $domain} end)
    + (if $repo == "" then {} else {repo: $repo} end)
    + (if $style == "" then {} else {style: $style} end)') || exit 1
  append "$line"
}

cmd_abandoned() {
  session=''
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage "missing value for $1"
    case "$1" in --session) session=$2 ;; *) usage "unknown option $1" ;; esac
    shift 2
  done
  [ -n "$session" ] || usage "--session is required"
  [ -f "$LOG" ] || return 0
  ts=$(now_utc)
  read_log | jq -c --arg s "$session" --arg ts "$ts" '
    (map(select(.type != "question.asked") | .id) | unique) as $closed
    | .[]
    | select(.type == "question.asked" and .session == $s)
    | select(.id as $i | $closed | index($i) | not)
    | {v: 1, type: "question.abandoned", id: .id, ts: $ts, session: $s}' |
  while IFS= read -r line; do
    append "$line"
  done
}

# Session history rows as unit-separator-joined fields: normalised row, then
# Date, Repo, Domain, Style, Verdict, Note, Theme. \037 rather than a tab
# because read collapses consecutive whitespace separators, and an empty Note
# cell would shift every field after it.
history_fields() {
  awk -v US="$(printf '\037')" '
    /^[ \t]*\|/ {
      norm = $0
      gsub(/[ \t]+/, " ", norm); gsub(/ *\| */, "|", norm)
      sub(/^ +/, "", norm); sub(/ +$/, "", norm)
      if (norm ~ /^\|[-|]+\|$/) next
      if (norm ~ /^\|Date\|/) next
      n = split(norm, c, "|")
      printf "%s", norm
      for (i = 2; i <= 8; i++) printf "%s%s", US, (i < n ? c[i] : "")
      printf "\n"
    }' "$1"
}

cmd_import() {
  rec="$LEARNER_CFG_DIR/learner/recap.md"
  imported=0; already=0; invalid=0; live=0
  if [ -f "$rec" ]; then
    log=$(read_log)
    known=$(printf '%s' "$log" | jq -r '.[].id')
    # YYYYMMDD of the earliest live event, empty when every event is imported.
    cutoff=$(printf '%s' "$log" | jq -r '
      [.[] | select((.id | type) == "string" and (.id | startswith("q_imp_") | not))
           | .ts | strings | .[0:10] | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))]
      | min // empty | gsub("-"; "")')
    US=$(printf '\037')
    # A here-doc, not a pipe: the counters must survive the loop.
    while IFS="$US" read -r norm date repo domain style verdict note theme; do
      [ -n "$norm" ] || continue          # a recap with no table yields one empty line
      case "$date" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) invalid=$((invalid + 1)); continue ;;
      esac
      [ -n "$domain" ] || { invalid=$((invalid + 1)); continue; }
      sum=$(printf '%s' "$norm" | cksum | awk '{print $1 "_" $2}')
      qid="q_imp_$sum"
      if printf '%s\n' "$known" | grep -qxF "$qid"; then
        already=$((already + 1)); continue
      fi
      if [ -n "$cutoff" ] && [ "$(printf '%s' "$date" | tr -d -)" -ge "$cutoff" ]; then
        live=$((live + 1)); continue
      fi
      ts="${date}T00:00:00Z"
      case "$verdict" in
        *skip*)    cmd_skipped --id "$qid" --domain "$domain" --repo "$repo" --style "$style" --ts "$ts" ;;
        *revisit*) cmd_answered --id "$qid" --verdict revisit --domain "$domain" --theme "$theme" \
                     --note "$note" --repo "$repo" --style "$style" --ts "$ts" ;;
        *ok*)      cmd_answered --id "$qid" --verdict ok --domain "$domain" --theme "$theme" \
                     --note "$note" --repo "$repo" --style "$style" --ts "$ts" ;;
        *) invalid=$((invalid + 1)); continue ;;
      esac
      known=$(printf '%s\n%s' "$known" "$qid")
      imported=$((imported + 1))
    done <<EOF
$(history_fields "$rec")
EOF
  fi
  jq -nc --argjson i "$imported" --argjson a "$already" --argjson k "$invalid" --argjson l "$live" \
    '{ok: true, imported: $i, already: $a, invalid: $k, live: $l}'
}

sub=${1:-}
[ -n "$sub" ] || usage "missing subcommand"
shift
case "$sub" in
  asked)     cmd_asked "$@" ;;
  answered)  cmd_answered "$@" ;;
  skipped)   cmd_skipped "$@" ;;
  abandoned) cmd_abandoned "$@" ;;
  import)    cmd_import ;;
  *) usage "unknown subcommand $sub" ;;
esac
