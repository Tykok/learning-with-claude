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
# `-r /dev/tty` only tests permissions, and a redirection failure on the `:`
# special built-in makes a POSIX shell (dash) exit outright. A subshell
# contains both problems: it either opens the terminal or dies alone.
HAVE_TTY=0
if (exec 3< /dev/tty) 2>/dev/null; then
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
