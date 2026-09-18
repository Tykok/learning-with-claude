# Learner

Turn Claude Code into a **learning loop**. While it writes code with you, it periodically stops
to quiz you on what was just built, at your level, and keeps a per-developer record of your weak
spots and progress. Stack-agnostic, and active in every git repo you open with Claude Code — no
per-repo setup.

This directory is the Claude Code plugin. The repository that holds it — installers for curl,
Homebrew and apt, the test suite, the site sources — is
[Tykok/learning-with-claude](https://github.com/Tykok/learning-with-claude).

## Install

```bash
claude plugin marketplace add Tykok/learning-with-claude
claude plugin install learner@learning-with-claude
```

Claude Code enables the skills and their hooks natively and manages updates itself
(`/plugin update learner`). Already installed via curl, clone, Homebrew or apt? Run that
install's `uninstall.sh` (or `learner-uninstall`) first — running both wires every hook twice.

## What you get

Nine skills, invocable as `/learner:<name>` or in plain language, in English or French:

| Skill | What it does |
|-------|--------------|
| `learner` | The hub: dispatch, the five levels, every config key, `learner off` / `on` / `config` |
| `quiz` | Quizzes you on the current branch's diff, one question at a time |
| `status` | Read-only summary of your record: level, version, coach status, open weak spots |
| `improve` | Coaches one recorded weak spot to mastery against this repo's real code |
| `coach` | Inverts the loop: you write the code, Claude only challenges it — never a patch |
| `pilot` | Opt-in delegation-habit tracking, scored from the transcript itself |
| `export` | Pushes the learning recap into a Notion database |
| `sync` | Carries the record between machines through one private gist |
| `update` | Checks for a newer version and refreshes the install |

Eight hooks drive the loop without you asking: `SessionStart` flags a broken install,
`PostToolUse` records edited files, and `Stop` blocks once per turn to ask one question —
`code`, `architecture`, or `fill`, where Claude cuts `// LEARNER-TODO` holes in a real function
for you to fill back in (a guardrail keeps a crashed exercise from leaving the tree broken).

## Configuration

Five levels — `D` (débutant), `J` (junior), `C` (confirmé), `S` (senior), `E` (expert) — set how
hard the questions get. Every key can be set globally or per project:

```
learner config level=S
learner off            # in this repo only
```

Full reference — question styles, every config key and its default, the `fill` guardrail,
platform notes and uninstall — lives at
**[tykok.github.io/learning-with-claude](https://tykok.github.io/learning-with-claude/)**.

## What it writes

The only file Learner ever adds to a repository is `.claude/learner.local.json`, and only when
you ask (`learner off` / `on` / `config project …`). A `fill` exercise temporarily edits one of
your own source files and restores it. Everything else — your record, the config, the queues —
lives under your Claude Code config directory (`~/.claude/learner/`). Nothing leaves the machine
unless you run `sync` or `export` yourself.

## License

GPL-3.0-or-later. See [LICENSE](./LICENSE).
