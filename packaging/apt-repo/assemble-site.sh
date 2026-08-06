#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Assemble the full Pages site: the hand-written docs/ pages, verbatim, plus a
# freshly-generated apt repository built from the current latest GitHub
# Release. Nothing about the apt repo is ever committed anywhere — this
# script's whole job is to produce it fresh, every time it's called.
#
# Usage: packaging/apt-repo/assemble-site.sh [output-dir]
#   output-dir defaults to _site.
#
# Env:
#   APT_SIGNING_KEY  required. Armored GPG private key (no passphrase) that
#                    signs the repo. Imported into a throwaway GNUPGHOME and
#                    destroyed before this script exits — never left on disk.
#   APT_DEB_SOURCE   optional. A local path to a .deb file, used instead of
#                    `gh release download`. test.sh sets this to a fixture so
#                    the suite never touches the network — the same pattern
#                    bootstrap.sh's LEARNER_URL and the update-check hook's
#                    LEARNER_VERSION_URL already use.
#   GH_TOKEN         required unless APT_DEB_SOURCE is set — passed through to
#                    `gh release download`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-_site}"

[ -n "${APT_SIGNING_KEY:-}" ] || { echo "error: APT_SIGNING_KEY is required"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp -r "$ROOT"/docs/*.html "$ROOT/docs/assets" "$OUT/"
[ -f "$ROOT/docs/.nojekyll" ] && cp "$ROOT/docs/.nojekyll" "$OUT/"
echo "  ✓ hand-written site copied to $OUT"

APTDIR="$OUT/apt"
DEBFILE=""

if [ -n "${APT_DEB_SOURCE:-}" ]; then
  DEBFILE="$APT_DEB_SOURCE"
else
  TMPDL="$(mktemp -d)"
  trap 'rm -rf "$TMPDL"' EXIT
  if gh release download --pattern 'learner_*_all.deb' --dir "$TMPDL" latest 2>/dev/null; then
    DEBFILE=$(find "$TMPDL" -maxdepth 1 -name 'learner_*_all.deb' | head -n1)
  fi
fi

if [ -n "$DEBFILE" ] && [ -f "$DEBFILE" ]; then
  mkdir -p "$APTDIR/pool/main/l/learner" "$APTDIR/dists/stable/main/binary-all"
  cp "$DEBFILE" "$APTDIR/pool/main/l/learner/"

  ( cd "$APTDIR" && dpkg-scanpackages --arch all pool /dev/null > dists/stable/main/binary-all/Packages )
  gzip -9c "$APTDIR/dists/stable/main/binary-all/Packages" > "$APTDIR/dists/stable/main/binary-all/Packages.gz"
  ( cd "$APTDIR/dists/stable" && apt-ftparchive release . > Release )

  GNUPGHOME="$(mktemp -d)"
  chmod 700 "$GNUPGHOME"
  export GNUPGHOME
  printf '%s' "$APT_SIGNING_KEY" | gpg --batch --import
  KEYID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5; exit}')
  gpg --batch --yes --clearsign -o "$APTDIR/dists/stable/InRelease" "$APTDIR/dists/stable/Release"
  gpg --batch --armor --export "$KEYID" > "$APTDIR/learner.gpg"
  rm -rf "$GNUPGHOME"
  unset GNUPGHOME

  echo "  ✓ apt repo assembled for $(basename "$DEBFILE")"
else
  echo "  • no release .deb available — shipping the site with no apt/ tree"
  rm -rf "$APTDIR"
fi

echo "site assembled at $OUT"
