#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetch Learner and hand over to its installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh
#   curl -fsSL .../bootstrap.sh | sh -s -- --level S --synthesis often
#
# To install a specific revision, name it twice — LEARNER_REF pins the payload
# fetched below, not this script, which the shell has already read from the URL
# above. <ref> is anything git resolves: a release tag, a branch name, or a
# commit SHA.
#
#   curl -fsSL .../v0.1.0/bootstrap.sh | LEARNER_REF=v0.1.0 sh
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
# ${HOME:-} rather than $HOME: under `set -u`, if CLAUDE_CONFIG_DIR is unset,
# this line evaluates $HOME too, and an unset HOME (cron, some systemd units)
# would abort right here with a raw "HOME: parameter not set" instead of the
# friendly "Claude Code not found" message below. ${HOME:-} degrades to an
# unreachable path ("/.claude") instead of crashing, which the checks that
# follow handle the same way they handle any other missing config directory.
CFG_DIR="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# 1) Preflight before the network. Fetching a payload for a machine that cannot
# use it wastes the user's time and hands them an error about jq when the real
# problem is that Claude Code is not installed. bash is checked here too, not
# just assumed: install.sh is a bash script, and a PATH that has `claude` (via
# npm, say) but no bash at all (Alpine/busybox containers) would otherwise
# fetch the whole payload only to fail with a bare "command not found" and no
# `error:` line once handed to bash — exactly the network-then-fail waste this
# preflight exists to prevent for the other two dependencies.
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v tar  >/dev/null 2>&1 || die "tar is required."
command -v bash >/dev/null 2>&1 || die "bash is required (install.sh is a bash script)."
if ! command -v claude >/dev/null 2>&1 && [ ! -d "$CFG_DIR" ]; then
  die "Claude Code not found (no 'claude' on PATH and no $CFG_DIR).
       Install it first: https://claude.com/claude-code"
fi

# 2) A pipe owns stdin, so install.sh's prompts are unreachable unless the real
# terminal is reopened for it. Where there is no terminal at all (CI, Docker) and
# no level was passed, say so here: install.sh's own message names a flag the user
# never saw, because they invoked a URL rather than a script with arguments.
#
# Exception: a config that already exists needs no onboarding answers at all —
# install.sh's entire prompt block is gated on the config NOT existing yet — so
# refusing here would block a legitimate non-interactive re-install (re-copying
# hooks after an update, say) that never needed a level in the first place.
#
# `-r /dev/tty` only tests permissions, and a redirection failure on the `:`
# special built-in makes a POSIX shell (dash) exit outright. A subshell
# contains both problems: it either opens the terminal or dies alone.
HAVE_TTY=0
if (exec 3< /dev/tty) 2>/dev/null; then
  HAVE_TTY=1
fi
#
# The hint carries $REF in both places rather than a literal "main": a user who
# pinned a ref and then tripped this guard would otherwise be handed a command
# that silently moved them back to main. Both, because a fresh shell inherits
# neither — the URL pins this script, LEARNER_REF pins the payload — so with the
# default ref it reads "main" twice, which is redundant but true.
if [ "$HAVE_TTY" = 0 ] && [ ! -f "$CFG_DIR/learner.json" ]; then
  case " $* " in
    *" --level "*|*" --level="*) ;;
    *) die "no terminal available, so the level cannot be asked for.
       Re-run with the level set, e.g.:
       curl -fsSL https://raw.githubusercontent.com/$REPO/$REF/bootstrap.sh | LEARNER_REF=$REF sh -s -- --level S" ;;
  esac
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/learner-bootstrap.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT HUP TERM

# 3) Fetch to a file, then extract, as two separate steps rather than a
# streamed `curl | tar` pipe. POSIX sh has no pipefail, so a pipe's exit status
# is its LAST command's — and that made "could not fetch" unreachable on
# macOS: a curl that fails early leaves zero bytes on stdin, which GNU tar
# rejects (non-zero exit) but bsdtar accepts as a valid, empty archive (exits
# 0), so on macOS every real fetch failure (404, DNS, timeout, proxy) surfaced
# as "has no install.sh (bad ref?)" below instead — naming the wrong cause.
# The archive is tens of KB into a temp dir the trap already cleans up, so
# streaming to avoid an intermediate file buys nothing, and a hand-rolled
# marker of curl's exit status would just re-implement pipefail by hand.
# --strip-components=1 drops the learning-with-claude-<ref>/ wrapper so the
# payload lands directly in $TMP with no directory name to guess.
ARCHIVE="$TMP/payload.tar.gz"
curl -fsSL "$URL" -o "$ARCHIVE" || die "could not fetch $URL"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$TMP" \
  || die "the archive from $URL is not a readable tar.gz"
rm -f "$ARCHIVE"
[ -f "$TMP/install.sh" ] \
  || die "the archive from $URL has no install.sh (bad ref '$REF'?)"

# 4) Hand over. install.sh is bash, so run it with bash rather than sh.
if [ "$HAVE_TTY" = 1 ]; then
  bash "$TMP/install.sh" "$@" < /dev/tty
else
  bash "$TMP/install.sh" "$@"
fi
