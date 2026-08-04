# Notion Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `learner export` — push the learning recap into a Notion database, one row per
competency theme, with a derived five-value learning level.

**Architecture:** No new executable. The whole feature is instructions the model follows: a new
`skills/learner/references/export.md` protocol file, one Dispatch row in `SKILL.md` that routes to
it, and one new `Theme` column in the `Session history` table of `references/data.md` that makes
the level derivable. Delivery is through the Notion MCP connector only. The single piece of
persistent state is `$CFG/learner/export.json`, holding the remembered database id.

**Tech Stack:** POSIX sh, `jq`, `git`, Markdown skill files, hand-written HTML for the docs site.
Tests are `./test.sh` — a plain shell assertion suite, no framework, that never reaches the
network.

**Spec:** [`../specs/2026-08-04-notion-export-design.md`](../specs/2026-08-04-notion-export-design.md)

## Global Constraints

- `skills/learner/SKILL.md` must stay **≤ 120 lines** — it is always loaded (`test.sh:673`). All
  protocol detail belongs in `references/export.md`.
- Grep patterns use **bracket expressions or `-F`**, never a backslash before an ordinary
  character. An undefined ERE escape has already produced a bug here that passed under ugrep and
  failed under GNU grep.
- No skill file may mention a removed config key — `recapEvery`, `trouBlanks`, `trackGlobs`,
  `"language"` (`test.sh:678`) — nor the old data paths `learner-memory.md` / `learner-recap.md`
  (`test.sh:682`).
- **No new `learner.json` keys.** The database id is state, in `export.json`, not configuration.
- The only files this skill writes inside a repo remain `.claude/learner.local.json` and its
  `.gitignore` line. `export.json` lives under `$CLAUDE_CONFIG_DIR`.
- Shipped files are in English. The Notion schema is fixed English because the upsert matches on
  it; every line printed to the dev mirrors the dev's language.
- `install.sh` needs no change — it copies `skills/learner/references/*.md` as a glob.
- `README.md` needs no change — it stopped enumerating subcommands when the site took that over.
- Baseline before starting: `./test.sh` prints `Passed: 289   Failed: 0` in about 7 seconds.

---

## File Structure

| File | Responsibility |
|---|---|
| `skills/learner/references/export.md` | **new** — the entire export protocol: connector check, target resolution, schema, row building, level derivation, upsert, report |
| `skills/learner/references/data.md` | the `Theme` column and its write/read rule; unchanged otherwise |
| `skills/learner/SKILL.md` | one Dispatch row; the Notion tools in `allowed-tools` |
| `docs/usage.html` | one `<dt>`/`<dd>` pair under `On demand` |
| `test.sh` | the assertions that pin all of the above |

---

### Task 1: The `Theme` column

Makes the learning level derivable. Everything else depends on this column existing, so it lands
first and alone.

**Files:**
- Modify: `test.sh` — insert after the `data.md resolves the config dir` assertion (currently
  `test.sh:703-705`)
- Modify: `skills/learner/references/data.md:52-72`

**Interfaces:**
- Produces: the `Session history` table shape
  `| Date | Repo | Domain | Style | Verdict | Note | Theme |`, and the rule that a row ending at
  `Note` is untagged. Task 2 reads both.

- [ ] **Step 1: Write the failing assertion**

In `test.sh`, immediately after the block ending
`|| ko "data.md resolves the config dir from CLAUDE_CONFIG_DIR"`, insert:

```sh
# The Learning level in the Notion export is computed per theme from these rows, so a row
# that does not name its theme is uncountable. `Theme` going last is the decision, not an
# accident: an old six-cell row then reads unambiguously as untagged, where an inserted
# column would make cell 4 mean `Style` on old rows and `Theme` on new ones — and the
# reader here is a model, not a parser holding a schema.
grep -qF '| Date | Repo | Domain | Style | Verdict | Note | Theme |' "$REFS/data.md" \
  && ok "data.md's Session history table ends with the Theme column" \
  || ko "data.md's Session history table ends with the Theme column"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^  (FAIL|Passed)|^Passed'`

Expected: exactly one failure —
`FAIL - data.md's Session history table ends with the Theme column`, and the summary line
`Passed: 289   Failed: 1`.

- [ ] **Step 3: Add the column to `data.md`**

Replace the whole `### \`Session history\`` block (currently `data.md:52-61`):

```markdown
### `Session history`

Table:

```
| Date | Repo | Domain | Style | Verdict | Note | Theme |
```

Verdicts: `✅ ok`, `⚠️ revisit`, `⏭️ skip`. This is the only place per-question detail
lives in `recap.md`.

`Theme` is the exact theme text the point was filed under in `To improve` or `Mastered` —
the same choice step 2 of § After every answer already makes, written down so it can be
counted later. Always fill it. A row that ends at `Note`, with no `Theme` cell, was
written before the column existed: read it as untagged and leave it alone.
```

- [ ] **Step 4: Make the writer fill it**

In the same file, replace step 2 of `## After every answer`:

```markdown
2. `recap.md` — append a `Session history` row, naming the theme in its `Theme` cell, and
   attach the point to that broad theme under `To improve` or `Mastered` (create the
   theme only if it does not already exist).
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`

Expected: `Passed: 290   Failed: 0`.

- [ ] **Step 6: Commit**

```bash
git add test.sh skills/learner/references/data.md
git commit -m "$(cat <<'EOF'
feat(data): record the theme on every Session history row

The Notion export derives a per-theme learning level from these rows,
which is impossible while a row only names its domain.

The column goes last so existing six-cell rows stay positionally
unambiguous and need no migration: a row ending at Note reads as
untagged rather than as a row whose fourth cell changed meaning.
EOF
)"
```

---

### Task 2: The export protocol

The whole feature, as one reference file. Not yet reachable — `SKILL.md` routes to it in Task 3 —
which is deliberate: the protocol is worth its own review gate before the subcommand goes live.

**Files:**
- Create: `skills/learner/references/export.md`
- Modify: `test.sh:668` (the reference-file loop) and the skill-content block after it

**Interfaces:**
- Consumes: the `Theme` column and the untagged-row rule from Task 1.
- Produces: the path `references/export.md`, which Task 3's Dispatch row targets; the seven
  property names `Subject`, `Domain`, `Learning level`, `Passes`, `To revisit`, `Last reviewed`,
  `Repos`; the five level values `Discovered`, `Shaky`, `Progressing`, `Solid`, `Mastered`.

- [ ] **Step 1: Write the failing assertions**

In `test.sh`, extend the existing reference-file loop at line 668:

```sh
for f in hook-quiz.md quiz.md improve.md data.md export.md; do
```

Then, after the `data.md`'s Session history assertion added in Task 1, insert:

```sh
# The five-value scale is the export's whole contribution beyond a copy of recap.md, and
# rule 1 is what keeps recap.md authoritative over the tally. A value renamed or a rule
# dropped in a later edit would silently regrade every row, with no other symptom.
for v in Discovered Shaky Progressing Solid Mastered; do
  grep -qF "\`$v\`" "$REFS/export.md" \
    && ok "export.md documents the '$v' learning level" \
    || ko "export.md documents the '$v' learning level"
done

# Bracket expressions, not `\|`: the rule rows are the only lines in the file that open
# with a pipe, a single digit and a pipe.
nrules=$(awk '/^[|] [1-6] [|]/{c++} END{print c+0}' "$REFS/export.md")
[ "$nrules" -eq 6 ] \
  && ok "export.md keeps all six level-derivation rules" \
  || ko "export.md keeps all six level-derivation rules (got $nrules)"

grep -qF 'CLAUDE_CONFIG_DIR' "$REFS/export.md" \
  && grep -qF 'export.json' "$REFS/export.md" \
  && ok "export.md resolves export.json under CLAUDE_CONFIG_DIR" \
  || ko "export.md resolves export.json under CLAUDE_CONFIG_DIR"

# Locked decision 2: no connector, no export. A file-shaped consolation prize would
# reopen the export surface this design defers, so the two words are banned outright —
# the protocol cannot drift into offering one without turning this red.
grep -qiE 'csv|markdown' "$REFS/export.md" \
  && ko "export.md offers no file-format fallback" \
  || ok "export.md offers no file-format fallback"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^  FAIL'; ./test.sh 2>&1 | tail -2`

Expected: eight failures — `references/export.md exists`, five `learning level` ones,
`keeps all six level-derivation rules (got 0)`, `resolves export.json under CLAUDE_CONFIG_DIR`.
The file-format assertion passes vacuously on a missing file, which is fine: Step 3 is what puts
it under real load. Summary: `Passed: 291   Failed: 8` — nine new assertions, one of them green.

- [ ] **Step 3: Write `skills/learner/references/export.md`**

````markdown
# Export mode

`learner export [notion-page-url]` — push the recap into a Notion database, one row per
competency theme. Read-only over the learning record: this mode never quizzes, never edits
config, and never rewrites `memory.md` or `recap.md`.

Mirror the dev's language in everything you print, as everywhere else in this skill. The
schema below is fixed English on purpose — it is the key the upsert matches on, and it
cannot depend on the language one dev happens to work in.

## 1. Check the connector

This mode needs the Notion MCP tools. If none are reachable, say so in one line — enable
the Notion connector in the claude.ai connector settings, then re-run `learner export` —
and stop. Write nothing, locally or remotely. There is no offline substitute: a
half-finished export the dev then has to finish by hand is worse than a clear no.

## 2. Resolve the target database

```bash
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cat "$CFG/learner/export.json" 2>/dev/null
```

| State | What to do |
|-------|------------|
| A `notion.databaseId` is recorded | Upsert into it (§6). |
| No `export.json`, a page URL in `$ARGUMENTS` | Create the database in that page (§3), then write `export.json`. |
| No `export.json`, no URL | Stop, and ask for one page URL: `learner export <notion-page-url>`. Never guess a parent page, never search for one. |
| A database is recorded and `$ARGUMENTS` names a different page | Ask before repointing. On yes, create a new database there and overwrite `export.json`; the old database is left untouched. |

`export.json`:

```json
{
  "notion": {
    "databaseId": "…",
    "url": "…",
    "lastExport": "YYYY-MM-DD"
  }
}
```

`lastExport` comes from `date +%F`. After writing, confirm with
`jq -e . "$CFG/learner/export.json" >/dev/null && echo OK`. This file is per-dev state and
is never written inside a repo.

## 3. The database

Title: `Learner — Subjects`. Properties, created once:

| Property | Type | Values |
|----------|------|--------|
| `Subject` | Title | — |
| `Domain` | Select | `Code`, `Architecture`, `Tests`, `CI/Build`, `Data & DB`, `Integrations` |
| `Learning level` | Select | `Discovered`, `Shaky`, `Progressing`, `Solid`, `Mastered` |
| `Passes` | Number | — |
| `To revisit` | Number | — |
| `Last reviewed` | Date | — |
| `Repos` | Multi-select | — |

## 4. Build one row per theme

Read `references/data.md` for the paths, then read `recap.md`.

- One row per entry under `To improve` and under `Mastered`. `Subject` is the entry text
  verbatim; `Domain` is the sub-heading it sits under. Never build a row from a `memory.md`
  line — those are deleted the moment the dev masters them, so they have no stable
  identity to match on and would leave orphans behind.
- `Passes`, `To revisit`, `Last reviewed` and `Repos` come from the `Session history` rows
  whose `Theme` cell names this theme. A row with no `Theme` cell predates the column:
  leave it out of every count.
- `To revisit` counts the `⚠️ revisit` and `⏭️ skip` verdicts together. A skip is a miss —
  passing on a question is not evidence of knowing the answer, and counting it as neutral
  would let a dev grade themself upward by skipping.
- `Repos` is the set of `Repo` values on those rows, plus the repo tag of any `memory.md`
  line you attach in the page body.
- Page body: the still-open `memory.md` concepts belonging to this theme, as bullets. A
  line carries `[Domain][repo]` and never a theme, so let the domain narrow the candidates
  and judge which theme the concept rolls up under — the same judgement `data.md`
  § After every answer already makes when it files a point. Collect any line you cannot
  place and report it in §6 rather than dropping it in silence.

## 5. Derive `Learning level`

Per theme, over its tagged `Session history` rows: `n` rows in total, `ok` = how many
`✅ ok`, `bad` = how many `⚠️ revisit` plus `⏭️ skip`. First matching rule wins.

| # | Condition | Level |
|---|-----------|-------|
| 1 | the theme sits under `Mastered` | `Mastered` |
| 2 | `n = 0` | `Discovered` |
| 3 | `ok = 0` | `Shaky` |
| 4 | `ok < bad` | `Shaky` |
| 5 | `bad = 0` and `ok ≥ 2` | `Solid` |
| 6 | otherwise | `Progressing` |

Rule 1 makes `recap.md` authoritative over the arithmetic: the dev's own judgement that a
theme is done outranks a stale tally. Rule 2 is also the honest answer for a theme whose
whole history predates the `Theme` column — nothing is known about how those passes went.

## 6. Upsert, then report

Match an existing page on its exact `Subject` title: found → update it, absent → create it.

Write **only** the seven properties of §3 and the page body. Any other column the dev added
by hand — a priority, a link to a course, a next-review date — must survive untouched, so
never enumerate the schema in order to prune it. A theme that has vanished from `recap.md`
keeps its page: a rename is indistinguishable from a deletion here, and losing the dev's
own annotations to that guess is not worth it.

Close with a short summary in the dev's language: the database link, how many pages were
created and how many updated, and anything you could not place. A silent success hides
exactly the cases worth knowing about.
````

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`

Expected: `Passed: 299   Failed: 0`.

If `export.md offers no file-format fallback` is red, the protocol text has picked up one of the
two banned words — remove it rather than loosen the pattern; the ban is the decision.

- [ ] **Step 5: Commit**

```bash
git add test.sh skills/learner/references/export.md
git commit -m "$(cat <<'EOF'
feat(skill): add the Notion export protocol

One row per broad recap theme rather than per memory.md concept: a
concept line is deleted at mastery, so it has no stable identity to
upsert against and would leave orphan rows behind.

The upsert writes only the seven properties it owns, so a column the
dev adds by hand survives a refresh, and it never archives a row for a
vanished theme — a rename is indistinguishable from a deletion here.

Not reachable yet; SKILL.md routes to it in the next commit.
EOF
)"
```

---

### Task 3: Wire the subcommand

`test.sh:1214` derives the subcommand list from `SKILL.md`'s own Dispatch table and requires each
one to be documented on `usage.html`. So the Dispatch row and the docs entry are one task: adding
the row alone turns the suite red, which is exactly what that check is for.

**Files:**
- Modify: `skills/learner/SKILL.md:3` (`allowed-tools`) and `:18-27` (the Dispatch table)
- Modify: `docs/usage.html:56-75` (the `<dl>` under `On demand`)

**Interfaces:**
- Consumes: `references/export.md` from Task 2.
- Produces: the subcommand token `export`, which `test.sh`'s `SUBCOMMANDS` extraction picks up.

- [ ] **Step 1: Add the Dispatch row and watch the docs check fail**

In `skills/learner/SKILL.md`, insert after the `improve` row:

```markdown
| `export [notion-page-url]` | Push the recap into a Notion database | `references/export.md` |
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^  FAIL'; ./test.sh 2>&1 | tail -2`

Expected: one failure — `FAIL - usage.html documents the 'learner export' subcommand` — and
`Passed: 299   Failed: 1`. Seeing this failure is the point of the step: it proves the extraction
picked `export` out of the new row rather than silently skipping it. The extraction has been
checked against this exact row: it yields eight subcommands — `config export help improve off on
quiz status` — where it yielded seven before.

- [ ] **Step 3: Document it on the site**

In `docs/usage.html`, insert after the `learner improve [topic]` `<dd>`:

```html
    <dt><code>learner export [notion-page-url]</code></dt>
    <dd>Pushes the recap into a Notion database — one row per competency theme, with a
    learning level derived from your session history. Needs the Notion connector; the
    parent page URL is asked for once, on the first export, and remembered after that.</dd>
```

- [ ] **Step 4: Grant the Notion tools**

In `skills/learner/SKILL.md`, replace the `allowed-tools` line:

```yaml
allowed-tools: Read, Write, Edit, Grep, Bash, mcp__claude_ai_Notion, mcp__notionApi, mcp__notion
```

Three prefixes because the MCP server name depends on how the dev connected Notion:
`mcp__claude_ai_Notion__…` for the claude.ai connector, `mcp__notionApi__…` and `mcp__notion__…`
for the common self-configured servers. Unmatched entries are inert. Task 4 confirms this against
a live connector — it is the one part of the design that paper cannot settle.

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`

Expected: `Passed: 300   Failed: 0`.

- [ ] **Step 6: Check `SKILL.md` is still within budget**

Run: `wc -l < skills/learner/SKILL.md`

Expected: 89. The cap is 120 and the suite already enforces it; this is here so a future edit that
moves protocol text into `SKILL.md` gets caught by a human, not only by a red test.

- [ ] **Step 7: Commit**

```bash
git add skills/learner/SKILL.md docs/usage.html
git commit -m "$(cat <<'EOF'
feat(skill): route learner export to the protocol file

The Dispatch table is what test.sh derives the documented-subcommand
list from, so the site entry lands in the same commit — adding the row
alone is a red suite by design.

allowed-tools lists three MCP prefixes because the Notion server name
depends on how the dev connected it; unmatched entries are inert.
EOF
)"
```

---

### Task 4: Live smoke test

`test.sh` never reaches the network, so nothing above proves the export works — only that the
contract is written down. This task is the missing half, and it needs a real Notion page. It
cannot be delegated to a subagent with no connector.

**Files:**
- Modify (only if Step 2 fails): `skills/learner/SKILL.md:3`

**Interfaces:**
- Consumes: everything from Tasks 1-3.

- [ ] **Step 1: Create a scratch parent page in Notion**

Any private page. Copy its URL.

- [ ] **Step 2: First export**

Run in a Claude Code session with the Notion connector enabled:

```
learner export <the-page-url>
```

Expected: a `Learner — Subjects` database inside that page, with the seven properties of §3, one
row per entry under `To improve` and `Mastered` in your `recap.md`, and a summary naming how many
rows were created.

Against the current `recap.md` that is four rows: three under `Architecture` / `CI/Build` /
`Code` from `To improve`, and none from `Mastered`, which is empty. Every one of them should read
`Discovered`, because no `Session history` row carries a `Theme` cell yet — Task 1 only started
requiring it. That is rule 2 doing its job, not a bug.

**If the Notion tools are unreachable despite the connector being on**, the `allowed-tools`
prefixes are wrong. Ask the session which `mcp__…` Notion tools it can see, then either add that
exact prefix to the list, or list the full tool names if prefix-level entries turn out not to
match. Do not widen the grant beyond Notion.

- [ ] **Step 3: Verify the state file**

Run: `jq . "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner/export.json"`

Expected: a `notion` object with a `databaseId`, the page `url`, and today's date in `lastExport`.

- [ ] **Step 4: Verify the upsert contract**

In Notion, add a `Priority` select column by hand and set it on one row. Answer one quiz question
so a `Session history` row lands with a `Theme` cell. Then run:

```
learner export
```

Expected: no URL needed; the touched theme's `Passes` becomes 1 and its `Learning level` moves off
`Discovered` per §5; **the `Priority` value is still there.** That last part is the contract — if
it is gone, §6's "write only the seven properties" was not followed.

- [ ] **Step 5: Verify the refusal**

Disable the Notion connector, then run `learner export`. Expected: one line asking you to enable
the connector, and no local write — `lastExport` in `export.json` is unchanged.

- [ ] **Step 6: Commit only if Step 2 forced a change**

```bash
git add skills/learner/SKILL.md
git commit -m "fix(skill): correct the Notion MCP prefix in allowed-tools"
```

If Step 2 worked as written, there is nothing to commit — record the result and stop.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Locked decisions 1, 2 (Notion only, no fallback) | 2 — the banned-words assertion pins it |
| Locked decision 3 (row per theme) | 2 §4 |
| Locked decision 4 (upsert, URL once) | 2 §2, §6 |
| Locked decision 5 (derived level) | 2 §5 |
| Locked decision 6 (`Theme` last, no migration) | 1 |
| Locked decision 7 (write only the seven properties) | 2 §6; verified live in 4 Step 4 |
| Locked decision 8 (no write to `memory.md` / `recap.md`) | 2 preamble |
| Locked decision 9 (English schema) | 2 preamble and §3 |
| §1 command surface, run summary | 2 §2, §6; 3 Step 1 |
| §2 database, `memory.md`→theme attachment | 2 §3, §4 |
| §3 level derivation | 2 §5 |
| §4 data-model change | 1 |
| §5 export state | 2 §2; verified live in 4 Step 3 |
| §6 missing connector, `allowed-tools` risk | 2 §1; 3 Step 4; resolved in 4 Step 2 |
| §7 files touched | File Structure above |
| §8 tests, all seven | 1 Step 1; 2 Step 1; 3 Step 2 (assertion 2 is pre-existing); 3 Step 6 (assertion 3 is pre-existing) |

**Placeholder scan:** the `…` inside the `export.json` example is illustrative JSON, matching the
spec, not a gap. Task 4 Step 2's contingency names concrete actions rather than "handle the
error". No TBD, no "similar to Task N".

**Type consistency:** the seven property names and five level values are spelled identically in
Task 2's `Interfaces`, its Step 1 assertions and its Step 3 file. `Theme` is capitalised the same
way in Task 1's table, Task 1's assertion and Task 2 §4. The subcommand token is `export`
everywhere.

**Test-count chain**, verified rather than estimated: 289 baseline → 290 after Task 1 (+1) → 299
after Task 2 (+9: one reference-file iteration, five level values, the rule count, the
`export.json` path, the banned words) → 300 after Task 3 (+1, the derived `usage.html` check).
`SKILL.md` goes 88 → 89 lines against a cap of 120.
