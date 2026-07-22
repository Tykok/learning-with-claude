---
description: Learning mode for this project. Invoke as "learner" with a subcommand — "config" (view/edit settings in .claude/learner.local.json), "quiz" (on-demand Q&A about the current branch), "status" (concise bullet summary of what to improve + level), or "improve" (coach the dev to master one weak spot, drawing on past quiz sessions + the real code). Trigger on "learner", "learner config", "learner quiz", "learner status", "learner improve", "mode apprentissage", "change mon niveau", "configurer le quiz", "règle les questions", "quiz", "quiz me on the branch", "interroge-moi", "session de questions", "quiz sur la branche", "ce que je dois améliorer", "mon niveau", "monter en compétence", "m'améliorer sur".
allowed-tools: Read Write Edit Grep Bash
---

# Learner

Usage: `learner <subcommand> [args]`. The subcommand is the first token of `$ARGUMENTS`:

| Subcommand | What it does |
|------------|--------------|
| `config` (or empty) | View/edit the learning-mode settings in `.claude/learner.local.json` → **Config mode**. |
| `quiz` | Run an on-demand Q&A session about the **current branch's** changes → **Quiz mode**. |
| `status` | Print a concise bullet summary of what to improve + the dev's level → **Status mode**. |
| `improve [topic]` | Coach the dev to master one weak spot, using past sessions + the real code → **Improve mode**. |
| `help` | Print the usage summary (subcommands + parameter table) and stop → **Help mode**. |

Dispatch rules for `$ARGUMENTS`:
- First token `help` (or `-h` / `--help`) → **Help mode**: print the Help output below and do nothing
  else (no config read/write, no quiz).
- First token `status` → **Status mode**: print the improvement summary and stop (read-only; no quiz,
  no config write, no file update).
- First token `improve` (or `learn`) → **Improve mode**. Remaining tokens = the weak spot/topic to work
  on (optional; if omitted, pick from the open weak spots or ask which one).
- First token `quiz` → **Quiz mode**. Remaining tokens are optional: a base ref and/or a count
  (e.g. `quiz`, `quiz 5`, `quiz origin/develop`, `quiz develop 4`).
- First token `config` → **Config mode**. Remaining tokens may be `key=value` pairs applied directly
  (e.g. `config level=senior`, `config disable`); with no pairs, show the menu.
- No subcommand but a bare config instruction (`level=senior`, `disable`, …) → treat as **Config mode**
  shorthand.
- Empty `$ARGUMENTS` → **Config mode** (menu).

## Help mode

Print a concise usage summary — the subcommand table above plus the Config-mode **Parameters** table
(keys, values, defaults) and the one-line meaning of each `questionStyles` value (`code` / `archi` /
`trou`). Ask the question in the configured `language` if a config file exists, else default to `fr`.
Do not read/write config or start a quiz.

The settings drive both the SessionStart / PostToolUse / Stop hooks (`.claude/hooks/learner-*.sh`,
which quiz on the code edited during a session) and the on-demand Quiz mode here.

## Status mode

Triggered when `$ARGUMENTS` begins with `status`. Print a **concise** message telling the developer
what to improve and at what level. **Read-only**: do not run a quiz, do not edit config, do not modify
the memory/recap files.

1. Read the level:
   ```bash
   test -f .claude/learner.local.json && jq -r '.level // "non configuré"' .claude/learner.local.json || echo "non configuré"
   ```
2. Read the open weak spots — prefer `.claude/learner-recap.md` (its `À améliorer` sections); if absent,
   fall back to `.claude/learner-memory.md`. If neither exists / nothing is recorded, say so.
   ```bash
   cat .claude/learner-recap.md 2>/dev/null || cat .claude/learner-memory.md 2>/dev/null || echo "NO_DATA"
   ```
3. Print, in the configured `language` (default `fr`):
   - one line with the **level** (`Niveau : <level>`);
   - a short **bulleted list** of what to improve, grouped by domain, keeping only non-empty domains
     (skip anything already under `Acquis`); a handful of bullets max — summarise, don't dump the file;
   - if nothing is recorded yet, a one-line note that no weak spot has been captured (do a `quiz` to start).

Keep it to a compact, skimmable message — no tables, no history dump.

## Improve mode

Triggered when `$ARGUMENTS` begins with `improve` (or `learn`). Coach the developer to actually
**master one weak spot**, using the record of past quiz sessions plus the real code — then mark it
resolved once they demonstrate it. This is the "level-up" counterpart to `quiz`.

1. Load config (`level`, `language`, `questionStyles`, `trouBlanks`).
2. Read `.claude/learner-memory.md` (open weak spots) and `.claude/learner-recap.md`
   (`À améliorer` + `Historique des sessions`).
3. **Pick the target weak spot:** the topic in `$ARGUMENTS` if given (fuzzy-match a bullet); else pick
   the most relevant open one (recurring or oldest) or ask the dev which. Confirm which one you'll work on.
4. **Use the history:** look at the `Historique des sessions` rows for that topic (verdicts/notes) to see
   *how* they struggled, and read the real source files the concept lives in — ground everything in this
   repo's actual code, never abstractly.
5. **Coach**, at the configured level/language, in a short loop:
   - a concise explanation of the concept and the *why* (grounded in the real code);
   - a concrete worked example pulled from the actual codebase;
   - an **active-recall practice step** — a targeted question or an interactive `trou` exercise (honour
     `questionStyles`/`trouBlanks`); wait for the dev, then give brief feedback.
   Repeat until the dev demonstrates understanding (or says `stop`).
6. **On mastery:** update `.claude/learner-memory.md` (remove the weak spot) and `.claude/learner-recap.md`
   (move it to `Acquis` and append a `Historique des sessions` row, today's date, style `improve`). If not
   yet mastered, leave it open and note in the recap what still needs work.

---

# Config mode

Edit the learning-mode settings stored (gitignored, per-developer) in
`.claude/learner.local.json`.

## Parameters

| Key            | Values                                   | Default  | Effect |
|----------------|------------------------------------------|----------|--------|
| `level`        | `junior` \| `intermediaire` \| `senior`  | —        | **Required.** Difficulty of the questions. |
| `enabled`      | `true` \| `false`                        | `true`   | Master switch. `false` = no quiz, level kept. |
| `recapEvery`   | integer ≥ 1                              | `3`      | A session-wide **synthesis** question every N quiz. |
| `questionStyles` | `"auto"` or array of `code`/`trou`/`archi` | `"auto"` | Allowed formats. `auto` = Claude varies. |
| `language`     | `fr` \| `en`                             | `fr`     | Language the question is asked in. |
| `trouBlanks`   | integer ≥ 1                              | `2`      | Number of `// TODO` holes left for the dev in an interactive `trou` (fill-in) exercise. |
| `trackGlobs`   | array of shell globs                     | common source globs | Which edited files the hooks record as quiz material (outside build/vendor dirs). |

**About the `trou` (fill-in) format:** it is **interactive and happens in the real source file**, not
in chat. Claude picks a short function that was just written/edited, removes `trouBlanks` key part(s)
of its body (replacing them with `// TODO: <hint>` comments), and the developer writes the missing
code **directly in the file**. Claude then reviews, **restores a correct version and checks it is valid
(focused compile/lint/test for the language)** — never leaving the source broken or with leftover
`// TODO`.

**Two learning files (both gitignored, per-dev; create them if missing):**

1. **`.claude/learner-memory.md` — working memory (machine).** The list of open weak spots, one per
   line (`- [Domaine] concept — vu: date`). The hooks and Quiz mode **read** it to prefer a still-open
   weak spot (spaced repetition) and **update** it (add when missed, remove when mastered). This is the
   ONLY file that drives question selection.
2. **`.claude/learner-recap.md` — readable dashboard (dev-facing).** Sections `À améliorer` per domain
   (`Code`, `Architecture`, `Tests`, `CI/Build`, `Données & DB`, `Intégrations`), `Acquis`, and
   `Historique des sessions` (`Date | Domaine | Style | Verdict | Note`). Claude **only writes/updates**
   it — it is **never read to pick a question**. It exists so the developer can see their progress.

After each answer, update **both**: the weak spot in `learner-memory.md`, and `learner-recap.md`
(append a history row + reflect the point under `À améliorer`/`Acquis`).

## Step 1 — Read current config

```bash
test -f .claude/learner.local.json && cat .claude/learner.local.json || echo "NOT_CONFIGURED"
```

Show the user the current values (or state that learning mode is not configured yet).

## Step 2 — Ask what to change

Strip a leading `config` token first. If the remaining `$ARGUMENTS` already says what to change
(e.g. `level=senior`, `disable`), skip to step 3.
Otherwise ask the user (prefer the multiple-choice question tool) which parameter(s) to set,
using the table above. Only `level` is mandatory; keep existing values for anything untouched.

## Step 3 — Validate

- `level` ∈ {junior, intermediaire, senior}.
- `enabled` is a boolean.
- `recapEvery` is an integer ≥ 1.
- `questionStyles` is `"auto"` or an array whose items ⊆ {code, trou, archi}.
- `language` ∈ {fr, en}.
- `trouBlanks` is an integer ≥ 1.
- `trackGlobs` is an array of non-empty strings (shell globs).

Reject invalid values and re-ask rather than writing them.

## Step 4 — Write the file

Merge the new values over the existing ones (do not drop keys the user did not change) and
write valid JSON to `.claude/learner.local.json`. Example:

```json
{ "level": "senior", "enabled": true, "recapEvery": 2, "questionStyles": ["code", "archi"], "language": "fr" }
```

Verify it parses:

```bash
jq -e . .claude/learner.local.json >/dev/null && echo "OK" || echo "INVALID JSON"
```

## Step 5 — Confirm

Summarise the effective settings in one or two lines. Remind the user the file is gitignored
(personal) and that changes take effect on the next quiz (no restart needed — the hook scripts
re-read the file every time).

---

# Quiz mode

Triggered when `$ARGUMENTS` begins with `quiz`. Runs an interactive quiz session about the
**current branch's** changes (the whole branch diff, not just this session's edits). This is the
on-demand counterpart to the Stop-hook quiz.

## Q1 — Load the learner settings

```bash
test -f .claude/learner.local.json && cat .claude/learner.local.json || echo "NOT_CONFIGURED"
```

- `level` → difficulty (default `intermediaire` if not configured).
- `language` → ask in `fr` (default) or `en`.
- `questionStyles` → `auto` (vary) or a subset of `code` / `archi` / `trou` (same meanings as the
  hook: `code` = what a specific changed function does; `archi` = which module / directory / layer it
  lives in and why; `trou` = **interactive fill-in exercise in the real source file** — see below).
- `trouBlanks` → number of `// TODO` holes for a `trou` exercise (default `2`).
- `enabled=false` does **not** block an explicit quiz request — the user asked for it directly.

For a **`trou`** question: pick a short function from the branch diff, edit its real source file to
replace `trouBlanks` key part(s) of the body with `// TODO: <hint>` comments (keep the signature and
surrounding code), tell the dev which file/function and ask them to write the missing code **directly
in the file**, then wait. Keep the correct version in mind (it is in git / the branch diff). After they
answer, review, then **restore a correct version and verify it is valid (focused compile/lint/test)** —
never end the turn with the source broken or with leftover `// TODO`. Since this edits real source,
prefer it only when the user is set up to edit locally; otherwise fall back to `code`/`archi`.

## Q2 — Compute the branch diff

Pick the base ref from `$ARGUMENTS` if given, else the repo's main integration branch
(`develop`, else `main`, else `master`).

```bash
BASE=$(git merge-base origin/develop HEAD 2>/dev/null \
  || git merge-base develop HEAD 2>/dev/null \
  || git merge-base origin/main HEAD 2>/dev/null \
  || git merge-base main HEAD 2>/dev/null \
  || git merge-base master HEAD)
git diff --stat "$BASE"..HEAD
git diff "$BASE"..HEAD
```

Read the changed files / diff so every question is grounded in the branch's real code — never quiz
on code you have not read. Ignore pure-docs/test-scaffolding churn unless it is the point of the branch.

## Q3 — Run the session

- Ask **one question at a time**, in the configured language, at the configured level, using the
  allowed `questionStyles` (vary when `auto`). Prefer plain chat questions (like the hooks); use the
  multiple-choice tool only when options genuinely help.
- **Wait for the user's answer** before the next question. Never answer for them.
- After each answer, give **brief** feedback (correct / à corriger + the missing bit) before moving on.
- **Read `.claude/learner-memory.md`** first (the working memory — create if missing): prefer a
  still-open weak spot when relevant (spaced repetition). Never read `learner-recap.md` to pick a
  question. **After each answer**, update `learner-memory.md` (add/remove the weak spot) AND write to
  `learner-recap.md` (append a `Historique des sessions` row with today's date + reflect the point under
  `À améliorer`/`Acquis`).
- **Spread coverage** across the branch's distinct areas (data model, persistence, core logic, error
  handling, external integrations, config/build) — don't re-ask about the same file.
- Default to **~5 questions**, then a final **synthesis** question ("réexplique en 2-3 phrases…").
  Honour a count in `$ARGUMENTS` (e.g. `quiz 3`). Stop early if the user says `skip` repeatedly or
  `stop`.

## Q4 — Wrap up

Close with a one-line recap of what looked solid and any concept worth revisiting.
