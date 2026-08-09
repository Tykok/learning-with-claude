# Claude Code plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship learner as a real, installable Claude Code plugin (`claude plugin install
learner`), the most native install path available since every learner user is already a
Claude Code user.

**Architecture:** Add a `.claude-plugin/plugin.json` manifest and a self-hosted
`.claude-plugin/marketplace.json` (one entry, `source: "./"`) at the repo root, plus a new
`hooks/hooks.json` that wires four of the six existing hook scripts via
`${CLAUDE_PLUGIN_ROOT}`. The hook scripts and skill files themselves are untouched — confirmed
by reading their actual content that they already resolve everything (their shared helper,
user config, user data) relative to their own location or `$CLAUDE_CONFIG_DIR`, never to a
hardcoded traditional-install path.

**Tech Stack:** JSON manifests, the existing POSIX `sh` hooks, the `claude` CLI's own
`plugin validate`/`plugin marketplace add`/`plugin install`/`plugin details` subcommands for
real (not just read) verification.

## Global Constraints

- Spec: `design/superpowers/specs/2026-08-09-claude-code-plugin-design.md` — every task implements one of its numbered sections.
- Self-hosted marketplace, same repo (`Tykok/learning-with-claude`), `source: "./"` — no second repo.
- Reuse `hooks/*.sh` and `skills/learner/` verbatim — no changes to either directory in this plan except the two files named in Task 2.
- The plugin wires exactly 4 of the 5 currently-wired hooks: `learner-onboard.sh`, `learner-record-edit.sh`, `learner-quiz.sh`, `learner-cleanup.sh`. `learner-update-check.sh` is deliberately never referenced by `hooks/hooks.json`.
- `learner update` and `learner status` detect a plugin install by checking whether this skill's own base directory (visible in context when the skill loads) contains `/plugins/`, and defer to `/plugin update learner` / Claude Code's own version display instead of reading `$CFG/skills/learner/VERSION` or curl-bootstrapping a second install.
- Doc order: **Claude Code plugin** (first) → apt → Homebrew → clone-and-run → curl one-liner (alternative, last).
- `plugin.json`'s `version` field is kept in sync with the repo-root `VERSION` file; a CI guard enforces this on every push, the same shape as the existing tag-vs-`VERSION` guard.
- Submitting to the community marketplace is out of scope for this plan — a web form, not a task.

---

### Task 1: Plugin manifest, marketplace, and hook wiring

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `hooks/hooks.json`
- Modify: `test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks — this is the first task.
- Produces: the three new files, whose exact paths and `name`/`version` fields Task 4's CI
  guard reads (`.claude-plugin/plugin.json`'s `.version`), and whose existence Task 5's real
  verification depends on.

- [ ] **Step 1: Write the failing tests**

Add a new section to `test.sh`, after the existing licence-scan block (search for
`# --- summary` to find the very end, and insert just before it):

```bash
# --- Claude Code plugin ------------------------------------------------------
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$ROOT/.claude-plugin/marketplace.json"
PLUGIN_HOOKS="$ROOT/hooks/hooks.json"

[ -f "$PLUGIN_JSON" ] && ok ".claude-plugin/plugin.json exists" || ko ".claude-plugin/plugin.json exists"
[ -f "$MARKETPLACE_JSON" ] && ok ".claude-plugin/marketplace.json exists" || ko ".claude-plugin/marketplace.json exists"
[ -f "$PLUGIN_HOOKS" ] && ok "hooks/hooks.json exists" || ko "hooks/hooks.json exists"

jq -e . "$PLUGIN_JSON" >/dev/null 2>&1 \
  && ok "plugin.json is valid JSON" \
  || ko "plugin.json is valid JSON"

jq -e . "$MARKETPLACE_JSON" >/dev/null 2>&1 \
  && ok "marketplace.json is valid JSON" \
  || ko "marketplace.json is valid JSON"

jq -e . "$PLUGIN_HOOKS" >/dev/null 2>&1 \
  && ok "hooks/hooks.json is valid JSON" \
  || ko "hooks/hooks.json is valid JSON"

[ "$(jq -r '.name' "$PLUGIN_JSON")" = "learner" ] \
  && ok "plugin.json names the plugin learner" \
  || ko "plugin.json names the plugin learner"

[ "$(jq -r '.plugins[0].name' "$MARKETPLACE_JSON")" = "learner" ] \
  && [ "$(jq -r '.plugins[0].source' "$MARKETPLACE_JSON")" = "./" ] \
  && ok "marketplace.json lists learner with source ./" \
  || ko "marketplace.json lists learner with source ./"

for h in SessionStart PostToolUse Stop SessionEnd; do
  jq -e --arg h "$h" '.hooks[$h]' "$PLUGIN_HOOKS" >/dev/null 2>&1 \
    && ok "hooks/hooks.json wires $h" \
    || ko "hooks/hooks.json wires $h"
done

for script in learner-onboard.sh learner-record-edit.sh learner-quiz.sh learner-cleanup.sh; do
  grep -qF "$script" "$PLUGIN_HOOKS" \
    && ok "hooks/hooks.json references $script" \
    || ko "hooks/hooks.json references $script"
done

grep -qF 'CLAUDE_PLUGIN_ROOT' "$PLUGIN_HOOKS" \
  && ok "hooks/hooks.json commands use \${CLAUDE_PLUGIN_ROOT}" \
  || ko "hooks/hooks.json commands use \${CLAUDE_PLUGIN_ROOT}"

grep -qF 'learner-update-check.sh' "$PLUGIN_HOOKS" \
  && ko "hooks/hooks.json does not wire learner-update-check.sh" \
  || ok "hooks/hooks.json does not wire learner-update-check.sh"

[ "$(jq -r '.version' "$PLUGIN_JSON")" = "$(cat "$ROOT/VERSION")" ] \
  && ok "plugin.json's version matches the VERSION file" \
  || ko "plugin.json's version matches the VERSION file"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -iE 'plugin|marketplace|FAIL'`
Expected: every new assertion fails (none of the three files exist yet).

- [ ] **Step 3: Create `.claude-plugin/plugin.json`**

```bash
mkdir -p .claude-plugin
```

```json
{
  "name": "learner",
  "description": "Turns Claude Code into a learning loop: quizzes you on your own diffs, tracks weak spots per developer.",
  "version": "0.2.0",
  "author": {
    "name": "Tykok",
    "url": "https://github.com/Tykok"
  },
  "homepage": "https://tykok.github.io/learning-with-claude/",
  "repository": "https://github.com/Tykok/learning-with-claude",
  "license": "GPL-3.0-or-later"
}
```

- [ ] **Step 4: Create `.claude-plugin/marketplace.json`**

```json
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "learning-with-claude",
  "description": "Claude Learner — quizzes you on your own diffs, at your level.",
  "owner": {
    "name": "Tykok",
    "url": "https://github.com/Tykok"
  },
  "plugins": [
    {
      "name": "learner",
      "description": "Turns Claude Code into a learning loop: quizzes you on your own diffs, tracks weak spots per developer.",
      "source": "./",
      "category": "productivity",
      "homepage": "https://tykok.github.io/learning-with-claude/"
    }
  ]
}
```

- [ ] **Step 5: Create `hooks/hooks.json`**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/learner-onboard.sh\"", "timeout": 10 }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/learner-record-edit.sh\"", "timeout": 10 }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/learner-quiz.sh\"", "timeout": 10, "statusMessage": "Learner: checking understanding..." }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/learner-cleanup.sh\"", "timeout": 10 }
        ]
      }
    ]
  }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -20`
Expected: `Failed: 0`.

- [ ] **Step 7: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json test.sh
git commit -m "feat(plugin): add the Claude Code plugin manifest and hook wiring"
```

---

### Task 2: `learner update` and `learner status` become plugin-aware

**Files:**
- Modify: `skills/learner/references/update.md` (full replacement, below)
- Modify: `skills/learner/SKILL.md`
- Modify: `test.sh`

**Interfaces:**
- Consumes: nothing from Task 1 directly (this task's check is structural — the skill's own
  load path — not a file Task 1 created).
- Produces: nothing later tasks consume.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, in the "skill content" section (near the other `references/*.md` content
checks), add:

```bash
UPD="$ROOT/skills/learner/references/update.md"

grep -qF '/plugins/' "$UPD" \
  && ok "update.md detects a plugin install by its own load path" \
  || ko "update.md detects a plugin install by its own load path"

grep -qF '/plugin update learner' "$UPD" \
  && ok "update.md points a plugin install at /plugin update" \
  || ko "update.md points a plugin install at /plugin update"
```

Near the existing SKILL.md content assertions, add:

```bash
grep -qF '/plugin' "$SK" \
  && ok "SKILL.md's Status section is plugin-aware" \
  || ko "SKILL.md's Status section is plugin-aware"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -iE 'plugin install|plugin-aware|FAIL'`
Expected: all three new assertions fail.

- [ ] **Step 3: Replace `skills/learner/references/update.md` in full**

```markdown
# Update mode

`learner update` — check the remote version, and if it is newer, re-run the installer pinned
to it. Read-only until step 2 decides an update is actually needed: nothing is written,
locally or remotely, when the dev is already current.

## 1. Check whether this is a Claude Code plugin install

Before anything else — including the network fetch in step 2 — check whether this skill was
loaded as a Claude Code plugin rather than a traditional install. The base directory this
`SKILL.md` was read from is already visible in your own context (it was named when the skill
loaded); if that path contains `/plugins/`, this is a plugin install.

If so, stop here — report and go no further:

```
Installed as a Claude Code plugin. Run `/plugin update learner` (or
`claude plugin update learner`) instead — Claude Code manages this install's version, not
this file.
```

A plugin install never runs `install.sh`, so `$CFG/skills/learner/VERSION` and
`$CFG/skills/learner/INSTALL_ORIGIN` (steps 2 and 3 below) never exist for it — proceeding
past this check would either misreport "no version installed" or, worse, curl-bootstrap a
second, traditional install directly on top of a plugin install that already works.

## 2. Read, validate and compare

```bash
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOCAL=$(cat "$CFG/skills/learner/VERSION" 2>/dev/null)
REMOTE=$(curl -fsSL --max-time 5 "${LEARNER_VERSION_URL:-https://raw.githubusercontent.com/Tykok/learning-with-claude/main/VERSION}")
. "$CFG/hooks/learner-config.sh"
learner_version_valid "$REMOTE" || { echo "remote VERSION is malformed: '$REMOTE'"; exit 1; }
if [ -n "$LOCAL" ] && ! learner_version_gt "$REMOTE" "$LOCAL"; then
  echo "already on the latest version (v$LOCAL)"
  exit 0
fi
```

Compare with the same helpers `hooks/learner-update-check.sh` uses, sourced from the install
rather than re-implemented: `learner_version_gt` compares the `X.Y.Z` components as integers,
so "0.9.0" vs "0.10.0" comes out right where reading the two strings as text would not. An
empty `$LOCAL` means this install predates versioning — treat it as older than anything, which
is exactly what the `[ -n "$LOCAL" ]` guard does: it skips the comparison and falls straight
through to step 4. Validate before comparing, and before anything else touches `$REMOTE`: step
4 builds a URL out of it, and a malformed value must never reach that unchecked. A `curl`
failure on the fetch above is not silence, unlike the background check — the dev asked for
this directly, so report it in one line and stop rather than falling through with an empty
`$REMOTE` that `learner_version_valid` would then (correctly) reject anyway.

## 3. Check the install origin

```bash
ORIGIN=$(cat "$CFG/skills/learner/INSTALL_ORIGIN" 2>/dev/null); ORIGIN="${ORIGIN:-curl}"
```

An install from before this file existed has no marker at all — treat a missing file the same
as `curl`, since curl or a bare clone is exactly what every install predating it used.

- **`curl`** → continue to step 4, unchanged.
- **`brew`** → print, and stop. Nothing is written — `brew` owns the payload on disk, not this
  protocol:
  ```
  Installed via Homebrew. Run: brew upgrade learner && learner-install
  ```
- **`apt`** → print, and stop, naming the exact asset so the dev isn't left guessing at a
  filename:
  ```
  Installed via apt. Download learner_$REMOTE_all.deb from
  https://github.com/Tykok/learning-with-claude/releases/tag/v$REMOTE, then:
    sudo apt install ./learner_$REMOTE_all.deb && learner-install
  ```

Both guidance branches point at `learner-install` rather than re-deriving `install.sh`'s own
flags here — a third copy of "here's how to pass --level" would drift from the other two the
same way two implementations of the installer itself would.

## 4. Re-run the installer, pinned (origin: curl only)

```bash
if ! curl -fsSL "https://raw.githubusercontent.com/Tykok/learning-with-claude/v$REMOTE/bootstrap.sh" -o /tmp/learner-bootstrap.sh 2>/dev/null; then
  echo "no released tag v$REMOTE yet (VERSION on main is ahead of the tags) — try again later"
  exit 1
fi
LEARNER_REF="v$REMOTE" sh /tmp/learner-bootstrap.sh
rm -f /tmp/learner-bootstrap.sh
```

Fetched to a file and run as two separate steps, not a streamed `curl | sh` pipe: in a pipe, a
failed fetch leaves the right-hand side reading empty stdin, and `sh` on empty stdin exits 0 —
a silent no-op with no error, not a failure Claude can see and report. That gap is real here
specifically, not theoretical: `VERSION` on `main` and the release tag `vX.Y.Z` are two
separate git pushes, so the file can say a version is out before the matching tag exists to
back it up. CI's tag-vs-VERSION guard only runs on the tag push, so it structurally cannot
catch that window from the other side. Report the named reason above instead of "nothing
happened." Carry `LEARNER_REF="v$REMOTE"` over onto the direct `sh` call above — it is no
longer free the way it was as a prefix on the one `sh` in the old pipe. Drop it here and the
fetched `bootstrap.sh` would default its payload fetch back to `main` while the script itself
stayed pinned to `v$REMOTE`: two different refs, silently.

No other flags are needed: `learner.json` already exists — this is always a re-install, never
a first one — so `install.sh`'s onboarding prompts stay gated off regardless, and
`bootstrap.sh`'s no-tty guard only fires when `learner.json` is absent.

## 5. Confirm (origin: curl only)

Re-read `$CFG/skills/learner/VERSION`. If it now reads `$REMOTE`, report the new version in one
line. If it still reads the old value, say the update did not take — never claim success on an
assumption. Step 3's `brew`/`apt` branches, and step 1's plugin branch, already stopped before
this point — there is nothing here to confirm for them.
```

- [ ] **Step 4: Edit `skills/learner/SKILL.md`'s Status section**

Find, in the `## Status` section:

```markdown
1. Level and version: `jq -r '.level // "not set"' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner.json"`
   (a project override wins if present), and
   `cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/learner/VERSION" 2>/dev/null`.
```

Replace with:

```markdown
1. Level and version: `jq -r '.level // "not set"' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner.json"`
   (a project override wins if present), and
   `cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/learner/VERSION" 2>/dev/null` — unless this
   skill's own base directory (visible in your context when it loaded) contains `/plugins/`,
   in which case report the version as `plugin-managed` instead: a plugin install never
   creates that file, and Claude Code's own `/plugin` command is the source of truth for which
   version is installed.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -20`
Expected: `Failed: 0`.

- [ ] **Step 6: Commit**

```bash
git add skills/learner/references/update.md skills/learner/SKILL.md test.sh
git commit -m "feat(skill): make learner update and status plugin-aware"
```

---

### Task 3: Docs — Claude Code plugin first, ahead of apt

**Files:**
- Modify: `README.md`
- Modify: `docs/install.html`
- Modify: `test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks (pure docs), but the commands it documents must match
  Task 1's actual plugin name (`learner`) and marketplace source (`Tykok/learning-with-claude`).
- Produces: nothing later tasks consume.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, near the other README ordering assertions (the ones checking apt-before-Homebrew
etc.), add:

```bash
plugin_line=$(grep -n '^### Claude Code plugin$' "$RM" | head -1 | cut -d: -f1)
apt_line=$(grep -n '^### apt (Debian/Ubuntu)$' "$RM" | head -1 | cut -d: -f1)

{ [ -n "$plugin_line" ] && [ -n "$apt_line" ] && [ "$plugin_line" -lt "$apt_line" ]; } \
  && ok "README lists the Claude Code plugin before apt" \
  || ko "README lists the Claude Code plugin before apt"

grep -qF 'claude plugin install learner' "$RM" \
  && ok "README documents installing the plugin by name" \
  || ko "README documents installing the plugin by name"

grep -qF 'claude plugin marketplace add Tykok/learning-with-claude' "$RM" \
  && ok "README documents adding the self-hosted marketplace" \
  || ko "README documents adding the self-hosted marketplace"
```

Near the other `docs/install.html` assertions, add:

```bash
plugin_h2=$(grep -n '<h2 id="plugin">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
apt_h2=$(grep -n '<h2 id="apt">' "$SITE_INSTALL" | head -1 | cut -d: -f1)

{ [ -n "$plugin_h2" ] && [ -n "$apt_h2" ] && [ "$plugin_h2" -lt "$apt_h2" ]; } \
  && ok "install.html lists the plugin section before apt" \
  || ko "install.html lists the plugin section before apt"

grep -qF 'claude plugin install learner' "$SITE_INSTALL" \
  && ok "install.html documents installing the plugin by name" \
  || ko "install.html documents installing the plugin by name"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -iE 'plugin before apt|plugin by name|marketplace|FAIL'`
Expected: all five new assertions fail.

- [ ] **Step 3: Edit `README.md`**

Find:

```markdown
## Install

### apt (Debian/Ubuntu)
```

Replace with:

```markdown
## Install

### Claude Code plugin

```bash
claude plugin marketplace add Tykok/learning-with-claude
claude plugin install learner
```

Installs and enables the skill and its hooks natively — no `~/.claude` file copying, no
`learner-install` step. Claude Code manages updates itself (`/plugin update learner`); run
`learner update` and it will tell you the same thing rather than trying to curl a second,
traditional install on top.

### apt (Debian/Ubuntu)
```

- [ ] **Step 4: Edit `docs/install.html`**

Find the table of contents `<ol>` (search for `<li><a href="#requirements">`). Add a new
entry immediately after it, before the `#apt` entry:

```html
      <li><a href="#plugin">Claude Code plugin</a></li>
```

Find `<h2 id="apt">apt (Debian/Ubuntu)</h2>`. Insert a new section immediately before it:

```html
  <h2 id="plugin">Claude Code plugin</h2>

<pre><code>claude plugin marketplace add Tykok/learning-with-claude
claude plugin install learner</code></pre>

  <p>Installs and enables the skill and its hooks natively — no <code>~/.claude</code> file
  copying, no <code>learner-install</code> step. Claude Code manages updates itself
  (<code>/plugin update learner</code>); run <code>learner update</code> and it will tell you
  the same thing rather than trying to curl a second, traditional install on top.</p>

```

- [ ] **Step 5: Run the full test suite**

Run: `./test.sh 2>&1 | tail -20`
Expected: `Failed: 0`, including the generic per-page "table of contents matches its N
sections" structural check for `install.html` (now 8 sections, plugin first) — automatic, no
new assertion needed beyond the TOC edit already made in Step 4.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/install.html test.sh
git commit -m "docs: add the Claude Code plugin install path, first"
```

---

### Task 4: CI guard — `plugin.json` version matches `VERSION`

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `test.sh`

**Interfaces:**
- Consumes: Task 1's `.claude-plugin/plugin.json`.
- Produces: nothing later tasks consume.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, near the existing CI-shape assertions (the ones reading `$CI_YML`), add:

```bash
grep -qF 'plugin.json version matches VERSION' "$CI_YML" \
  && ok "CI guards plugin.json's version against the VERSION file" \
  || ko "CI guards plugin.json's version against the VERSION file"

grep -qF "jq -r '.version' .claude-plugin/plugin.json" "$CI_YML" \
  && ok "the plugin.json version guard reads the real field" \
  || ko "the plugin.json version guard reads the real field"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -iE 'plugin.json|FAIL'`
Expected: both new assertions fail.

- [ ] **Step 3: Add the step to `.github/workflows/ci.yml`**

Find the `ci` job's steps (search for `name: shellcheck`). Add a new step after the existing
`tests` step (before `tag matches VERSION`, or after it — either position is fine since this
check doesn't depend on the tag; place it right after `tests` for locality with the other
content-consistency checks the job already runs):

```yaml
      - name: plugin.json version matches VERSION
        run: |
          PLUGIN_VERSION=$(jq -r '.version' .claude-plugin/plugin.json)
          FILE="$(cat VERSION)"
          if [ "$PLUGIN_VERSION" != "$FILE" ]; then
            echo "plugin.json version ($PLUGIN_VERSION) does not match VERSION file ($FILE)"; exit 1
          fi
```

- [ ] **Step 4: Run the tests and validate the YAML**

Run: `./test.sh 2>&1 | tail -10 && python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo OK`
Expected: `Failed: 0`; `OK`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml test.sh
git commit -m "ci: guard plugin.json's version against the VERSION file"
```

---

### Task 5: Real verification — validate, install, and inspect the plugin for real

**Files:** none — no commits from this task; it verifies Tasks 1–4's combined result.

**Interfaces:**
- Consumes: Task 1's three new files, exactly as committed.
- Produces: a written report other tasks (and the final review) can point to; no code.

- [ ] **Step 1: Validate the manifests**

```bash
claude plugin validate .
```

Expected: `✔ Validation passed` (or `✔ Validation passed with warnings` — read any warning
text and note it in the report; warnings don't fail validation, but must not be ignored
blindly). If it prints `✘ Validation failed`, read the specific error, fix the referenced file
(from Task 1), and re-run this step before continuing — do not proceed to Step 2 on a failing
validation.

- [ ] **Step 2: Add the local repo as a marketplace and install the plugin for real**

```bash
claude plugin marketplace add "$(pwd)"
claude plugin install learner
```

Expected: both commands succeed. If `claude plugin marketplace add` reports the marketplace
already exists from a prior run, that's fine — proceed to install.

- [ ] **Step 3: Inspect the installed plugin's real component inventory**

```bash
claude plugin details learner
```

Expected: the output lists the plugin's skills (should show the `learner` skill) and hooks
(should list all four wired events — `SessionStart`, `PostToolUse`, `Stop`, `SessionEnd` —
and none referencing `learner-update-check.sh`). Read the actual output; do not assume it
matches `hooks/hooks.json` without checking.

- [ ] **Step 4: Confirm the four intended hook scripts, and only those four, are what's wired**

```bash
claude plugin details learner | grep -iE 'learner-onboard|learner-record-edit|learner-quiz|learner-cleanup|learner-update-check'
```

Expected: the four intended scripts appear; `learner-update-check` does not appear at all.

- [ ] **Step 5: Clean up — leave the local Claude Code environment as it was found**

```bash
claude plugin uninstall learner
claude plugin marketplace remove learning-with-claude
```

(If the marketplace name printed by Step 2 differs from `learning-with-claude`, use the name
`claude plugin marketplace list` actually shows — check before removing.)

- [ ] **Step 6: Write the report**

No file path is prescribed for this task since it produces no commits — if running this task
under subagent-driven-development, write the report to this plan's usual report path
(`task-5-report.md` in the plan's SDD workspace) covering: the exact output of Steps 1, 3, and
4 (quoted, not paraphrased), whether cleanup in Step 5 succeeded, and any warning text from
Step 1 that needs a human decision. Status contract:
- Status: DONE (or BLOCKED if validation fails and the fix isn't obvious from Task 1's own
  files, or NEEDS_CONTEXT if `claude` isn't on `PATH` in the execution environment)
- Tests: N/A (no test.sh assertions from this task — the verification IS the deliverable)
- Concerns: none, or the specific warning text from Step 1

---

## Post-plan note (not a task)

Community-marketplace submission (spec §8) is not a task here — it needs the human partner to
run `claude plugin validate .` one more time against the released commit and then use
[platform.claude.com/plugins/submit](https://platform.claude.com/plugins/submit) themselves,
whenever they choose. Nothing in this plan does that automatically, and nothing should.

`claude plugin tag` (a real subcommand: creates a `learner--v{version}` git tag, validating
`plugin.json` and the marketplace entry agree first) is available for cutting future plugin
releases but is not wired into this plan — the existing manual `VERSION`-bump-then-tag
discipline this project already uses for every other channel covers this release too, and
introducing a second, plugin-specific tag namespace is a separate decision this plan doesn't
make.
