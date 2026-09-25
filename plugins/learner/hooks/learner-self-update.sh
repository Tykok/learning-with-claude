#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# learner-self-update.sh <X.Y.Z> — re-install a curl/clone install at release vX.Y.Z.
#
# Run by the `update` skill (step 4), never wired as a hook. It ships with the
# install so the skill runs a local, readable file instead of fetching a script
# from the network and executing it: the only thing downloaded here is the
# tagged release tarball, and the only thing run from it is its install.sh.
#
# LEARNER_URL overrides the tarball URL outright and is how test.sh drives this
# without a network.
set -eu

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

VER="${1:-}"
# The version builds a URL below: refuse anything that is not plain X.Y.Z
# before it gets there, whatever the caller already checked.
# shellcheck source=learner-config.sh
. "$(dirname "$0")/learner-config.sh"
learner_version_valid "$VER" || die "not a version: '$VER'"

command -v curl >/dev/null 2>&1 || die "curl is required."
command -v tar  >/dev/null 2>&1 || die "tar is required."
command -v bash >/dev/null 2>&1 || die "bash is required (install.sh is a bash script)."

REPO="Tykok/learning-with-claude"
URL="${LEARNER_URL:-https://codeload.github.com/$REPO/tar.gz/v$VER}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/learner-update.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT HUP TERM

# Fetch to a file, then extract — same reasoning as bootstrap.sh: without
# pipefail, a failed curl feeding bsdtar reads as an empty, valid archive.
ARCHIVE="$TMP/payload.tar.gz"
curl -fsSL "$URL" -o "$ARCHIVE" \
  || die "no released tag v$VER yet (VERSION on main is ahead of the tags) — try again later"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$TMP" \
  || die "the archive from $URL is not a readable tar.gz"
rm -f "$ARCHIVE"
[ -f "$TMP/install.sh" ] || die "the archive from $URL has no install.sh"

# learner.json already exists on any install this runs for, so install.sh's
# onboarding prompts stay gated off and no terminal is needed.
bash "$TMP/install.sh"
