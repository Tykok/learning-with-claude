# Claude Learning Mode

[![CI](https://github.com/Tykok/learning-with-claude/actions/workflows/ci.yml/badge.svg)](https://github.com/Tykok/learning-with-claude/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](./LICENSE)
![Claude Code](https://img.shields.io/badge/Claude%20Code-hooks%20%2B%20skill-8A63D2)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25?logo=gnu-bash&logoColor=white)

Turn Claude Code into a **learning loop**. While it writes code with you, it periodically
stops to quiz you on what was just built, at your level, and keeps a per-developer record of
your weak spots and progress. Stack-agnostic. One install, active in every git repo you open
with Claude Code — no per-repo setup.

## What it is

**The full reference lives on the site:
[tykok.github.io/learning-with-claude](https://tykok.github.io/learning-with-claude/)** —
question styles, config keys and defaults, levels, platforms, the `fill` guardrail, on-demand
subcommands, and uninstall are all documented there, across five pages joined by a menu. They
are hand-written HTML sharing one stylesheet, so `docs/` in a clone reads identically offline.
This README only gets you installed.

Fifteen POSIX `sh` hooks plus nine skills — a `learner` hub, one per subcommand (`quiz`,
`status`, `improve`, `coach`, `export`, `sync`, `update`) and `pilot`, invocable as `/learner:quiz` and
friends in a plugin install: `SessionStart` flags a broken install and, on a
second entry, notifies once a day when a newer version is out; `PostToolUse` records edited
files, and `Stop` blocks once per turn to ask one question —
`code`, `architecture`, or `fill` (Claude cuts `// LEARNER-TODO` holes in a real function for
you to fill back in; a guardrail keeps a crashed exercise from ever leaving the tree broken).
The only file Learner ever *adds* to a repository is `.claude/learner.local.json`, written by
`learner off` / `on` / `config project …` on request; a `fill` exercise temporarily edits one
of your own source files instead. Everything else lives under your Claude Code config
directory.

## Coach mode — you write, Claude challenges

The default regime has Claude write the code and quiz you afterwards. Coach mode inverts it:
you write the code, and Claude watches your working tree and comes back when you pause to
challenge you — one question on a small diff, up to three on a large one (three arrive one at
a time; fewer arrive together) — plus findings and leads, never a patch.

```
learner coach on
```

From then on, Claude is **denied** write access to your source: a `PreToolUse` hook refuses any
`Write` or `Edit` outside the slice you hand it explicitly.

```
learner coach delegate 'src/**/repository/**'
```

Now Claude writes the repositories — the layer that looks the same in every project — and you
write the service and the business logic. Both regimes feed the same record: Claude quizzes you
on what it wrote, the coach challenges you on what you wrote, and `learner status` sees all of
it.

A review fires when you pause typing: the watcher polls your working tree, and once it has
seen enough consecutive quiet polls with at least `coachMinLines` changed since the last
review, it fires — floored by `coachCooldownMinutes` so short pauses don't turn into a run of
interruptions, and forced anyway past `coachMaxWaitMinutes` so a long uninterrupted stretch
still gets reviewed. The review itself is sized by the diff: one question on a small change, up
to three on a large one — one or two arrive together, three are asked one at a time — plus
findings and leads. Zero changes for `coachIdleMinutes` and the watcher stops itself and asks
whether you want to continue. Tune all of this with the seven `coach*` keys — see the site's
[Configuration](https://tykok.github.io/learning-with-claude/config.html) page.

Coach mode needs an interactive Claude Code session: the watcher runs as a `Monitor`, which
does not exist in `claude -p`, in a subagent or in a cloud session. The write refusal still
applies everywhere, since it is an ordinary hook.

## Pilot — a delegation score, read from the transcript

Pilot is a separate, **opt-in** skill that scores how much of the thinking on a task you
handed to Claude versus did yourself — direction, verification, contradiction and how much
of the code you actually wrote — rolled into a rolling index and a profile you watch move
over weeks. It never asks you a question to produce that score: everything comes from the
sessions you already had, read straight from the transcript, never from a quiz written to
test you.

```
learner pilot on
```

Pilot is **off by default** (`pilotEnabled: false`) and fully **local**: it reads every
prompt you have typed, in every repository — including ones where the automatic quiz above
is switched off — and that is not something a tool should do without being asked first. The
transcript itself is referenced by path and never copied.

- **Contained.** `disabledPaths` is honoured for Pilot too — a repository listed there is
  never read, exactly as it already isn't for the quiz.
- **Reversible.** The quotes kept as evidence are capped at 200 characters each, and
  `learner pilot forget --all` purges every one of them, any time.

Pilot measures a habit, not you: **it is not a measure of intelligence and not a measure of
cognitive health.** It scores how much thinking gets handed over, nothing else — full
reference, including the four axes, the weekly brief and the privacy paragraph, on
[the site](https://tykok.github.io/learning-with-claude/usage.html#pilot).
## Sync — carry your record between machines

`learner sync` moves your learning record — `memory.md`, `recap.md`, `libs.md` and the global
`learner.json` — between machines through one private GitHub gist. It is the only path that
ever sends the record off the machine, and it is **manual only**: no hook pushes anything;
nothing leaves until you type it.

```
learner sync push            # snapshot the local record to the gist
learner sync pull [gist]     # merge the gist back in; name a gist the first time on a new machine
learner sync status          # what's pushed, what isn't, whether the remote moved ahead
learner sync use <gist>      # repoint this machine at a different gist
```

The first `push` asks before creating the gist, and creates it `--secret`. A secret gist is
**unlisted, not access-controlled**: anyone who has the URL can read it, without a GitHub
account. It carries your repo names, file names and the wording of your weak spots, plus
`pushedFrom` (this machine's hostname), `learner.json`'s `disabledPaths` (absolute local
paths) and `events.jsonl` (the text of every question you were asked and each repo's absolute
path) — treat the link like a password.

A `pull` backs up the local record first, under
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner/backups/<timestamp>/`, then three-way merges
`memory.md` (a line you deleted here because you mastered it stays deleted, even if the other
side still has it), unions the `Session history` table, and lets Claude merge the theme
sections. `learner export` (Notion) is unchanged by any of this — it stays the human-readable
view, not a restore path; the gist carries the raw state.

Requires `gh`, authenticated (`gh auth login`). Habit worth keeping: `learner sync push` before
you switch machines, so the record you left behind is the one you pick back up.
## Agent salvo — questions while the subagents work

When Claude hands work to subagents, the main conversation would otherwise go quiet. Instead it
owes you a short burst per dispatched agent: two questions about the delegation, the diff and
your open weak spots, then one fill-in exercise cut in your own code by a dedicated agent while
you answer. Three agents dispatched at once earn three salvos, served one per turn; the moment
the last agent returns, the rest are dropped.

    learner config agentSalvo=false     # off
    learner config agentSalvoQuestions=1
    learner config agentSalvoFill=false # questions only

In coach mode the salvo is questions-only: the exercise would need a write, and the coach gate
denies it. If your client runs subagents synchronously, the salvo lands just after the result
instead of during the wait — the questions are still asked.

## Requirements

- **`jq`** on `PATH`. Required to install (the hook-wiring merge needs it) and required by
  every hook at run time except the update-check notifier, which has no `jq` dependency by
  design — without it the rest are inert, and `SessionStart` says so.
- **`bash`** on `PATH` to install, by either path: `install.sh` is a bash script, and the
  one-liner checks for `bash` up front rather than fetching a payload it could not hand over.
  This is separate from the shell the hooks need, below.
- **`curl`** on `PATH` — needed once for the apt repository's trust-anchor setup, and for the
  one-line install further below. **`tar`** is needed for the one-line install only. Neither is
  needed by the clone-and-run path.
- **`curl` is also used at run time**, by the update-check hook only, to look for a newer
  version once every 24h. Its absence there is silent, not an error — unlike `jq`, `curl` is
  never a hard requirement for anything already installed.
- **Installed via Homebrew or apt?** Use `learner-install` / `learner-uninstall` instead of
  `install.sh` / `uninstall.sh` — same flags, just staged by the package rather than a clone.
- **A POSIX-compliant shell to run the hooks** — a run-time requirement, not an install-time
  one, and not `bash`: the hooks are plain `sh` scripts, wired into `settings.json` as
  `sh "$CFG/hooks/…"`. Which platforms provide one, and which do not, is on
  [the site](docs/install.html).
- **Claude Code** installed (`claude` on `PATH`, or an existing config directory).

## Install

### Claude Code plugin

```bash
claude plugin marketplace add Tykok/learning-with-claude
claude plugin install learner@learning-with-claude
```

Installs and enables the skills and their hooks natively — no `~/.claude` file copying, no
`learner-install` step. Claude Code manages updates itself (`/plugin update learner`); run
`learner update` and it will tell you the same thing rather than trying to curl a second,
traditional install on top. Already installed via curl, clone, Homebrew, or apt? Run
`uninstall.sh` (or `learner-uninstall`) first — running both wires every hook twice.

### apt (Debian/Ubuntu)

```bash
# one time
curl -fsSL https://tykok.github.io/learning-with-claude/apt/learner.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/learner.gpg
echo "deb [signed-by=/usr/share/keyrings/learner.gpg] https://tykok.github.io/learning-with-claude/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/learner.list

# from then on
sudo apt update && sudo apt install learner
learner-install --level S --synthesis normal --blanks 2
```

One `curl` remains — fetching the repository's trust anchor once, the same pattern Docker's
and HashiCorp's own apt repos use. There is no keyless way to establish that first trust, but
after this one-time step, `sudo apt update && sudo apt upgrade learner` is the whole update
story — no more `curl` involved, ever.

Prefer not to add a repository? Grab the `.deb` directly from
[Releases](https://github.com/Tykok/learning-with-claude/releases) instead:

```bash
curl -LO https://github.com/Tykok/learning-with-claude/releases/download/v0.3.0/learner_0.3.0_all.deb
sudo apt install ./learner_0.3.0_all.deb
learner-install --level S --synthesis normal --blanks 2
```

(`v0.3.0` is this release. Check [Releases](https://github.com/Tykok/learning-with-claude/releases)
for the current version if you're reading this after a newer one has shipped.)

### Homebrew (macOS or Linux)

```bash
brew install tykok/tap/learner
learner-install --level S --synthesis normal --blanks 2
```

A personal tap ([Tykok/homebrew-tap](https://github.com/Tykok/homebrew-tap)), not homebrew-core. Each tagged release updates it.

Both apt and Homebrew only stage the files and drop `learner-install`/`learner-uninstall` on
`PATH` — neither touches `~/.claude` by itself; run `learner-install` afterward, same flags
`install.sh` takes below. Uninstalling reverses the same way: `sudo apt remove learner` /
`brew uninstall learner` only remove those two wrapper binaries — the payload under
`~/.claude` still needs `learner-uninstall` (same as `uninstall.sh`) to actually come out.

### Clone and run

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
  [the site](docs/config.html), in any case.
- `--synthesis off|rare|normal|often` — how often a synthesis question replaces a granular one.
- `--blanks N` — holes left in a `fill` exercise (integer ≥ 1).
- `--dry-run` — print what would be written; write nothing.
- `--yes` (`-y`) — never prompt; fill in anything not passed with its default.

The installer is idempotent: re-running re-copies the hooks and the skills and re-merges the
hook wiring into `settings.json` without duplicating entries, and it never overwrites an
existing config. **It writes nothing into any repository** — every path it touches sits under
`$CLAUDE_CONFIG_DIR` (default `~/.claude`), and every hook command it wires into
`settings.json` carries the literal `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, so moving your
config directory later needs no reinstall.

### Alternative: the curl one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh
```

It asks for your level, how often you want a synthesis question, and how many holes a `fill`
exercise leaves — then writes everything under your Claude Code config directory; this is what
it fetches and runs under the hood. To skip the prompts, pass the same flags `install.sh`
takes; `bootstrap.sh` forwards them through unchanged:

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

`LEARNER_REF` pins the payload, not `bootstrap.sh` itself — your shell has already read that
from the URL by the time the variable is visible. Pinning only one of the two still runs
whatever `main` says, which is why the ref appears in both places.

On trust: the fetch is plain HTTPS from `codeload.github.com`, and `LEARNER_REF` pins the
payload to an exact ref rather than tracking `main`. Be clear about what that does *not* cover —
`LEARNER_REF` says nothing about `bootstrap.sh` itself, which the first form above still fetches
from `/main/`, so pinning only the payload still runs whatever `main` says today. That is why the
pinned form names the ref in the URL as well. A checksum baked into `bootstrap.sh` would not add
anything either way — the script and the archive it fetches share an origin, so anyone able to
change one can change the other. If that boundary matters to you, the clone-and-run path above
never crosses it: you read `install.sh` before you run it.

One more thing: the hook wiring is read when a Claude Code session starts, so installing while
a session is already open changes nothing in it — quit and start a new session afterward.

## Development

```bash
./test.sh                                                     # hook + installer + skill tests
shellcheck --severity=warning plugins/learner/hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh scripts/bump-formula.sh packaging/deb/build.sh packaging/apt-repo/assemble-site.sh
```

The `plugins/learner/hooks/*.sh` glob covers all fifteen shipped hook files, including `learner-config.sh`. CI
(`.github/workflows/ci.yml`) runs both commands, byte for byte as written above, on every push
to `main` and every pull request — an assertion in `test.sh` reads that workflow file and
keeps the two in step. CI also runs `claude plugin validate` on the marketplace, on the
plugin, and on a copy of the repository root with the marketplace manifest removed — that
last one because `validate` picks the marketplace manifest whenever both sit in
`.claude-plugin/`, and would otherwise pass a root plugin that is plainly broken. Only the
first two are what the community-marketplace review pipeline runs on a submission; a broken
root fallback is ours to catch, not theirs.

The plugin payload lives in `plugins/learner/`, but the repository root is a valid plugin
too: `.claude-plugin/plugin.json` there delegates its skills to the payload, and
`hooks/hooks.json` carries the same wiring with the extra path segment. That exists for one
reason — the community marketplace pins an approved plugin to a commit SHA and advances that
pin as commits land, and this repository was submitted while its plugin root *was* the
repository root. Both files are derived from the payload's own, and `test.sh` re-derives them
and compares, so neither can drift.

## License

[GPL-3.0-or-later](./LICENSE) © Tykok

Copyleft: a fork stays free. If you distribute a modified version of Learner, you distribute
it under the GPL too, with its source. Using Learner on your own code does **not** affect your
code's licence — running a program over your files never makes those files derivative works.
Only redistributing a modified Learner triggers the obligation.
