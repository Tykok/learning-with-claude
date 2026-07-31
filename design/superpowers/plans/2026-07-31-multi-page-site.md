# Five-page site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `docs/index.html` into five hand-written pages joined by a menu, sharing one stylesheet, with every fact `test.sh` pins repointed at the page that owns it.

**Architecture:** No build step, no JavaScript, no external request. The CSS moves out to `docs/assets/style.css` first; then the site is carved one page at a time, in an order chosen so that no intermediate commit ever contains a dangling link. Each task moves whole HTML blocks out of `index.html`, adds the page's chrome, extends the menu, and repoints that page's assertions. `./test.sh` is green at the end of every task.

**Tech Stack:** Hand-written HTML5 and CSS. POSIX `sh` for the test suite. `jq` and `git` are already required by the repo. No new dependency.

## Global Constraints

- Spec: [`design/superpowers/specs/2026-07-31-multi-page-site-design.md`](../specs/2026-07-31-multi-page-site-design.md). Read it before Task 1.
- Plans and specs live under `design/`, never `docs/` — `test.sh` asserts `docs/superpowers` is absent, because publishing `/docs` would make internal design records reachable. (Assertion text: "the published root carries no internal design records".)
- The site stays in **English**. This plan is in English for that reason; the conversation driving it was in French.
- No JavaScript on any page. No `<img>`, `<iframe>`, `<script>`, web font, CDN link, or analytics — `test.sh` enforces this per page and on the stylesheet.
- Existing prose moves **verbatim**. The only new prose is: one `<p class="lede">` per new page, one `<p class="next">` per page, and the rewritten last sentence of the footer. Do not reword moved paragraphs, do not reorder them, do not "improve" them.
- Every existing `id` is preserved. `install` and `config` migrate from an `<h2>` to their page's `<h1>`; every other `id` stays on the element it is on today.
- Menu order is fixed: Home, Install, Usage, Configuration, Safety. A page absent from the site is absent from the menu, so the menu grows from two entries to five across Tasks 2–5.
- Every commit must leave `./test.sh` at 0 failures and `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh` clean. CI runs both on every push.
- Patterns added to `test.sh` use bracket expressions or `grep -F`, never a backslash before an ordinary character. An undefined ERE escape has already shipped a bug here that passed under ugrep and failed under GNU grep.
- Work on branch `site/multi-page`, which already exists and holds the spec commit.

---

## File Structure

| File | Responsibility |
|---|---|
| `docs/assets/style.css` | **Create.** Every rule the site uses: the current inline block verbatim, plus the menu, lede, and "next" rules. The only stylesheet. |
| `docs/index.html` | **Modify throughout.** Ends as: chrome, `<h1>Claude Learner</h1>`, lede, sub, The problem, What it actually looks like. Shrinks in every task. |
| `docs/safety.html` | **Create (Task 2).** The guardrail, What counts as quiz material, Uninstall. |
| `docs/config.html` | **Create (Task 3).** Configuration, Levels, Turning it off. |
| `docs/install.html` | **Create (Task 4).** Requirements, One line, Clone and run, What gets installed and where, Platforms. |
| `docs/usage.html` | **Create (Task 5).** The three question styles, On demand. |
| `test.sh` | **Modify in every task.** Gains a `PAGES` list and per-page loops; content assertions are repointed as content moves. |
| `README.md` | **Modify (Task 6).** Three edits: the "single hand-written file" claim, and two deep links. |

### Why this carve order

Each page must exist before another page links into it, or the "every internal link resolves" assertion goes red. The six cross-references in the spec impose:

- `safety.html` has no outgoing internal cross-reference → carve it **first**.
- `config.html` links to `index.html#looks-like` (always present) and to `safety.html#material` → **second**.
- `install.html` links to `config.html#levels` → **third**.
- `usage.html` links to `config.html#off`, and creating it rewrites `index.html`'s `#commands` → **fourth**.

Any other order forces a link to be written twice, or leaves a commit with a dangling anchor.

---

## Task 1: Extract the CSS to a shared stylesheet

Nothing about the page changes visually. One page, one stylesheet, tests rescoped to allow a local `<link>` and to look for the theme rules where they now live.

**Files:**
- Create: `docs/assets/style.css`
- Modify: `docs/index.html` (lines 8–185 today: the whole `<style>` block)
- Modify: `test.sh` (add `STYLE`, `PAGES`, `page_path` near line 762; replace the assertions at lines 1020–1032)

**Interfaces:**
- Produces: `docs/assets/style.css`, referenced by every page as `<link rel="stylesheet" href="assets/style.css">`. `test.sh` gains `PAGES` (a space-separated list of page basenames without `.html`), `page_path <name>` (prints the absolute path of a page), and `STYLE` (absolute path of the stylesheet). Tasks 2–5 append to `PAGES`; every later per-page loop iterates it.

- [ ] **Step 1: Write the failing assertions in `test.sh`**

Immediately after line 762 (`SITE="$ROOT/docs/index.html"`), add:

```sh
STYLE="$ROOT/docs/assets/style.css"

# Every published page, by basename. Per-page loops iterate this list, so a page
# added to the site cannot quietly skip the structural checks below.
PAGES="index"

page_path() { printf '%s/docs/%s.html' "$ROOT" "$1"; }
```

Then replace lines 1020–1032 — the "no external request", "exactly one h1" and "prefers-color-scheme" assertions — with:

```sh
# No external request at load. <a href> navigation is fine; fetching tags/properties are
# not. The original three (script/link-href/@import) missed a whole class of fetch: an
# `@font-face { src: url(https://…) }` needs none of them, so a reviewer added one and the
# suite stayed green. img/iframe/embed/object/srcset cover the other tags that fetch;
# url(...) is scoped to an http(s) scheme so a local url(#fragment) or a data: URI (no
# request either) is not a false positive.
#
# The <link> branch is scoped to a scheme rather than banning href outright: the pages
# share one local stylesheet, which issues no external request. `//` is included because a
# protocol-relative URL fetches off-origin exactly like an absolute one.
EXTERNAL='<script|<link[^>]+href="(https?:|//)|@import|<img|<iframe|<embed|<object|srcset|url\([^)]*https?:'

for p in $PAGES; do
  f=$(page_path "$p")

  grep -qiE "$EXTERNAL" "$f" \
    && ko "$p.html issues no external request at load" \
    || ok "$p.html issues no external request at load"

  grep -qF '<link rel="stylesheet" href="assets/style.css">' "$f" \
    && ok "$p.html links the shared stylesheet" \
    || ko "$p.html links the shared stylesheet"

  # -o counts occurrences, not matching lines: two <h1> on one line must still fail.
  n=$(grep -oiE '<h1[ >]' "$f" | wc -l | tr -d ' ')
  [ "$n" = 1 ] && ok "$p.html has exactly one h1" \
               || ko "$p.html has exactly one h1 (found $n)"
done

# The stylesheet is scanned too, and it is the likelier place for a web font to appear.
grep -qiE "$EXTERNAL" "$STYLE" \
  && ko "the stylesheet issues no external request" \
  || ok "the stylesheet issues no external request"

grep -qiF 'prefers-color-scheme' "$STYLE" \
  && ok "the stylesheet styles both light and dark" \
  || ko "the stylesheet styles both light and dark"
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^(FAIL|Passed)'`

Expected: four failures — `index.html links the shared stylesheet`, `the stylesheet issues no external request`, `the stylesheet styles both light and dark` (the file does not exist yet, so `grep` errors and the branch reports a miss), and a non-zero `Failed:` count.

- [ ] **Step 3: Create the stylesheet**

`mkdir -p docs/assets`, then move the contents of `docs/index.html` lines 9–184 — everything **between** `<style>` and `</style>`, comments included, byte for byte — into `docs/assets/style.css`. Do not reformat, do not reorder, do not drop the comments: they record two accessibility fixes and three CSS traps.

Append these rules to the end of the file. They are the only new CSS; every task after this one reuses them.

```css

/* --- site chrome ---------------------------------------------------------- */

/* The menu, on every page. Same width as main so the whole page shares one
   measure. flex-wrap so two rows are possible on a narrow viewport before the
   list starts scrolling. */
.site {
  max-width: 44rem;
  margin: 0 auto 2.5rem;
  padding-bottom: 0.7rem;
  border-bottom: 1px solid var(--rule);
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.35rem 1.1rem;
}
.site .brand {
  font-weight: 600;
  color: var(--fg);
  text-decoration: none;
}
.site ul {
  display: flex;
  gap: 0.9rem;
  margin: 0;
  padding: 0;
  list-style: none;
  /* A menu wider than the viewport scrolls inside itself rather than pushing the
     page body sideways — the same rule the code blocks and tables follow. */
  overflow-x: auto;
}
.site li { margin: 0; }
.site a { white-space: nowrap; }
/* The current page is marked by weight and a thicker underline, not by colour
   alone: colour alone is not a distinction for a reader who cannot see it. */
.site [aria-current="page"] {
  color: var(--fg);
  font-weight: 600;
  text-decoration-thickness: 2px;
  text-underline-offset: 0.25em;
}

/* The link to the next page. No border-top: the footer immediately below already
   draws one, and two rules a line apart read as a mistake. */
.next {
  margin-top: 2.5rem;
  color: var(--muted);
}

/* Was `.toc h2`. "On this page" is not a section of the document, and an <h2>
   there put it in the heading outline between the real ones. */
.toc .toc-title {
  font-size: 0.8rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted);
  margin: 0 0 0.5rem;
}
```

Then delete the old `.toc h2 { … }` block from the file (it was lines 137–145 of `index.html`), since the rule above replaces it.

- [ ] **Step 4: Point `index.html` at the stylesheet**

In `docs/index.html`, replace the entire `<style>` … `</style>` block (lines 8–185) with one line:

```html
<link rel="stylesheet" href="assets/style.css">
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`
Expected: `Failed: 0`.

- [ ] **Step 6: Check the page still renders**

Run: `open docs/index.html` (macOS) or `xdg-open docs/index.html`.
Expected: identical to before — same colours, same code blocks, same tables. Toggle your OS between light and dark and confirm both themes still apply. If the page renders unstyled, the `href` is wrong or `docs/assets/style.css` is not where the link says.

- [ ] **Step 7: shellcheck**

Run: `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add docs/assets/style.css docs/index.html test.sh
git commit -m "refactor(site): move the CSS to a shared stylesheet

Five pages cannot each carry their own copy of 180 lines of CSS. The rules move
out verbatim, plus the menu and lede rules the split needs.

The no-external-request assertion banned <link href> outright, so a local
stylesheet would have turned it red. Scoped to an http(s) or protocol-relative
scheme instead, which is what it was always for: a CDN sheet or a web font stays
red, a relative path does not. It now runs per page and over the stylesheet, and
the theme check follows prefers-color-scheme to where it lives."
```

---

## Task 2: Carve out `safety.html`, and introduce the chrome

The first page out, and the one that introduces the menu, the footer duplication, and the five structural assertions. `safety.html` goes first because it links nowhere inside the site, so nothing can dangle.

**Files:**
- Create: `docs/safety.html`
- Modify: `docs/index.html` — delete the 11-entry table of contents (lines 200–215), the guardrail section (362–420), the `What counts as quiz material` subsection (628–647), and the Uninstall section (724–744); add the chrome; rewrite the `#guardrail` link at line 338; rewrite the footer's last sentence
- Modify: `test.sh` — extend `PAGES`; add the five structural assertions; repoint `--project`, `--purge`, `LEARNER-TODO`, `working tree`/`HEAD`; turn the removed-key and licence checks into per-page loops

**Interfaces:**
- Consumes: `PAGES`, `page_path`, `STYLE`, `EXTERNAL` from Task 1.
- Produces: the chrome markup (`<head>`, `<nav class="site">`, `<footer>`) that Tasks 3–5 copy; `SITE_SAFETY="$ROOT/docs/safety.html"`; the test helper `nav_links <file>` printing the menu's ordered `href|label` list, one per line; `id="material"` on `safety.html`, which Task 3 links to.

- [ ] **Step 1: Write the failing assertions in `test.sh`**

Change the `PAGES` line added in Task 1 to:

```sh
PAGES="index safety"
```

Add, next to it:

```sh
SITE_SAFETY="$ROOT/docs/safety.html"
```

Then, immediately after the Task 1 per-page loop, add the structural block:

```sh
# --- the shared chrome ------------------------------------------------------
# The menu is copied into every page by hand, so the thing to assert is not that
# copying happened but that the copies agree.

nav_links() {
  # The menu's ordered "href|label" list, one per line. aria-current sits between
  # the href and the '>' and is deliberately dropped: it differs by page on
  # purpose, so comparing raw bytes would report every page as divergent.
  awk '/<nav class="site"/,/<\/nav>/' "$1" \
    | grep -oE '<li><a href="[^"]+"[^>]*>[^<]+</a></li>' \
    | sed -e 's/^<li><a href="//' -e 's/"[^>]*>/|/' -e 's|</a></li>$||'
}

nav_ref=$(nav_links "$(page_path index)")

[ -n "$nav_ref" ] \
  && ok "index.html carries a menu" \
  || ko "index.html carries a menu"

for p in $PAGES; do
  [ "$(nav_links "$(page_path "$p")")" = "$nav_ref" ] \
    && ok "$p.html's menu matches index.html's" \
    || ko "$p.html's menu matches index.html's"
done

# The menu lists every page and nothing else. Without this, five pages could agree
# on a menu that omits one of them.
nav_n=$(printf '%s\n' "$nav_ref" | grep -c '|')
# shellcheck disable=SC2086  # word splitting is how the page list is iterated
page_n=$(printf '%s\n' $PAGES | wc -l | tr -d ' ')
[ "$nav_n" = "$page_n" ] \
  && ok "the menu lists every page ($page_n)" \
  || ko "the menu lists every page (menu $nav_n, pages $page_n)"

# Each page marks itself, and only itself. Two matches make $cur two lines and fail
# the comparison, so this covers "exactly one" without a separate count.
for p in $PAGES; do
  cur=$(awk '/<nav class="site"/,/<\/nav>/' "$(page_path "$p")" \
        | grep -oE 'href="[^"]+" aria-current="page"' \
        | sed -e 's/^href="//' -e 's/" aria-current="page"$//')
  [ "$cur" = "$p.html" ] \
    && ok "$p.html marks itself current in the menu" \
    || ko "$p.html marks itself current in the menu (got '$cur')"
done

# Every local href resolves: the file exists, and a fragment exists as an id in it.
# This is what guards the cross-page links the split creates, and the only check
# that catches an id deleted later. Hrefs on this site carry no spaces, so word
# splitting over the grep output is safe.
link_bad=0
for f in "$ROOT"/docs/*.html; do
  for h in $(grep -oE 'href="[^"]+"' "$f" | sed -e 's/^href="//' -e 's/"$//'); do
    case "$h" in http:*|https:*|//*|mailto:*) continue ;; esac
    target=${h%%#*}
    [ -n "$target" ] || target=$(basename "$f")
    if [ ! -f "$ROOT/docs/$target" ]; then
      link_bad=$((link_bad + 1))
      echo "    dangling file: $h  (in $(basename "$f"))"
      continue
    fi
    case "$h" in
      *[#]*)
        frag=${h#*#}
        grep -qF "id=\"$frag\"" "$ROOT/docs/$target" || {
          link_bad=$((link_bad + 1))
          echo "    dangling anchor: $h  (in $(basename "$f"))"
        } ;;
    esac
  done
done
[ "$link_bad" = 0 ] \
  && ok "every internal link resolves to a file and an id" \
  || ko "every internal link resolves to a file and an id ($link_bad dangling)"

# A page with four or more sections gets an "On this page" list; a shorter page does
# not, because a two-entry table of contents is decoration rather than navigation.
# Where the list exists, its entries must be the page's h2 ids in document order.
for p in $PAGES; do
  f=$(page_path "$p")
  h2_ids=$(grep -oE '<h2 id="[^"]+"' "$f" | sed -e 's/^<h2 id="//' -e 's/"$//')
  h2_n=$(printf '%s\n' "$h2_ids" | grep -c .)
  toc_ids=$(awk '/<nav class="toc"/,/<\/nav>/' "$f" \
            | grep -oE 'href="#[^"]+"' | sed -e 's/^href="#//' -e 's/"$//')
  if [ "$h2_n" -ge 4 ]; then
    [ "$toc_ids" = "$h2_ids" ] \
      && ok "$p.html's table of contents matches its $h2_n sections" \
      || ko "$p.html's table of contents matches its $h2_n sections"
  else
    [ -z "$toc_ids" ] \
      && ok "$p.html has $h2_n sections and needs no table of contents" \
      || ko "$p.html has $h2_n sections and needs no table of contents"
  fi
done

# Every page ends with a link onward, so no page is a dead end.
for p in $PAGES; do
  grep -qF '<p class="next">' "$(page_path "$p")" \
    && ok "$p.html links onward" \
    || ko "$p.html links onward"
done
```

Now repoint the four safety-owned assertions. Replace `"$SITE"` with `"$SITE_SAFETY"` at what are today lines 1088 (`--project`), 1092 (`--purge`), 1134 (`LEARNER-TODO`) and 1140 (`working tree` / `HEAD`), and reword their `ok`/`ko` messages from "the site" to "safety.html". For example:

```sh
grep -qF -- '--project' "$SITE_SAFETY" \
  && ok "safety.html documents the legacy cleanup flag" \
  || ko "safety.html documents the legacy cleanup flag"
```

Finally turn the two whole-site checks into loops over `PAGES`. Replace the removed-key check (line 1144):

```sh
for p in $PAGES; do
  grep -qE 'recapEvery|trouBlanks|(^|[^A-Za-z])trackGlobs|"language"|intermediaire' "$(page_path "$p")" \
    && ko "$p.html mentions no removed key or old level" \
    || ok "$p.html mentions no removed key or old level"
done
```

and the two licence checks (lines 1174 and 1179–1183), which are footer text and so must hold on every page or none:

```sh
for p in $PAGES; do
  f=$(page_path "$p")
  grep -qF '>GPL-3.0-or-later</a>' "$f" \
    && ok "$p.html's footer links the licence by name" \
    || ko "$p.html's footer links the licence by name"
  grep -qiF 'copyleft' "$f" \
    && ok "$p.html states the licence is copyleft" \
    || ko "$p.html states the licence is copyleft"
done

grep -qiF 'copyleft' "$RM" \
  && ok "README.md states the licence is copyleft" \
  || ko "README.md states the licence is copyleft"
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^FAIL|^Passed'`

Expected: failures for every `safety.html` assertion (the file does not exist), for `index.html carries a menu`, for the `aria-current`, `next` and menu-count checks on `index.html`, and for the four repointed content checks.

- [ ] **Step 3: Create `docs/safety.html`**

The head, menu and footer below are the chrome. Tasks 3–5 copy this shape; only the `<title>`, the `<meta name="description">`, the `aria-current` link and the menu's entry list differ.

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Safety — Claude Learner</title>
<meta name="description" content="What a fill exercise does to your files, the guardrail that stops it leaving them broken, and how to remove Learner entirely.">
<link rel="stylesheet" href="assets/style.css">
</head>
<body>

<nav class="site" aria-label="Sections">
  <a class="brand" href="index.html">Claude Learner</a>
  <ul>
    <li><a href="index.html">Home</a></li>
    <li><a href="safety.html" aria-current="page">Safety</a></li>
  </ul>
</nav>

<main>

  <h1>Safety</h1>
  <p class="lede">What a <code>fill</code> exercise does to your files, what stops it
  leaving them broken, and how to remove Learner entirely.</p>

  <!-- MOVE HERE, verbatim: docs/index.html lines 362-420, the whole
       <h2 id="guardrail">The guardrail</h2> section through the paragraph ending
       "…and git will show you every hole." -->

  <!-- MOVE HERE, verbatim: docs/index.html lines 628-647, the
       <h3>What counts as quiz material</h3> subsection, with the heading changed to
       <h2 id="material">What counts as quiz material</h2> -->

  <!-- MOVE HERE, verbatim: docs/index.html lines 724-744, the whole
       <h2 id="uninstall">Uninstall</h2> section -->

  <p class="next">Next: <a href="index.html">what Learner is</a>, if you came in
  sideways.</p>

</main>

<footer>
  <p><a href="https://github.com/Tykok/learning-with-claude">github.com/Tykok/learning-with-claude</a>
  — issues and pull requests welcome.</p>
  <p><a href="https://github.com/Tykok/learning-with-claude/blob/main/LICENSE">GPL-3.0-or-later</a>
  — copyleft, so a fork stays free. Using Learner on your own code does not affect your code's
  licence; only redistributing a modified Learner does. This site is five hand-written files
  and one stylesheet: no build step, no tracking, and no request to anywhere when you open
  it.</p>
</footer>
</body>
</html>
```

Two things to get right while moving:

1. `What counts as quiz material` is an `<h3>` today with no `id`. It becomes `<h2 id="material">`. Its prose is unchanged, including the sentence about `untrackGlobs` — Task 3 links to this `id` from the config table.
2. The guardrail section's prose mentions `disabledPaths` and `untrackGlobs`. Leave both mentions alone; the assertions for those key names target `config.html` (Task 3), not this page.

`safety.html` has three `<h2>`s, so per the rule in Step 1 it gets **no** table of contents.

- [ ] **Step 4: Cut those three blocks out of `index.html` and add its chrome**

In `docs/index.html`:

1. Delete lines 362–420, 628–647 and 724–744 — the three blocks just moved. Nothing else in those ranges.
2. **Prune** the table of contents at lines 200–215 rather than deleting it, and convert its heading to the new markup. `index.html` still has nine `<h2>`s at this point, so the four-or-more rule from Step 1 requires it to carry a list matching them in order — deleting it here turns that assertion red, which is the assertion doing its job. Drop the two entries whose targets just left (`#guardrail`, `#uninstall`), keep the other nine in document order, and replace `<h2 id="toc-h">On this page</h2>` with `<p class="toc-title" id="toc-title">On this page</p>` — an `<h2>` carrying an `id` would otherwise count as one of the page's own sections and make the list disagree with itself:

```html
  <nav class="toc" aria-labelledby="toc-title">
    <p class="toc-title" id="toc-title">On this page</p>
    <ol>
      <li><a href="#problem">The problem</a></li>
      <li><a href="#looks-like">What it actually looks like</a></li>
      <li><a href="#styles">The three question styles</a></li>
      <li><a href="#install">Install</a></li>
      <li><a href="#commands">On demand</a></li>
      <li><a href="#config">Configuration</a></li>
      <li><a href="#levels">Levels</a></li>
      <li><a href="#platforms">Platforms</a></li>
      <li><a href="#off">Turning it off</a></li>
    </ol>
  </nav>
```

Tasks 3 and 4 prune it further as their sections leave; Task 5 deletes it outright, when `index.html` finally drops to two sections and the rule forbids it.
3. Insert the menu between `<body>` and `<main>`:

```html
<nav class="site" aria-label="Sections">
  <a class="brand" href="index.html">Claude Learner</a>
  <ul>
    <li><a href="index.html" aria-current="page">Home</a></li>
    <li><a href="safety.html">Safety</a></li>
  </ul>
</nav>
```

4. Rewrite the `#guardrail` link at line 338 (inside the `fill` note):

```html
    <a href="safety.html#guardrail">the guardrail</a> exists — read it before you install.</p>
```

5. Add a "next" link as the last child of `<main>`, just before `</main>`:

```html
  <p class="next">Next: <a href="safety.html">Safety</a> — what a <code>fill</code>
  exercise does to your files.</p>
```

6. Replace the footer's last sentence. Was: `This page is a single hand-written file: no build step, no tracking, and no request to anywhere when you open it.` Now: `This site is five hand-written files and one stylesheet: no build step, no tracking, and no request to anywhere when you open it.`

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`
Expected: `Failed: 0`.

If `every internal link resolves` fails, read the dangling lines it prints: the commonest cause is a `#guardrail`, `#uninstall` or `#material` anchor still pointing at `index.html` from a link left behind.

- [ ] **Step 6: Check both pages in a browser**

Run: `open docs/index.html docs/safety.html`
Expected: the menu shows Home and Safety on both, the current one weighted and thickly underlined. Click each link both ways. Narrow the window to phone width and confirm the menu does not push the page sideways. The "next" link sits above the footer with a single horizontal rule between them, not two.

- [ ] **Step 7: shellcheck**

Run: `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh`
Expected: no output. If SC2086 fires on the `printf '%s\n' $PAGES` line, the `# shellcheck disable=SC2086` comment above it is missing or misplaced — it must be the line directly above.

- [ ] **Step 8: Commit**

```bash
git add docs/safety.html docs/index.html test.sh
git commit -m "feat(site): split out safety.html, add the shared menu

First page out, and the one that carries the chrome the other four will copy:
head, menu, footer. Safety goes first because it links nowhere else inside the
site, so no intermediate commit can hold a dangling anchor.

The menu is copied by hand, so the assertions check that the copies agree rather
than that copying happened: identical ordered href|label lists across pages,
exactly one aria-current per page pointing at itself, and every local href
resolving to a file and an id. That last one is what makes the remaining four
carves safe. The eleven-entry table of contents is gone; a page earns a local one
at four sections, which none has yet.

The footer's 'single hand-written file' claim stopped being true, and the licence
and removed-key checks now loop over every page, since footer text holds
everywhere or nowhere."
```

---

## Task 3: Carve out `config.html`

**Files:**
- Create: `docs/config.html`
- Modify: `docs/index.html` — delete the Configuration section (lines 570–627 after Task 2's edits shift them), Levels, and Turning it off; extend the menu; rewrite the `#looks-like` link
- Modify: `test.sh` — extend `PAGES`; add `SITE_CONFIG`; repoint the seven config keys, the seven defaults, the level letters, and `learner off`

**Interfaces:**
- Consumes: the chrome from Task 2, `id="material"` on `safety.html`.
- Produces: `id="config"` (on the `<h1>`), `id="levels"` and `id="off"` on `config.html` — Task 4 links to `#levels`, Task 5 links to `#off`.

- [ ] **Step 1: Write the failing assertions in `test.sh`**

Set:

```sh
PAGES="index config safety"
SITE_CONFIG="$ROOT/docs/config.html"
```

Keep the list in menu order — `PAGES` drives the menu-count assertion, not the menu's order, but reading them in the same order makes a mismatch obvious.

Repoint, changing `"$SITE"` to `"$SITE_CONFIG"` and rewording the messages:

- the string loop currently at line 1036: split it. `untrackGlobs`, `disabledPaths`, `synthesisFrequency`, `blanksPerExercise` and `learner off` move to `config.html`; leave `CLAUDE_CONFIG_DIR` and `learner-config.sh` on `"$SITE"` for now — Task 4 moves them to `install.html`.

```sh
for s in untrackGlobs disabledPaths synthesisFrequency blanksPerExercise 'learner off'; do
  grep -qF "$s" "$SITE_CONFIG" \
    && ok "config.html documents $s" \
    || ko "config.html documents $s"
done

for s in CLAUDE_CONFIG_DIR 'learner-config.sh'; do
  grep -qF "$s" "$SITE" && ok "the site documents $s" || ko "the site documents $s"
done
```

- the defaults loop at lines 1049–1069: change `row=$(grep -F "<tr><td><code>$key</code></td>" "$SITE")` to read `"$SITE_CONFIG"`, and reword its two messages to name `config.html`. Leave the rest of that block — the `LEARNER_DEFAULTS` parsing, the `awk -F'</td>'` column scoping, and the comments explaining both — exactly as it is.
- the level-letter loop at lines 1098–1102: `"$SITE"` → `"$SITE_CONFIG"`.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^FAIL|^Passed'`
Expected: failures for every `config.html` assertion, plus the chrome loops (`config.html`'s menu, `aria-current`, `next`, h1, stylesheet) and the menu-count check, which now wants three entries.

- [ ] **Step 3: Create `docs/config.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Configuration — Claude Learner</title>
<meta name="description" content="Every setting Claude Learner reads, the two layers it reads them from, the five levels, and the three ways to make it stop.">
<link rel="stylesheet" href="assets/style.css">
</head>
<body>

<nav class="site" aria-label="Sections">
  <a class="brand" href="index.html">Claude Learner</a>
  <ul>
    <li><a href="index.html">Home</a></li>
    <li><a href="config.html" aria-current="page">Configuration</a></li>
    <li><a href="safety.html">Safety</a></li>
  </ul>
</nav>

<main>

  <h1 id="config">Configuration</h1>
  <p class="lede">Every setting Learner reads, where to put it, and how to make it
  stop.</p>

  <!-- MOVE HERE, verbatim: the body of the <h2 id="config">Configuration</h2>
       section — from "Two layers, read in this order:" through the paragraph ending
       "…for reference or copy-paste." The <h2> itself is NOT moved: the <h1> above
       carries its id, so the page does not open with a heading that repeats its own
       title. Everything below that heading moves unchanged: the two-item <ol>, the
       "project layer wins key by key" paragraph, the seven-key table inside its
       <div class="scroll">, the LEARNER_DEFAULTS paragraph, the JSON example, and the
       closing paragraph about `learner config`. -->

  <!-- MOVE HERE, verbatim: the whole <h2 id="levels">Levels</h2> section -->

  <!-- MOVE HERE, verbatim: the whole <h2 id="off">Turning it off</h2> section -->

  <p class="next">Next: <a href="safety.html">Safety</a> — what a <code>fill</code>
  exercise does to your files.</p>

</main>

<footer>
  <p><a href="https://github.com/Tykok/learning-with-claude">github.com/Tykok/learning-with-claude</a>
  — issues and pull requests welcome.</p>
  <p><a href="https://github.com/Tykok/learning-with-claude/blob/main/LICENSE">GPL-3.0-or-later</a>
  — copyleft, so a fork stays free. Using Learner on your own code does not affect your code's
  licence; only redistributing a modified Learner does. This site is five hand-written files
  and one stylesheet: no build step, no tracking, and no request to anywhere when you open
  it.</p>
</footer>
</body>
</html>
```

**Also rewrite two links that are about to dangle.** The carve-order reasoning above tracked which *page* links to which, but two of the six cross-references have their source prose still sitting in `index.html` at this point — so the moment `Levels` and `Turning it off` leave, those links break. The internal-link assertion catches it. Fix them here, in `index.html`, and they arrive already correct when Tasks 4 and 5 move the surrounding prose:

- the `--level` bullet under Clone and run: `href="#levels"` → `href="config.html#levels"`
- the `learner off` / `on` entry under On demand: `href="#off"` → `href="config.html#off"`

Tasks 4 and 5 therefore have no link edit to make for these two.

Two edits inside the moved content:

1. In the seven-key table, the `untrackGlobs` row's Effect cell reads `Extra paths excluded from quiz material`. Link the last two words:

```html
<tr><td><code>untrackGlobs</code></td><td>array of globs</td><td><code>[]</code></td><td>Extra paths excluded from <a href="safety.html#material">quiz material</a></td></tr>
```

2. In `Turning it off`, item 2, the `(see <a href="#looks-like">above</a>)` link becomes:

```html
    (see <a href="index.html#looks-like">above</a>) is a different kind of change: it temporarily
```

`config.html` has two `<h2>`s (Levels, Turning it off), so it gets **no** table of contents.

- [ ] **Step 4: Cut those blocks out of `index.html` and extend its menu**

1. Delete the three sections just moved, including the `<h2 id="config">Configuration</h2>` line itself.
2. Prune `index.html`'s table of contents to the six sections that remain — drop the `#config`, `#levels` and `#off` entries. Six is still four or more, so the list stays.
3. In `index.html` **and** `safety.html`, replace the menu's `<ul>` with the three-entry version, keeping each page's own `aria-current`:

```html
  <ul>
    <li><a href="index.html">Home</a></li>
    <li><a href="config.html">Configuration</a></li>
    <li><a href="safety.html">Safety</a></li>
  </ul>
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`
Expected: `Failed: 0`.

If `config.html's menu matches index.html's` fails, the `<ul>` was updated in one file and not the other — that is exactly the drift this assertion exists to catch.

- [ ] **Step 6: Check the three pages in a browser**

Run: `open docs/index.html docs/config.html docs/safety.html`
Expected: three entries in the menu on all three pages, in the same order. On `config.html`, the `untrackGlobs` row's "quiz material" link lands on `safety.html`'s "What counts as quiz material" heading, and `Turning it off` item 2's "above" link lands on the `fill` demo on `index.html`.

- [ ] **Step 7: shellcheck**

Run: `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add docs/config.html docs/index.html docs/safety.html test.sh
git commit -m "feat(site): split out config.html

Configuration, Levels and Turning it off. The Configuration <h2> is dropped and
its id moves to the <h1>: a page that opens with a heading repeating its own
title is not a section, and the anchor still lands where it always did.

The seven keys, the seven defaults read out of LEARNER_DEFAULTS, the five level
letters and 'learner off' now pin to config.html. CLAUDE_CONFIG_DIR and
learner-config.sh stay on index.html until the install page exists."
```

---

## Task 4: Carve out `install.html`

The only page long enough to earn a local table of contents. Its four `<h3>`s are promoted to `<h2>`s, because with the redundant `<h2>Install</h2>` gone, `h1 Install > h2 Requirements` is the correct outline and `h1 > h2 Install > h3 Requirements` is not.

**Files:**
- Create: `docs/install.html`
- Modify: `docs/index.html` — delete the Install section and the Platforms section; extend the menu
- Modify: `docs/config.html`, `docs/safety.html` — extend the menu
- Modify: `test.sh` — extend `PAGES`; add `SITE_INSTALL`; repoint the one-liner, `CLAUDE_CONFIG_DIR`, `learner-config.sh`, and all six platform assertions

**Interfaces:**
- Consumes: the chrome from Task 2; `config.html#levels` from Task 3.
- Produces: `install.html` with `id="install"` on the `<h1>` and new ids `requirements`, `one-line`, `clone`, `installed` on the promoted headings, plus `id="platforms"`. Task 6 links the README at this page.

- [ ] **Step 1: Write the failing assertions in `test.sh`**

Set:

```sh
PAGES="index install config safety"
SITE_INSTALL="$ROOT/docs/install.html"
```

Repoint:

- the one-liner cross-check at line 818 — this is the assertion that keeps the README and the site from drifting, so it must name the page that actually carries the command:

```sh
{ grep -qF "$ONELINER" "$RM" && grep -qF "$ONELINER" "$SITE_INSTALL"; } \
  && ok "the install one-liner is identical in the README and on install.html" \
  || ko "the install one-liner is identical in the README and on install.html"
```

- the two-string loop from Task 3:

```sh
for s in CLAUDE_CONFIG_DIR 'learner-config.sh'; do
  grep -qF "$s" "$SITE_INSTALL" \
    && ok "install.html documents $s" \
    || ko "install.html documents $s"
done
```

- every platform assertion — today lines 1104–1132: the `WSL` / `Git Bash` loop, `native windows`, `posix`, the two `<tr>` row checks, and the row-states-the-reason check. Change `"$SITE"` to `"$SITE_INSTALL"` in all six and reword their messages from "the site" to "install.html". Leave the patterns themselves untouched, including the comments explaining why the row-shaped patterns exist alongside the prose ones.

After this task `SITE` has no content assertions left pointing at it — only the `[ -f "$SITE" ]` existence check at line 999, which stays.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^FAIL|^Passed'`
Expected: failures for every `install.html` assertion, the chrome loops for that page, and the menu-count check, which now wants four entries.

- [ ] **Step 3: Create `docs/install.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Install — Claude Learner</title>
<meta name="description" content="What Claude Learner needs, the two ways to install it, what lands where, and which platforms can run it.">
<link rel="stylesheet" href="assets/style.css">
</head>
<body>

<nav class="site" aria-label="Sections">
  <a class="brand" href="index.html">Claude Learner</a>
  <ul>
    <li><a href="index.html">Home</a></li>
    <li><a href="install.html" aria-current="page">Install</a></li>
    <li><a href="config.html">Configuration</a></li>
    <li><a href="safety.html">Safety</a></li>
  </ul>
</nav>

<main>

  <h1 id="install">Install</h1>
  <p class="lede">What Learner needs, the two ways in, what lands where, and which
  platforms can run it.</p>

  <nav class="toc" aria-labelledby="toc-title">
    <p class="toc-title" id="toc-title">On this page</p>
    <ol>
      <li><a href="#requirements">Requirements</a></li>
      <li><a href="#one-line">One line</a></li>
      <li><a href="#clone">Clone and run</a></li>
      <li><a href="#installed">What gets installed, and where</a></li>
      <li><a href="#platforms">Platforms</a></li>
    </ol>
  </nav>

  <h2 id="requirements">Requirements</h2>

  <!-- MOVE HERE, verbatim: the <ul> of five requirement bullets that follows
       <h3>Requirements</h3> in index.html. The last bullet's `<a href="#platforms">`
       stays as it is — Platforms is on this page too. -->

  <h2 id="one-line">One line</h2>

  <!-- MOVE HERE, verbatim: everything under <h3>One line</h3> — the <pre> with the
       one-liner, the paragraph about what it asks, the --level/--synthesis/--blanks
       <pre>, the LEARNER_REF paragraph, its <pre>, and the closing paragraph. The
       one-liner inside the first <pre> is byte-compared against the README, so do
       not rewrap or reindent it. -->

  <h2 id="clone">Clone and run</h2>

  <!-- MOVE HERE, verbatim: everything under <h3>Clone and run</h3> — the paragraph,
       the <pre> of four ./install.sh invocations, the <ul> of six flags, and the two
       closing paragraphs about idempotence and hook wiring. -->

  <h2 id="installed">What gets installed, and where</h2>

  <!-- MOVE HERE, verbatim: everything under <h3>What gets installed, and where</h3> —
       the $CFG paragraph, the <div class="scroll"> table of eleven paths, and the
       closing paragraph about five hook files and four wired. -->

  <!-- MOVE HERE, verbatim: the whole <h2 id="platforms">Platforms</h2> section from
       index.html, heading included. -->

  <p class="next">Next: <a href="config.html">Configuration</a> — every setting Learner
  reads.</p>

</main>

<footer>
  <p><a href="https://github.com/Tykok/learning-with-claude">github.com/Tykok/learning-with-claude</a>
  — issues and pull requests welcome.</p>
  <p><a href="https://github.com/Tykok/learning-with-claude/blob/main/LICENSE">GPL-3.0-or-later</a>
  — copyleft, so a fork stays free. Using Learner on your own code does not affect your code's
  licence; only redistributing a modified Learner does. This site is five hand-written files
  and one stylesheet: no build step, no tracking, and no request to anywhere when you open
  it.</p>
</footer>
</body>
</html>
```

The "next" link names `config.html`, not `usage.html`, on purpose: `usage.html` does not exist until Task 5, and a link to it would fail the internal-link assertion — which is what that assertion is for. Task 5 Step 4 repoints it.

One edit inside the moved content: in `Clone and run`, the `--level` bullet's `<a href="#levels">levels table</a>` becomes `<a href="config.html#levels">levels table</a>`.

- [ ] **Step 4: Cut those blocks out of `index.html` and extend every menu**

1. In `index.html`, delete the whole Install section — the `<h2 id="install">Install</h2>` line, its four `<h3>` subsections and all their content — and the whole Platforms section.
2. Prune `index.html`'s table of contents to the four sections that remain — drop the `#install` and `#platforms` entries. Four is still four or more, so the list stays.
3. In `index.html`, `config.html` and `safety.html`, replace the menu's `<ul>` with the four-entry version, keeping each page's own `aria-current`:

```html
  <ul>
    <li><a href="index.html">Home</a></li>
    <li><a href="install.html">Install</a></li>
    <li><a href="config.html">Configuration</a></li>
    <li><a href="safety.html">Safety</a></li>
  </ul>
```

3. `index.html`'s lede ends "It installs once at Claude Code user level and is then active in every git repository you open, with no per-repo setup." Leave the sentence alone, but its `<p class="sub">` no longer sits above an Install section on the same page. Add nothing: the "next" link and the menu both lead there, and §4 of the spec forbids new prose.

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`
Expected: `Failed: 0`. `install.html`'s table of contents is now checked against its five `<h2>` ids in order — if that assertion fails, an id was misspelled or the list is out of document order.

- [ ] **Step 6: Check the four pages in a browser**

Run: `open docs/index.html docs/install.html docs/config.html docs/safety.html`
Expected: four menu entries everywhere. On `install.html`, all five table-of-contents links jump within the page, the `--level` bullet's "levels table" link lands on `config.html`, and the Requirements bullet's "Platforms" link stays on the page.

- [ ] **Step 7: shellcheck**

Run: `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add docs/install.html docs/index.html docs/config.html docs/safety.html test.sh
git commit -m "feat(site): split out install.html

Requirements, both install paths, the files table and the platform table. The
redundant Install <h2> is dropped, its id moves to the <h1>, and its four <h3>s
are promoted: h1 Install > h2 Requirements is a correct outline, h1 > h2 Install
> h3 Requirements is not. Five sections earns the page the only local table of
contents on the site.

The README/site one-liner cross-check follows the command to install.html, as do
the six platform assertions. No content assertion points at index.html any more."
```

---

## Task 5: Carve out `usage.html`

The last carve. After it, `index.html` is the landing page and nothing else.

**Files:**
- Create: `docs/usage.html`
- Modify: `docs/index.html` — delete the question-styles and On demand sections; rewrite the `#commands` link in the lede; extend the menu; repoint the "next" link
- Modify: `docs/install.html`, `docs/config.html`, `docs/safety.html` — extend the menu; `install.html`'s "next" link becomes `usage.html`
- Modify: `test.sh` — extend `PAGES`; add `SITE_USAGE`; repoint the subcommand loop

**Interfaces:**
- Consumes: the chrome from Task 2; `config.html#off` from Task 3.
- Produces: `usage.html` with `id="styles"` and `id="commands"`.

- [ ] **Step 1: Write the failing assertions in `test.sh`**

Set:

```sh
PAGES="index install usage config safety"
SITE_USAGE="$ROOT/docs/usage.html"
```

Repoint the subcommand loop (today lines 1072–1086) to `"$SITE_USAGE"`, keeping the `DISPATCH`/`SUBCOMMANDS` derivation and both comments verbatim — the point of that block is that it reads the subcommand list out of `skills/learner/SKILL.md` rather than hard-coding it:

```sh
for sub in $SUBCOMMANDS; do
  # Bounded on the right: an unanchored `grep -F "learner $sub"` passes on any prose
  # that happens to contain the substring — "the learner once told me…" satisfies
  # "learner on" with no `on` subcommand in sight. Space or punctuation (a closing
  # `<`, in practice) after the word; end of line covers a subcommand as the last
  # word on its line.
  grep -qE "learner ${sub}([[:space:][:punct:]]|\$)" "$SITE_USAGE" \
    && ok "usage.html documents the 'learner $sub' subcommand" \
    || ko "usage.html documents the 'learner $sub' subcommand"
done
```

`learner off` is asserted twice on purpose after this task — on `usage.html` by this loop, because that is where the subcommand is documented, and on `config.html` by Task 3's string loop, because that is where the three ways to disable Learner are explained. Both are true and both should stay true.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^FAIL|^Passed'`
Expected: one failure per subcommand in the dispatch table, plus `usage.html`'s chrome assertions, plus the menu-count check wanting five entries.

- [ ] **Step 3: Create `docs/usage.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Usage — Claude Learner</title>
<meta name="description" content="The three shapes a Claude Learner question can take, and what you can ask the learner skill for directly.">
<link rel="stylesheet" href="assets/style.css">
</head>
<body>

<nav class="site" aria-label="Sections">
  <a class="brand" href="index.html">Claude Learner</a>
  <ul>
    <li><a href="index.html">Home</a></li>
    <li><a href="install.html">Install</a></li>
    <li><a href="usage.html" aria-current="page">Usage</a></li>
    <li><a href="config.html">Configuration</a></li>
    <li><a href="safety.html">Safety</a></li>
  </ul>
</nav>

<main>

  <h1>Usage</h1>
  <p class="lede">The three shapes a question can take, and what you can ask Learner
  for directly.</p>

  <!-- MOVE HERE, verbatim: the whole <h2 id="styles">The three question styles</h2>
       section — the <dl> of three styles, the questionStyles paragraph, and the
       paragraph about the language of the questions. -->

  <!-- MOVE HERE, verbatim: the whole <h2 id="commands">On demand</h2> section —
       its intro paragraph and the <dl> of subcommands. -->

  <p class="next">Next: <a href="config.html">Configuration</a> — every setting
  Learner reads.</p>

</main>

<footer>
  <p><a href="https://github.com/Tykok/learning-with-claude">github.com/Tykok/learning-with-claude</a>
  — issues and pull requests welcome.</p>
  <p><a href="https://github.com/Tykok/learning-with-claude/blob/main/LICENSE">GPL-3.0-or-later</a>
  — copyleft, so a fork stays free. Using Learner on your own code does not affect your code's
  licence; only redistributing a modified Learner does. This site is five hand-written files
  and one stylesheet: no build step, no tracking, and no request to anywhere when you open
  it.</p>
</footer>
</body>
</html>
```

One edit inside the moved content: in the `On demand` `<dl>`, the `learner off` / `learner on` entry's `<a href="#off">Turning it off</a>` becomes `<a href="config.html#off">Turning it off</a>`.

`usage.html` has two `<h2>`s, so **no** table of contents.

- [ ] **Step 4: Cut those blocks out of `index.html` and finish every menu**

1. In `index.html`, delete both sections just moved.
2. **Delete** `index.html`'s table of contents outright, `<nav class="toc" …>` through `</nav>`. It has carried a shrinking list since Task 2; the page is now down to its final two sections, and the four-or-more rule turns a surviving list red. The menu is the navigation from here.
3. Rewrite the lede's `#commands` link:

```html
  should work on (<a href="usage.html#commands">read it back</a> any time with
```

4. Repoint `index.html`'s "next" link, which pointed at `safety.html` since Task 2:

```html
  <p class="next">Next: <a href="install.html">Install</a> — what Learner needs, and
  the two ways in.</p>
```

5. Repoint `install.html`'s "next" link to the page it was always meant to name:

```html
  <p class="next">Next: <a href="usage.html">Usage</a> — the three shapes a question
  takes.</p>
```

6. In all five pages, the menu's `<ul>` becomes the final five-entry version, each page keeping its own `aria-current`:

```html
  <ul>
    <li><a href="index.html">Home</a></li>
    <li><a href="install.html">Install</a></li>
    <li><a href="usage.html">Usage</a></li>
    <li><a href="config.html">Configuration</a></li>
    <li><a href="safety.html">Safety</a></li>
  </ul>
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`
Expected: `Failed: 0`.

- [ ] **Step 6: Verify the carve is complete**

Run:

```bash
grep -c '<h2' docs/index.html docs/install.html docs/usage.html docs/config.html docs/safety.html
wc -l docs/*.html docs/assets/style.css
```

Expected `<h2>` counts: `index.html` 2, `install.html` 5, `usage.html` 2, `config.html` 2, `safety.html` 3 — twelve headings hosting the eleven original sections plus the promoted `material`. If `index.html` reports anything but 2, a section was left behind.

- [ ] **Step 7: Check all five pages in a browser**

Run: `open docs/index.html docs/install.html docs/usage.html docs/config.html docs/safety.html`
Expected: five menu entries in the same order on all five, each marking itself. Walk the whole "next" chain Home → Install → Usage → Configuration → Safety → Home. Check both themes. Check phone width on `install.html`, the widest page (the eleven-row files table and the four-column config table both scroll inside their own panel).

- [ ] **Step 8: shellcheck**

Run: `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add docs/usage.html docs/index.html docs/install.html docs/config.html docs/safety.html test.sh
git commit -m "feat(site): split out usage.html, completing the carve

The three question styles and the on-demand subcommands. index.html is now the
landing page and nothing else: pitch, the problem, and the demo.

The subcommand loop still derives its list from the dispatch table in
skills/learner/SKILL.md and now reads usage.html, so a seventh subcommand added
later still fails the suite rather than shipping undocumented. 'learner off' is
asserted on two pages on purpose: usage.html documents the subcommand,
config.html documents the three ways to disable Learner."
```

---

## Task 6: Update the README

**Files:**
- Modify: `README.md` lines 18–19, 42, 82

**Interfaces:**
- Consumes: `docs/install.html` and `docs/config.html` from Tasks 3–4.
- Produces: nothing other tasks depend on. This is the last task.

- [ ] **Step 1: Fix the "single hand-written file" claim**

Replace, at lines 18–19:

```markdown
subcommands, and uninstall are all documented there. It is a single hand-written file, so
`docs/index.html` in a clone reads identically offline. This README only gets you installed.
```

with:

```markdown
subcommands, and uninstall are all documented there, across five pages joined by a menu. They
are hand-written HTML sharing one stylesheet, so `docs/` in a clone reads identically offline.
This README only gets you installed.
```

- [ ] **Step 2: Repoint the two deep links**

At line 42, the POSIX-shell requirement bullet: `[the site](docs/index.html)` → `[the site](docs/install.html)`.

At line 82, the `--level` bullet: `[the site](docs/index.html)` → `[the site](docs/config.html)`.

Both sentences otherwise stay as written. The "README links to the site" assertion is satisfied by its `github.io` branch, so neither edit turns it red — but confirm that in Step 3 rather than assuming it.

- [ ] **Step 3: Run the full suite**

Run: `./test.sh 2>&1 | tail -3`
Expected: `Failed: 0`.

- [ ] **Step 4: Confirm no stale link to the old single page survives**

Run: `grep -rn 'docs/index.html' README.md docs/ .github/`
Expected: no output. Any hit is a link that should now name a specific page. (`design/` is excluded on purpose: those documents record what was decided at the time and must not be rewritten.)

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(readme): follow the site's split into five pages

The site stopped being a single file, so the claim that it is one had to go, and
the two deep links now name the pages that hold what they promise: platforms on
install.html, the levels table on config.html."
```

---

## Self-Review

**Spec coverage** — every section of the spec maps to a task:

| Spec | Task |
|---|---|
| §1 layout: five flat `.html` files plus `assets/style.css` | 1 (stylesheet), 2–5 (pages) |
| §2 shared chrome: `<head>`, `<nav>`, `<footer>` copied per page | 2 introduces, 3–5 extend |
| §2 CSS to one sheet; `<link>` assertion rescoped to `https?:`/`//` | 1 |
| §2 `aria-current` per page; menu scrolls under ~30rem; footer sentence rewritten | 2 |
| §3 content distribution table (five pages, ids preserved) | 2 (safety), 3 (config), 4 (install), 5 (usage) |
| §3 the six cross-links | 2 (`#guardrail`), 3 (`#looks-like`, new `#material`), 4 (`#levels`, `#platforms` unchanged), 5 (`#commands`, `#off`) |
| §3 additions: lede per page, per-page toc, "next" chain | 2–5 (lede, next), 4 (the toc) |
| §3 removal: the 11-entry table of contents | 2 |
| §3 the `untrackGlobs` → `safety.html#material` link | 3 |
| §4 constraints (no JS, both themes, responsive, one h1, readable without CSS) | 1 (CSS, h1 loop), 2 (structural assertions) |
| §5 repointing table, all twelve rows | 2 (safety-owned, removed-key loop, licence loop), 3 (config-owned), 4 (install-owned, one-liner), 5 (subcommands) |
| §5 new assertion 1–2 (menu identical, `aria-current`) | 2 |
| §5 new assertion 3 (one h1 per page) | 1 (loop introduced), 2–5 (extended by `PAGES`) |
| §5 new assertion 4 (internal links resolve) | 2 |
| §5 new assertion 5 (no external request per page and in the stylesheet) | 1 |
| §6 the README's three edits | 6 |

**Two deviations from the spec, both deliberate and both stated in the tasks that make them:**

1. **The per-page table of contents lands on `install.html` only.** The spec says each page gets one. Once the redundant `<h2>` duplicating a page title is dropped, `index.html`, `usage.html` and `config.html` have two sections each and `safety.html` has three — a two-entry "On this page" is decoration, not navigation. Task 2 encodes the rule as an assertion instead of a habit: a page with four or more `<h2>`s must carry a table of contents matching its section ids in order, and a shorter page must not carry one. A future page with four sections gets one automatically.
2. **`install.html`'s four `<h3>`s are promoted to `<h2>`s** (Task 4). The spec's content table does not mention heading levels. The promotion follows from dropping the `<h2>Install</h2>` that repeated the page title, and it is what makes the five-entry table of contents the approved design showed.

**Placeholder scan** — the `<!-- MOVE HERE -->` comments in Tasks 2–5 are move instructions naming exact line ranges and exact boundary sentences, not content to invent; the prose they move already exists and §4 of the spec forbids rewriting it. Every new line of markup, CSS and shell in this plan is written out in full. No step says "handle errors appropriately" or "write tests for the above".

**Type consistency** — `PAGES`, `page_path`, `STYLE`, `EXTERNAL` and `nav_links` are defined once (Tasks 1–2) and used with the same names and shapes afterwards. `SITE_SAFETY`, `SITE_CONFIG`, `SITE_INSTALL`, `SITE_USAGE` follow one naming pattern, each introduced in the task that creates its page. `SITE` keeps its meaning throughout — `docs/index.html` — and by the end of Task 4 carries only the existence check. Page basenames in `PAGES` match the filenames in the menu and the `aria-current` assertion's `$p.html` comparison.
