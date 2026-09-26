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
#   sh learner-sync.sh push [--create-ok] [--events-ok]
#   sh learner-sync.sh pull [<gist-id-or-url>]
#   sh learner-sync.sh pull-finish <work-dir>
#   sh learner-sync.sh status
#   sh learner-sync.sh use <gist-id-or-url>
#   sh learner-sync.sh merge-memory  <base> <local> <remote>
#   sh learner-sync.sh merge-history <local> <remote>
#   sh learner-sync.sh new-events    <local> <remote>

# shellcheck source=hooks/learner-config.sh
. "$(dirname "$0")/learner-config.sh"

SYNC_SCHEMA=1
SYNC_DESC="claude-learner-state"

DATA_DIR="$LEARNER_CFG_DIR/learner"
MEM_FILE="$DATA_DIR/memory.md"
REC_FILE="$DATA_DIR/recap.md"
LIBS_FILE="$DATA_DIR/libs.md"
CFG_FILE="$LEARNER_CFG_DIR/learner.json"
EV_FILE="$DATA_DIR/events.jsonl"
SYNC_JSON="$DATA_DIR/sync.json"
BASE_DIR="$DATA_DIR/sync-base"
BACKUP_DIR="$DATA_DIR/backups"

# Every failure leaves stdout with one machine-readable object and nothing else.
fail() { printf '{"ok":false,"error":"%s"}\n' "$1"; exit 1; }

usage() { printf '{"ok":false,"error":"usage"}\n'; exit 2; }

need_jq() { command -v jq >/dev/null 2>&1 || fail jq-missing; }

# The GitHub token is one the dev hands over, never one read off the machine:
# the github_token plugin option (userConfig, sensitive), or LEARNER_GITHUB_TOKEN
# on a curl/Homebrew/apt install. gh runs against an empty config directory of
# its own, so it never falls back to the credential `gh auth login` stored.
need_gh() {
  command -v gh >/dev/null 2>&1 || fail gh-missing
  _tok="${CLAUDE_PLUGIN_OPTION_GITHUB_TOKEN:-${LEARNER_GITHUB_TOKEN:-}}"
  [ -n "$_tok" ] || fail github-token-missing
  GH_TOKEN="$_tok"
  GH_CONFIG_DIR="$DATA_DIR/gh-config"
  GH_NO_UPDATE_NOTIFIER=1
  export GH_TOKEN GH_CONFIG_DIR GH_NO_UPDATE_NOTIFIER
  unset GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN _tok
  mkdir -p "$GH_CONFIG_DIR" || fail gh-unauthenticated
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
  push|pull|pull-finish|status|use|merge-memory|merge-history|new-events|snapshot) ;;
  *) usage ;;
esac

need_jq

case "$cmd" in
  merge-memory|merge-history|new-events|snapshot) ;;   # pure text, no network
  *) need_gh ;;
esac

# A readable path for a file that may be missing, so awk always gets three
# distinct filenames. Distinct matters: the merge tells the three inputs apart
# by FILENAME, and two identical names would fold two inputs into one. Each
# missing input gets its own file straight from mktemp, so two placeholders
# in the same call can never collide on a shared name or a guessable path.
readable_or_empty() {
  if [ -f "$1" ]; then
    printf '%s' "$1"
    return 0
  fi
  mktemp "${TMPDIR:-/tmp}/learner-sync-empty.XXXXXX"
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
  ' "$_hl" "$_hr" | LC_ALL=C sort -s -t "$(printf '\t')" -k1,1 | cut -f2-
}

history_rows() {  # FILE -> how many Session history rows it holds
  _hf=$(readable_or_empty "$1")
  awk '
    /^[ \t]*\|/ {
      norm = $0
      gsub(/[ \t]+/, " ", norm); gsub(/ *\| */, "|", norm)
      sub(/^ +/, "", norm); sub(/ +$/, "", norm)
      if (norm ~ /^\|[-|]+\|$/) next
      if (norm ~ /^\|Date\|/) next
      n++
    }
    END { print n + 0 }
  ' "$_hf"
}

libs_rows() {  # FILE -> how many libs.md rows it holds
  _lf=$(readable_or_empty "$1")
  awk '
    /^[ \t]*\|/ {
      norm = $0
      gsub(/[ \t]+/, " ", norm); gsub(/ *\| */, "|", norm)
      sub(/^ +/, "", norm); sub(/ +$/, "", norm)
      if (norm ~ /^\|[-|]+\|$/) next        # separator row
      if (norm ~ /^\|Library\|/) next       # header row
      n++
    }
    END { print n + 0 }
  ' "$_lf"
}

bullet_lines() {  # FILE -> how many "- " lines it holds
  if [ -f "$1" ]; then n=$(grep -c '^-[ \t]' "$1" 2>/dev/null); printf '%s' "${n:-0}"; else printf '0'; fi
}

event_lines() {  # FILE -> how many non-empty lines it holds (0 when missing)
  # Non-empty lines, not `wc -l`'s newline count: a gist round-trip that drops
  # or adds a lone trailing newline must not turn into an off-by-one that
  # fails every later pull until the next push.
  if [ -f "$1" ]; then n=$(grep -c . "$1" 2>/dev/null); printf '%s' "${n:-0}"; else printf '0'; fi
}

new_events() {  # LOCAL REMOTE -> the remote records local lacks, remote order, once each
  # Append-only on both sides, so the union is the whole truth: no base needed.
  # Only the missing (id, type) pairs come out, byte for byte and in the order
  # the remote holds them: pull appends them and never rewrites the log, since
  # an IDE tails it by byte offset. Torn or non-object lines on either side
  # are ignored.
  jq -rRn --rawfile loc "$(readable_or_empty "$1")" '
    def key: select(type == "object" and has("id") and has("type")) | [.id, .type] | tostring;
    (reduce ($loc | split("\n")[] | fromjson? | key) as $k ({}; .[$k] = true)) as $have
    | foreach (inputs | . as $raw | (fromjson? | key) as $k | [$k, $raw]) as $e
        ({seen: $have, out: null};
         if .seen[$e[0]] then .out = null else .seen[$e[0]] = true | .out = $e[1] end;
         .out // empty)' "$(readable_or_empty "$2")"
}

read_version() {
  if [ -f "$LEARNER_CFG_DIR/skills/learner/VERSION" ]; then
    tr -d '[:space:]' < "$LEARNER_CFG_DIR/skills/learner/VERSION"
  else
    printf 'unknown'
  fi
}

snapshot_into() {  # DIR — the gist files, or fail empty-record
  _sd="$1"
  has_content "$MEM_FILE" || has_content "$REC_FILE" || fail empty-record
  mkdir -p "$_sd" || fail snapshot-dir
  # `mkdir -p` above only proves $_sd exists as a directory, not that it is
  # writable: it succeeds unconditionally on an already-existing path,
  # including one that exists read-only (a caller-supplied snapshot dir, a
  # TMPDIR remounted mid-session). Each `else` branch's `:` is a POSIX special
  # built-in, so a redirection failure on it aborts a non-interactive shell
  # outright under dash — before the `||` below ever runs, before this
  # script's own `fail()` gets a chance to print its one JSON object, and
  # with the raw dash error escaping straight to the real stderr instead.
  # Every caller of this script (skills/sync's references/sync.md) depends on
  # stdout carrying exactly one machine-readable object; an unguarded abort
  # here hands it nothing at all. The subshell confines the abort to itself,
  # `2>/dev/null` sits outside it because a compound command's redirections
  # are installed before it runs, and `|| :` degrades to a no-op cp source
  # would have degraded to anyway — the manifest write further down still
  # catches the underlying unwritable directory and reports it through
  # `fail()` properly.
  if [ -f "$MEM_FILE" ]; then cp "$MEM_FILE" "$_sd/memory.md"; else ( : > "$_sd/memory.md" ) 2>/dev/null || :; fi
  if [ -f "$REC_FILE" ]; then cp "$REC_FILE" "$_sd/recap.md"; else ( : > "$_sd/recap.md" ) 2>/dev/null || :; fi
  if [ -f "$LIBS_FILE" ]; then cp "$LIBS_FILE" "$_sd/libs.md"; else ( : > "$_sd/libs.md" ) 2>/dev/null || :; fi
  if [ -f "$CFG_FILE" ]; then cp "$CFG_FILE" "$_sd/learner.json"; else printf '{}\n' > "$_sd/learner.json"; fi
  if [ -f "$EV_FILE" ]; then cp "$EV_FILE" "$_sd/events.jsonl"; else ( : > "$_sd/events.jsonl" ) 2>/dev/null || :; fi
  # pushedFrom is the machine_name plugin option (userConfig), never read off
  # the machine itself: the dev chooses what label, if any, leaves with the gist.
  # The option reaches hooks only; learner-onboard.sh hands it on to the Bash
  # commands the sync skill runs as LEARNER_MACHINE_NAME.
  # eventLines counts the snapshot copy just made, not the live $EV_FILE: a
  # session can append to the live log between the cp above and this count,
  # and the manifest must describe exactly what is about to be uploaded, not
  # what the log happens to hold a moment later.
  jq -nc \
    --argjson schema "$SYNC_SCHEMA" \
    --arg at "$(now_utc)" \
    --arg from "${CLAUDE_PLUGIN_OPTION_MACHINE_NAME:-${LEARNER_MACHINE_NAME:-unknown}}" \
    --arg ver "$(read_version)" \
    --argjson mem "$(bullet_lines "$MEM_FILE")" \
    --argjson theme "$(bullet_lines "$REC_FILE")" \
    --argjson hist "$(history_rows "$REC_FILE")" \
    --argjson libs "$(libs_rows "$LIBS_FILE")" \
    --argjson ev "$(event_lines "$_sd/events.jsonl")" \
    '{schemaVersion:$schema, pushedAt:$at, pushedFrom:$from, learnerVersion:$ver,
      counts:{memoryLines:$mem, themeLines:$theme, historyRows:$hist, libsRows:$libs, eventLines:$ev}}' \
    > "$_sd/manifest.json" || fail manifest
}

sync_json_get() {  # KEYPATH -> value or empty
  [ -f "$SYNC_JSON" ] || return 0
  jq -r "$1 // empty" "$SYNC_JSON" 2>/dev/null
}

sync_json_set() {  # KEY VALUE (string values only)
  mkdir -p "$DATA_DIR"
  _cur='{}'
  [ -f "$SYNC_JSON" ] && _cur=$(jq -c 'if type == "object" then . else {} end' "$SYNC_JSON" 2>/dev/null)
  [ -n "$_cur" ] || _cur='{}'
  printf '%s' "$_cur" | jq -c --arg v "$2" "$1 = \$v" > "$SYNC_JSON.tmp" || fail sync-json
  mv "$SYNC_JSON.tmp" "$SYNC_JSON" || fail sync-json
}

sync_json_set_true() {  # KEY — a JSON boolean true, not the string "true"
  mkdir -p "$DATA_DIR"
  _cur='{}'
  [ -f "$SYNC_JSON" ] && _cur=$(jq -c 'if type == "object" then . else {} end' "$SYNC_JSON" 2>/dev/null)
  [ -n "$_cur" ] || _cur='{}'
  printf '%s' "$_cur" | jq -c "$1 = true" > "$SYNC_JSON.tmp" || fail sync-json
  mv "$SYNC_JSON.tmp" "$SYNC_JSON" || fail sync-json
}

gist_file() {  # ID NAME -> the file's content on stdout, exit 1 when absent
  gh gist view "$1" -f "$2" --raw 2>/dev/null
}

advance_base() {  # DIR — adopt DIR as the new common ancestor
  rm -rf "$BASE_DIR.tmp"
  mkdir -p "$BASE_DIR.tmp" || fail base-dir
  # libs.md carries no base entry (see the "libs.md has no base entry" note
  # below, in cmd_pull's manifest): it is append-only, so there is no "deleted
  # on one side" question for a base to answer, and nothing anywhere reads
  # $BASE_DIR/libs.md. Copying it here would be dead state kept only to look
  # symmetric with memory.md and recap.md.
  for f in memory.md recap.md learner.json manifest.json events.jsonl; do
    [ -f "$1/$f" ] && cp "$1/$f" "$BASE_DIR.tmp/$f"
  done
  rm -rf "$BASE_DIR"
  mv "$BASE_DIR.tmp" "$BASE_DIR" || fail base-dir
}

cmd_push() {
  _create_ok=0; _events_ok=0
  for _a in "$@"; do
    case "$_a" in
      --create-ok) _create_ok=1 ;;
      --events-ok) _events_ok=1 ;;
      *) usage ;;
    esac
  done

  _work=$(mktemp -d "${TMPDIR:-/tmp}/learner-sync-push.XXXXXX") || fail work-dir
  snapshot_into "$_work"     # calls fail empty-record when there is nothing to push

  _id=$(sync_json_get '.github.gistId')

  if [ -z "$_id" ]; then
    [ "$_create_ok" = 1 ] || { rm -rf "$_work"; fail needs-create-ok; }
    set -- "$_work/memory.md" "$_work/recap.md" "$_work/libs.md" "$_work/learner.json" \
           "$_work/manifest.json"
    [ -s "$_work/events.jsonl" ] && set -- "$@" "$_work/events.jsonl"
    _url=$(gh gist create --secret -d "$SYNC_DESC" "$@" 2>/dev/null | tail -1)
    [ -n "$_url" ] || { rm -rf "$_work"; fail gh-create; }
    _id=${_url##*/}
    sync_json_set '.github.gistId' "$_id"
    _action=created
  else
    # A gist is recorded but this machine has never pulled it (fresh `use`, or
    # a base wiped some other way): there is no agreement to check a push
    # against, so a push here would overwrite whatever the other machine has
    # unseen. Refuse and send the dev to `pull` first.
    [ -f "$BASE_DIR/manifest.json" ] || { rm -rf "$_work"; fail needs-pull; }
    # The base is what we last agreed on. A remote pushedAt beyond it means the
    # other machine has pushed since, and this push would erase that session.
    _remote_at=$(gist_file "$_id" manifest.json | jq -r '.pushedAt // empty' 2>/dev/null)
    _base_at=''
    [ -f "$BASE_DIR/manifest.json" ] && _base_at=$(jq -r '.pushedAt // empty' "$BASE_DIR/manifest.json" 2>/dev/null)
    # Pinned to the C locale: an LC_COLLATE where digits don't sort in byte
    # order would otherwise silently mis-order these fixed-width timestamps.
    if [ -n "$_remote_at" ] && [ -n "$_base_at" ] && [ "$_remote_at" != "$_base_at" ] \
       && [ "$(LC_ALL=C printf '%s\n%s\n' "$_base_at" "$_remote_at" | LC_ALL=C sort | tail -n1)" = "$_remote_at" ]; then
      rm -rf "$_work"; fail remote-ahead
    fi
    # The dev consented to this gist before it carried events.jsonl (question
    # text, absolute repo paths): the first push that would upload the log
    # asks again. The create path records this consent, its warning names it.
    if [ -s "$_work/events.jsonl" ] && [ "$(sync_json_get '.consent.events')" != true ] \
       && [ "$_events_ok" != 1 ]; then
      rm -rf "$_work"; fail needs-events-ok
    fi
    # A log emptied since the last agreed push (a dev who deleted it for
    # privacy) deletes the gist copy too. Only when the base shows the gist
    # held one: nulling a file a gist never had is a 422.
    _drop_ev=false
    [ ! -s "$_work/events.jsonl" ] && [ -s "$BASE_DIR/events.jsonl" ] && _drop_ev=true
    # libs.md is append-only and has no base copy to three-way merge against
    # (see advance_base), so nothing downstream can notice it shrinking. It
    # shrinks for one reason: the model skipped `sync.md`'s step 4 union after a
    # pull — a documented instruction with no code behind it — leaving this
    # machine with fewer rows than the remote it just adopted. The PATCH below
    # would then replace a populated remote ledger with an empty file, `ok:true`
    # and unrecoverable. counts.libsRows in the base manifest is what the last
    # pull or push agreed on; fewer rows than that is never a legitimate push.
    # An older base manifest carries no count and skips the check, exactly like
    # the pull's own count guards.
    _base_libs=$(jq -r '.counts.libsRows // empty' "$BASE_DIR/manifest.json" 2>/dev/null)
    case "$_base_libs" in ''|*[!0-9]*) _base_libs='' ;; esac
    if [ -n "$_base_libs" ] && [ "$(libs_rows "$LIBS_FILE")" -lt "$_base_libs" ]; then
      rm -rf "$_work"; fail needs-pull
    fi
    # One PATCH with every file: a gist whose manifest announces a recap.md
    # that has not landed would make the next pull merge against a lie.
    jq -n \
      --rawfile mem "$_work/memory.md" \
      --rawfile rec "$_work/recap.md" \
      --rawfile libs "$_work/libs.md" \
      --rawfile cfg "$_work/learner.json" \
      --rawfile man "$_work/manifest.json" \
      --rawfile ev "$_work/events.jsonl" \
      --argjson drop "$_drop_ev" \
      '{files:({"memory.md":{content:$mem},"recap.md":{content:$rec},
                "libs.md":{content:$libs},
                "learner.json":{content:$cfg},"manifest.json":{content:$man}}
               + (if $ev != "" then {"events.jsonl":{content:$ev}}
                  elif $drop then {"events.jsonl":null} else {} end))}' \
      | gh api --method PATCH "/gists/$_id" --input - >/dev/null 2>&1 \
      || { rm -rf "$_work"; fail gh-push; }
    _action=updated
  fi

  # Only now, with GitHub's yes in hand.
  advance_base "$_work"
  { [ "$_action" = created ] || [ "$_events_ok" = 1 ]; } && sync_json_set_true '.consent.events'
  sync_json_set '.github.lastPush' "$(now_utc)"
  rm -rf "$_work"
  jq -nc --arg action "$_action" --arg id "$_id" \
    '{ok:true, action:$action, gistId:$id, url:("https://gist.github.com/" + $id)}'
}

gist_id_from() {  # <id-or-url> -> bare id
  _g=${1%/}
  printf '%s' "${_g##*/}"
}

discover_gist() {  # -> the single gist id carrying SYNC_DESC, or empty
  gh gist list --limit 100 2>/dev/null | awk -v d="$SYNC_DESC" -F '\t' '
    index($0, d) { n++; id = $1 }
    END { if (n == 1) print id; else if (n > 1) print "AMBIGUOUS" }'
}

backup_local() {  # sets BACKUP_PATH to the directory it created
  # Never call this under $( ): a subshell would run `fail`'s exit 1 in a
  # copy of the shell, so the caller would see rc=0 and carry on rewriting
  # memory.md with no backup underneath it.
  BACKUP_PATH="$BACKUP_DIR/$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  mkdir -p "$BACKUP_PATH" || fail backup-dir
  for f in "$MEM_FILE" "$REC_FILE" "$LIBS_FILE" "$CFG_FILE" "$EV_FILE"; do
    [ -f "$f" ] && cp "$f" "$BACKUP_PATH/$(basename "$f")"
  done
}

write_atomic() {  # SRC DEST — never leave a half-written record behind
  cp "$1" "$2.tmp" || fail write
  mv "$2.tmp" "$2" || fail write
}

cmd_pull() {
  _id=$(sync_json_get '.github.gistId')
  if [ -n "${1:-}" ]; then
    _new_id=$(gist_id_from "$1")
    # A base describes agreement with the *previous* gist. Repointing to a
    # different one and keeping it would make this merge read the new
    # remote's absent lines as deletions — the same reasoning `cmd_use`
    # already applies.
    [ "$_new_id" = "$_id" ] || rm -rf "$BASE_DIR"
    _id="$_new_id"
  elif [ -z "$_id" ]; then
    _id=$(discover_gist)
    [ "$_id" = "AMBIGUOUS" ] && fail ambiguous-gist
    [ -n "$_id" ] || fail no-gist
  fi

  _work=$(mktemp -d "${TMPDIR:-/tmp}/learner-sync-pull.XXXXXX") || fail work-dir

  for f in memory.md recap.md learner.json manifest.json; do
    gist_file "$_id" "$f" > "$_work/$f" || { rm -rf "$_work"; fail gh-fetch; }
  done
  [ -s "$_work/manifest.json" ] || { rm -rf "$_work"; fail gh-fetch; }

  # libs.md is fetched leniently, not in the loop above: a gist pushed by an
  # older learner never had one, and refusing the whole pull over a file that
  # legitimately predates this feature would be worse than the data it protects.
  gist_file "$_id" libs.md > "$_work/libs.md" 2>/dev/null
  # `:` is a POSIX special built-in: a redirection failure on it aborts a
  # non-interactive shell outright under dash, before the `||` above it ever
  # runs — unlike the ordinary `gist_file … >` redirect on the line above,
  # whose failure just leaves $_work/libs.md absent or short and falls
  # through to this line normally. $_work is mktemp's own fresh directory, so
  # it is writable when created, but a TMPDIR remounted read-only between
  # that mktemp and this point (or a libs.md this same statement already
  # wrote as read-only, on a filesystem that preserves an inherited mode
  # across the empty write above) reproduces the same abort this file's other
  # guarded sites exist to prevent — with no `fail()` JSON to show for it, on
  # a script whose entire contract with its caller is one JSON object.
  ( [ -s "$_work/libs.md" ] || : > "$_work/libs.md" ) 2>/dev/null || :
  # Optional: a gist pushed by an older learner has no events.jsonl.
  gist_file "$_id" events.jsonl > "$_work/events.jsonl" 2>/dev/null || : > "$_work/events.jsonl"

  _schema=$(jq -r '.schemaVersion // 0' "$_work/manifest.json" 2>/dev/null)
  case "$_schema" in
    ''|*[!0-9]*) rm -rf "$_work"; fail gh-fetch ;;
  esac
  [ "$_schema" -le "$SYNC_SCHEMA" ] || { rm -rf "$_work"; fail schema-too-new; }

  # gh's own exit status only rules out an outright fetch failure. A gist that
  # answers but hands back fewer lines than its own manifest claims is just as
  # dangerous: the merge below would read the missing lines as deleted on the
  # other machine and drop them here too. A manifest written by an older
  # learner may carry no counts at all, so the check is skipped, not failed,
  # when the expected value is empty.
  _want_mem=$(jq -r '.counts.memoryLines // empty' "$_work/manifest.json" 2>/dev/null)
  [ -z "$_want_mem" ] || [ "$(bullet_lines "$_work/memory.md")" = "$_want_mem" ] \
    || { rm -rf "$_work"; fail gh-fetch; }
  _want_hist=$(jq -r '.counts.historyRows // empty' "$_work/manifest.json" 2>/dev/null)
  [ -z "$_want_hist" ] || [ "$(history_rows "$_work/recap.md")" = "$_want_hist" ] \
    || { rm -rf "$_work"; fail gh-fetch; }
  # libs.md was fetched leniently above (empty on any failure, indistinguishable
  # from a gist that genuinely has none), so it gets the same manifest-declared
  # count guard as memory.md and recap.md rather than the required loop: a
  # pre-feature manifest has no counts.libsRows and skips the check, but a
  # manifest that does declare a nonzero count catches the one failure mode
  # leniency alone cannot — a transient fetch error silently emptying a
  # populated remote ledger the next time this machine pushes.
  _want_libs=$(jq -r '.counts.libsRows // empty' "$_work/manifest.json" 2>/dev/null)
  [ -z "$_want_libs" ] || [ "$(libs_rows "$_work/libs.md")" = "$_want_libs" ] \
    || { rm -rf "$_work"; fail gh-fetch; }
  _want_ev=$(jq -r '.counts.eventLines // empty' "$_work/manifest.json" 2>/dev/null)
  # An empty file cannot be PATCHed in, and push only deletes the gist copy when
  # its base shows one, so a stale events.jsonl can outlive an emptied log; the
  # manifest's 0 is the truth.
  [ "$_want_ev" = 0 ] && : > "$_work/events.jsonl"
  [ -z "$_want_ev" ] || [ "$(event_lines "$_work/events.jsonl")" = "$_want_ev" ] \
    || { rm -rf "$_work"; fail gh-fetch; }

  # Past this line the local record changes, so the net goes up first.
  backup_local; _backup="$BACKUP_PATH"

  _first=true
  [ -f "$BASE_DIR/memory.md" ] && _first=false

  merge_memory "$BASE_DIR/memory.md" "$MEM_FILE" "$_work/memory.md" > "$_work/memory.merged" \
    || { rm -rf "$_work"; fail merge; }
  write_atomic "$_work/memory.merged" "$MEM_FILE"

  # Read the live log at the last moment: a session may have appended during the fetch.
  # The log is append-only for its readers too (an IDE tails it by byte offset),
  # so pull only ever appends the records it lacks, with one >>, and writes
  # nothing at all when there is nothing new. A torn last line gets a newline
  # first, so the first appended record is not glued onto it.
  new_events "$EV_FILE" "$_work/events.jsonl" > "$_work/events.new" \
    || { rm -rf "$_work"; fail merge; }
  if [ -s "$_work/events.new" ]; then
    mkdir -p "$DATA_DIR" || { rm -rf "$_work"; fail write; }
    _torn=0
    [ -s "$EV_FILE" ] && [ -n "$(tail -c 1 "$EV_FILE")" ] && _torn=1
    { [ "$_torn" = 1 ] && printf '\n'; cat "$_work/events.new"; } >> "$EV_FILE" \
      || { rm -rf "$_work"; fail write; }
  fi

  merge_history "$REC_FILE" "$_work/recap.md" > "$_work/history.md" \
    || { rm -rf "$_work"; fail merge; }

  # The remote config wins, except disabledPaths: those are absolute paths that
  # mean nothing on the other machine, so replacing them would silence learner
  # on repos that are not here and wake it on the ones the dev muted.
  if [ -s "$_work/learner.json" ]; then
    [ -f "$CFG_FILE" ] || printf '{}\n' > "$CFG_FILE"
    jq -s '(.[0] * .[1])
           + {disabledPaths: (((.[0].disabledPaths // []) + (.[1].disabledPaths // [])) | unique)}' \
      "$CFG_FILE" "$_work/learner.json" > "$_work/config.merged" \
      || { rm -rf "$_work"; fail config-merge; }
    write_atomic "$_work/config.merged" "$CFG_FILE"
  fi

  # sync.json records the gist only once the fetch has actually worked, so a
  # mistyped id never sticks.
  sync_json_set '.github.gistId' "$_id"

  # libs.md has no base entry: nothing is ever removed from it (a row only ever
  # gets added, per data.md), so there is no "deleted on one side" question for
  # a base to answer — unlike recap.md's themes, where the base decides whether
  # an absent entry was dropped or never pushed.
  jq -nc --arg id "$_id" --arg bk "$_backup" --arg w "$_work" \
     --arg rl "$REC_FILE" --arg rr "$_work/recap.md" --arg rb "$BASE_DIR/recap.md" \
     --arg rh "$_work/history.md" --argjson first "$_first" \
     --arg ll "$LIBS_FILE" --arg lr "$_work/libs.md" \
     '{ok:true, action:"pulled", gistId:$id, backup:$bk, work:$w, memory:"merged",
       firstSync:$first,
       recap:{local:$rl, remote:$rr, base:$rb, historyMerged:$rh},
       libs:{local:$ll, remote:$lr}}'
}

cmd_pull_finish() {
  _work=${1:-}
  [ -n "$_work" ] && [ -f "$_work/manifest.json" ] || fail no-work-dir
  # This path is handed in from the outside (the model relays what `pull`
  # printed). Refuse anything that is not one of this script's own pull work
  # dirs before the rm -rf below, so a stale or mistaken argument can never
  # turn into an arbitrary recursive delete.
  case "$_work" in
    "${TMPDIR:-/tmp}/learner-sync-pull."*) ;;
    *) fail no-work-dir ;;
  esac
  advance_base "$_work"
  sync_json_set '.github.lastPull' "$(now_utc)"
  rm -rf "$_work"
  jq -nc '{ok:true, action:"pull-finished"}'
}

cmd_status() {
  _id=$(sync_json_get '.github.gistId')
  [ -n "$_id" ] || fail no-gist

  _has_base=false
  [ -f "$BASE_DIR/manifest.json" ] && _has_base=true

  _bm=0; _bh=0; _base_at=''
  if [ "$_has_base" = true ]; then
    _bm=$(bullet_lines "$BASE_DIR/memory.md")
    _bh=$(history_rows "$BASE_DIR/recap.md")
    _base_at=$(jq -r '.pushedAt // empty' "$BASE_DIR/manifest.json" 2>/dev/null)
  fi
  _lm=$(bullet_lines "$MEM_FILE")
  _lh=$(history_rows "$REC_FILE")
  _dm=$((_lm - _bm)); [ "$_dm" -lt 0 ] && _dm=0
  _dh=$((_lh - _bh)); [ "$_dh" -lt 0 ] && _dh=0

  _remote_at=$(gist_file "$_id" manifest.json | jq -r '.pushedAt // empty' 2>/dev/null)
  _ahead=false
  # Pinned to the C locale, matching the push's divergence guard: an
  # LC_COLLATE where digits don't sort in byte order would otherwise
  # silently mis-order these fixed-width timestamps.
  if [ -n "$_remote_at" ] && [ -n "$_base_at" ] && [ "$_remote_at" != "$_base_at" ] \
     && [ "$(LC_ALL=C printf '%s\n%s\n' "$_base_at" "$_remote_at" | LC_ALL=C sort | tail -n1)" = "$_remote_at" ]; then
    _ahead=true
  fi

  jq -nc --arg id "$_id" \
     --arg push "$(sync_json_get '.github.lastPush')" \
     --arg pull "$(sync_json_get '.github.lastPull')" \
     --argjson base "$_has_base" --argjson dm "$_dm" --argjson dh "$_dh" \
     --argjson ahead "$_ahead" \
     '{ok:true, gistId:$id, url:("https://gist.github.com/" + $id),
       lastPush:$push, lastPull:$pull, hasBase:$base,
       unpushed:{memoryLines:$dm, historyRows:$dh}, remoteAhead:$ahead}'
}

cmd_use() {
  [ -n "${1:-}" ] || usage
  _id=$(gist_id_from "$1")
  [ -n "$_id" ] || usage
  sync_json_set '.github.gistId' "$_id"
  # The base describes agreement with the *previous* gist. Kept, it would make
  # the next pull read the new remote's missing lines as deletions.
  rm -rf "$BASE_DIR"
  jq -nc --arg id "$_id" '{ok:true, action:"repointed", gistId:$id}'
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
  new-events)
    [ $# -eq 2 ] || usage
    new_events "$1" "$2"
    exit 0
    ;;
  snapshot)
    [ $# -eq 1 ] || usage
    snapshot_into "$1"
    printf '{"ok":true,"action":"snapshot","dir":"%s"}\n' "$1"
    exit 0
    ;;
  push) cmd_push "$@"; exit 0 ;;
  pull) cmd_pull "$@"; exit 0 ;;
  pull-finish) cmd_pull_finish "$@"; exit 0 ;;
  status) cmd_status; exit 0 ;;
  use) cmd_use "$@"; exit 0 ;;
  *) fail not-implemented ;;
esac
