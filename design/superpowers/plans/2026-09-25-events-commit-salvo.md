# Events: commit/dirty and the salvo on the log — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `question.asked` carries `commit` and `dirty`. The agent salvo emits and closes events like the hook quiz. learner-ide vendors the new schema.

**Architecture:** `learner-event.sh asked` derives `commit` and `dirty` itself, with read-only, hardened git calls: `rev-parse` plus `hash-object --no-filters`, and never `git status`. The schema gains two optional, co-dependent fields. `agent-salvo.md` points at `data.md` for the event commands. Tasks 1 and 2 go in Learner PR `feat/events-commit-salvo`. Task 3 is a learner-ide PR, done after that one merges.

**Tech Stack:** POSIX sh (`dash`-clean), jq, git ≥ 2.24, `test.sh` (bash), JSON Schema 2020-12 (ajv-cli via `LEARNER_SCHEMA_CHECK=1`). learner-ide: vitest and JUnit, both of which already load `contract/fixtures/`.

**Spec:** `design/superpowers/specs/2026-09-25-events-commit-salvo-design.md`

## Global Constraints

- The model passes nothing new: `commit` and `dirty` are computed inside `learner-event.sh`.
- No `git status`. `dirty` compares the `<commit>:<file>` blob with `git hash-object --no-filters --stdin < "$root/<file>"`.
- Every git child runs with `GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL= GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0` and `-c protocol.allow=never`, and puts `--end-of-options` before a revision. `hash-object` never gets `-w`.
- In doubt, `dirty` is `true`.
- A git failure never breaks `asked`: it still writes its event, prints its id and exits 0.
- `commit` matches `^[0-9a-f]{40}([0-9a-f]{24})?$`. `commit` and `dirty` are both present, or both absent.
- The schema stays `v: 1`, and the change is additive only.
- `agent-salvo.md` never restates the `HOOKS=` block: it points to `references/data.md` § `events.jsonl`.
- A salvo question with no file emits no event.
- Run the suite as `bash test.sh </dev/null`. Without the `</dev/null`, a pre-existing bug in the zsh recipe test near `test.sh:5686` hangs it; that bug is out of scope.
- `shellcheck --severity=warning plugins/learner/hooks/learner-event.sh test.sh` stays clean. CI runs it.
- Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- No UI automation (`osascript`, `runIde`, opening an IDE window). `./gradlew test` and `npm test` are fine.

## Review Focus

1. **A `--files` value holding a glob character** (`"src/*.ts"`) must not be expanded by the shell. It is looked up literally and, since no such file exists, reads `dirty: true`. Pinned in Task 1 (the `*.txt` case).
2. **A symlinked file** is never compared through its target. It reads `dirty: true`. Pinned in Task 1.
3. **A repo whose `.git/config` configures `core.fsmonitor` and a clean filter** must run neither of them. A control assertion proves that the trap fires under `git status`. Pinned in Task 1.
4. **A git that fails mid-way** (the `rev-parse --verify` fails) still yields a written event with an id, no `commit`, and exit 0. Pinned in Task 1.
5. **Staged-but-uncommitted** reads dirty, because the comparison is against the commit and not the index. Pinned in Task 1.

---

### Task 1: `commit` and `dirty` on `question.asked`

**Files:**
- Modify: `plugins/learner/hooks/learner-event.sh`: add the helpers `safe_git`, `head_commit` and `files_dirty` above `cmd_asked`; change `cmd_asked` (currently lines ~69–120) and the header comment (lines 1–25).
- Modify: `contract/events.schema.json`
- Modify: `plugins/learner/skills/learner/references/data.md`, § `events.jsonl`, in the bullet list after the `asked` example (around line 38).
- Test: `test.sh`. Add a new block just before the line `# --- events log: import from recap.md ---`, and one line in the schema block (`# --- events log: every event type against the schema`).

**Interfaces:**
- Consumes: `root` (set in `cmd_asked` by `learner_repo_root`, empty outside git) and `files` (the raw `--files` string, space-separated).
- Produces: `question.asked` lines with `"commit": "<hex>"` and `"dirty": true|false`, or neither. Task 3 vendors the schema.

- [ ] **Step 1: Write the failing tests**

Insert this block in `test.sh`, immediately before `# --- events log: import from recap.md ----`:

```bash
# --- events log: commit and dirty on asked -----------------------------------
# The panel opens a file "as it was" only when commit is set and dirty is false,
# so dirty errs to true: a false positive hides an action, a false negative lies.
EVR="$WORK/tmp/evrev"
evr() { CLAUDE_CODE_SESSION_ID=sess-R CLAUDE_PROJECT_DIR="$EVR" sh "$EV" "$@"; }
evlast() { tail -n1 "$EVLOG" | jq -c "$1"; }
dirty_for() {
  evr asked --style code --mode granular --level J --domain Code --files "$1" --prompt p >/dev/null
  evlast .dirty
}
rm -rf "$EVR" "$WORK/tmp/evnogit"; mkdir -p "$EVR" "$WORK/tmp/evnogit"
( CLAUDE_CODE_SESSION_ID=sess-R CLAUDE_PROJECT_DIR="$WORK/tmp/evnogit" \
    sh "$EV" asked --style code --mode granular --level J --domain Code --files a.txt --prompt p >/dev/null )
[ "$(evlast '[has("commit"), has("dirty")]')" = '[false,false]' ] \
  && ok "outside git asked writes neither commit nor dirty" \
  || ko "outside git asked writes neither commit nor dirty ($(tail -n1 "$EVLOG"))"
git -C "$EVR" init -q
printf 'one\n' > "$EVR/a.txt"
evr asked --style code --mode granular --level J --domain Code --files a.txt --prompt p >/dev/null
[ "$(evlast '[has("commit"), has("dirty")]')" = '[false,false]' ] \
  && ok "on an unborn branch asked writes neither commit nor dirty" \
  || ko "on an unborn branch asked writes neither commit nor dirty ($(tail -n1 "$EVLOG"))"
printf 'two\n' > "$EVR/b.txt"
git -C "$EVR" add -A
git -C "$EVR" -c user.email=t@t -c user.name=t commit -qm init
evhead=$(git -C "$EVR" rev-parse HEAD)
evr asked --style code --mode granular --level J --domain Code --files "a.txt b.txt" --prompt p >/dev/null
[ "$(evlast '[.commit, .dirty]')" = "[\"$evhead\",false]" ] \
  && ok "clean tracked files: commit is HEAD and dirty is false" \
  || ko "clean tracked files: commit is HEAD and dirty is false ($(tail -n1 "$EVLOG"))"
printf 'changed\n' > "$EVR/a.txt"
[ "$(dirty_for a.txt)" = true ] && ok "a modified file reads dirty" || ko "a modified file reads dirty"
[ "$(dirty_for "a.txt b.txt")" = true ] \
  && ok "one dirty file among several makes the question dirty" \
  || ko "one dirty file among several makes the question dirty"
git -C "$EVR" add a.txt
[ "$(dirty_for a.txt)" = true ] \
  && ok "a staged-but-uncommitted change reads dirty" \
  || ko "a staged-but-uncommitted change reads dirty"
git -C "$EVR" reset -q; git -C "$EVR" checkout -q -- a.txt
printf 'new\n' > "$EVR/c.txt"
[ "$(dirty_for c.txt)" = true ] && ok "an untracked file reads dirty" || ko "an untracked file reads dirty"
rm -f "$EVR/c.txt" "$EVR/b.txt"
[ "$(dirty_for b.txt)" = true ] && ok "a deleted file reads dirty" || ko "a deleted file reads dirty"
git -C "$EVR" checkout -q -- b.txt
{ [ "$(dirty_for ../a.txt)" = true ] && [ "$(dirty_for "$EVR/a.txt")" = true ]; } \
  && ok "a path with .. or an absolute path reads dirty, never read outside root" \
  || ko "a path with .. or an absolute path reads dirty, never read outside root"
[ "$(dirty_for '*.txt')" = true ] \
  && ok "a glob in --files is taken literally, not expanded" \
  || ko "a glob in --files is taken literally, not expanded"
ln -s a.txt "$EVR/link.txt"
git -C "$EVR" add link.txt; git -C "$EVR" -c user.email=t@t -c user.name=t commit -qm link
[ "$(dirty_for link.txt)" = true ] && ok "a symlink reads dirty" || ko "a symlink reads dirty"
[ "$(dirty_for a.txt)" = false ] \
  && ok "back to a clean checkout, dirty is false again" \
  || ko "back to a clean checkout, dirty is false again ($(tail -n1 "$EVLOG"))"

# A repo can name programs git runs on read paths: core.fsmonitor on status, a
# clean filter on a stat-dirty file. asked must run neither; the control proves
# the trap is armed.
EVT="$WORK/tmp/evtrap"; EVMARK="$WORK/tmp/evtrap.ran"
rm -rf "$EVT" "$EVMARK"; mkdir -p "$EVT"; git -C "$EVT" init -q
printf 'x\n' > "$EVT/f.txt"
git -C "$EVT" add -A; git -C "$EVT" -c user.email=t@t -c user.name=t commit -qm init
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$EVMARK" > "$WORK/tmp/evtrap.sh"; chmod +x "$WORK/tmp/evtrap.sh"
git -C "$EVT" config core.fsmonitor "$WORK/tmp/evtrap.sh"
git -C "$EVT" config filter.x.clean "$WORK/tmp/evtrap.sh"
printf '* filter=x\n' > "$EVT/.gitattributes"
touch -t 203001010000 "$EVT/f.txt"
CLAUDE_CODE_SESSION_ID=sess-R CLAUDE_PROJECT_DIR="$EVT" \
  sh "$EV" asked --style code --mode granular --level J --domain Code --files f.txt --prompt p >/dev/null
[ ! -e "$EVMARK" ] \
  && ok "asked runs neither the repo's fsmonitor nor its clean filter" \
  || ko "asked runs neither the repo's fsmonitor nor its clean filter"
git -C "$EVT" status --porcelain >/dev/null 2>&1
[ -e "$EVMARK" ] \
  && ok "(control) git status in that repo does run them" \
  || ko "(control) git status in that repo does run them"

# A git that fails mid-way leaves the question intact, just without commit.
REALGIT=$(command -v git)
mkdir -p "$WORK/tmp/gitstub"
cat > "$WORK/tmp/gitstub/git" <<STUB
#!/bin/sh
for a; do [ "\$a" = --verify ] && exit 1; done
exec "$REALGIT" "\$@"
STUB
chmod +x "$WORK/tmp/gitstub/git"
n=$(evn)
out=$(PATH="$WORK/tmp/gitstub:$PATH" evr asked --style code --mode granular --level J --domain Code \
        --files a.txt --prompt p); rc=$?
{ [ "$rc" = 0 ] && [ -n "$out" ] && [ "$(evn)" = $((n + 1)) ] \
  && [ "$(evlast '[.id, has("commit"), has("dirty")]')" = "[\"$out\",false,false]" ]; } \
  && ok "a failing git still writes the event and prints its id, without commit" \
  || ko "a failing git still writes the event and prints its id, without commit (rc=$rc out=$out)"
grep -qF '`commit` and `dirty`' "$PLUG/skills/learner/references/data.md" \
  && ok "data.md says commit and dirty are the script's, not the model's" \
  || ko "data.md says commit and dirty are the script's, not the model's"
```

In the schema block, add a line after `ev abandoned --session sess-A`, so the ajv check sees an asked event carrying both fields:

```bash
evr asked --style code --mode granular --level J --domain Code --files a.txt --prompt p >/dev/null
```

Then, right after the `kinds` assertion (`… || ko "the schema fixture holds every event type the script writes (kinds=$kinds)"`), add:

```bash
jq -Re 'fromjson? | select(.type == "question.asked" and has("commit") and has("dirty"))' "$EVLOG" >/dev/null \
  && ok "the schema fixture holds an asked event with commit and dirty" \
  || ko "the schema fixture holds an asked event with commit and dirty"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test.sh </dev/null 2>&1 | grep -E 'FAIL|^Passed'`
Expected: FAIL on "clean tracked files: commit is HEAD…", on every "reads dirty" case, on "back to a clean checkout", on "data.md says…" and on "the schema fixture holds an asked event with commit and dirty". The outside-git, unborn, trap, control and failing-git cases already pass. That is expected: they pin behaviour that must not change once git gets called.

- [ ] **Step 3: Implement in `learner-event.sh`**

Add this above `cmd_asked() {`:

```sh
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
```

`hash-object` bypasses `safe_git` only because `safe_git` feeds `</dev/null`, while `hash-object` needs the file on stdin. The env and `-c` flags are the same.

In `cmd_asked`, after `root=$(learner_repo_root)`, add:

```sh
  commit=''; dirty=''
  if [ -n "$root" ]; then
    commit=$(head_commit)
    [ -z "$commit" ] || dirty=$(files_dirty "$commit")
  fi
```

In the same function's `jq -nc` call, add `--arg commit "$commit" --arg dirty "$dirty"` to the arguments. After the anchor `+ (if $afile == "" …)` clause, add:

```jq
    + (if $commit == "" then {} else {commit: $commit, dirty: ($dirty != "false")} end)
```

(`!= "false"`: an empty `dirty`, which only happens if `files_dirty` itself died, reads `true`.)

In the header comment, after the `asked` usage lines, add:

```sh
#   asked adds commit (HEAD's full hash) and dirty (any of --files differs from
#   that commit) when the project is a git repo with a commit; neither otherwise.
```

- [ ] **Step 4: Schema**

In `contract/events.schema.json`, add these to `properties` after `"note"`:

```json
    "note": { "type": "string" },
    "commit": {
      "type": "string", "pattern": "^[0-9a-f]{40}([0-9a-f]{24})?$",
      "description": "question.asked only: the full hash HEAD pointed at when the question was asked. Absent outside git and on an unborn branch, and then dirty is absent too."
    },
    "dirty": {
      "type": "boolean",
      "description": "question.asked only: true when any of files differs from its blob at commit, is untracked, missing, a symlink, or could not be checked. Fail-closed: true hides the IDE's revision actions."
    }
```

Then, at top level after `"allOf": […],`:

```json
  "dependentRequired": { "commit": ["dirty"], "dirty": ["commit"] },
```

- [ ] **Step 5: data.md**

In `plugins/learner/skills/learner/references/data.md` § `events.jsonl`, add this after the `--prompt` bullet of the *When the question goes out* list:

```markdown
- `commit` and `dirty` are added by the script from the repo itself: never pass them.
```

- [ ] **Step 6: Run everything**

Run: `bash test.sh </dev/null 2>&1 | grep -E 'FAIL|^Passed'`
Expected: `Passed: N   Failed: 0`

Run: `LEARNER_SCHEMA_CHECK=1 bash test.sh </dev/null 2>&1 | grep -E 'validate against|FAIL'`
Expected: `ok   - all N events (every type) validate against contract/events.schema.json`

Run: `shellcheck --severity=warning plugins/learner/hooks/learner-event.sh test.sh && echo OK`
Expected: `OK`

Run this under dash, in a clean temp repo:

```bash
T=$(mktemp -d); git -C "$T" init -q; echo a > "$T/a"; git -C "$T" add a; git -C "$T" -c user.email=t@t -c user.name=t commit -qm i
CLAUDE_CONFIG_DIR="$T/cfg" CLAUDE_PROJECT_DIR="$T" dash plugins/learner/hooks/learner-event.sh asked --style code --mode granular --level J --domain Code --files a --prompt p
tail -n1 "$T/cfg/learner/events.jsonl" | jq -c '[.commit|length, .dirty]'; rm -rf "$T"
```

Expected: `[40,false]`

- [ ] **Step 7: Commit**

```bash
git add plugins/learner/hooks/learner-event.sh contract/events.schema.json plugins/learner/skills/learner/references/data.md test.sh
git commit -m "feat(events): commit and dirty on question.asked

The IDE panel opens a file as it was only when the question records the
commit it was asked at and that its files matched it. The script derives
both itself, comparing blobs with hash-object --no-filters rather than
running git status, so no repo-configured program runs. In doubt, dirty
is true, which only hides the revision actions.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: the salvo emits and closes events

**Files:**
- Modify: `plugins/learner/skills/learner/references/agent-salvo.md`: § *Order of operations* steps 3 and 5, and § *When it reports*.
- Test: `test.sh`: add after the existing `SALVO_REF` text checks (search `SALVO_REF="$PLUG/skills/learner/references/agent-salvo.md"`, and add at the end of that group of `grep … "$SALVO_REF"` checks).

**Interfaces:**
- Consumes: `learner-event.sh asked`/`answered`/`skipped` as documented in `references/data.md` § `events.jsonl`. It does not depend on Task 1.
- Produces: documentation only.

- [ ] **Step 1: Write the failing tests**

```bash
# The salvo is a quiz channel like any other: its questions reach the IDE.
{ grep -qF 'learner-event.sh asked' "$SALVO_REF" \
  && grep -qF -- '--style fill --anchor' "$SALVO_REF" \
  && grep -qF '§ `events.jsonl`' "$SALVO_REF" \
  && grep -qF 'the id its `asked` printed' "$SALVO_REF"; } \
  && ok "agent-salvo.md emits asked per question and for the exercise, and closes by id" \
  || ko "agent-salvo.md emits asked per question and for the exercise, and closes by id"
grep -qF 'emits no event' "$SALVO_REF" \
  && ok "agent-salvo.md never invents --files for a question about no file" \
  || ko "agent-salvo.md never invents --files for a question about no file"
grep -qF 'HOOKS=' "$SALVO_REF" \
  && ko "agent-salvo.md points to data.md instead of restating the HOOKS block" \
  || ok "agent-salvo.md points to data.md instead of restating the HOOKS block"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash test.sh </dev/null 2>&1 | grep -E 'agent-salvo.md (emits|never invents)'`
Expected: both `FAIL`. The HOOKS check already passes.

- [ ] **Step 3: Edit `agent-salvo.md`**

Replace step 3 of § *Order of operations*:

```markdown
3. **Ask `questions` questions, one at a time.** Wait for each answer and give brief feedback
   before the next. Never two at once, never a question with sub-questions.
```

with:

```markdown
3. **Ask `questions` questions, one at a time.** Wait for each answer and give brief feedback
   before the next. Never two at once, never a question with sub-questions. Each question
   emits `learner-event.sh asked` in the turn it goes out, per `references/data.md`
   § `events.jsonl`, *When the question goes out*: its real `--style` (`code` or
   `architecture`), `--mode granular`, and as `--files` the files it is about — the trigger's
   `files:` for a question on the diff, the files the delegated task targets for one on the
   task, the `memory.md` entry's file for a weak spot. A question about no file emits no
   event: never invent a `--files` value.
```

Replace step 5:

```markdown
5. **Record** every answer in `memory.md` and `recap.md` per `references/data.md` § *After every
   answer*, with `salvo` in the `Style` column.
```

with:

```markdown
5. **Record** every answer in `memory.md`, `recap.md` and `events.jsonl` per
   `references/data.md` § *After every answer*, with `salvo` in the recap's `Style` column,
   closing each question with the id its `asked` printed.
```

In § *When it reports*, after the first sentence ("Tell the dev the file and the function, ask them to write the missing code **in the file**, and wait."), add:

```markdown
As you hand it over, emit `learner-event.sh asked --style fill --anchor FILE:LINE`, the line
being the first `LEARNER-TODO`, as `references/data.md` says. The holes are already cut, so the
event reads `dirty: true` and the IDE opens the current file — the one with the holes, which
is the one the dev works in.
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash test.sh </dev/null 2>&1 | grep -E 'FAIL|^Passed'`
Expected: `Passed: N   Failed: 0`

- [ ] **Step 5: Commit**

```bash
git add plugins/learner/skills/learner/references/agent-salvo.md test.sh
git commit -m "feat(salvo): emit and close events like the hook quiz

Salvo questions never reached events.jsonl, so they were invisible in the
IDEs and their answers had no id to close. Each question and the fill
exercise now emit asked, per data.md; a question about no file emits
nothing rather than invent one.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3 (learner-ide, after the Learner PR merges): vendor the schema

Repo: `/Users/elietreport/Projet/Perso/learner-ide`. Branch `chore/contract-commit-dirty` from `feat/vscode-dev-launch` (PR #4), with its PR based on it.

**Files:**
- Modify: `contract/events.schema.json`: a byte copy of Learner `main`'s file.
- Modify: `contract/CONTRACT_VERSION`: `learning-with-claude <merged short sha> (PR #<n>)`.
- Create: `contract/fixtures/revision.jsonl` and `contract/fixtures/revision.state.json`.
- Modify: `vscode/test/unit/enrich.test.ts` and `jetbrains/src/test/kotlin/io/github/tykok/learner/core/EnrichTest.kt`.
- Modify: `design/superpowers/specs/2026-09-24-panel-design.md` § 5, the first bullet.

**Interfaces:**
- Consumes: Task 1's schema (`commit`, `dirty`, `dependentRequired`).
- Produces: a fixture both IDEs load; `enrichHistory` passes `commit`/`dirty` through, as before.

- [ ] **Step 1: The fixture**

`contract/fixtures/revision.jsonl`, exact bytes: LF endings and a final newline.

```
{"v":1,"type":"question.asked","id":"q_20260925T100000Z_00000001","ts":"2026-09-25T10:00:00Z","session":"s1","repo":"api","root":"/work/api","style":"code","mode":"granular","level":"S","domain":"Code","files":["src/a.ts"],"prompt":"Why retry here?","commit":"0123456789abcdef0123456789abcdef01234567","dirty":false}
{"v":1,"type":"question.answered","id":"q_20260925T100000Z_00000001","ts":"2026-09-25T10:05:00Z","verdict":"ok","domain":"Code","theme":null}
{"v":1,"type":"question.asked","id":"q_20260925T110000Z_00000002","ts":"2026-09-25T11:00:00Z","session":"s1","repo":"api","root":"/work/api","style":"fill","mode":"granular","level":"S","domain":"Code","files":["src/b.ts"],"anchor":{"file":"src/b.ts","line":3},"prompt":"Fill in the guard.","commit":"0123456789abcdef0123456789abcdef01234567","dirty":true}
{"v":1,"type":"question.answered","id":"q_20260925T110000Z_00000002","ts":"2026-09-25T11:05:00Z","verdict":"revisit","domain":"Code","theme":null}
```

For `revision.state.json`, write the expected state by hand from `contract/README.md`, the way the existing fixtures are written. `reduce` ignores `commit` and `dirty`, so neither appears in it. Check it with `cd vscode && npx vitest run test/unit/model.test.ts`: `model.test.ts` loads every fixture pair.

- [ ] **Step 2: Failing enrich tests**

In `vscode/test/unit/enrich.test.ts`:

```ts
  it('revision: commit and dirty pass through from the asked event', () => {
    const { events, state } = load('revision');
    const byId = new Map(enrichHistory(state, events).history.map((h) => [h.id, h]));
    expect(byId.get('q_20260925T100000Z_00000001')).toMatchObject({ commit: '0123456789abcdef0123456789abcdef01234567', dirty: false });
    expect(byId.get('q_20260925T110000Z_00000002')).toMatchObject({ commit: '0123456789abcdef0123456789abcdef01234567', dirty: true });
  });
```

In `EnrichTest.kt`:

```kotlin
    @Test fun `revision - commit and dirty pass through from the asked event`() {
        val (events, state) = load("revision")
        val byId = enrichHistory(state, events).history.associateBy { it.id }
        val sha = "0123456789abcdef0123456789abcdef01234567"
        assertEquals(listOf(sha, false), byId.getValue("q_20260925T100000Z_00000001").let { listOf(it.commit, it.dirty) })
        assertEquals(listOf(sha, true), byId.getValue("q_20260925T110000Z_00000002").let { listOf(it.commit, it.dirty) })
    }
```

Run: `cd vscode && npx vitest run test/unit/enrich.test.ts`, then `cd jetbrains && ./gradlew test --tests '*EnrichTest*'`.
Expected: they fail only because `revision.jsonl` is missing, if Step 1 has not been done yet. With the fixture in place they should pass, since `enrichHistory` already passes both fields through. If they pass straight away, that is the expected result: they pin the contract. Record in the report that they passed with the fixture and failed without it.

- [ ] **Step 3: Vendor the schema and document it**

```bash
cp ../claude-learner-mode/contract/events.schema.json contract/events.schema.json   # from Learner main, after the merge
printf 'learning-with-claude %s (PR #%s)\n' "<short sha>" "<n>" > contract/CONTRACT_VERSION
```

In panel spec § 5, first bullet, replace `` and `dirty` (`true` when `git status --porcelain -- <files>` reports any of the question's files) `` with:

```markdown
and `dirty` (`true` when any of the question's files differs from its blob at `commit`, is untracked, missing, a symlink, or could not be checked — blob against blob with `hash-object --no-filters`, never `git status`, so the producer runs no program the repo configures)
```

- [ ] **Step 4: Run everything**

Run: `sh contract/validate.sh`. Expected: `validated N fixture lines`, with N 4 above the count before.
Run: `cd vscode && npm test`. Expected: all pass.
Run: `cd jetbrains && ./gradlew test`. Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add contract design vscode/test jetbrains/src/test
git commit -m "chore(contract): vendor commit and dirty on question.asked

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
