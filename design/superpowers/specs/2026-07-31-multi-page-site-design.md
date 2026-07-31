# Claude Learner — splitting the site into five pages

Date: 2026-07-31
Status: approved design, not yet implemented

## Goal

Turn the single 757-line `docs/index.html` into a navigable site: five pages, one per subject a
reader actually arrives with, joined by a menu present on every page. The content is already
good; what is missing is a way to find a part of it without scrolling past the rest.

## Relationship to the previous design

This supersedes two decisions in
[`2026-07-30-github-pages-design.md`](2026-07-30-github-pages-design.md):

- its locked decision #1, "one hand-written HTML page"
- its out-of-scope entry "**Multiple pages.** One page covers this surface; splitting it invites
  the duplication this design exists to avoid."

The rest of that document still holds — published from `/docs` on `main`, no generator, no
Jekyll, no external request, both pitch and full reference, and the anti-drift assertions
follow the content they guard. The concern behind the rejected entry is answered rather than
dismissed: the duplication a split introduces is the shared chrome, and §5 turns it into a
tested invariant instead of a hope.

That document stays in place. It records what was decided on 2026-07-30 and rewriting it would
falsify the record.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | Five thematic pages, flat `.html` files, hand-written, no build step. |
| 2 | CSS moves to one shared `docs/assets/style.css`. |
| 3 | A horizontal menu on every page, plus a per-page table of contents. |
| 4 | Existing prose moves unchanged; the only new prose is navigational. |
| 5 | Every pinned fact is repointed at the page that owns it, not at a concatenation. |
| 6 | The site stays in English. |

## 1. Layout and URLs

```
docs/
  index.html          Home
  install.html        Install
  usage.html          Usage
  config.html         Configuration
  safety.html         Safety
  assets/style.css    the shared sheet, one copy
  .nojekyll           unchanged
```

Flat `.html` files, not `install/index.html`. An `href="install/"` under `file://` does not open
`index.html` — the browser shows a directory listing or fails outright. Reading the site from
disk before it is published is a property the original design bought deliberately, and it is
how these pages get reviewed. Extensionless URLs would cost it, and are not worth that.

`index.html` keeps its name: GitHub Pages serves it at the root.

## 2. The shared chrome

Three blocks are copied into all five files: `<head>`, `<nav>`, `<footer>`.

**CSS.** The ~180 lines currently inline in `index.html` move verbatim to
`docs/assets/style.css`, plus the new rules for the menu, the per-page table of contents and the
"next" link. Each page carries `<link rel="stylesheet" href="assets/style.css">`.

This has one consequence for the test suite. The existing "no external request at load"
assertion bans `<link[^>]+href` outright, so a local stylesheet would turn it red. The pattern
is rescoped to an `http`/`https` scheme, exactly as the `url(...)` branch beside it already is.
This tightens the check toward its stated intent rather than weakening it: a
`<link href="https://…">` — a web font, a CDN sheet — stays red, and a relative local path,
which issues no external request, no longer trips it.

**Menu.** Five links in a fixed order: Home, Install, Usage, Configuration, Safety. The link for
the current page carries `aria-current="page"`, so the block is deliberately **not**
byte-identical across pages. The testable invariant is therefore narrower than "identical
bytes" and is stated in §5.

Below ~30rem the bar scrolls horizontally rather than collapsing into a burger — a burger needs
JavaScript or a checkbox hack, and five short labels do not need either.

**Footer.** Identical on all five pages, with one sentence rewritten: "This page is a single
hand-written file" stops being true at five files and one stylesheet.

No JavaScript anywhere, on any page.

## 3. Content distribution

| Page | Sections, in order | `id`s |
|---|---|---|
| `index.html` | h1, lede, sub · The problem · What it actually looks like (granular, synthesis, `fill`, the note) | `problem`, `looks-like` |
| `install.html` | Requirements · One line · Clone and run · What gets installed, and where · Platforms | `install`, `platforms` |
| `usage.html` | The three question styles · On demand | `styles`, `commands` |
| `config.html` | Configuration (two layers, the seven-key table, the full JSON example) · Levels · Turning it off | `config`, `levels`, `off` |
| `safety.html` | The guardrail · What counts as quiz material · Uninstall | `guardrail`, `material`, `uninstall` |

Every existing `id` is reused unchanged, so a link already in circulation — the README, an
issue, a bookmark — survives the split with only its filename changed. `material` is new: the
"What counts as quiz material" section is currently an `<h3>` with no `id` and needs one to be
linkable from the config table.

`index.html`'s Install section is not duplicated; the lede links to `install.html`.

### Cross-links to rewrite

`index.html` carries seventeen internal `href="#…"` today: eleven are the table of contents being
deleted, and six are cross-references inside the prose. Those six are the ones that need
rewriting, five of them across a page boundary:

| Source page and place | Was | Becomes |
|---|---|---|
| Home lede, "read it back" with `learner status` | `#commands` | `usage.html#commands` |
| Home, the `fill` note — "read it before you install" | `#guardrail` | `safety.html#guardrail` |
| Install, the `--level` bullet under Clone and run | `#levels` | `config.html#levels` |
| Usage, the `learner off` / `on` entry under On demand | `#off` | `config.html#off` |
| Config, Turning it off, item 2 — "a `fill` exercise (see above)" | `#looks-like` | `index.html#looks-like` |
| Install, the POSIX-shell bullet under Requirements | `#platforms` | unchanged, same page |

Plus one link that does not exist yet: the `untrackGlobs` row of the config table gains an
`href="safety.html#material"`, for the reason in "One deliberate oddity" below.

### What is added

- One `<p class="lede">` on each of the four new pages: a single sentence saying what the page
  answers, so a reader arriving from a search result does not land cold on an inherited `<h2>`.
  `index.html` already has a lede and a `.sub`; both stay as they are.
- A per-page `.toc` listing that page's `<h2>`s — the existing component, at four or five
  entries instead of eleven.
- A `<p class="next">` at the foot of each page. The chain is Home → Install → Usage →
  Configuration → Safety, and Safety points back to Home.

### What is removed

`index.html`'s eleven-entry table of contents. The menu plus the per-page one replace it.

### One deliberate oddity

"What counts as quiz material" explains `untrackGlobs`, a key documented on `config.html`, but
lives on `safety.html`. That is on purpose: the section's subject is what Learner will and will
not touch on your disk, which is the safety page's subject. The `untrackGlobs` row in the config
table links across to it.

## 4. Constraints carried over

Unchanged from the previous design, and still binding on every page:

- Self-contained: no web fonts, no external scripts, no analytics, no request off-origin.
- Light and dark via `prefers-color-scheme`, now living in `style.css`. No toggle, no JS.
- Responsive; code blocks and wide tables scroll inside their own container so the page body
  never scrolls sideways.
- Readable without CSS — which now matters more than before, since the CSS is a separate file
  that could fail to load. Semantic headings, real `<table>` markup, `<nav>` for the menu.
- One `<h1>` per page, headings in order, sufficient contrast in both themes.
- System font stack.

## 5. The anti-drift contract

`test.sh` pins about forty facts to `docs/index.html`. Splitting the file breaks all of them, and
repointing them at a concatenation of the five pages would keep them green while losing what
they are for: a fact that silently migrated to the wrong page would go unnoticed. So each fact is
repointed at the page that owns it, and the facts belonging to the shared chrome are required on
all five.

### Repointing

| Pinned fact | Target |
|---|---|
| the install one-liner is byte-identical to the README's | `install.html` |
| `learner-config.sh`, `CLAUDE_CONFIG_DIR` | `install.html` |
| `WSL`, `Git Bash`, `posix`, native Windows unsupported, the WSL and native-Windows table rows, the native-Windows row stating the POSIX reason | `install.html` |
| the `learner <sub>` subcommands, derived from the dispatch table in `skills/learner/SKILL.md` | `usage.html` |
| the seven config keys' names; the seven defaults read out of `LEARNER_DEFAULTS` in `hooks/learner-config.sh`, matched in the Default column of the table | `config.html` |
| `untrackGlobs`, `disabledPaths`, `synthesisFrequency`, `blanksPerExercise`, `learner off` | `config.html` |
| the five level letters as `<td><code>D</code></td>` cells | `config.html` |
| `LEARNER-TODO`; "working tree" together with `HEAD`; `--project`; `--purge` | `safety.html` |
| no removed key or old level (`recapEvery`, `trouBlanks`, `trackGlobs`, `"language"`, `intermediaire`) | all five pages, in a loop |
| `>GPL-3.0-or-later</a>`, `copyleft` | all five pages — it is footer text, so it holds everywhere or nowhere |
| `prefers-color-scheme` | `assets/style.css` |
| `.nojekyll` exists; `docs/superpowers` absent; `design/superpowers` present; the MIT scan over `docs/` | unchanged |

The MIT scan already targets the `docs/` directory rather than a file, so it covers the new
pages and the stylesheet with no change.

### New assertions

Five, all of them things a single page could not be asked:

1. **The menu cannot drift.** For each page, extract the ordered sequence of `href` values and
   link labels from `<nav class="site">`; require all five sequences to be identical. Comparing
   raw bytes would be wrong — `aria-current` differs by page — and comparing only the count of
   links would pass on five pages with five different link sets.
2. **`aria-current` is right.** On each page exactly one menu link carries `aria-current="page"`,
   and its `href` names that page's own file. Without the second half, all five pages could mark
   Home as current and the first assertion would still pass.
3. **Exactly one `<h1>` per page.** The existing occurrence-counting check, run per file. Run
   over a concatenation it would only prove the total is five, which a page with two and a page
   with none also satisfies.
4. **Every internal link resolves.** For each `href` in `docs/*.html` that names a local file
   and/or a fragment: the file exists, and the fragment exists as an `id` in the target file.
   This is what guards the six rewritten cross-links in §3, and the only assertion that catches
   an `id` deleted later.
5. **No external request, per page and in the stylesheet.** The existing pattern, with
   `<link[^>]+href` rescoped to an `http`/`https` scheme per §2, run over each of the five pages
   and over `assets/style.css`.

Patterns use bracket expressions or `-F`, never a backslash before an ordinary character: an
undefined ERE escape has already produced a bug in this repository that passed under ugrep and
failed under GNU grep.

## 6. The README

Three edits, no restructuring:

- The claim that the site "is a single hand-written file, so `docs/index.html` in a clone reads
  identically offline" becomes false. Reworded to five files plus a stylesheet, still readable
  offline from a clone.
- The platforms link, `docs/index.html` → `docs/install.html`.
- The levels-table link, `docs/index.html` → `docs/config.html`.

The "README links to the site" assertion is satisfied by its `github.io` branch and needs no
change. Install and Requirements stay in the README for the reason already settled in the
previous design: a reader needs them at the moment of acting.

## Out of scope

- **A French translation.** Everything shipped is in English and the repository is public. The
  site stays in English.
- **A generator, Jekyll, or npm.** Settled in §2 and in the previous design.
- **Extensionless URLs.** Settled in §1: incompatible with reading the site from disk.
- **JavaScript, a burger menu, search, a light/dark toggle.** `prefers-color-scheme` needs none
  of it and respects the reader's own setting.
- **A custom domain and `docs/CNAME`; screenshots or asciicasts; versioned documentation.**
- **New prose.** Existing text moves unchanged; the only additions are the lede, the per-page
  table of contents and the "next" link.

## Traceability

| Request | Section |
|---|---|
| A clean, usable GitHub Pages site | 1, 2, 3 |
| A menu | 2, 3, 5 |
| Separate pages per important section | 1, 3 |
| Keep the no-build, no-request, offline-readable properties | 1, 2, 4 |
| Keep the anti-drift net honest across the split | 5 |
