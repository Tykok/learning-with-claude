# Claude Learner — docs site redesign

Date: 2026-08-06
Status: approved, implemented

## Goal

The five-page docs site (`docs/*.html` + `docs/assets/style.css`) works but reads as
system-default styling rather than a considered design. Give it a more modern, more épuré
(clean/minimal) look without touching content, navigation, or the site's core promise: no
build step, no JS, no external request at load.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | Hard constraint, non-negotiable: zero external fonts/CDN/JS/build step. Pure CSS against the existing static HTML. |
| 2 | Visual-only. Same five pages, same content, same nav, same classes/ids. Only `docs/assets/style.css` changes. |
| 3 | The direction was chosen by process, not by hand: 5 independent AI-generated CSS directions, scored by 3 independent judges, the top 2 refined against judge feedback, both verified (self-containment + hand-computed WCAG AA contrast in light and dark) before either was shown to the human partner. |
| 4 | The human partner picked the winner from a live, real-markup preview (an Artifact rendering both finalists against actual site components, toggleable light/dark) — not from a description. |

## The five directions and how they scored

Each judged 0–10 by 3 independent judges (averaged), against: feels more modern/épuré than
plain system-default styling; readability for long-form technical prose with heavy inline
code; WCAG AA contrast in both light and dark (judges computed actual ratios, not just read
the file's own comments); internal consistency/polish; stays dev-documentation-appropriate
rather than drifting toward a marketing-landing-page feel.

| Direction | Score | One line |
|---|---|---|
| **Editorial minimal — winner** | **8.7** | Cool neutral surfaces, one restrained violet accent, a fluid type scale, a figcaption fused to its code block like a titlebar. |
| Mono-technical | 7.5 | Monospace-leaning headings, terminal cursor/pointer idioms, sharp corners, a cursor-green accent used only as a pointer. |
| Calm cards | 6.6 | Notion/Linear-docs inspired: soft accent, large rounded corners, near-borderless separation. |
| Stark contrast | 6.3 | Bold oversized headings, thick rules, near-monochrome with one loud accent. |
| Soft depth | 5.8 | Warm-neutral continuation of the old palette with a shadow/elevation system. |

## What shipped

`docs/assets/style.css` is replaced wholesale by the editorial-minimal candidate, refined
once against the judges' one substantive finding (a typo'd `*::as::after` selector had
silently disabled `box-sizing: border-box` everywhere — fixed to `*::after`), then verified:

- **Self-containment**: no `@import`, no `url(http…)`/`url(//…)`, no `@font-face` off-domain
  — grepped clean.
- **WCAG AA contrast**, hand-computed (relative-luminance formula, not approximated): every
  `--fg`/`--muted`/`--accent` pairing against every background it is actually painted on, in
  both the light block and the dark `@media (prefers-color-scheme: dark)` block. Worst case
  5.27:1 (light-mode accent on `--code-bg`), all clear of the 4.5:1 floor.
- **Selector coverage against the real site, not just the design workflow's kitchen-sink
  sample**: every class (`brand`, `hl`, `lede`, `next`, `note`, `scroll`, `site`, `sub`,
  `toc`, `toc-title`) and every tag actually used across all five real pages
  (`dl`/`dt`/`dd`, `figure`/`figcaption`, `table`/`th`/`td`, etc. — extracted by grep, not
  assumed) has a rule in the new file. `usage.html` and `safety.html` are `dl`-heavy and
  were not part of the kitchen sink shown to the design/judge/refine agents; both were
  spot-checked separately by rendering the real page against the shipped CSS.
- **`./test.sh`**: 364 passed, 0 failed — no HTML changed, so every structural assertion
  (h2-id/TOC ordering, "next" link, licence scan, SPDX tags) is unaffected by construction.

## Out of scope

- **Content, navigation, or page-count changes.** Explicitly ruled out — visual-only, locked
  decision #2.
- **The four runner-up directions.** Not discarded from history — captured in this doc and
  in the design-workflow's transcript — but not carried further.
- **A manual light/dark toggle.** The site has none today and this redesign doesn't add one;
  both themes still resolve from `prefers-color-scheme` only, per decision #1 (a toggle needs
  JS).

## Traceability

| Request | Outcome |
|---|---|
| Update the GitHub Pages site | `docs/assets/style.css` replaced |
| More modern, more épuré design | Editorial-minimal direction, chosen by scored multi-agent process, §"What shipped" |
