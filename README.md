# Claude Learning Mode

[![CI](https://github.com/Tykok/learning-with-claude/actions/workflows/ci.yml/badge.svg)](https://github.com/Tykok/learning-with-claude/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Claude Code](https://img.shields.io/badge/Claude%20Code-hooks%20%2B%20skill-8A63D2)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25?logo=gnu-bash&logoColor=white)

Turn any repo into a **learning loop**. While Claude Code writes code with you, it
periodically stops to quiz you on what was just built — at your level, in your language —
and keeps a per-developer record of your weak spots and progress. Language- and
stack-agnostic.

## What it does

- **SessionStart** — if unconfigured, asks your level and writes `.claude/learner.local.json`.
- **After edits** — records which source files were touched this session.
- **On Stop** — blocks once and asks Claude to pose **one** question about the code just
  written (or a periodic **synthesis** question across the whole session).
- **`learner` skill** — on-demand: `quiz` (Q&A on the branch diff), `status` (what to
  improve), `improve` (coach a weak spot to mastery), `config` (settings).

Three question styles: `code` (what a function does), `archi` (which module/layer/why),
`trou` (interactive fill-in — Claude blanks part of a real function, you write it back
in-editor, Claude restores + validates).

## Requirements

- **jq** on `PATH` (the hooks use it; without it they are inert and the SessionStart hook says so).
- POSIX `sh` — **macOS / Linux / WSL**. Native Windows (no `sh`) is not supported.

## Install

```bash
./install.sh /path/to/your/repo      # or run with no arg inside the target repo
```

This copies the skill + hooks into `<repo>/.claude/`, merges the hook wiring into
`.claude/settings.json` (idempotent — safe to re-run), and gitignores the per-dev files.

Then start a new Claude Code session — the SessionStart hook prompts for your level — or run
`learner config`.

## Files installed

| Path | Role | Committed? |
|------|------|-----------|
| `.claude/skills/learner/SKILL.md` | The `learner` skill (quiz/status/improve/config) | yes |
| `.claude/hooks/learner-onboard.sh` | SessionStart: onboard/level prompt | yes |
| `.claude/hooks/learner-record-edit.sh` | PostToolUse: record edited files | yes |
| `.claude/hooks/learner-quiz.sh` | Stop: pose the quiz question | yes |
| `.claude/settings.json` | Hook wiring (merged) | yes |
| `.claude/learner.local.json` | Your settings (level, language, styles…) | **no** (gitignored) |
| `.claude/learner-memory.md` | Working memory: open weak spots (drives questions) | **no** |
| `.claude/learner-recap.md` | Readable dashboard: to-improve / mastered / history | **no** |

## Settings (`.claude/learner.local.json`)

| Key | Values | Default | Effect |
|-----|--------|---------|--------|
| `level` | `junior`\|`intermediaire`\|`senior` | — (required) | Question difficulty |
| `enabled` | bool | `true` | Master switch for the Stop-hook quiz |
| `recapEvery` | int ≥ 1 | `3` | A synthesis question every N quiz |
| `questionStyles` | `"auto"` or subset of `code`/`trou`/`archi` | `"auto"` | Allowed formats |
| `language` | `fr`\|`en` | `fr` | Language of the questions |
| `trouBlanks` | int ≥ 1 | `2` | Holes left in a `trou` exercise |
| `trackGlobs` | array of globs | multi-language source globs | Which edited files count as quiz material |

See `learner.local.json.example`. Changes take effect on the next quiz (hooks re-read the
file every time — no restart).

## Uninstall

Remove the three `.claude/hooks/learner-*.sh` files, the `.claude/skills/learner` folder,
the three `learner-*` blocks from `.claude/settings.json`, and the per-dev files. Or set
`"enabled": false` to keep everything but silence the automatic quiz.

## Development

```bash
./test.sh                                   # hook + installer tests (needs jq, git)
shellcheck --severity=warning hooks/*.sh install.sh test.sh
```

CI (`.github/workflows/ci.yml`) runs both on every push and PR.

## License

[MIT](./LICENSE) © Tykok
