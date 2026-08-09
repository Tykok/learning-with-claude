# Claude Learner — a real Claude Code plugin

Date: 2026-08-09
Status: approved design, not yet implemented

## Goal

Every learner user is, by definition, already a Claude Code user — it's the one thing the
curl one-liner, the clone, the Homebrew tap and the apt repository can't assume about anyone
else's machine. Claude Code has its own native extension mechanism (plugins, installed via
`/plugin install`) built for exactly this. Ship learner through it, as the new default,
most-native path in.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | Self-hosted marketplace, same repo (`Tykok/learning-with-claude`), same pattern as the existing brew tap and apt repo — no second repo. `.claude-plugin/marketplace.json` lists one plugin, `source: "./"`. |
| 2 | Reuse the existing `hooks/*.sh` and `skills/learner/` directories verbatim — confirmed by reading their actual content that every hook already resolves its shared helper via `$(dirname "$0")` (self-relative) and reads user data via `$CLAUDE_CONFIG_DIR` (install-method-independent), so nothing about them needs to change for the plugin path. |
| 3 | The plugin wires 4 of the existing 5 hooks — `learner-onboard.sh`, `learner-record-edit.sh`, `learner-quiz.sh`, `learner-cleanup.sh`. `learner-update-check.sh` is deliberately **not** wired: Claude Code's own plugin manager already tracks and surfaces updates for a plugin install, and a second, independent "a new version is out" notifier would be redundant and could disagree with it. |
| 4 | `learner update` and `learner status` become plugin-aware: when the running skill can see it was loaded from a plugin location (its own base directory contains `/plugins/`), they defer to `/plugin update learner` / Claude Code's own version display instead of reading `$CFG/skills/learner/VERSION` (which a plugin-only install never creates) or curl-bootstrapping a parallel traditional install on top of the plugin. |
| 5 | Doc order becomes: **Claude Code plugin** (new, first) → apt → Homebrew → clone-and-run → curl one-liner (alternative, last). |
| 6 | Verification is real, not read-only: `claude --plugin-dir .` locally (hooks actually fire, the skill actually loads) and `claude plugin validate .` (the same check Anthropic's own review pipeline runs), both run for real before this is considered done — matching how the apt work was verified with real Docker installs rather than code review alone. |
| 7 | Submitting to the community marketplace (`claude-community`, reviewed, public) is **out of scope for implementation** — it's a web form (`platform.claude.com/plugins/submit` for an individual author), not something a git commit or a script can do. This design ships everything needed to submit and documents the steps; the human partner submits it themselves, whenever they choose. |

## 1. Plugin manifest — `.claude-plugin/plugin.json`

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

`version` is kept in sync with the repo-root `VERSION` file by hand, the same manual discipline
the project already applies to `VERSION`-vs-git-tag (§6 adds a CI guard, the same shape as the
existing tag-vs-`VERSION` one). `author` uses the GitHub profile URL rather than an email, the
same choice already made for `Formula/learner.rb`'s `Maintainer` field, for the same reason —
no personal address baked into a file that ships to strangers.

No `hooks` key here — hooks live in the separate `hooks/hooks.json` file (§2), matching how the
existing `hooks/settings.snippet.json` already keeps hook wiring in its own file rather than
inline in a manifest.

## 2. Hook wiring — `hooks/hooks.json`

A new file, sitting beside the six existing hook scripts (not replacing
`hooks/settings.snippet.json`, which `install.sh` still uses for the curl/clone/brew/apt path —
these are two different consumers of the same underlying scripts):

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

Byte-for-byte the same shape as the corresponding four entries in
`hooks/settings.snippet.json`, with `${CLAUDE_PLUGIN_ROOT}` standing in for
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}` — the only thing that differs between "where the code
lives" across every install method this project ships. `learner-config.sh` (sourced-only,
never wired directly, per the existing convention) needs no entry here, same as it has none in
`settings.snippet.json`. `learner-update-check.sh` is the one entry deliberately not present —
decision #3.

## 3. The marketplace — `.claude-plugin/marketplace.json`

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

Same pattern as the "caveman" plugin (inspected directly, real file): a single-plugin
marketplace whose one entry uses `source: "./"` to mean "the plugin lives at this same repo's
root" — no separate plugin repo, no git-subdir indirection.

## 4. `learner update` / `learner status` become plugin-aware

Both currently read `$CFG/skills/learner/VERSION`, a file only `install.sh` ever writes — a
plugin-only install never runs `install.sh` at all, so that file never exists for a plugin
user, and `learner update`'s existing origin-check (curl/brew/apt, defaulting to `curl` when
no marker is present) would wrongly curl-bootstrap a second, traditional install right on top
of a working plugin install if invoked as-is.

Both protocols gain one check, run first, before anything else: does this skill's own base
directory (the path Claude was told this `SKILL.md` was loaded from) contain `/plugins/`? If
so:

- **`learner status`**: report the level as normal (still read from `$CLAUDE_CONFIG_DIR`,
  install-method-independent), and for the version, say "managed by Claude Code — see
  `/plugin` for the installed version" instead of reading a `VERSION` file that doesn't exist.
- **`learner update`**: stop immediately, before touching curl or `$CFG/skills/learner/VERSION`
  at all, and tell the dev: "Installed as a Claude Code plugin. Run `/plugin update learner`
  (or `claude plugin update learner`) instead — Claude Code manages this install's version."

This is the same shape as the brew/apt origin-check already in `references/update.md` (curl
origin proceeds as today; brew/apt origins defer to their own package manager) — a fourth
origin, detected structurally (the skill's own load path) rather than from a marker file,
because a plugin install has no file of its own to write one into.

## 5. Docs

`README.md` and `docs/install.html`'s Install sections gain a new first entry, ahead of apt:

```markdown
### Claude Code plugin

```bash
claude plugin marketplace add Tykok/learning-with-claude
claude plugin install learner
```

Installs and enables the skill and its hooks natively — no `~/.claude` file copying, no
`learner-install` step. Claude Code manages updates itself (`/plugin update learner`); run
`learner update` and it will tell you the same thing rather than trying to curl a second,
traditional install on top.
```

`docs/install.html` gets a matching `<h2 id="plugin">` section in the same position (first,
before `#apt`), and the page's TOC gains the matching `<li>` in the same position — the
existing generic structural test (h2-order-vs-TOC-order equality) covers this automatically,
same as every prior reorder this project has done.

`README.md`'s Requirements section needs no new bullet: the plugin path needs nothing beyond
Claude Code itself — no `jq`, no `bash`, no `curl` at install time (the hooks still need a
POSIX shell and `jq` at *run* time, same as every other install path, already covered by the
existing bullets).

## 6. CI guard: `plugin.json`'s version matches `VERSION`

Same shape as the existing tag-vs-`VERSION` guard in `.github/workflows/ci.yml`, run
unconditionally (not just on a tag push, since a mismatch is wrong on every commit, not only
at release time):

```yaml
      - name: plugin.json version matches VERSION
        run: |
          PLUGIN_VERSION=$(jq -r '.version' .claude-plugin/plugin.json)
          FILE="$(cat VERSION)"
          if [ "$PLUGIN_VERSION" != "$FILE" ]; then
            echo "plugin.json version ($PLUGIN_VERSION) does not match VERSION file ($FILE)"; exit 1
          fi
```

## 7. Real verification (decision #6)

Both run locally against a checkout of this repo, output captured and read, not assumed:

1. `claude --plugin-dir .` — start a session with the plugin loaded from the working tree.
   Confirm: the skill is listed (as `learner` or `learner:learner` under Custom commands /
   `/help`), a `SessionStart` message about level/jq appears if applicable, editing a file and
   ending the turn triggers the `Stop` hook's quiz block the same way the traditionally
   installed version does.
2. `claude plugin validate .` — the same structural/safety check Anthropic's own community
   marketplace review pipeline runs before approving a submission. Must print
   `✔ Validation passed` (warnings are acceptable and non-blocking per Anthropic's own docs,
   but should be read and understood, not ignored blindly).

## 8. Community marketplace submission (decision #7 — human partner does this manually)

Not a task in the implementation plan below — a short note for whoever runs it, once the
plugin is live on `main`:

1. Run `claude plugin validate .` one more time against the released commit; confirm
   `✔ Validation passed`.
2. Go to [platform.claude.com/plugins/submit](https://platform.claude.com/plugins/submit) (the
   Console form — the claude.ai form at `claude.ai/admin-settings/directory/submissions` needs
   a Team/Enterprise org with directory-management access, which this project doesn't have).
3. Point it at `Tykok/learning-with-claude`. Anthropic's review pipeline re-runs the same
   validation plus automated safety screening.
4. If approved, the plugin is pinned to a specific commit SHA in
   `anthropics/claude-plugins-community`'s catalog; CI there bumps the pin automatically on
   later pushes. The public catalog syncs nightly, so there's a delay between approval and the
   plugin actually showing up for `claude plugin marketplace add anthropics/claude-plugins-community`
   users to find. Check by searching the name in that repo's `.claude-plugin/marketplace.json`.
5. This is entirely separate from, and does not replace, decision #1's self-hosted marketplace
   — `claude plugin marketplace add Tykok/learning-with-claude` keeps working regardless of
   whether the community submission is ever made or approved.

## Known limitations

- **`/learner:learner` namespacing.** Claude Code namespaces plugin skills as
  `<plugin-name>:<skill-folder-name>`; since both are `learner`, the skill's explicit slash
  form is the slightly redundant `/learner:learner`. Not fixed — renaming `skills/learner/`
  just for this would touch a directory every other install path also depends on, for a purely
  cosmetic `/help` listing. The skill's actual trigger mechanism (natural-language matching
  against `SKILL.md`'s frontmatter description — "quiz me", "learner status", etc.) is
  unaffected either way; nobody types the slash form to use learner day to day.
- **No automated end-to-end plugin install test.** `claude --plugin-dir`/`claude plugin
  validate` are run by hand once, the same category of gap the apt work already has for
  `brew install` (no Homebrew runner in CI) — noted, not solved, consistent with prior
  precedent on this project rather than a new gap invented here.
- **The community marketplace submission can't be automated or verified by this session** —
  decision #7. Whether it's ever submitted, and when, is entirely the human partner's call.

## Files touched

| File | Change |
|---|---|
| `.claude-plugin/plugin.json` | new — §1 |
| `.claude-plugin/marketplace.json` | new — §3 |
| `hooks/hooks.json` | new — §2 |
| `skills/learner/references/update.md` | plugin-origin branch — §4 |
| `skills/learner/SKILL.md` | plugin-aware status line — §4 |
| `README.md` | new install section, first — §5 |
| `docs/install.html` | new section + TOC entry, first — §5 |
| `.github/workflows/ci.yml` | new guard step — §6 |
| `test.sh` | assertions below |

## Tests

1. **`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` are valid JSON** and
   contain the expected keys (`name`, `version`, `source: "./"` for the one plugin entry).
2. **`hooks/hooks.json` is valid JSON**, wires exactly the four intended events, and every
   `command` references `${CLAUDE_PLUGIN_ROOT}` and one of the four intended scripts — and
   does **not** reference `learner-update-check.sh` (decision #3, a negative assertion so a
   future edit can't silently re-add it).
3. **`plugin.json`'s `version` matches the root `VERSION` file** — mirrors the existing
   tag-vs-`VERSION` CI guard's own `test.sh` coverage.
4. **`update.md` and `SKILL.md` both mention the plugin-path detection and `/plugin update`**
   — content assertions, same style as the existing brew/apt origin-branch checks.
5. **README/install.html ordering**: the plugin section's marker comes before the apt
   section's marker, in both files — same positional-assertion style already used for
   apt-before-Homebrew-before-clone-before-curl.
6. **`install.html`'s TOC-matches-h2-order check** — existing generic test, needs no new code,
   only for the new section + TOC entry to actually satisfy it.
7. **CI shape**: the new `plugin.json version matches VERSION` step's presence and exact guard
   logic, read back out of `ci.yml`, same style as the existing tag-vs-`VERSION` shape check.

Everything above runs in `test.sh` with no network access, consistent with the rest of the
suite. Decision #6's real verification (`claude --plugin-dir`, `claude plugin validate`) is
run once by hand during implementation, documented in the task's report, not added as a
permanent `test.sh` case — the same treatment the apt work gave its own real-container
end-to-end check.

## Out of scope

- **Submitting to the community marketplace.** Decision #7 — documented, not automated; the
  human partner's call, on their own schedule.
- **The official `claude-plugins-official` marketplace.** Curated by Anthropic at their sole
  discretion; confirmed directly from their own docs that there is no application process for
  it — the community-marketplace submission form does not add plugins there.
- **Renaming `skills/learner/` to avoid the `/learner:learner` namespace.** Known limitation,
  not a defect — see above.
- **A plugin-specific update-check hook** (e.g. one that calls `claude plugin update` itself
  automatically). Decision #3 rules out *any* independent update notifier for the plugin path;
  Claude Code's own plugin manager already owns that signal.

## Traceability

| Request | Section |
|---|---|
| Rendre learner installable via le CLI Claude (plugin) | 1–3 |
| L'ajouter à la documentation | 5, 8 |
