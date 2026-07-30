# Claude Learning Mode

[![CI](https://github.com/Tykok/learning-with-claude/actions/workflows/ci.yml/badge.svg)](https://github.com/Tykok/learning-with-claude/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Claude Code](https://img.shields.io/badge/Claude%20Code-hooks%20%2B%20skill-8A63D2)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25?logo=gnu-bash&logoColor=white)

Turn Claude Code into a **learning loop**. While it writes code with you, it periodically
stops to quiz you on what was just built, at your level, and keeps a per-developer record of
your weak spots and progress. Stack-agnostic. One install, active in every git repo you open
with Claude Code — no per-repo setup.

## What it is

**The full reference lives on the site: [docs/index.html](docs/index.html)** — question
styles, config keys and defaults, levels, platforms, the `fill` guardrail, and uninstall are
all documented there. This README only gets you installed.

Five POSIX `sh` hooks plus a `learner` skill: `SessionStart` flags a broken install,
`PostToolUse` records edited files, and `Stop` blocks once per turn to ask one question —
`code`, `architecture`, or `fill` (Claude cuts `// LEARNER-TODO` holes in a real function for
you to fill back in; a guardrail keeps a crashed exercise from ever leaving the tree broken).
The only thing that ever writes into a repository is `learner off` / `on` /
`config project …`, and only when you ask for it — everything else lives under your Claude
Code config directory.

## Requirements

- **`jq`** on `PATH`. Required to install (the hook-wiring merge needs it) and required by
  every hook at run time — without it they are inert, and `SessionStart` says so.
- **`bash`** on `PATH` to install, by either path: `install.sh` is a bash script, and the
  one-liner checks for `bash` up front rather than fetching a payload it could not hand over.
  This is separate from the shell the hooks need, below.
- **`curl` and `tar`** on `PATH` for the one-line install below; the clone-and-run path does
  not need them.
- **A POSIX-compliant shell to run the hooks** — a run-time requirement, not an install-time
  one, and not `bash`: the hooks are plain `sh` scripts, wired into `settings.json` as
  `sh "$CFG/hooks/…"`. Which platforms provide one, and which do not, is on
  [the site](docs/index.html).
- **Claude Code** installed (`claude` on `PATH`, or an existing config directory).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh
```

It asks for your level, how often you want a synthesis question, and how many holes a `fill`
exercise leaves — then writes everything under your Claude Code config directory. To skip the
prompts, pass the same flags `install.sh` takes; `bootstrap.sh` forwards them through unchanged:

```bash
curl -fsSL .../bootstrap.sh | sh -s -- --level S --synthesis normal --blanks 2
```

To install a specific revision instead of whatever `main` says today, name the ref twice — once
in the URL the shell runs, once in `LEARNER_REF` for the payload it fetches. `$REF` is anything
git resolves: a release tag, a branch name, or a commit SHA.

```bash
REF=v0.1.0   # or a branch name, or a commit SHA
curl -fsSL "https://raw.githubusercontent.com/Tykok/learning-with-claude/$REF/bootstrap.sh" \
  | LEARNER_REF="$REF" sh
```

Prefer to read the code before running it? Clone and use the installer directly — it stays a
first-class path, not a fallback:

```bash
git clone https://github.com/Tykok/learning-with-claude
cd learning-with-claude
./install.sh                                          # interactive prompt for level/synthesis/blanks
./install.sh --level S --synthesis normal --blanks 2  # non-interactive, one shot
./install.sh --dry-run                                # print what would happen, write nothing
./install.sh --yes                                    # never prompt; defaults for anything unset
```

- `--level D|J|C|S|E` — your level: the letter, or the full word from the levels table on
  [the site](docs/index.html), in any case.
- `--synthesis off|rare|normal|often` — how often a synthesis question replaces a granular one.
- `--blanks N` — holes left in a `fill` exercise (integer ≥ 1).
- `--dry-run` — print what would be written; write nothing.
- `--yes` (`-y`) — never prompt; fill in anything not passed with its default.

The installer is idempotent: re-running re-copies the hooks and the skill and re-merges the
hook wiring into `settings.json` without duplicating entries, and it never overwrites an
existing config. **It writes nothing into any repository** — every path it touches sits under
`$CLAUDE_CONFIG_DIR` (default `~/.claude`), and every hook command it wires into
`settings.json` carries the literal `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, so moving your
config directory later needs no reinstall.

On trust: the fetch is plain HTTPS from `codeload.github.com`, and `LEARNER_REF` pins the
payload to an exact ref rather than tracking `main`. Be clear about what that does *not* cover —
`LEARNER_REF` says nothing about `bootstrap.sh` itself, which the first form above still fetches
from `/main/`, so pinning only the payload still runs whatever `main` says today. That is why the
pinned form names the ref in the URL as well. A checksum baked into `bootstrap.sh` would not add
anything either way — the script and the archive it fetches share an origin, so anyone able to
change one can change the other. If that boundary matters to you, the clone-and-run path above
never crosses it: you read `install.sh` before you run it.

## Development

```bash
./test.sh                                                     # hook + installer + skill tests
shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh
```

The `hooks/*.sh` glob covers all five shipped hook files, including `learner-config.sh`. CI
(`.github/workflows/ci.yml`) runs both commands, byte for byte as written above, on every push
and PR — an assertion in `test.sh` keeps the two lists in step.

## License

[MIT](./LICENSE) © Tykok
