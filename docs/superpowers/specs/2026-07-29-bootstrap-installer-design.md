# Claude Learner — one-line remote install

Date: 2026-07-29
Status: approved design, not yet implemented

## Goal

Today installing Learner means cloning the repo and running `./install.sh`. This adds a
one-line remote install:

```bash
curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh
```

and documents which platforms that actually works on.

## Why a bootstrap is needed at all

`install.sh` is not self-contained. It copies eleven files that must sit next to it — five
hooks, `SKILL.md`, four `references/*.md`, and `hooks/settings.snippet.json` — and it
*sources* `hooks/learner-config.sh` for level normalisation. Piping `install.sh` alone into
`sh` therefore cannot work: it would run with no payload to copy.

`bootstrap.sh` exists to fetch the payload, then hand over to `install.sh`.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | The bootstrap lives in the repo, not in a Gist — one copy, versioned with the code, covered by `test.sh`. |
| 2 | Windows is supported through WSL or Git Bash only, and the README says why. |
| 3 | The payload is fetched as a tarball with `curl` + `tar`; no `git clone`, nothing left on disk. |
| 4 | The one-liner tracks `main` by default; `LEARNER_REF` pins any ref. |
| 5 | The bootstrap reconnects `/dev/tty` so the interactive onboarding still runs behind a pipe. |
| 6 | Homebrew and `apt` are out of scope for this iteration. |

## 1. `bootstrap.sh` contract

```bash
# interactive: asks level, synthesis frequency, blanks
curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh

# non-interactive: flags pass straight through to install.sh
curl -fsSL .../bootstrap.sh | sh -s -- --level S --synthesis often --blanks 2

# pinned to a tag
LEARNER_REF=v0.2.0 curl -fsSL .../bootstrap.sh | sh
```

Flow, in order:

1. **Preflight, before any network call.** Require `curl` and `tar`. Require Claude Code —
   `command -v claude`, or `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` exists as a directory.
   Failing fast matters: downloading a payload for a machine that cannot use it wastes the
   user's time and leaves them reading an error about `jq` when the real problem is that
   Claude Code is not installed.
2. **Resolve the ref.** `REF="${LEARNER_REF:-main}"`.
3. **Fetch and extract in one stream:**
   ```sh
   curl -fsSL "$URL" | tar -xzf - --strip-components=1 -C "$TMP"
   ```
   `--strip-components=1` removes the `learning-with-claude-<ref>/` wrapper, so the payload
   lands directly in `$TMP` and nothing has to guess the extracted directory name. Streaming
   avoids an intermediate file. Both BSD and GNU `tar` support the flag.
4. **Hand over to the installer**, reconnecting the terminal (see §2):
   ```sh
   if (exec 3< /dev/tty) 2>/dev/null; then
     bash "$TMP/install.sh" "$@" < /dev/tty
   else
     bash "$TMP/install.sh" "$@"
   fi
   ```
   `install.sh` is bash, so it is invoked with `bash`, not `sh`.
5. **Clean up** via `trap 'rm -rf "$TMP"' EXIT INT HUP TERM`, so a failed or interrupted run
   leaves nothing behind.

The bootstrap adds no behaviour of its own beyond fetching: every flag, every default and
every validation stays in `install.sh`. Two implementations of the same onboarding would
drift.

## 2. The TTY problem

`curl … | sh` makes the *script* the shell's stdin. `install.sh` gates its onboarding
prompts on `[ -t 0 ]`, which is false in that situation, so the one-liner would silently skip
the questions and abort for want of a `--level` — the exact opposite of the smooth install
this feature exists to provide.

The fix is to reopen the real terminal for the installer: `< /dev/tty`. With stdin pointing at
a tty, `[ -t 0 ]` is true and the prompts work normally.

Detecting "no terminal" has to be an open *attempt*, not a permission check.
`[ -r /dev/tty ]` only tests the device node's permission bits, and `/dev/tty` is typically
world-readable (`crw-rw-rw-`) even with no controlling terminal attached, so that check reports
`true` right up until the real `< /dev/tty` redirection fails with `ENXIO` — exactly the case
under cron, systemd units, `nohup`, and `docker run` without `-t`.

The open attempt itself has a trap: `:` is a POSIX *special built-in*, and POSIX requires a
non-interactive shell to exit outright when a redirection on one fails, so
`{ : < /dev/tty; } 2>/dev/null` kills the whole script under dash (Debian's `/bin/sh`) instead
of reporting failure to an `if` — it passes under bash and zsh, which are lenient about this,
and only shows up once the script runs somewhere dash is `/bin/sh`. A subshell confines the
exit instead of propagating it, so the bootstrap attempts the open there:

```sh
HAVE_TTY=0
if (exec 3< /dev/tty) 2>/dev/null; then
  HAVE_TTY=1
fi
```

and, if that fails and no `--level` was passed, prints the exact command to re-run:

```
error: no terminal available, so the level cannot be asked for.
       Re-run with the level set, e.g.:
       curl -fsSL .../bootstrap.sh | sh -s -- --level S
```

Letting `install.sh` fail on its own here would leave the user with a message about a flag
they never saw, because they invoked a URL and not a script with arguments.

## 3. Testability

`test.sh` must not reach the network. The fetch URL is therefore overridable:

```sh
URL="${LEARNER_URL:-https://codeload.github.com/Tykok/learning-with-claude/tar.gz/$REF}"
```

`test.sh` builds the tarball with `tar` over the **working tree**, not `git archive`, so a
change under test is covered before it is committed. It must carry exactly one top-level
directory, because the bootstrap strips one component:

```sh
tar -czf "$TARBALL" -C "$(dirname "$ROOT")" "$(basename "$ROOT")"
```

`curl` reads it back through a `file://` URL, so the bootstrap's fetch path is exercised as
written rather than special-cased for tests:

```sh
LEARNER_URL="file://$TARBALL" sh "$ROOT/bootstrap.sh" --level S
```

That exercises the real mechanism — extraction, argument passing, TTY branch, cleanup — with
no egress.

Without this hook the bootstrap would be the only file in the repo with no test, which is a
poor property for the entry point every new user hits first.

Assertions:

- aborts when Claude Code is absent, before fetching
- aborts when `curl` or `tar` is missing
- extracts the payload and delegates to `install.sh`
- passes `--level` / `--synthesis` / `--blanks` through unchanged
- honours `LEARNER_REF` in the constructed URL
- removes the temp directory on success, on failure, and on interrupt
- with no tty and no `--level`, prints the re-run hint and exits non-zero

## 4. Repo changes

| File | Change |
|------|--------|
| `bootstrap.sh` | new, at the repo root (the one-liner URL points at it) |
| `test.sh` | new bootstrap section per §3 |
| `README.md` | one-liner, argument form, pinning, platform table |
| `.github/workflows/ci.yml` | `shellcheck` covers `bootstrap.sh` |

`bootstrap.sh` is POSIX `sh` — it runs before anything is known about the machine, so it may
not assume bash. `shellcheck --severity=warning` must pass on it.

## 5. README changes

Replace the current install section with the one-liner first and the clone-and-run form
second, then a platform table stating what is actually true:

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS | yes | needs `jq` |
| Linux | yes | needs `jq` |
| Windows via WSL | yes | it is a Linux environment |
| Windows via Git Bash | yes | provides the POSIX `sh` the hooks need |
| Windows, native | no | the hooks are POSIX `sh` scripts; without a POSIX shell Claude Code cannot run them |

Naming the reason for the Windows gap turns it from a hole into a documented decision, and
tells a Windows user what to do instead.

## 6. Trust posture

`curl … | sh` runs code fetched at request time. Two honest statements belong in the README
rather than a false sense of safety:

- the fetch is HTTPS from `codeload.github.com`, and `LEARNER_REF` lets a user pin an exact
  tag instead of tracking `main`;
- a checksum embedded in `bootstrap.sh` would prove nothing, because the script and the
  archive come from the same origin — anyone able to alter one can alter the other.

A user who wants to read before running is told to clone and run `./install.sh`, which stays
a first-class path.

## 7. Sequencing

This depends on the user-level `install.sh` from PR #1 (`feat/global-install`): the letter
levels, the `--synthesis` / `--blanks` flags and the `$CFG` layout all come from there.
Implementation should start once that PR merges, or on a branch stacked on it and rebased onto
`main` afterwards.

## Out of scope

- **Homebrew.** Next iteration, its own spec. It lives in a separate repo
  (`Tykok/homebrew-tap`), and a formula needs a tagged tarball plus a `sha256`, so it also
  requires tagging `v0.1.0` — a release process this iteration deliberately avoids.
- **`apt`.** A signed repository is disproportionate for eleven text files, and offers a user
  nothing the one-liner does not already give them.
- **Native Windows.** Would mean rewriting all five hooks to run without a POSIX shell and
  doubling the test surface. A separate project, not a packaging task.
- **`wget` fallback.** `curl` only, stated in the error message.

## Traceability

| Request | Section |
|---------|---------|
| Simple one-command install | 1 |
| Then update the README | 5 |
| Homebrew for macOS | Out of scope — next iteration, sketched |
| `apt` for Linux | Out of scope, with reasoning |
| Windows | 5 — WSL / Git Bash, native refused with a reason |
