# GitHub Pages Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one hand-written page at `docs/index.html` that both pitches Learner and documents it fully, published from `/docs` on `main`, with the README slimmed to a short entry point.

**Architecture:** No generator and no build step — the page is HTML with inline CSS, so it can be opened from disk and reviewed before it is ever published (a Jekyll build only runs on GitHub's side, and the repo is private). `docs/.nojekyll` makes GitHub serve the folder literally. The internal specs and plans move to `design/` so the published root holds only the site.

**Tech Stack:** HTML5, inline CSS with `prefers-color-scheme`. No JavaScript, no web fonts, no external requests. `test.sh` (bash) guards the content.

**Spec:** [design/superpowers/specs/2026-07-30-github-pages-design.md](../specs/2026-07-30-github-pages-design.md) — note the spec moves in Task 1; before that it is at `docs/superpowers/specs/`.

## Global Constraints

- The page issues **no external request at load**: no `<script>`, no `<link>` with an `href`, no `@import`, no web fonts, no analytics. Ordinary `<a href="https://github.com/…">` navigation links are expected and fine.
- All CSS inline in a single `<style>` block. Light and dark via `prefers-color-scheme`, no toggle, no JS.
- Semantic HTML: exactly one `<h1>`, headings in order, real `<table>` markup, every code sample in `<pre><code>`. The page must remain readable with CSS disabled.
- Responsive: relative units; code blocks scroll inside their own `overflow-x: auto` container so the page body never scrolls sideways.
- `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh` must exit 0.
- `test.sh` must not touch the network, and must pass **both** locally and in `debian:stable-slim` (Linux, dash, GNU grep, no `claude` binary). A local-only pass is not evidence — five bugs on this repo came from that gap.
- Grep patterns use bracket expressions or `-F`, never a backslash before an ordinary character: `\`` is undefined in an ERE and already produced a bug here that passed under ugrep and failed under GNU grep.
- All content in English. Conventional Commits, English subjects ≤ 72 chars.
- Every factual claim on the page must be true of the shipped code. Check against `install.sh`, `bootstrap.sh`, `uninstall.sh`, `hooks/learner-config.sh` and `skills/learner/SKILL.md` — not against the README, which is itself being rewritten.

## File Structure

| Path | Responsibility | Action |
|------|----------------|--------|
| `docs/index.html` | The site: pitch plus full reference, one page. | Create |
| `docs/.nojekyll` | Make GitHub serve `/docs` literally. | Create |
| `design/superpowers/` | Specs and plans, out of the published root. | Move from `docs/superpowers/` |
| `README.md` | Short entry point: what it is, install, requirements, development. | Rewrite (Task 2) |
| `test.sh` | Site assertions (Task 1); repointed doc assertions (Task 2). | Modify |

---

### Task 1: The site, and move the design records out of the published root

**Files:**
- Create: `docs/index.html`, `docs/.nojekyll`
- Move: `docs/superpowers/` → `design/superpowers/` (use `git mv` so history follows)
- Modify: `test.sh` (new `site` section, immediately before `# --- summary`)

**Interfaces:**
- Consumes: the shipped behaviour it documents — `install.sh`'s flags, `bootstrap.sh`'s one-liner and `LEARNER_REF`, `hooks/learner-config.sh`'s seven keys and defaults, `uninstall.sh`'s `--purge` / `--project`, `skills/learner/SKILL.md`'s levels and subcommands.
- Produces: `docs/index.html` as the reference Task 2's README links to, and the assertion target Task 2 repoints its doc checks at.

- [ ] **Step 1: Move the design records first, so nothing later lands in the published root**

```bash
mkdir -p design
git mv docs/superpowers design/superpowers
grep -rn 'docs/superpowers' --include='*.md' --include='*.sh' --include='*.yml' . | grep -v '^./design/'
```

Update every reference the grep finds. Relative links *inside* `design/superpowers/` (a plan pointing at `../specs/…`) keep working because both directories move together — verify rather than assume. Commit this move on its own so the diff is readable.

- [ ] **Step 2: Write the failing tests**

Add a `skip`-free `site` section immediately before `# --- summary` in `test.sh`:

```bash
# --- site -------------------------------------------------------------------
SITE="$ROOT/docs/index.html"

[ -f "$SITE" ] && ok "the site exists at docs/index.html" \
               || ko "the site exists at docs/index.html"

[ -f "$ROOT/docs/.nojekyll" ] \
  && ok "docs/.nojekyll stops GitHub running the page through Jekyll" \
  || ko "docs/.nojekyll stops GitHub running the page through Jekyll"

# The published root must hold the site, not internal design records.
[ ! -d "$ROOT/docs/superpowers" ] \
  && ok "the published root carries no internal design records" \
  || ko "the published root carries no internal design records"
[ -d "$ROOT/design/superpowers" ] \
  && ok "the design records moved to design/" \
  || ko "the design records moved to design/"

# No external request at load. <a href> navigation is fine; fetching tags are not.
grep -qiE '<script|<link[^>]+href|@import' "$SITE" \
  && ko "the page issues no external request at load" \
  || ok "the page issues no external request at load"

# -o counts occurrences, not matching lines: two <h1> on one line must still fail.
n=$(grep -oiE '<h1[ >]' "$SITE" | wc -l | tr -d ' ')
[ "$n" = 1 ] && ok "the page has exactly one h1" \
             || ko "the page has exactly one h1 (found $n)"

grep -qiF 'prefers-color-scheme' "$SITE" \
  && ok "the page styles both light and dark" \
  || ko "the page styles both light and dark"

# The reference content that moves off the README lives here now.
for s in CLAUDE_CONFIG_DIR untrackGlobs disabledPaths synthesisFrequency \
         blanksPerExercise 'learner off' 'learner-config.sh'; do
  grep -qF "$s" "$SITE" && ok "the site documents $s" || ko "the site documents $s"
done

grep -qF -- '--project' "$SITE" \
  && ok "the site documents the legacy cleanup flag" \
  || ko "the site documents the legacy cleanup flag"

grep -qF -- '--purge' "$SITE" \
  && ok "the site documents --purge" \
  || ko "the site documents --purge"

# Letter levels, as real table cells rather than prose. The markup shape is fixed by
# the plan (`<td><code>D</code></td>`) so this can be a fixed-string match — a bracket
# expression trying to allow several shapes is how the `\`` ERE bug got in last time.
for l in D J C S E; do
  grep -qF "<td><code>$l</code></td>" "$SITE" \
    && ok "the site documents level $l as a table cell" \
    || ko "the site documents level $l as a table cell"
done

for p in WSL 'Git Bash'; do
  grep -qF "$p" "$SITE" && ok "the site covers $p" || ko "the site covers $p"
done

grep -qiE 'native windows|windows, native' "$SITE" \
  && ok "the site states native Windows is unsupported" \
  || ko "the site states native Windows is unsupported"

grep -qiF 'posix' "$SITE" \
  && ok "the site gives the reason native Windows cannot work" \
  || ko "the site gives the reason native Windows cannot work"

grep -qF 'LEARNER-TODO' "$SITE" \
  && ok "the site shows the fill markers" \
  || ko "the site shows the fill markers"

# Case-SENSITIVE, and a phrase rather than the bare word: `grep -i HEAD` would match
# the page's own <head> tag and pass without the guardrail being explained at all.
grep -qF 'working tree' "$SITE" && grep -qF 'HEAD' "$SITE" \
  && ok "the site explains the guardrail counts leftovers only" \
  || ko "the site explains the guardrail counts leftovers only"

grep -qE 'recapEvery|trouBlanks|(^|[^A-Za-z])trackGlobs|"language"|intermediaire' "$SITE" \
  && ko "the site mentions no removed key or old level" \
  || ok "the site mentions no removed key or old level"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./test.sh`
Expected: every `site` assertion FAILS except the two about `docs/superpowers` / `design/superpowers`, which Step 1 already satisfied. The 191 pre-existing assertions must still pass.

- [ ] **Step 4: Write `docs/.nojekyll`**

An empty file. Its presence is the whole point:

```bash
touch docs/.nojekyll
```

- [ ] **Step 5: Write `docs/index.html`**

Skeleton — fill each section per the content requirements below:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Learner — quiz yourself on the code Claude just wrote</title>
<meta name="description" content="A Claude Code plugin that quizzes you on the code it just wrote with you, at your level, and tracks what to work on.">
<style>
:root {
  --bg: #fbfaf8; --fg: #1a1a18; --muted: #5d5a54;
  --rule: #e2ded6; --card: #f4f1ec; --accent: #7a5cc0;
  --code-bg: #f0ece5;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16161a; --fg: #e8e6e1; --muted: #9d9890;
    --rule: #2c2c32; --card: #1e1e24; --accent: #a98cf0;
    --code-bg: #1c1c22;
  }
}
/* system font stack, max-width ~/72ch measure, relative units throughout,
   pre { overflow-x: auto } so only code scrolls sideways, table { width: 100% }
   with a scroll container, and visible :focus-visible outlines. */
</style>
</head>
<body>
<main>
  <h1>…</h1>   <!-- the only h1 on the page -->
  …
</main>
</body>
</html>
```

Sections, in this order:

1. **`<h1>` plus a two-sentence statement of what it is.** Claude Code quizzes you on the code it just wrote with you, at your level, and keeps a record of what to work on.
2. **The problem.** Code arrives faster than understanding. Reviewing what an agent wrote is easy to skip and hard to do well; a question you have to answer is not skippable. Keep it to a short paragraph — no bullet-point marketing.
3. **Install.** The one-liner first, clone-and-run second. The one-liner block must be **byte-identical** to the README's (Task 2 asserts this), so settle on the exact text here:
   ```
   curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh
   ```
4. **What it actually looks like** — the section that does the convincing, and the longest. Show, as real rendered output:
   - a granular question, in the shape the Stop hook produces;
   - a synthesis question;
   - a `fill` exercise: the function before, the same function with two `// LEARNER-TODO: <hint>` comments in place of parts of its body, and a sentence on what happens next (you write it in the file, Claude compares, restores and validates). Take the example from real code in this repo — `learner_synthesis_n` in `hooks/learner-config.sh` is short enough to show whole.
5. **The three question styles** — `code`, `architecture` (alias `archi`), `fill`.
6. **The guardrail.** Why letting it edit your real source is safe, as four points: leftovers only (a marker the working tree has and `HEAD` does not, so a marker committed in your docs never triggers it); untracked files count, because a file the session just created is the commonest case; it fires even when the quiz is off, because an abandoned exercise still has to be cleaned up; bounded at two blocks per unfinished exercise so a session can always end.
7. **Configuration.** The two layers — `$CLAUDE_CONFIG_DIR/learner.json` then `<repo>/.claude/learner.local.json`, project winning key by key, arrays replaced not merged — then a table of the seven keys with values and defaults, taken from `LEARNER_DEFAULTS` in `hooks/learner-config.sh`.
8. **Levels.** The five letters as table rows, with what each changes about a question. Note letters are canonical and full words are accepted, case-insensitively.
9. **Platforms.** macOS, Linux, Windows via WSL, Windows via Git Bash — supported; native Windows not, because the hooks are POSIX `sh` scripts and without a POSIX shell Claude Code cannot run them.
10. **Turning it off.** The three ways: `"enabled": false` globally; `learner off` in a repo you own; `disabledPaths` for a repo you do not own, which writes nothing into it.
11. **Uninstall.** `./uninstall.sh`, `--purge`, and `--project <repo>` for a repo left over from the per-project beta.
12. **Footer** — a link to the GitHub repository and the MIT licence.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./test.sh` → every `site` assertion `ok`, `Failed: 0`.

Run the container check — mandatory, not optional:

```bash
docker run --rm -v "$PWD:/w" -w /w debian:stable-slim sh -c '
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq jq git curl >/dev/null 2>&1
  git config --global --add safe.directory /w
  git config --global user.email ci@t; git config --global user.name ci
  ./test.sh'
```

Expected: `Failed: 0` in both. Paste both results in your report.

Run: `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh` → exit 0.

- [ ] **Step 7: Look at the page you wrote**

Open `docs/index.html` in a browser and check it in both colour schemes and at a narrow width. Automated assertions cannot tell you whether it reads well or whether the dark theme has enough contrast. Report what you saw, including anything you fixed as a result. If you cannot open a browser, say so plainly rather than implying you looked.

- [ ] **Step 8: Commit**

```bash
git add docs/index.html docs/.nojekyll test.sh
git commit -m "feat: add a GitHub Pages site for the skill"
```

---

### Task 2: Slim the README and repoint its assertions

**Files:**
- Modify: `README.md`, `test.sh`

**Interfaces:**
- Consumes: `docs/index.html` from Task 1 as the link target and the new assertion target.
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing tests**

Repoint the existing README assertions whose subject moves to the site, and add the drift guard. In `test.sh`'s `docs` section:

- **Repoint to `$SITE`** (delete the README version, keep the assertion): the `for s in CLAUDE_CONFIG_DIR untrackGlobs disabledPaths synthesisFrequency blanksPerExercise 'learner off'` loop (currently `test.sh:769`); `--project` (`:773`); the letter-level row check (`:780`); the `for p in WSL 'Git Bash'` loop (`:796`); native Windows (`:803`); and the platform-table row checks (`:829`, `:833`, `:837`). Task 1 already added site versions of most of these — **do not leave two assertions checking the same fact in the same file.** Reconcile: one assertion per fact, targeting the file that now owns it.
- **Keep on `$RM`**: no-removed-key (`:765`), `bootstrap.sh` (`:784`), `LEARNER_REF` (`:788`), `sh -s --` (`:792`), `posix` in Requirements (`:807`), the `bash` requirement bullet (`:819`), the shellcheck-line-matches-CI check (`:843`).

Then add the drift guard that makes the split safe:

```bash
# The install one-liner appears in two files by design. Pin them to each other so
# they cannot drift: this is the whole reason the split is acceptable.
ONELINER='curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh'
{ grep -qF "$ONELINER" "$RM" && grep -qF "$ONELINER" "$SITE"; } \
  && ok "the install one-liner is identical in the README and on the site" \
  || ko "the install one-liner is identical in the README and on the site"

{ grep -qF 'docs/index.html' "$RM" || grep -qiF 'github.io' "$RM"; } \
  && ok "the README links to the site" \
  || ko "the README links to the site"
```

Before accepting each repointed assertion, confirm it fails against the file that no longer owns the fact — otherwise you have moved the words and kept a check that passes for the wrong reason. Report how you verified.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: the repointed assertions FAIL because the README still contains everything and the new link assertion has nothing to match. `Failed:` is non-zero.

- [ ] **Step 3: Rewrite `README.md`**

Keep, in this order: the badges (first six lines), a short "what it is", **Install** (unchanged — it stays because a reader needs it at the moment of acting, and while the repo is private the site is unreachable), **Requirements**, **Development**, **License**.

Add, prominently near the top, a line pointing at the site for the full reference.

Remove — these now live on the site: `Three question styles`, `Levels`, `Turning it off`, `Settings`, `Files installed`, `Uninstall`. Replace them with a single short sentence in the "what it is" section noting that configuration, levels, the guardrail and uninstall are documented on the site, and link it.

Keep the README under roughly 100 lines. If it is much longer, detail leaked back in.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh` → `Failed: 0`. Then the container run from Task 1 Step 6 → `Failed: 0`. Paste both.

Run: `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add README.md test.sh
git commit -m "docs: point the README at the site for the reference"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|--------------|------|
| Why not a generator; `.nojekyll` | Task 1 Steps 4, 5 |
| §1 layout, moving the design records | Task 1 Step 1 |
| §2 page content, all twelve sections | Task 1 Step 5 |
| §3 design constraints | Global Constraints; Task 1 Steps 5, 7 |
| §4 the README's new shape, and why install stays | Task 2 Step 3 |
| §5 the anti-drift contract | Task 1 Step 2, Task 2 Step 1 |
| §6 publishing | Not implementable — enabling Pages needs the repo public; called out below |

**Known gaps, both deliberate:**
- Nothing here enables GitHub Pages. On a free plan that needs a public repository, which is the owner's decision. The site is complete and reviewable from disk either way; enabling Pages is one settings change once visibility allows it.
- Task 1 Step 7 is a human-eye check with no assertion behind it. Contrast and readability cannot be greped, and a screenshot test would be a disproportionate amount of machinery for one page.
