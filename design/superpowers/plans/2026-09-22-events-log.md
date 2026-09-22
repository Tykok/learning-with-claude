# Learner events log — Implementation Plan (plan 1 of 3: producer)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Learner writes a versioned, append-only `events.jsonl` — one line per question asked, answered, skipped or abandoned — that the future VS Code and JetBrains extensions read.

**Architecture:** One new POSIX `sh` script, `plugins/learner/hooks/learner-event.sh`, owns every write to the log (the model calls it with arguments and never hand-writes JSON). The `SessionEnd` cleanup hook closes a dead session's open questions through it; `learner-sync.sh` carries the log in the gist; the skills' prose tells the model when to call it. A JSON Schema at `contract/events.schema.json` is the contract the extensions consume.

**Tech Stack:** POSIX `sh`, `jq`, `awk`, `cksum`; tests in the existing `test.sh` (no framework); optional `ajv-cli` schema check in CI.

**Spec:** `/Users/elietreport/Projet/Perso/learner-ide/design/superpowers/specs/2026-09-22-ide-extensions-design.md` — §§ 1 and 2 (the data contract and the producer). Plans 2 (VS Code) and 3 (JetBrains) live in the `learner-ide` repo and start once this ships.

**Branch:** create `feat/events-log` from `main` before Task 1, and commit this plan there first (`git add design/superpowers/plans/2026-09-22-events-log.md && git commit -m "docs(plan): events log producer"`).

## Global Constraints

- Every hook script is POSIX `sh` (`#!/bin/sh`), starts with `# SPDX-License-Identifier: GPL-3.0-or-later`, and passes `shellcheck --severity=warning`.
- Log path: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner/events.jsonl` (i.e. `$LEARNER_CFG_DIR/learner/events.jsonl`).
- Every event line carries `"v":1`, `type`, `id`, `ts` (UTC, `YYYY-MM-DDTHH:MM:SSZ`).
- `type` is one of `question.asked`, `question.answered`, `question.skipped`, `question.abandoned`.
- Ids: `q_<YYYYMMDDTHHMMSSZ>_<8 lowercase hex>` for live questions, `q_imp_<cksum>_<bytes>` for imported rows; both match `^q_[A-Za-z0-9_]+$`.
- Session id comes from `--session`, else `$CLAUDE_CODE_SESSION_ID`, else the literal `unknown`.
- `--prompt` is truncated to **800 characters**; no event ever carries code or a diff.
- A missing `jq` makes `learner-event.sh` print one warning on stderr and exit 0 without writing. A usage error (bad or missing argument) exits 2 without writing.
- Readers of the log skip unparseable lines (`fromjson?`) and never fail on them.
- `memory.md` and `recap.md` formats do not change.
- Commit messages: Conventional Commits, ending with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **A prompt with quotes, backslashes, newlines and emoji** must come back byte-identical from `jq -r .prompt`, on one physical line — Task 1 pins it.
2. **A torn or hand-edited line in `events.jsonl`** (crash mid-append) must not stop `abandoned`, `import` or the sync merge — Tasks 2, 3 and 5 each append a broken line before their assertions.
3. **The very first event on a fresh machine** (no `learner/` directory yet) must create the directory and the file — Task 1 pins it.
4. **A pull from a gist pushed by an older Learner** (no `events.jsonl` in it) must succeed and keep the local log intact — Task 5 pins it.
5. **An event emitted outside a git repo, or with no session id in the environment**, must still be a valid line (`root`/`repo` null, `session` `"unknown"`) — Task 1 pins it.

---

## File map

| File | Status | Responsibility |
|------|--------|----------------|
| `contract/events.schema.json` | create | The JSON Schema consumers validate against. |
| `plugins/learner/hooks/learner-event.sh` | create | Every write to `events.jsonl`: `asked`, `answered`, `skipped`, `abandoned`, `import`. |
| `plugins/learner/hooks/learner-cleanup.sh` | modify | On `SessionEnd`, close this session's open questions. |
| `plugins/learner/hooks/learner-sync.sh` | modify | Snapshot, push, pull, merge and back up `events.jsonl`. |
| `plugins/learner/skills/learner/references/data.md` | modify | When and how the model emits events. |
| `plugins/learner/skills/learner/references/hook-quiz.md` | modify | Emit `asked` when the question goes out; `fill` anchor. |
| `plugins/learner/skills/quiz/SKILL.md`, `plugins/learner/skills/improve/SKILL.md` | modify | Point at the events step. |
| `plugins/learner/skills/learner/SKILL.md` | modify | `events import` dispatch row. |
| `plugins/learner/skills/sync/SKILL.md`, `.../sync/references/sync.md` | modify | Name `events.jsonl` in the record and in the consent warning. |
| `README.md`, `docs/install.html`, `docs/safety.html`, `docs/usage.html` | modify | File table and consent lists. |
| `test.sh` | modify | New `events log` sections; sync additions. |
| `.github/workflows/ci.yml` | modify | Turn on the schema check. |

`install.sh`, the Homebrew formula and the `.deb` build copy `hooks/*.sh` by glob, so the new script ships with no edit to them. The log is closed from inside `learner-cleanup.sh`, so `hooks.json` and `settings.snippet.json` do not change.

---

### Task 1: Schema and `learner-event.sh asked`

**Files:**
- Create: `contract/events.schema.json`
- Create: `plugins/learner/hooks/learner-event.sh`
- Modify: `test.sh` (new section just above `# --- summary ---`)
- Modify: `.github/workflows/ci.yml` (`tests` step)

**Interfaces:**
- Produces: `sh learner-event.sh asked --style S --mode M --level L --domain D --files "a b" --prompt P [--anchor FILE:LINE] [--session SID]` → prints the new id on stdout, appends one line. Shared helpers inside the script that later tasks reuse: `append LINE`, `now_utc`, `read_log` (valid events as one JSON array), `usage MSG`.

- [ ] **Step 1: Write the schema**

`contract/events.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/Tykok/learning-with-claude/contract/events.schema.json",
  "title": "Learner event",
  "description": "One line of ${CLAUDE_CONFIG_DIR:-~/.claude}/learner/events.jsonl. Written only by learner-event.sh.",
  "type": "object",
  "required": ["v", "type", "id", "ts"],
  "properties": {
    "v": { "const": 1 },
    "type": { "enum": ["question.asked", "question.answered", "question.skipped", "question.abandoned"] },
    "id": { "type": "string", "pattern": "^q_[A-Za-z0-9_]+$" },
    "ts": { "type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" },
    "session": { "type": "string", "minLength": 1 },
    "repo": { "type": ["string", "null"] },
    "root": { "type": ["string", "null"] },
    "style": { "type": "string", "minLength": 1 },
    "mode": { "enum": ["granular", "synthesis"] },
    "level": { "enum": ["D", "J", "C", "S", "E"] },
    "domain": { "type": "string", "minLength": 1 },
    "files": { "type": "array", "items": { "type": "string", "minLength": 1 } },
    "anchor": {
      "type": "object",
      "required": ["file", "line"],
      "properties": {
        "file": { "type": "string", "minLength": 1 },
        "line": { "type": "integer", "minimum": 1 }
      },
      "additionalProperties": false
    },
    "prompt": { "type": "string", "maxLength": 800 },
    "verdict": { "enum": ["ok", "revisit"] },
    "theme": { "type": ["string", "null"] },
    "note": { "type": "string" }
  },
  "allOf": [
    {
      "if": { "properties": { "type": { "const": "question.asked" } } },
      "then": {
        "required": ["session", "repo", "root", "style", "mode", "level", "domain", "files", "prompt"],
        "properties": { "style": { "enum": ["code", "architecture", "fill"] } }
      }
    },
    {
      "if": { "properties": { "type": { "const": "question.answered" } } },
      "then": { "required": ["verdict", "domain", "theme"] }
    },
    {
      "if": { "properties": { "type": { "const": "question.abandoned" } } },
      "then": { "required": ["session"] }
    }
  ],
  "additionalProperties": false
}
```

(`style` is a strict enum on `asked` only: an imported `answered` carries whatever the recap's Style cell said, `improve` included.)

- [ ] **Step 2: Write the failing tests**

Append to `test.sh`, immediately above the `# --- summary ---` line:

```bash
# --- events log: asked --------------------------------------------------------
EV="$PLUG/hooks/learner-event.sh"
EVLOG="$WORK/cfg/learner/events.jsonl"
# CLAUDE_CODE_SESSION_ID is pinned so the suite behaves the same inside and
# outside a Claude Code session.
ev() { CLAUDE_CODE_SESSION_ID="${EV_SID:-sess-A}" CLAUDE_PROJECT_DIR="$WORK/proj" sh "$EV" "$@"; }
evn() { wc -l < "$EVLOG" | tr -d ' '; }
rm -rf "$WORK/cfg/learner"

EVP='Say "hi" — then \ leave 🎓
second line'
id=$(ev asked --style fill --mode granular --level senior --domain Code \
       --anchor src/foo.ts:42 --files "src/foo.ts  src/bar.ts" --prompt "$EVP"); rc=$?
line=$(tail -n1 "$EVLOG" 2>/dev/null)
{ [ "$rc" = 0 ] && [ -f "$EVLOG" ] && [ "$(evn)" = 1 ]; } \
  && ok "the first event creates learner/ and events.jsonl, one physical line" \
  || ko "the first event creates learner/ and events.jsonl, one physical line (rc=$rc)"
printf '%s' "$id" | grep -Eq '^q_[0-9]{8}T[0-9]{6}Z_[0-9a-f]{8}$' \
  && [ "$(printf '%s' "$line" | jq -r .id)" = "$id" ] \
  && ok "asked prints the id it wrote, in the q_<UTC>_<hex> format" \
  || ko "asked prints the id it wrote, in the q_<UTC>_<hex> format (id=$id)"
{ [ "$(printf '%s' "$line" | jq -r '.v')" = 1 ] \
  && [ "$(printf '%s' "$line" | jq -r '.type')" = "question.asked" ] \
  && [ "$(printf '%s' "$line" | jq -r '.level')" = "S" ] \
  && [ "$(printf '%s' "$line" | jq -r '.session')" = "sess-A" ] \
  && [ "$(printf '%s' "$line" | jq -r '.root')" = "$WORK/proj" ] \
  && [ "$(printf '%s' "$line" | jq -r '.repo')" = "proj" ] \
  && [ "$(printf '%s' "$line" | jq -c '.files')" = '["src/foo.ts","src/bar.ts"]' ] \
  && [ "$(printf '%s' "$line" | jq -c '.anchor')" = '{"file":"src/foo.ts","line":42}' ] \
  && printf '%s' "$line" | jq -r .ts | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; } \
  && ok "asked records v, type, canonical level, session, root, repo, files, anchor, ts" \
  || ko "asked records v, type, canonical level, session, root, repo, files, anchor, ts (line=$line)"
[ "$(printf '%s' "$line" | jq -r .prompt)" = "$EVP" ] \
  && ok "a prompt with quotes, backslash, newline and emoji round-trips" \
  || ko "a prompt with quotes, backslash, newline and emoji round-trips"

long=$(awk 'BEGIN { for (i = 0; i < 3000; i++) printf "a" }')
ev asked --style code --mode granular --level J --domain Code --files a.ts --prompt "$long" >/dev/null
[ "$(tail -n1 "$EVLOG" | jq '.prompt | length')" = 800 ] \
  && ok "asked truncates the prompt to 800 characters" \
  || ko "asked truncates the prompt to 800 characters"
[ "$(tail -n1 "$EVLOG" | jq -c 'has("anchor")')" = false ] \
  && ok "asked without --anchor writes no anchor key" \
  || ko "asked without --anchor writes no anchor key"

mkdir -p "$WORK/tmp/nogit"
( cd "$WORK/tmp/nogit" && env -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$WORK/tmp/nogit" \
    sh "$EV" asked --style code --mode synthesis --level C --domain Tests --files x --prompt p >/dev/null )
line=$(tail -n1 "$EVLOG")
{ [ "$(printf '%s' "$line" | jq -c '[.root, .repo, .session]')" = '[null,null,"unknown"]' ]; } \
  && ok "outside git and with no session env: root/repo null, session unknown" \
  || ko "outside git and with no session env: root/repo null, session unknown (line=$line)"

EV_SID=sess-X ev asked --session sess-override --style code --mode granular --level J \
  --domain Code --files a --prompt p >/dev/null
[ "$(tail -n1 "$EVLOG" | jq -r .session)" = "sess-override" ] \
  && ok "--session wins over CLAUDE_CODE_SESSION_ID" \
  || ko "--session wins over CLAUDE_CODE_SESSION_ID"

n=$(evn)
for bad in "--style poem" "--mode fast" "--level Z" "--anchor src/foo.ts" "--anchor src/foo.ts:0" "--anchor src/foo.ts:x"; do
  # shellcheck disable=SC2086
  ev asked --style code --mode granular --level J --domain Code --files a --prompt p $bad >/dev/null 2>&1; rc=$?
  { [ "$rc" = 2 ] && [ "$(evn)" = "$n" ]; } \
    && ok "asked rejects $bad with exit 2 and writes nothing" \
    || ko "asked rejects $bad with exit 2 and writes nothing (rc=$rc)"
done
ev asked --style code --mode granular --level J --files a --prompt p >/dev/null 2>&1; rc=$?
{ [ "$rc" = 2 ] && [ "$(evn)" = "$n" ]; } \
  && ok "asked without --domain exits 2 and writes nothing" \
  || ko "asked without --domain exits 2 and writes nothing (rc=$rc)"

out=$(PATH="$NOJQ_PATH" /bin/sh "$EV" asked --style code --mode granular --level J --domain Code \
        --files a --prompt p 2>"$WORK/tmp/ev-nojq.err"); rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ] && grep -q 'jq' "$WORK/tmp/ev-nojq.err" && [ "$(evn)" = "$n" ]; } \
  && ok "without jq, learner-event.sh warns once, exits 0 and writes nothing" \
  || ko "without jq, learner-event.sh warns once, exits 0 and writes nothing (rc=$rc out=$out)"

# Schema check: opt-in, because npx fetches ajv-cli from the network. CI sets it.
if [ -n "${LEARNER_SCHEMA_CHECK:-}" ] && command -v npx >/dev/null 2>&1; then
  mkdir -p "$WORK/tmp/evjson"; i=0; bad=0
  while IFS= read -r l; do
    i=$((i + 1)); printf '%s\n' "$l" > "$WORK/tmp/evjson/$i.json"
    npx --yes ajv-cli@5 validate --spec=draft2020 --strict=false \
      -s "$ROOT/contract/events.schema.json" -d "$WORK/tmp/evjson/$i.json" >/dev/null 2>&1 || bad=$((bad + 1))
  done < "$EVLOG"
  [ "$bad" = 0 ] && ok "every asked line validates against contract/events.schema.json" \
    || ko "every asked line validates against contract/events.schema.json ($bad invalid)"
else
  skip "schema check (set LEARNER_SCHEMA_CHECK=1 with npx available)"
fi
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `./test.sh 2>&1 | grep -E 'events|asked|jq, learner-event|Passed'`
Expected: every new `asked`/`events` line is `FAIL` (the script does not exist).

- [ ] **Step 4: Write `learner-event.sh` with `asked`**

`plugins/learner/hooks/learner-event.sh`:

```sh
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
```

- [ ] **Step 5: Run the tests**

Run: `chmod +x plugins/learner/hooks/learner-event.sh && ./test.sh 2>&1 | grep -E 'FAIL|Passed'`
Expected: no `FAIL` line; `Failed: 0`.
Then: `shellcheck --severity=warning plugins/learner/hooks/learner-event.sh` → no output.

- [ ] **Step 6: Turn the schema check on in CI**

In `.github/workflows/ci.yml`, replace the `tests` step:

```yaml
      - name: tests
        run: ./test.sh
        env:
          LEARNER_SCHEMA_CHECK: '1'
```

(Node is already on `ubuntu-latest`; the later `install Claude Code` step relies on it too.)

- [ ] **Step 7: Commit**

```bash
git add contract/events.schema.json plugins/learner/hooks/learner-event.sh test.sh .github/workflows/ci.yml
git commit -m "feat(events): learner-event.sh asked and the events.jsonl schema

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `answered`, `skipped`, `abandoned` and the SessionEnd close

**Files:**
- Modify: `plugins/learner/hooks/learner-event.sh`
- Modify: `plugins/learner/hooks/learner-cleanup.sh`
- Modify: `test.sh` (append a section after Task 1's)

**Interfaces:**
- Consumes: `append`, `now_utc`, `read_log`, `usage` from Task 1.
- Produces: `answered --id ID --verdict ok|revisit --domain D --theme T [--note N] [--repo R] [--style S] [--ts TS]` (the last three are used by Task 3's import), `skipped --id ID [--domain D] [--ts TS]`, `abandoned --session SID` → one `question.abandoned` per still-open `asked` of that session, idempotent.

- [ ] **Step 1: Write the failing tests**

Append after the Task 1 section in `test.sh`:

```bash
# --- events log: answered, skipped, abandoned --------------------------------
rm -f "$EVLOG"
q1=$(ev asked --style code --mode granular --level S --domain Code --files a --prompt p1)
ev answered --id "$q1" --verdict revisit --domain Code --theme "Error and exception handling" --note "missed the retry" >/dev/null
line=$(tail -n1 "$EVLOG")
{ [ "$(printf '%s' "$line" | jq -c '[.type, .id, .verdict, .domain, .theme, .note, .v]')" \
      = "[\"question.answered\",\"$q1\",\"revisit\",\"Code\",\"Error and exception handling\",\"missed the retry\",1]" ]; } \
  && ok "answered records id, verdict, domain, theme and note" \
  || ko "answered records id, verdict, domain, theme and note (line=$line)"

ev answered --id "$q1" --verdict ok --domain Code --theme '' >/dev/null
[ "$(tail -n1 "$EVLOG" | jq -c '[.theme, has("note")]')" = '[null,false]' ] \
  && ok "an empty --theme is written as null, and no --note means no note key" \
  || ko "an empty --theme is written as null, and no --note means no note key"

n=$(evn)
for args in "--verdict ok --domain Code --theme t" "--id $q1 --verdict meh --domain Code --theme t" "--id $q1 --verdict ok --theme t"; do
  # shellcheck disable=SC2086
  ev answered $args >/dev/null 2>&1; rc=$?
  { [ "$rc" = 2 ] && [ "$(evn)" = "$n" ]; } \
    && ok "answered rejects '$args' with exit 2" \
    || ko "answered rejects '$args' with exit 2 (rc=$rc)"
done

q2=$(ev asked --style code --mode granular --level S --domain Code --files a --prompt p2)
ev skipped --id "$q2" >/dev/null
[ "$(tail -n1 "$EVLOG" | jq -c '[.type, .id]')" = "[\"question.skipped\",\"$q2\"]" ] \
  && ok "skipped records the id" || ko "skipped records the id"

# Session A: q1 answered, q2 skipped, q3 open. Session B: q4 open.
q3=$(ev asked --style fill --mode granular --level S --domain Code --files a --prompt p3)
q4=$(EV_SID=sess-B ev asked --style code --mode granular --level S --domain Code --files a --prompt p4)
printf '{"v":1,"type":"question.asked","id":"q_torn' >> "$EVLOG"; printf '\n' >> "$EVLOG"
ev abandoned --session sess-A >/dev/null; rc=$?
ab=$(jq -Rr 'fromjson? | select(.type == "question.abandoned") | .id' "$EVLOG")
{ [ "$rc" = 0 ] && [ "$ab" = "$q3" ] \
  && [ "$(jq -Rr "fromjson? | select(.type == \"question.abandoned\") | .session" "$EVLOG")" = "sess-A" ]; } \
  && ok "abandoned closes only the session's still-open questions, past a torn line" \
  || ko "abandoned closes only the session's still-open questions, past a torn line (rc=$rc ab=$ab)"
n=$(evn); ev abandoned --session sess-A >/dev/null
[ "$(evn)" = "$n" ] && ok "abandoned is idempotent" || ko "abandoned is idempotent"
ev abandoned >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "abandoned without --session exits 2" || ko "abandoned without --session exits 2 (rc=$rc)"
rm -f "$EVLOG"; ev abandoned --session sess-A >/dev/null; rc=$?
{ [ "$rc" = 0 ] && [ ! -f "$EVLOG" ]; } \
  && ok "abandoned with no log is a no-op" || ko "abandoned with no log is a no-op (rc=$rc)"

q5=$(EV_SID=sess-C ev asked --style code --mode granular --level S --domain Code --files a --prompt p5)
printf '{"session_id":"sess-C"}' | sh "$CLEAN"; rc=$?
{ [ "$rc" = 0 ] && [ "$(tail -n1 "$EVLOG" | jq -c '[.type, .id]')" = "[\"question.abandoned\",\"$q5\"]" ]; } \
  && ok "the SessionEnd cleanup hook abandons the session's open questions" \
  || ko "the SessionEnd cleanup hook abandons the session's open questions (rc=$rc)"
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | grep -E 'answered|skipped|abandon|Passed'`
Expected: the new lines are `FAIL` (`unknown subcommand`).

- [ ] **Step 3: Implement the three subcommands**

In `learner-event.sh`, add before the `sub=${1:-}` line:

```sh
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
```

and extend the dispatch:

```sh
case "$sub" in
  asked)     cmd_asked "$@" ;;
  answered)  cmd_answered "$@" ;;
  skipped)   cmd_skipped "$@" ;;
  abandoned) cmd_abandoned "$@" ;;
  *) usage "unknown subcommand $sub" ;;
esac
```

- [ ] **Step 4: Close open questions from the cleanup hook**

In `plugins/learner/hooks/learner-cleanup.sh`, insert after the `[ -n "$SID" ] || exit 0` line:

```sh
# A session that ends with a question still open would leave the IDE badge lit
# forever. Best-effort, like the rest of this hook.
sh "${0%/*}/learner-event.sh" abandoned --session "$SID" >/dev/null 2>&1 || true
```

and update its header comment's second paragraph to: `SessionEnd hook: remove this session's scratch files from TMPDIR and close its open questions in events.jsonl. Best-effort; a no-op if jq or the session id is missing.`

- [ ] **Step 5: Run the tests**

Run: `./test.sh 2>&1 | grep -E 'FAIL|Passed'` → `Failed: 0`.
Run: `shellcheck --severity=warning plugins/learner/hooks/learner-event.sh plugins/learner/hooks/learner-cleanup.sh` → no output.

- [ ] **Step 6: Commit**

```bash
git add plugins/learner/hooks/learner-event.sh plugins/learner/hooks/learner-cleanup.sh test.sh
git commit -m "feat(events): answered, skipped, abandoned; SessionEnd closes open questions

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `learner-event.sh import` — backfill from `recap.md`

**Files:**
- Modify: `plugins/learner/hooks/learner-event.sh`
- Modify: `test.sh` (append a section after Task 2's)

**Interfaces:**
- Consumes: `cmd_answered`, `cmd_skipped` (with `--repo`, `--style`, `--ts`) from Task 2; `read_log` from Task 1.
- Produces: `sh learner-event.sh import` → appends one event per new `Session history` row and prints `{"ok":true,"imported":N,"already":M,"invalid":K}`.

Row format (`references/data.md`): `| Date | Repo | Domain | Style | Verdict | Note | Theme |`; rows written before the `Theme` column have six cells. Verdict cells are `✅ ok`, `⚠️ revisit`, `⏭️ skip`.

- [ ] **Step 1: Write the failing tests**

```bash
# --- events log: import from recap.md ----------------------------------------
rm -f "$EVLOG"
mkdir -p "$WORK/cfg/learner"
cat > "$WORK/cfg/learner/recap.md" <<'RECAP'
## To improve

### Code
- Error and exception handling

## Session history

| Date | Repo | Domain | Style | Verdict | Note | Theme |
|------|------|--------|-------|---------|------|-------|
| 2026-09-10 | api | Code | code | ✅ ok | retries fine | Error and exception handling |
| 2026-09-11 | api | Tests | fill | ⏭️ skip |  | Test design |
| 2026-09-12 | web | Architecture | architecture | ⚠️ revisit | layering unclear |
| not-a-date | web | Code | code | ✅ ok | x | y |
RECAP
printf '{"torn\n' > "$EVLOG"
out=$(sh "$EV" import); rc=$?
{ [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -c '[.ok, .imported, .already, .invalid]')" = '[true,3,0,1]' ]; } \
  && ok "import appends one event per valid history row and counts the invalid one" \
  || ko "import appends one event per valid history row and counts the invalid one (rc=$rc out=$out)"
got=$(jq -Rc 'fromjson? | [.type, .ts, .verdict, .domain, .theme, .repo, .style]' "$EVLOG" | tr '\n' ' ')
want='["question.answered","2026-09-10T00:00:00Z","ok","Code","Error and exception handling","api","code"] ["question.skipped","2026-09-11T00:00:00Z",null,"Tests",null,"api","fill"] ["question.answered","2026-09-12T00:00:00Z","revisit","Architecture",null,"web","architecture"] '
[ "$got" = "$want" ] \
  && ok "imported rows keep date, verdict, domain, theme (null when untagged), repo and style" \
  || ko "imported rows keep date, verdict, domain, theme (null when untagged), repo and style (got=$got)"
jq -Rr 'fromjson? | .id' "$EVLOG" | grep -Evq '^q_imp_[0-9]+_[0-9]+$' \
  && ko "imported ids use the q_imp_<cksum>_<bytes> form" \
  || ok "imported ids use the q_imp_<cksum>_<bytes> form"
n=$(evn); out=$(sh "$EV" import)
{ [ "$(evn)" = "$n" ] && [ "$(printf '%s' "$out" | jq -c '[.imported, .already]')" = '[0,3]' ]; } \
  && ok "a second import adds nothing" \
  || ko "a second import adds nothing (out=$out)"
rm -f "$WORK/cfg/learner/recap.md"
out=$(sh "$EV" import); rc=$?
{ [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -c '[.imported, .already, .invalid]')" = '[0,0,0]' ]; } \
  && ok "import with no recap.md reports zero and succeeds" \
  || ko "import with no recap.md reports zero and succeeds (out=$out)"
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | grep -E 'import|Passed'` → new lines `FAIL`.

- [ ] **Step 3: Implement `import`**

In `learner-event.sh`, add before the dispatch:

```sh
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
  imported=0; already=0; invalid=0
  if [ -f "$rec" ]; then
    known=$(read_log | jq -r '.[].id')
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
  jq -nc --argjson i "$imported" --argjson a "$already" --argjson k "$invalid" \
    '{ok: true, imported: $i, already: $a, invalid: $k}'
}
```

Add `import) cmd_import ;;` to the dispatch. (An empty `--note` from a row with no Note cell is
already dropped by Task 2's `cmd_answered`, which writes `note` only when it is non-empty.)

- [ ] **Step 4: Run the tests**

Run: `./test.sh 2>&1 | grep -E 'FAIL|Passed'` → `Failed: 0`. `shellcheck --severity=warning plugins/learner/hooks/learner-event.sh` → no output.

- [ ] **Step 5: Commit**

```bash
git add plugins/learner/hooks/learner-event.sh test.sh
git commit -m "feat(events): import backfills events.jsonl from recap.md's Session history

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Tell the model when to emit events

**Files:**
- Modify: `plugins/learner/skills/learner/references/data.md`
- Modify: `plugins/learner/skills/learner/references/hook-quiz.md`
- Modify: `plugins/learner/skills/quiz/SKILL.md`
- Modify: `plugins/learner/skills/improve/SKILL.md`
- Modify: `plugins/learner/skills/learner/SKILL.md`
- Modify: `test.sh` (append a section)

**Interfaces:**
- Consumes: the CLI of Tasks 1–3, exactly as documented in the script header.

- [ ] **Step 1: Write the failing tests**

```bash
# --- events log: the skills call it ------------------------------------------
DATAMD="$PLUG/skills/learner/references/data.md"
HQ="$PLUG/skills/learner/references/hook-quiz.md"
grep -qF 'learner-event.sh asked' "$DATAMD" && grep -qF 'learner-event.sh answered' "$DATAMD" \
  && grep -qF 'learner-event.sh skipped' "$DATAMD" \
  && ok "data.md documents asked, answered and skipped" \
  || ko "data.md documents asked, answered and skipped"
grep -qF 'CLAUDE_PLUGIN_ROOT' "$DATAMD" \
  && ok "data.md resolves the hooks dir for plugin and personal installs" \
  || ko "data.md resolves the hooks dir for plugin and personal installs"
grep -qF 'learner-event.sh asked' "$HQ" && grep -qF -- '--anchor' "$HQ" \
  && ok "hook-quiz.md emits asked, with the fill anchor" \
  || ko "hook-quiz.md emits asked, with the fill anchor"
for s in quiz improve; do
  grep -qF 'events.jsonl' "$PLUG/skills/$s/SKILL.md" \
    && ok "the $s skill points at the events step" \
    || ko "the $s skill points at the events step"
done
grep -qF 'events import' "$PLUG/skills/learner/SKILL.md" \
  && ok "the hub dispatch table routes events import" \
  || ko "the hub dispatch table routes events import"
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | grep -E 'data.md|hook-quiz|events step|events import|Passed'` → new lines `FAIL`.

- [ ] **Step 3: `data.md` — a new section and a third step**

Append to `plugins/learner/skills/learner/references/data.md`, after `## Paths`'s list (before `## memory.md — working memory`):

````markdown
- `$CFG/learner/events.jsonl` — the event log the Learner IDE extensions read. Never read it
  to pick a question, and never write it by hand: only `learner-event.sh` does.

## `events.jsonl` — what the IDE sees

One line per question, so an IDE can show a badge for the open question, highlight a
`fill` hole and list the history. Every write goes through the shipped script:

```bash
HOOKS="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/hooks"
[ -f "$HOOKS/learner-event.sh" ] || HOOKS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks"
```

**When the question goes out** — in the same turn, right after putting it to the dev:

```bash
QID=$(sh "$HOOKS/learner-event.sh" asked --style fill --mode granular --level S \
        --domain Code --files "src/foo.ts" --anchor src/foo.ts:42 --prompt "<the question as asked>")
```

- `--style`: `code`, `architecture` or `fill` — what this question actually is, never `auto`.
- `--domain`: the domain you will file the answer under (`Code`, `Architecture`, `Tests`,
  `CI/Build`, `Data & DB`, `Integrations`).
- `--anchor FILE:LINE`: for `fill`, the first `LEARNER-TODO` line
  (`grep -n 'LEARNER-TODO' FILE | head -1`); for another style, the line the question is
  about when there is exactly one; omit it otherwise.
- `--prompt`: the question text only — never the code or a diff.

Remember `QID` until the answer. If the script prints nothing (no `jq`), carry on without it.
````

Then add a step 3 to `## After every answer`:

````markdown
3. `events.jsonl` — close the question with the same verdict and theme as the recap row:

   ```bash
   sh "$HOOKS/learner-event.sh" answered --id "$QID" --verdict ok --domain Code \
     --theme "Error and exception handling" --note "<the recap row's Note>"
   sh "$HOOKS/learner-event.sh" skipped --id "$QID"      # on `skip`
   ```

   `--verdict` is `ok` for `✅ ok` and `revisit` for `⚠️ revisit`. A question left open when
   the session ends is closed by the `SessionEnd` hook; nothing to do for it.
````

and change the first line of that section to `Update **all three**:`.

- [ ] **Step 4: `hook-quiz.md`, `quiz`, `improve`, hub**

In `hook-quiz.md`, under `## The \`fill\` protocol`, change step 4 to:

```markdown
4. Tell the dev the file and function, and ask them to write the missing code
   **directly in the file**. Then emit the event with the first hole as anchor
   (`learner-event.sh asked … --anchor FILE:LINE`, see `references/data.md` § `events.jsonl`).
```

and in `## Running the question`, change the first sentence to:

```markdown
Ask ONE question, emit `learner-event.sh asked` for it (see `references/data.md` §
`events.jsonl`), then wait for the answer.
```

In `plugins/learner/skills/quiz/SKILL.md`, replace the line
`After each answer, update \`../learner/references/data.md\`: record the outcome in \`memory.md\`
and \`recap.md\`.` with:

```markdown
Emit each question to `events.jsonl` as it goes out, and after each answer record the outcome
in `memory.md`, `recap.md` and `events.jsonl` — all three per `../learner/references/data.md`.
```

In `plugins/learner/skills/improve/SKILL.md`, in `## Coach in a loop` step 3, append: `Emit it
and close it in \`events.jsonl\` like any other question (\`../learner/references/data.md\`).`

In `plugins/learner/skills/learner/SKILL.md`, add a dispatch row after the `sync` row:

```markdown
| `events import` | Backfill the IDE event log from `recap.md`'s Session history, once | this file, § Events |
```

and append at the end of the file:

````markdown
## Events

`learner events import` — run the shipped script and report its counts in one sentence:

```bash
HOOKS="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/hooks"
[ -f "$HOOKS/learner-event.sh" ] || HOOKS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks"
sh "$HOOKS/learner-event.sh" import
```

It is safe to run twice: rows already in the log are counted as `already`, not re-added.
````

- [ ] **Step 5: Run the tests**

Run: `./test.sh 2>&1 | grep -E 'FAIL|Passed'` → `Failed: 0`. The CI's `claude plugin validate --strict` must still pass: run it locally if `claude` is on PATH (`claude plugin validate ./plugins/learner --strict`).

- [ ] **Step 6: Commit**

```bash
git add plugins/learner/skills test.sh
git commit -m "feat(events): the quiz, improve and hook protocols emit events

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Carry `events.jsonl` in `learner sync`

**Files:**
- Modify: `plugins/learner/hooks/learner-sync.sh`
- Modify: `test.sh` (append after the existing sync sections, still above `# --- summary ---`, so the fake `gh`, `$SYNC`, `$SDATA` and `$GH_REMOTE` are in place)

**Interfaces:**
- Produces: `sh learner-sync.sh merge-events <local> <remote>` → merged JSONL on stdout (union deduplicated on `(id, type)`, sorted by `ts`, torn lines dropped). Manifest gains `counts.eventLines`.

Rules: a manifest `eventLines` of `0` means the remote log is empty, whatever `events.jsonl` the gist still holds. The gist holds `events.jsonl` only when the local log is non-empty (`gh gist create` refuses empty files). A pull from a gist without `events.jsonl` treats it as empty. The pull re-reads the live local log immediately before writing, so an event appended during the fetch is not lost.

- [ ] **Step 1: Write the failing tests**

```bash
# --- learner sync: events.jsonl ----------------------------------------------
SEV="$SDATA/events.jsonl"
# Earlier sections rewrite this directory; start from a known record.
mkdir -p "$SDATA"
printf -- '- [Code][api] retries — seen: 2026-09-14\n' > "$SDATA/memory.md"
printf '## To improve\n\n### Code\n- Error and exception handling\n' > "$SDATA/recap.md"
e1='{"v":1,"type":"question.asked","id":"q_a","ts":"2026-09-20T10:00:00Z"}'
e2='{"v":1,"type":"question.answered","id":"q_a","ts":"2026-09-20T10:05:00Z"}'
e3='{"v":1,"type":"question.asked","id":"q_b","ts":"2026-09-21T09:00:00Z"}'
printf '%s\n%s\n{"torn\n' "$e1" "$e3" > "$WORK/ev.local"
printf '%s\n%s\n' "$e2" "$e1" > "$WORK/ev.remote"
got=$(sh "$SYNC" merge-events "$WORK/ev.local" "$WORK/ev.remote" | jq -rc '[.id, .type] | join(":")' | tr '\n' ' ')
[ "$got" = "q_a:question.asked q_a:question.answered q_b:question.asked " ] \
  && ok "merge-events unions on (id, type), sorts by ts and drops torn lines" \
  || ko "merge-events unions on (id, type), sorts by ts and drops torn lines (got=$got)"
[ -z "$(sh "$SYNC" merge-events "$WORK/nope.a" "$WORK/nope.b")" ] \
  && ok "merge-events of two missing files is empty" \
  || ko "merge-events of two missing files is empty"

# Push carries the log and its line count.
printf '%s\n%s\n' "$e1" "$e2" > "$SEV"
rm -rf "$GH_REMOTE" "$SDATA/sync.json" "$SDATA/sync-base"
sh "$SYNC" push --create-ok >/dev/null
{ [ "$(wc -l < "$GH_REMOTE/events.jsonl" | tr -d ' ')" = 2 ] \
  && [ "$(jq -r .counts.eventLines "$GH_REMOTE/manifest.json")" = 2 ] \
  && [ -f "$SDATA/sync-base/events.jsonl" ]; } \
  && ok "push uploads events.jsonl, counts it in the manifest and keeps it in the base" \
  || ko "push uploads events.jsonl, counts it in the manifest and keeps it in the base"
printf '%s\n' "$e3" >> "$SEV"
sh "$SYNC" push >/dev/null
[ "$(wc -l < "$GH_REMOTE/events.jsonl" | tr -d ' ')" = 3 ] \
  && ok "a later push PATCHes events.jsonl too" \
  || ko "a later push PATCHes events.jsonl too"

# Pull merges the remote log into the local one and backs the local one up first.
printf '%s\n' "$e1" > "$SEV"
out=$(sh "$SYNC" pull); rc=$?
bk=$(printf '%s' "$out" | jq -r .backup)
{ [ "$rc" = 0 ] && [ "$(wc -l < "$SEV" | tr -d ' ')" = 3 ] && [ -f "$bk/events.jsonl" ]; } \
  && ok "pull merges the remote events into the local log after backing it up" \
  || ko "pull merges the remote events into the local log after backing it up (rc=$rc out=$out)"
sh "$SYNC" pull-finish "$(printf '%s' "$out" | jq -r .work)" >/dev/null

# A gist pushed by an older Learner has no events.jsonl and no eventLines count.
rm -f "$GH_REMOTE/events.jsonl"
jq 'del(.counts.eventLines)' "$GH_REMOTE/manifest.json" > "$WORK/m.tmp" && mv "$WORK/m.tmp" "$GH_REMOTE/manifest.json"
printf '%s\n%s\n' "$e1" "$e3" > "$SEV"
out=$(sh "$SYNC" pull); rc=$?
{ [ "$rc" = 0 ] && [ "$(wc -l < "$SEV" | tr -d ' ')" = 2 ]; } \
  && ok "pull from a gist with no events.jsonl succeeds and keeps the local log" \
  || ko "pull from a gist with no events.jsonl succeeds and keeps the local log (rc=$rc out=$out)"
sh "$SYNC" pull-finish "$(printf '%s' "$out" | jq -r .work)" >/dev/null

# A truncated remote log (fewer lines than its manifest says) is refused.
printf '%s\n' "$e1" > "$GH_REMOTE/events.jsonl"
jq '.counts.eventLines = 5' "$GH_REMOTE/manifest.json" > "$WORK/m.tmp" && mv "$WORK/m.tmp" "$GH_REMOTE/manifest.json"
out=$(sh "$SYNC" pull); rc=$?
{ [ "$rc" = 1 ] && [ "$(printf '%s' "$out" | jq -r .error)" = "gh-fetch" ]; } \
  && ok "pull refuses a remote events.jsonl shorter than its manifest count" \
  || ko "pull refuses a remote events.jsonl shorter than its manifest count (rc=$rc out=$out)"
rm -f "$SEV"
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | grep -E 'events|merge-events|Passed'` → new sync lines `FAIL`.

- [ ] **Step 3: Implement in `learner-sync.sh`**

1. Header usage block — add `#   sh learner-sync.sh merge-events  <local> <remote>`.
2. After `CFG_FILE=…`: `EV_FILE="$DATA_DIR/events.jsonl"`.
3. `case "$cmd"` allow-lists (both): add `merge-events` next to `merge-history`, so it runs with no network.
4. After `bullet_lines()`, add:

```sh
event_lines() {  # FILE -> how many lines it holds (0 when missing)
  if [ -f "$1" ]; then n=$(wc -l < "$1" | tr -d ' '); printf '%s' "${n:-0}"; else printf '0'; fi
}

merge_events() {  # LOCAL REMOTE -> merged JSONL on stdout
  # Append-only on both sides, so the union is the whole truth: no base needed.
  cat "$(readable_or_empty "$1")" "$(readable_or_empty "$2")" \
    | jq -Rn '[inputs | fromjson? | select(type == "object" and has("id") and has("type"))]
              | unique_by([.id, .type]) | sort_by(.ts) | .[]' -c
}
```

5. `snapshot_into` — after the `learner.json` copy line:

```sh
  if [ -f "$EV_FILE" ]; then cp "$EV_FILE" "$_sd/events.jsonl"; else : > "$_sd/events.jsonl"; fi
```

and in its manifest `jq -nc` call add `--argjson ev "$(event_lines "$EV_FILE")"` and extend `counts` to `{memoryLines:$mem, themeLines:$theme, historyRows:$hist, eventLines:$ev}`.

6. `advance_base` loop: `for f in memory.md recap.md learner.json manifest.json events.jsonl; do`.

7. `cmd_push`, create branch — build the file list so an empty log is left out:

```sh
    set -- "$_work/memory.md" "$_work/recap.md" "$_work/learner.json" "$_work/manifest.json"
    [ -s "$_work/events.jsonl" ] && set -- "$@" "$_work/events.jsonl"
    _url=$(gh gist create --secret -d "$SYNC_DESC" "$@" 2>/dev/null | tail -1)
```

(`$1` is no longer needed at that point: `_create_ok` was read at the top of the function.)

PATCH branch — replace the payload `jq -n` call with:

```sh
    jq -n \
      --rawfile mem "$_work/memory.md" \
      --rawfile rec "$_work/recap.md" \
      --rawfile cfg "$_work/learner.json" \
      --rawfile man "$_work/manifest.json" \
      --rawfile ev "$_work/events.jsonl" \
      '{files:({"memory.md":{content:$mem},"recap.md":{content:$rec},
                "learner.json":{content:$cfg},"manifest.json":{content:$man}}
               + (if $ev == "" then {} else {"events.jsonl":{content:$ev}} end))}' \
```

(the `| gh api --method PATCH …` continuation stays as is).

8. `cmd_pull` — after the four-file fetch loop:

```sh
  # Optional: a gist pushed by an older learner has no events.jsonl.
  gist_file "$_id" events.jsonl > "$_work/events.jsonl" 2>/dev/null || : > "$_work/events.jsonl"
```

after the `_want_hist` check:

```sh
  _want_ev=$(jq -r '.counts.eventLines // empty' "$_work/manifest.json" 2>/dev/null)
  # A push with an empty local log leaves the gist's previous events.jsonl in place
  # (an empty file cannot be PATCHed in); the manifest's 0 is the truth.
  [ "$_want_ev" = 0 ] && : > "$_work/events.jsonl"
  [ -z "$_want_ev" ] || [ "$(event_lines "$_work/events.jsonl")" = "$_want_ev" ] \
    || { rm -rf "$_work"; fail gh-fetch; }
```

after the `write_atomic "$_work/memory.merged" "$MEM_FILE"` line:

```sh
  # Read the live log at the last moment: a session may have appended during the fetch.
  merge_events "$EV_FILE" "$_work/events.jsonl" > "$_work/events.merged" \
    || { rm -rf "$_work"; fail merge; }
  [ -s "$_work/events.merged" ] && write_atomic "$_work/events.merged" "$EV_FILE"
```

9. `backup_local`: `for f in "$MEM_FILE" "$REC_FILE" "$CFG_FILE" "$EV_FILE"; do`.

10. Bottom dispatch — add:

```sh
  merge-events)
    [ $# -eq 2 ] || usage
    merge_events "$1" "$2"
    exit 0
    ;;
```

- [ ] **Step 4: Run the tests**

Run: `./test.sh 2>&1 | grep -E 'FAIL|Passed'` → `Failed: 0` (the pre-existing sync tests must stay green, including `--create-ok creates the gist and uploads the four files`). `shellcheck --severity=warning plugins/learner/hooks/learner-sync.sh` → no output.

- [ ] **Step 5: Commit**

```bash
git add plugins/learner/hooks/learner-sync.sh test.sh
git commit -m "feat(sync): carry events.jsonl in the gist, merged as an append-only union

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Docs and consent

**Files:**
- Modify: `plugins/learner/skills/sync/SKILL.md`, `plugins/learner/skills/sync/references/sync.md`
- Modify: `README.md`, `docs/install.html`, `docs/safety.html`, `docs/usage.html`
- Modify: `test.sh` (extend the existing consent loop at the end of the sync docs checks)

`events.jsonl` puts two new things in the gist: absolute repo paths (`root`) and the wording of every question (`prompt`). The dev must be told before the gist is created.

- [ ] **Step 1: Write the failing tests**

Extend the existing consent `for f in …sync.md README.md safety.html usage.html` loop body with:

```bash
  grep -qF 'events.jsonl' "$f" \
    && ok "$(basename "$f")'s consent warning names events.jsonl" \
    || ko "$(basename "$f")'s consent warning names events.jsonl"
```

and add after it:

```bash
grep -qF 'events.jsonl' "$ROOT/docs/install.html" \
  && ok "docs/install.html's file table lists events.jsonl" \
  || ko "docs/install.html's file table lists events.jsonl"
grep -qF 'events.jsonl' "$PLUG/skills/sync/SKILL.md" \
  && ok "the sync skill names events.jsonl in the record" \
  || ko "the sync skill names events.jsonl in the record"
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `./test.sh 2>&1 | grep -E 'events.jsonl|Passed'` → the new lines `FAIL`.

- [ ] **Step 3: Edit the docs**

- `sync/references/sync.md`, the consent blockquote — replace its last sentence with: `…plus \`pushedFrom\` (this machine's hostname), \`learner.json\`'s \`disabledPaths\` (absolute local paths) and \`events.jsonl\` (the text of every question you were asked and each repo's absolute path). Create it?`
- `sync/SKILL.md` — in the `description` and the first paragraph, `memory.md, recap.md and the global learner.json` → `memory.md, recap.md, events.jsonl and the global learner.json`.
- `README.md`, `docs/safety.html`, `docs/usage.html` — wherever the consent warning lists `pushedFrom` and `disabledPaths`, add `events.jsonl` with the same parenthesis as above (find the spot with `grep -n pushedFrom <file>`).
- `docs/install.html` — after the `recap.md` row (line ~242), add:

```html
      <tr><td><code>$CFG/learner/events.jsonl</code></td><td>Append-only event log (one line per question asked, answered, skipped or abandoned) read by the Learner IDE extensions; written only by <code>learner-event.sh</code>, never holds code. Created on the first question</td></tr>
```

- [ ] **Step 4: Run the full suite and linters**

Run: `./test.sh 2>&1 | tail -3` → `Failed: 0`.
Run: `shellcheck --severity=warning plugins/learner/hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh` → no output.

- [ ] **Step 5: Commit**

```bash
git add README.md docs plugins/learner/skills/sync test.sh
git commit -m "docs(events): the file table and the sync consent name events.jsonl

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Not in this plan

- Version bump and release (`VERSION`, `plugin.json`, Formula): a maintainer step once the branch merges.
- The `learner-ide` repo's `contract/` vendoring, and both extensions: plans 2 and 3.
