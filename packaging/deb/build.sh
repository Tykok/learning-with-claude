#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build learner_<VERSION>_all.deb from the repo's own VERSION file.
#
# Usage: packaging/deb/build.sh
# Writes learner_<VERSION>_all.deb into the current directory.
# Requires: dpkg-deb.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
PKG="learner_${VERSION}_all"

command -v dpkg-deb >/dev/null 2>&1 || { echo "error: dpkg-deb is required"; exit 1; }

PKGROOT="$(mktemp -d)"
chmod 0755 "$PKGROOT"
trap 'rm -rf "$PKGROOT"' EXIT

mkdir -p "$PKGROOT/DEBIAN" "$PKGROOT/usr/share/learner" "$PKGROOT/usr/bin"

# "$ROOT/skills" ships every skill under it without naming one here — do not
# narrow this to a per-skill path: that is the exact hand-maintained list
# install.sh's copy loop exists to avoid.
cp -r "$ROOT/hooks" "$ROOT/skills" "$ROOT/install.sh" "$ROOT/uninstall.sh" \
      "$ROOT/VERSION" "$ROOT/LICENSE" "$PKGROOT/usr/share/learner/"

cat > "$PKGROOT/usr/bin/learner-install" <<'EOF'
#!/bin/sh
exec /usr/share/learner/install.sh --origin apt "$@"
EOF

cat > "$PKGROOT/usr/bin/learner-uninstall" <<'EOF'
#!/bin/sh
exec /usr/share/learner/uninstall.sh "$@"
EOF

chmod 0755 "$PKGROOT/usr/bin/learner-install" "$PKGROOT/usr/bin/learner-uninstall" \
           "$PKGROOT/usr/share/learner/install.sh" "$PKGROOT/usr/share/learner/uninstall.sh"

cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: learner
Version: $VERSION
Section: utils
Priority: optional
Architecture: all
Depends: bash, jq
Recommends: curl
Maintainer: Tykok <https://github.com/Tykok>
Description: Turns Claude Code into a learning loop
 Quizzes you on your own diffs at your level, and keeps a per-developer
 record of your weak spots and progress.
EOF

dpkg-deb --build --root-owner-group "$PKGROOT" "${PKG}.deb"
echo "built ${PKG}.deb"
