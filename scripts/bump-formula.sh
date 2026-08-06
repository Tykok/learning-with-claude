#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Bump Formula/learner.rb's url/sha256 to a released tag.
#
# Usage: scripts/bump-formula.sh vX.Y.Z
#
# Downloads that tag's source tarball, computes its sha256, and rewrites the
# matching url/sha256 lines in Formula/learner.rb in place. Review the diff
# and commit it yourself — this never commits on its own.
set -euo pipefail

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: scripts/bump-formula.sh vX.Y.Z"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORMULA="$ROOT/Formula/learner.rb"
URL="https://github.com/Tykok/learning-with-claude/archive/refs/tags/${TAG}.tar.gz"

if command -v shasum >/dev/null 2>&1; then
  SHA=$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)
else
  SHA=$(curl -fsSL "$URL" | sha256sum | cut -d' ' -f1)
fi
[ -n "$SHA" ] || { echo "error: could not compute sha256 for $URL"; exit 1; }

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
sed -E \
  -e "s#^(  url \").*(\")\$#\1${URL}\2#" \
  -e "s#^(  sha256 \").*(\")\$#\1${SHA}\2#" \
  "$FORMULA" > "$TMP"
mv "$TMP" "$FORMULA"

grep -qF "$SHA" "$FORMULA" || { echo "error: rewrite did not take — check Formula/learner.rb's url/sha256 line format"; exit 1; }

echo "Formula/learner.rb updated for $TAG:"
echo "  url:    $URL"
echo "  sha256: $SHA"
echo "Review the diff, then commit it yourself."
