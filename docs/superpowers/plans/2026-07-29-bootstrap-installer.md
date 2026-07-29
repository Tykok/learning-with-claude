# One-Line Remote Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `bootstrap.sh` so Learner installs with one `curl … | sh`, and document which platforms that actually works on.

**Architecture:** `install.sh` is not self-contained — it copies eleven payload files and sources `hooks/learner-config.sh`. `bootstrap.sh` fetches the repo tarball into a temp dir, reopens `/dev/tty` so the interactive onboarding survives the pipe, then hands over to `install.sh` unchanged. The bootstrap owns no defaults and no validation; duplicating them would let the two drift.

**Tech Stack:** POSIX `sh` (`bootstrap.sh`), `bash` (`install.sh`, `test.sh`), `curl`, `tar`, `jq`, `git`.

**Spec:** [docs/superpowers/specs/2026-07-29-bootstrap-installer-design.md](../specs/2026-07-29-bootstrap-installer-design.md)

## Global Constraints

- `bootstrap.sh` is POSIX `sh` with `set -eu` — it runs before anything is known about the machine, so no bashisms, no arrays, no `local`, no process substitution, no `pipefail`.
- `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh` must exit 0. Suppress only with a targeted `# shellcheck disable=SCxxxx` plus a reason.
- `test.sh` must not touch the network. The fetch URL is overridable via `LEARNER_URL`; tests build a local tarball and pass a `file://` URL.
- The bootstrap adds **no options of its own**: every flag goes straight through to `install.sh`, which keeps sole ownership of defaults and validation.
- Canonical repo slug: `Tykok/learning-with-claude`. Default ref: `main`, overridable via `LEARNER_REF`.
- All content in English. Conventional Commits, English subjects ≤ 72 chars.
- **Never run `install.sh`, `uninstall.sh` or `bootstrap.sh` without an explicit throwaway `CLAUDE_CONFIG_DIR`.** Without it they operate on the real `~/.claude`.
- This branch is stacked on `feat/global-install` (PR #1). Do not rebase it; that happens after the PR merges.

## File Structure

| Path | Responsibility | Action |
|------|----------------|--------|
| `bootstrap.sh` | Preflight, fetch, TTY reconnect, hand over to `install.sh`. Nothing else. | Create |
| `test.sh` | New `bootstrap` section driven by a local `file://` tarball. | Modify |
| `README.md` | One-liner first, platform table, pinning, honest trust posture. | Modify |
| `.github/workflows/ci.yml` | `shellcheck` covers `bootstrap.sh`. | Modify |

---

### Task 1: `bootstrap.sh` and its tests

**Files:**
- Create: `bootstrap.sh`
- Modify: `test.sh` (new section before `# --- summary`)
- Modify: `.github/workflows/ci.yml:15`

**Interfaces:**
- Consumes: `install.sh`'s CLI — `--level D|J|C|S|E` (full words accepted), `--synthesis off|rare|normal|often`, `--blanks N`, `--dry-run`, `--yes`; and its preflight, which requires `jq` and Claude Code.
- Produces: `bootstrap.sh`, honouring `LEARNER_REF` (git ref, default `main`) and `LEARNER_URL` (full tarball URL, overrides `LEARNER_REF`; the test hook). Exit non-zero with a `error: …` line on stderr for every failure path.

- [ ] **Step 1: Write the failing tests**

Add a `skip` helper next to `ok`/`ko` (currently `test.sh:13-14`) — one assertion can only run where `/dev/tty` is unreadable:

```bash
skip() { printf '  skip - %s\n' "$1"; }
```

Then add this section immediately before `# --- summary`:

```bash
# --- bootstrap --------------------------------------------------------------
BOOT="$ROOT/bootstrap.sh"

# A tarball of the working tree, not `git archive`: the change under test must be
# covered before it is committed. Exactly one top-level directory, because the
# bootstrap strips one component.
TARBALL="$WORK/payload.tgz"
tar -czf "$TARBALL" -C "$(dirname "$ROOT")" "$(basename "$ROOT")"

boot() { CLAUDE_CONFIG_DIR="$1" LEARNER_URL="file://$TARBALL" sh "$BOOT" "${@:2}"; }

B1="$WORK/boot1"; mkdir -p "$B1"
boot "$B1" --level S >/dev/null 2>&1
{ [ -f "$B1/hooks/learner-config.sh" ] \
  && [ -f "$B1/hooks/learner-quiz.sh" ] \
  && [ -f "$B1/skills/learner/SKILL.md" ] \
  && [ -f "$B1/skills/learner/references/data.md" ] \
  && [ -f "$B1/learner.json" ]; } \
  && ok "bootstrap installs the payload from the tarball" \
  || ko "bootstrap installs the payload from the tarball"

B2="$WORK/boot2"; mkdir -p "$B2"
boot "$B2" --level senior --synthesis often --blanks 3 >/dev/null 2>&1
jq -e '.level == "S" and .synthesisFrequency == "often" and .blanksPerExercise == 3' \
  "$B2/learner.json" >/dev/null 2>&1 \
  && ok "bootstrap passes every flag through to install.sh" \
  || ko "bootstrap passes every flag through to install.sh"

B3="$WORK/boot3"; mkdir -p "$B3"
boot "$B3" --level S --dry-run >/dev/null 2>&1
[ ! -e "$B3/learner.json" ] \
  && ok "bootstrap honours --dry-run (nothing written)" \
  || ko "bootstrap honours --dry-run (nothing written)"

# Temp dirs must not accumulate: count what the bootstrap leaves behind.
before=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
B4="$WORK/boot4"; mkdir -p "$B4"
TMPDIR="$WORK/tmp" boot "$B4" --level S >/dev/null 2>&1
after=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$before" = "$after" ] \
  && ok "bootstrap removes its temp dir on success" \
  || ko "bootstrap removes its temp dir on success (before=$before after=$after)"

before=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
CLAUDE_CONFIG_DIR="$WORK/boot5" LEARNER_URL="file://$WORK/nope.tgz" \
  TMPDIR="$WORK/tmp" sh "$BOOT" --level S >/dev/null 2>&1
after=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$before" = "$after" ] \
  && ok "bootstrap removes its temp dir on a failed fetch" \
  || ko "bootstrap removes its temp dir on a failed fetch (before=$before after=$after)"

out=$(CLAUDE_CONFIG_DIR="$WORK/boot6" LEARNER_URL="file://$WORK/nope.tgz" \
  sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap fails on an unreachable URL" \
  || ok "bootstrap fails on an unreachable URL"
printf '%s' "$out" | grep -qi 'error' \
  && ok "the unreachable-URL message is an error line" \
  || ko "the unreachable-URL message is an error line"

# An archive without install.sh must be named as such, not fail deep inside bash.
BADTAR="$WORK/bad.tgz"; mkdir -p "$WORK/badsrc/inner"; echo x > "$WORK/badsrc/inner/f"
tar -czf "$BADTAR" -C "$WORK" badsrc
out=$(CLAUDE_CONFIG_DIR="$WORK/boot7" LEARNER_URL="file://$BADTAR" \
  sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap rejects an archive with no install.sh" \
  || ok "bootstrap rejects an archive with no install.sh"
printf '%s' "$out" | grep -q 'install.sh' \
  && ok "the bad-archive message names install.sh" \
  || ko "the bad-archive message names install.sh"

# Claude Code absent: must abort BEFORE fetching. A fake curl proves no fetch ran.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\ntouch "%s/curl-ran"\nexit 1\n' "$WORK" > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"
rm -f "$WORK/curl-ran"
out=$(PATH="$FAKEBIN:/usr/bin:/bin" HOME="$WORK/nohome" \
  CLAUDE_CONFIG_DIR="$WORK/no-such-cfg" sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap aborts when Claude Code is absent" \
  || ok "bootstrap aborts when Claude Code is absent"
printf '%s' "$out" | grep -qi 'claude' \
  && ok "the abort message names Claude Code" \
  || ko "the abort message names Claude Code"
[ ! -e "$WORK/curl-ran" ] \
  && ok "the Claude Code check runs before any fetch" \
  || ko "the Claude Code check runs before any fetch"

# LEARNER_REF must reach the URL. A fake curl records the URL it was handed.
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in http*|file*) echo "$a" > "%s/curl-url" ;; esac; done\nexit 1\n' \
  "$WORK" > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"
rm -f "$WORK/curl-url"
PATH="$FAKEBIN:/usr/bin:/bin" LEARNER_REF=v9.9.9 \
  CLAUDE_CONFIG_DIR="$B1" sh "$BOOT" --level S >/dev/null 2>&1
{ [ -f "$WORK/curl-url" ] && grep -q 'v9.9.9' "$WORK/curl-url"; } \
  && ok "LEARNER_REF reaches the fetch URL" \
  || ko "LEARNER_REF reaches the fetch URL"
grep -q 'Tykok/learning-with-claude' "$WORK/curl-url" 2>/dev/null \
  && ok "the fetch URL names the repo" \
  || ko "the fetch URL names the repo"

# No terminal and no --level: install.sh could neither prompt nor proceed, so the
# bootstrap must say so itself — the user typed a URL, not a script with flags.
# `-r /dev/tty` only checks permissions, not whether opening it actually succeeds
# (see bootstrap.sh), so this guard attempts the same open to agree with the code
# under test. Only assertable where that open fails; skipped where it succeeds.
if { : < /dev/tty; } 2>/dev/null; then
  skip "no-tty guidance (a terminal is available here)"
else
  out=$(CLAUDE_CONFIG_DIR="$B1" LEARNER_URL="file://$TARBALL" sh "$BOOT" 2>&1) \
    && ko "bootstrap refuses with no terminal and no --level" \
    || ok "bootstrap refuses with no terminal and no --level"
  printf '%s' "$out" | grep -q -- '--level' \
    && ok "the no-tty message shows the --level re-run" \
    || ko "the no-tty message shows the --level re-run"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: every new `bootstrap` assertion FAILS (`bootstrap.sh` does not exist, so `sh "$BOOT"` errors), and the summary reports a non-zero `Failed:` count. The 160 pre-existing assertions must still pass.

- [ ] **Step 3: Write `bootstrap.sh`**

```sh
#!/bin/sh
# Fetch Learner and hand over to its installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh
#   curl -fsSL .../bootstrap.sh | sh -s -- --level S --synthesis often
#   LEARNER_REF=v0.2.0 curl -fsSL .../bootstrap.sh | sh
#
# install.sh is not self-contained: it copies eleven payload files and sources
# hooks/learner-config.sh, so it cannot be piped into a shell on its own. This
# script exists only to put that payload on disk. Every flag is forwarded
# untouched — install.sh keeps sole ownership of defaults and validation, because
# two implementations of the same onboarding would drift.
#
# LEARNER_REF picks the git ref (default main). LEARNER_URL overrides the tarball
# URL outright and is how test.sh drives this without a network.
set -eu

REPO="Tykok/learning-with-claude"
REF="${LEARNER_REF:-main}"
URL="${LEARNER_URL:-https://codeload.github.com/$REPO/tar.gz/$REF}"
CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# 1) Preflight before the network. Fetching a payload for a machine that cannot
# use it wastes the user's time and hands them an error about jq when the real
# problem is that Claude Code is not installed.
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v tar  >/dev/null 2>&1 || die "tar is required."
if ! command -v claude >/dev/null 2>&1 && [ ! -d "$CFG_DIR" ]; then
  die "Claude Code not found (no 'claude' on PATH and no $CFG_DIR).
       Install it first: https://claude.com/claude-code"
fi

# 2) A pipe owns stdin, so install.sh's prompts are unreachable unless the real
# terminal is reopened for it. Where there is no terminal at all (CI, Docker) and
# no level was passed, say so here: install.sh's own message names a flag the user
# never saw, because they invoked a URL rather than a script with arguments.
#
# `-r /dev/tty` only tests permissions: with no controlling terminal the node is
# world-readable but opening it fails (ENXIO), which is the case under cron,
# systemd, `nohup` and `docker run` without -t. Attempt the open instead.
HAVE_TTY=0
if { : < /dev/tty; } 2>/dev/null; then
  HAVE_TTY=1
fi
if [ "$HAVE_TTY" = 0 ]; then
  case " $* " in
    *" --level "*|*" --level="*) ;;
    *) die "no terminal available, so the level cannot be asked for.
       Re-run with the level set, e.g.:
       curl -fsSL .../bootstrap.sh | sh -s -- --level S" ;;
  esac
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT HUP TERM

# 3) Fetch and unpack in one stream: no intermediate file, and
# --strip-components=1 drops the learning-with-claude-<ref>/ wrapper so the
# payload lands directly in $TMP with no directory name to guess.
#
# POSIX sh has no pipefail, so a curl that dies mid-stream can still leave tar
# exiting 0 on a truncated archive. The install.sh check below is what actually
# catches that, which is why it is a hard error rather than a nicety.
curl -fsSL "$URL" | tar -xzf - --strip-components=1 -C "$TMP" \
  || die "could not fetch $URL"
[ -f "$TMP/install.sh" ] \
  || die "the archive from $URL has no install.sh (bad ref '$REF'?)"

# 4) Hand over. install.sh is bash, so run it with bash rather than sh.
if [ "$HAVE_TTY" = 1 ]; then
  bash "$TMP/install.sh" "$@" < /dev/tty
else
  bash "$TMP/install.sh" "$@"
fi
```

- [ ] **Step 4: Wire `bootstrap.sh` into CI lint**

`.github/workflows/ci.yml:15` — add `bootstrap.sh` to the shellcheck list:

```yaml
        run: shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./test.sh`
Expected: every `bootstrap` assertion prints `ok` (the no-tty pair may print `skip` in an interactive shell), and `Failed: 0`.

Run: `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Verify the real fetch path once, by hand**

The suite deliberately never hits the network, so exercise the real URL once against a throwaway config dir. This is the only check that proves the codeload URL and `--strip-components=1` are right for GitHub's actual archive layout:

```bash
TMPCFG="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$TMPCFG" sh ./bootstrap.sh --level S --dry-run
CLAUDE_CONFIG_DIR="$TMPCFG" LEARNER_REF=feat/global-install sh ./bootstrap.sh --level S
find "$TMPCFG" -type f | sort
rm -rf "$TMPCFG"
```

Expected: the `--dry-run` prints what would be written and creates nothing; the second run lays down 5 hooks, `SKILL.md`, 4 references, `learner.json`, `settings.json` and `settings.json.bak`. Note the default `main` does not yet contain the user-level installer — pass `LEARNER_REF=feat/global-install` until PR #1 merges. Paste the output in the task report.

- [ ] **Step 7: Commit**

```bash
git add bootstrap.sh test.sh .github/workflows/ci.yml
git commit -m "feat: add a one-line remote installer"
```

---

### Task 2: README

**Files:**
- Modify: `README.md` — the `## Install` section (currently lines 62-80) and the `## Requirements` section

**Interfaces:**
- Consumes: `bootstrap.sh`'s contract from Task 1 — the one-liner URL, the `sh -s --` argument form, `LEARNER_REF`, and the failure messages.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Write the failing tests**

Add to the `docs` section of `test.sh`:

```bash
grep -qF 'bootstrap.sh' "$RM" \
  && ok "README documents the one-line install" \
  || ko "README documents the one-line install"

grep -qF 'LEARNER_REF' "$RM" \
  && ok "README documents pinning a ref" \
  || ko "README documents pinning a ref"

grep -qF 'sh -s --' "$RM" \
  && ok "README documents the non-interactive one-liner form" \
  || ko "README documents the non-interactive one-liner form"

for p in WSL 'Git Bash'; do
  grep -qF "$p" "$RM" && ok "README covers $p" || ko "README covers $p"
done

# The Windows gap must carry its reason, not just a "no". Case-insensitive on
# purpose: the table capitalises "Windows, native" while the prose says
# "Native Windows", and a case-sensitive pattern here would never match.
grep -qiE 'native windows|windows, native' "$RM" \
  && ok "README states native Windows is unsupported" \
  || ko "README states native Windows is unsupported"

grep -qiF 'posix' "$RM" \
  && ok "README gives the reason native Windows cannot work" \
  || ko "README gives the reason native Windows cannot work"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: the new `docs` assertions FAIL — the README currently documents only `./install.sh` and says nothing about `bootstrap.sh`, `LEARNER_REF`, WSL or Git Bash.

- [ ] **Step 3: Rewrite the `## Install` section**

Replace lines 62-80 with the one-liner first, the clone form second, then the platform table. Required content:

````markdown
## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh
```

It asks for your level, how often you want a synthesis question, and how many holes a `fill`
exercise leaves — then writes everything under your Claude Code config directory. To skip the
questions, pass the same flags `install.sh` takes:

```bash
curl -fsSL .../bootstrap.sh | sh -s -- --level S --synthesis normal --blanks 2
LEARNER_REF=v0.2.0 curl -fsSL .../bootstrap.sh | sh    # pin an exact ref
```

Prefer to read the code before running it? Clone and use the installer directly — it stays a
first-class path:

```bash
git clone https://github.com/Tykok/learning-with-claude
cd learning-with-claude
./install.sh                                          # interactive
./install.sh --level S --synthesis normal --blanks 2  # non-interactive
./install.sh --dry-run                                # print, write nothing
./install.sh --yes                                    # never prompt, defaults for anything unset
```
````

Keep the existing flag list (`--level`, `--synthesis`, `--blanks`, `--dry-run`, `--yes`) and the existing paragraph about idempotency and writing nothing into repositories.

On trust, state exactly two things and no more — do not claim a checksum makes `curl | sh` safe:

- the fetch is HTTPS from `codeload.github.com`, and `LEARNER_REF` pins an exact tag rather than tracking `main`;
- a checksum baked into `bootstrap.sh` would prove nothing, because the script and the archive share an origin — anyone able to change one can change the other.

- [ ] **Step 4: Add the platform table to `## Requirements`**

```markdown
| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS | yes | needs `jq` |
| Linux | yes | needs `jq` |
| Windows via WSL | yes | it is a Linux environment |
| Windows via Git Bash | yes | provides the POSIX `sh` the hooks need |
| Windows, native | no | the hooks are POSIX `sh` scripts; with no POSIX shell, Claude Code cannot run them |

Homebrew and `apt` packages are not available yet.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./test.sh`
Expected: every `docs` assertion prints `ok`, `Failed: 0`.

- [ ] **Step 6: Commit**

```bash
git add README.md test.sh
git commit -m "docs: lead with the one-line install, state platform support"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|--------------|------|
| Why a bootstrap is needed | Task 1 Step 3 (header comment) |
| §1 bootstrap contract, preflight order, streamed fetch, cleanup | Task 1 Steps 1, 3 |
| §2 the TTY problem and the no-tty message | Task 1 Steps 1, 3 |
| §3 testability via `LEARNER_URL` and a `file://` tarball | Task 1 Step 1 |
| §4 repo changes | Task 1 (bootstrap, test, CI), Task 2 (README) |
| §5 README, platform table | Task 2 Steps 3, 4 |
| §6 trust posture | Task 2 Step 3 |
| §7 sequencing | Global Constraints; Task 1 Step 6 uses `LEARNER_REF=feat/global-install` until PR #1 merges |

**Known gaps, both deliberate:**
- The no-tty assertion cannot run where `/dev/tty` is readable, so it prints `skip` locally and only really executes in CI. A test-only override of the tty check would make it always-run at the cost of a hook that exists solely for tests, which is worse.
- No assertion covers the real network fetch; Task 1 Step 6 is a manual check instead, and its output goes in the task report. Adding a network call to `test.sh` would make CI fail on an unrelated outage.
