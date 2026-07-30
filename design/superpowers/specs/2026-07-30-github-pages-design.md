# Claude Learner — a GitHub Pages site

Date: 2026-07-30
Status: approved design, not yet implemented

## Goal

Give Learner a page that both explains why it exists and documents how to use it, published
with GitHub Pages from `/docs` on `main`. The README becomes the short entry point and the site
becomes the reference.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | One hand-written HTML page, no generator, no Jekyll, no CDN. |
| 2 | Published from the `/docs` folder on `main`. |
| 3 | The site is both the pitch and the full reference. |
| 4 | The README keeps a description plus what you need before the site exists, and links out for the rest. |
| 5 | The internal design records move out of the published folder. |
| 6 | The anti-drift assertions follow the content they guard — they are repointed, never deleted. |

## Why not a generator

The project ships eleven text files and has no build step anywhere. A single page needs no
Jekyll theme, no npm, no Actions pipeline. Hand-written HTML also means the page can be opened
from disk and checked before it is published, which is the only way to see it at all while the
repo is private — a Jekyll build only ever runs on GitHub's side.

`docs/.nojekyll` makes GitHub serve the folder literally rather than running the file through
Jekyll, which would otherwise mangle anything that looks like Liquid syntax (`{{`, `{%`) in the
code samples.

## 1. Layout

```
docs/index.html        # the site: one page, inline CSS, no external requests
docs/.nojekyll         # serve literally, no Jekyll pass
design/superpowers/    # specs and plans, moved out of the published root
```

**The move matters for two reasons.** Publishing `/docs` makes everything under it reachable,
and `docs/superpowers/` holds the internal specs and plans — including candid accounts of
spec-level defects found during implementation. Beyond confidentiality, the published root
should hold the site and nothing else: a visitor who guesses `/superpowers/plans/…` should not
find an implementation plan where documentation is expected.

`design/` is not published and stays in the repository, so nothing is lost and git history
follows the files. This document is written in the old location and moves with its siblings — the
move is part of the implementation, not a prerequisite for it.

## 2. Page content

One page, in this order. Each section earns its place either by convincing a newcomer or by
answering a question a user actually has.

1. **What it is, in two sentences** — Claude Code quizzes you on the code it just wrote with
   you, at your level, and keeps a record of what to work on.
2. **The problem** — code arrives faster than understanding does. Reviewing what an agent wrote
   is easy to skip and hard to do well; a question you have to answer is not skippable.
3. **Install** — the one-liner first, the clone-and-run second.
4. **What it actually looks like** — the section that does the convincing. A real granular
   question, a real synthesis question, and a `fill` exercise shown as before/after source with
   the `// LEARNER-TODO` markers in place. Concrete beats description here: the `fill` style is
   the hardest thing to imagine from prose and the most distinctive thing the tool does.
5. **The three question styles** — `code`, `architecture`, `fill`.
6. **The guardrail** — why editing your real source is safe: leftovers only (a marker in the
   working tree that `HEAD` does not have), untracked files included, `disabledPaths` honoured,
   bounded per exercise.
7. **Configuration reference** — the seven keys, their values and defaults; the two layers,
   global then per-repo, project winning key by key.
8. **Levels** — the five letters and what each changes about a question.
9. **Platforms** — macOS, Linux, WSL, Git Bash; native Windows unsupported, with the reason.
10. **Turning it off** — the three ways: globally, per repo, or by path for a repo you do not own.
11. **Uninstall** — including `--project` for a repo left over from the per-project beta.

## 3. Design constraints

- **Self-contained.** All CSS inline in a `<style>` block, no web fonts, no external scripts,
  no analytics. A documentation page that cannot be read offline, or that phones home, is worse
  than a plain README.
- **Light and dark**, via `prefers-color-scheme`. No toggle, no JavaScript.
- **Responsive** with relative units; code blocks scroll inside their own container so the page
  body never scrolls sideways on a phone.
- **Readable without CSS.** Semantic headings and real `<table>` markup, so the content
  survives a reader mode or a text browser.
- System font stack — matches the terminal-adjacent subject and loads instantly.
- Accessible: one `<h1>`, headings in order, sufficient contrast in both themes, and every code
  sample in `<pre><code>`.

## 4. The README's new shape

Keeps, because a reader needs them at the moment of acting and the site may not be reachable:

- what Learner is, in short
- the install commands
- Requirements (`jq`, `bash`, a POSIX shell, Claude Code)
- Development (`./test.sh`, the shellcheck line)
- the licence and badges

Moves to the site: the full configuration table, the levels table, the question-style detail,
the guardrail mechanics, the files-installed table, the platform table, the three ways to
disable, and uninstall.

Gains a prominent link to the site near the top.

**Sequencing note.** While the repository is private, GitHub Pages cannot publish on a free
plan, so the site is unreachable and the README is the only entry point. That is why install and
Requirements stay put: slimming those out now would leave a hole with nothing on the other side
of the link.

## 5. The anti-drift contract

`test.sh` currently pins about a dozen facts in the README so documentation cannot silently
diverge from the code. That net already caught a real defect — the README's shellcheck line
falling out of sync with CI. Moving content without moving its assertion would quietly remove
the net.

So every assertion whose subject moves is **repointed at `docs/index.html`**, and the site gains
its own:

| Assertion | Target after this change |
|-----------|--------------------------|
| the seven config keys are documented | `docs/index.html` |
| the letter levels appear as table rows | `docs/index.html` |
| the platform table rows (WSL, Git Bash, native Windows) | `docs/index.html` |
| `learner off` is documented | `docs/index.html` |
| the `--project` uninstall flag is documented | `docs/index.html` |
| no removed config key (`language`, `trackGlobs`, `recapEvery`, `trouBlanks`) appears | both README and `docs/index.html` |
| the one-liner and `LEARNER_REF` are documented | README (install stays there) |
| the Development shellcheck line matches `ci.yml` | README |
| `bash` is listed as a requirement | README |

New assertions for the site:

- the install command on the site is byte-identical to the README's, so the two cannot drift
- `docs/.nojekyll` exists — without it a Liquid-looking code sample breaks the build
- the page issues no external request at load. Checking only `<script`, `<link href>` and
  `@import` is not enough: an `@font-face { src: url(https://…) }` needs none of the three, so
  a page could grow a web-font request (banned by §3) with that check staying green. The
  assertion also has to cover `<img`, `<iframe`, `<embed`, `<object`, `srcset`, and `url(...)`
  scoped to an `http`/`https` scheme — the last scoping is deliberate, so a local
  `url(#fragment)` or a `data:` URI, neither of which is a request, is not a false positive.
  Ordinary `<a href="https://github.com/…">` links are navigation, not requests, and are
  expected — the assertion must target the tags/properties that fetch, not every URL.
- exactly one `<h1>`

Patterns use bracket expressions or `-F`, never a backslash before an ordinary character: an
undefined ERE escape already produced a bug on this repo that passed under ugrep and failed
under GNU grep.

## 6. Publishing

Once the repository is public (or on a plan that allows Pages for private repositories), enable
Pages with source `main` / `/docs`. Nothing in the site depends on being served from a domain,
so `file://docs/index.html` renders identically — which is how it gets reviewed before it is
live.

## Out of scope

- **A custom domain**, and therefore `docs/CNAME`.
- **Multiple pages.** One page covers this surface; splitting it invites the duplication this
  design exists to avoid.
- **Screenshots or asciicasts.** They would need regenerating every time the output changes, and
  the output here is text that HTML renders faithfully.
- **A dark/light toggle.** `prefers-color-scheme` needs no JavaScript and respects the reader's
  choice.
- **Making the repository public.** The owner's decision; this design only states the dependency.

## Traceability

| Request | Section |
|---------|---------|
| A GitHub Pages site explaining the skill | 1, 2 |
| Landing page, detail on the site, description in the README | 2, 4 |
| Hand-written HTML/CSS | 1, 3 |
| Published from `/docs` on `main` | 1, 6 |
| Both convince and document | 2 |
