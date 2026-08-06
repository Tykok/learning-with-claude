# Brew and apt packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship learner via `brew install` (personal tap) and a downloadable `.deb` for apt,
without either package silently wiring `~/.claude` on its own, and without breaking
`learner update` for a package-managed install.

**Architecture:** Both packages stage the existing `install.sh`/`uninstall.sh` payload plus two
tiny wrapper binaries (`learner-install`, `learner-uninstall`) that just `exec` into the staged
copies with `--origin brew`/`--origin apt`. `install.sh` learns that flag and stamps it into a
new marker file next to the existing `VERSION` file. `learner update`'s protocol reads the
marker and defers to the package manager instead of curl-reinstalling behind its back.

**Tech Stack:** POSIX `sh` (hooks, wrapper scripts), `bash` (`install.sh`, `uninstall.sh`,
`packaging/deb/build.sh`, `scripts/bump-formula.sh`), Ruby (`Formula/learner.rb`, Homebrew's
DSL), `dpkg-deb`, GitHub Actions.

## Global Constraints

- Spec: `design/superpowers/specs/2026-08-06-brew-apt-packaging-design.md` — every task below implements one of its numbered sections.
- apt ships a `.deb` attached to a GitHub Release. No hosted apt repository, no GPG signing key.
- Homebrew ships via a personal tap (`Formula/learner.rb` in this repo, tapped by explicit URL). No homebrew-core submission.
- Neither package wires learner into `~/.claude` automatically. `brew install`/`apt install` only stage files and drop `learner-install`/`learner-uninstall` on `PATH`. The dev runs `learner-install` themself.
- `learner update` is origin-aware: it reads `$CFG/skills/learner/INSTALL_ORIGIN` and defers to the package manager for `brew`/`apt` installs instead of curl-reinstalling.
- Every shipped shell script carries `# SPDX-License-Identifier: GPL-3.0-or-later` on its own comment line, and is added to both the MIT-scan list (`LIC_SCAN` in `test.sh`) and the SPDX-tag loop in `test.sh` — the same treatment every existing shipped script already gets.
- `shellcheck --severity=warning` must stay clean on every `.sh` file it's pointed at, and the glob in `.github/workflows/ci.yml`'s `shellcheck` step must stay byte-identical to the one quoted in `README.md`'s Development section — `test.sh` asserts the two match verbatim.
- `SKILL.md` stays ≤ 120 lines (existing cap, unaffected by this feature — no dispatch-table change).
- Repo remote is `Tykok/learning-with-claude`; maintainer/tap owner is `Tykok`.

---

### Task 1: Install-origin marker in `install.sh`

**Files:**
- Modify: `install.sh:5-40` (usage header, arg parsing), `install.sh:104-131` (dry-run block, VERSION copy)
- Modify: `test.sh` (installer section, around the existing VERSION assertions)

**Interfaces:**
- Produces: `--origin curl|brew|apt` flag on `install.sh` (default `curl`); `$CFG_DIR/skills/learner/INSTALL_ORIGIN` file, one bare word (`curl`, `brew` or `apt`), written unconditionally on every install/re-install. Later tasks' wrapper scripts pass `--origin brew`/`--origin apt`; Task 2's `update.md` reads this file.

- [ ] **Step 1: Write the failing tests**

Open `test.sh`. Find this block (the existing VERSION re-install test):

```bash
echo '9.9.9' > "$I/skills/learner/VERSION"
inst "$I" --level S >/dev/null 2>&1
[ "$(cat "$I/skills/learner/VERSION")" = "$(cat "$ROOT/VERSION")" ] \
  && ok "a re-install always refreshes VERSION, unlike learner.json" \
  || ko "a re-install always refreshes VERSION, unlike learner.json"
```

Immediately after it, insert:

```bash
[ -f "$I/skills/learner/INSTALL_ORIGIN" ] && [ "$(cat "$I/skills/learner/INSTALL_ORIGIN")" = "curl" ] \
  && ok "install defaults --origin to curl" \
  || ko "install defaults --origin to curl"

IB="$WORK/inst-brew"; mkdir -p "$IB"
inst "$IB" --level S --origin brew >/dev/null 2>&1
[ "$(cat "$IB/skills/learner/INSTALL_ORIGIN" 2>/dev/null)" = "brew" ] \
  && ok "install stamps --origin brew" \
  || ko "install stamps --origin brew"

IA="$WORK/inst-apt"; mkdir -p "$IA"
inst "$IA" --level S --origin apt >/dev/null 2>&1
[ "$(cat "$IA/skills/learner/INSTALL_ORIGIN" 2>/dev/null)" = "apt" ] \
  && ok "install stamps --origin apt" \
  || ko "install stamps --origin apt"

out=$(inst "$WORK/inst-bad-origin" --level S --origin homebrew 2>&1) \
  && ko "install rejects an unknown --origin value" \
  || ok "install rejects an unknown --origin value"
printf '%s' "$out" | grep -qF -- '--origin' \
  && ok "the --origin error message names the flag" \
  || ko "the --origin error message names the flag (got '$out')"

echo 'brew' > "$I/skills/learner/INSTALL_ORIGIN"
inst "$I" --level S --origin curl >/dev/null 2>&1
[ "$(cat "$I/skills/learner/INSTALL_ORIGIN")" = "curl" ] \
  && ok "a re-install always refreshes INSTALL_ORIGIN, unlike learner.json" \
  || ko "a re-install always refreshes INSTALL_ORIGIN, unlike learner.json"
```

Then find the uninstall assertion:

```bash
{ [ "$left" = 0 ] \
  && [ ! -e "$U/hooks/learner-quiz.sh" ] \
  && [ ! -e "$U/hooks/learner-config.sh" ] \
  && [ ! -e "$U/hooks/learner-update-check.sh" ] \
  && [ ! -d "$U/skills/learner" ]; } \
  && ok "uninstall removes hooks, skill and wiring" \
  || ko "uninstall removes hooks, skill and wiring (left=$left)"
```

Add one line to the `&&` chain, right before `[ ! -d "$U/skills/learner" ]`:

```bash
  && [ ! -e "$U/skills/learner/INSTALL_ORIGIN" ] \
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -E 'origin|FAIL' `
Expected: several `FAIL` lines mentioning `--origin`/`INSTALL_ORIGIN` (the flag doesn't exist yet, so `inst` errors out on the unrecognized argument or simply never writes the file).

- [ ] **Step 3: Implement the flag and the marker file**

In `install.sh`, replace the usage header (currently lines 5-18) with:

```bash
# Usage:
#   ./install.sh [--level D|J|C|S|E] [--synthesis off|rare|normal|often]
#                [--blanks N] [--origin curl|brew|apt] [--dry-run] [--yes]
#
#   --level L      Your level. Full words (junior, senior, …) are accepted.
#   --synthesis W  How often a synthesis question replaces a granular one.
#   --blanks N     Holes left in a fill-in exercise.
#   --origin O     Who is installing: curl, brew or apt. Set by the brew/apt
#                  wrapper scripts — pass it by hand only if you know why.
#                  Default: curl.
#   --dry-run      Print what would be written, write nothing.
#   --yes          Never prompt; defaults for anything not passed — but --level
#                  has no default, so pass it too or the install aborts.
#
# Idempotent: re-running re-copies the files and re-merges the hook wiring
# without duplicating entries, and never overwrites an existing config.
# Requires: Claude Code, and jq (the hook-wiring merge cannot run without it).
```

Replace the argument-parsing block:

```bash
LEVEL=""; SYNTH=""; BLANKS=""; DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --level)     LEVEL="${2:-}"; shift 2 ;;
    --level=*)   LEVEL="${1#*=}"; shift ;;
    --synthesis) SYNTH="${2:-}"; shift 2 ;;
    --synthesis=*) SYNTH="${1#*=}"; shift ;;
    --blanks)    BLANKS="${2:-}"; shift 2 ;;
    --blanks=*)  BLANKS="${1#*=}"; shift ;;
    --dry-run)   DRY=1; shift ;;
    --yes|-y)    YES=1; shift ;;
    -h|--help)   sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unexpected argument '$1' (learner installs globally, not per repo)"; exit 1 ;;
  esac
done
```

with:

```bash
LEVEL=""; SYNTH=""; BLANKS=""; ORIGIN=""; DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --level)     LEVEL="${2:-}"; shift 2 ;;
    --level=*)   LEVEL="${1#*=}"; shift ;;
    --synthesis) SYNTH="${2:-}"; shift 2 ;;
    --synthesis=*) SYNTH="${1#*=}"; shift ;;
    --blanks)    BLANKS="${2:-}"; shift 2 ;;
    --blanks=*)  BLANKS="${1#*=}"; shift ;;
    --origin)    ORIGIN="${2:-}"; shift 2 ;;
    --origin=*)  ORIGIN="${1#*=}"; shift ;;
    --dry-run)   DRY=1; shift ;;
    --yes|-y)    YES=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unexpected argument '$1' (learner installs globally, not per repo)"; exit 1 ;;
  esac
done

ORIGIN="${ORIGIN:-curl}"
case "$ORIGIN" in
  curl|brew|apt) ;;
  *) echo "error: --origin must be curl | brew | apt"; exit 1 ;;
esac
```

(The `sed -n '2,17p'` → `'2,20p'` change keeps `--help`'s output in sync with the three new
usage-comment lines above it.)

Then find the VERSION copy line inside the "not a dry run" section:

```bash
cp "$SRC_DIR/VERSION" "$CFG_DIR/skills/learner/VERSION"
echo "  ✓ skill → $CFG_DIR/skills/learner/"
```

and insert the marker write between them:

```bash
cp "$SRC_DIR/VERSION" "$CFG_DIR/skills/learner/VERSION"
printf '%s' "$ORIGIN" > "$CFG_DIR/skills/learner/INSTALL_ORIGIN"
echo "  ✓ skill → $CFG_DIR/skills/learner/"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -30`
Expected: `Failed: 0`, and every line containing `origin` (case-insensitive) reads `ok`.

- [ ] **Step 5: Run shellcheck**

Run: `shellcheck --severity=warning install.sh`
Expected: no warnings.

- [ ] **Step 6: Commit**

```bash
git add install.sh test.sh
git commit -m "feat(install): stamp the install origin (curl/brew/apt)"
```

---

### Task 2: `learner update` becomes origin-aware

**Files:**
- Modify: `skills/learner/references/update.md` (full replacement, below)
- Modify: `test.sh`

**Interfaces:**
- Consumes: `$CFG/skills/learner/INSTALL_ORIGIN` (Task 1).
- Produces: no new interface — this is the terminal consumer of the marker.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, in the "skill content" section (near the other `references/*.md` content
checks), add:

```bash
UPD="$ROOT/skills/learner/references/update.md"

grep -qF 'INSTALL_ORIGIN' "$UPD" \
  && ok "update.md reads the install-origin marker" \
  || ko "update.md reads the install-origin marker"

grep -qF 'brew upgrade learner' "$UPD" \
  && ok "update.md tells a brew install to use brew upgrade" \
  || ko "update.md tells a brew install to use brew upgrade"

grep -qF 'apt install' "$UPD" \
  && ok "update.md tells an apt install to grab a new .deb" \
  || ko "update.md tells an apt install to grab a new .deb"

grep -qF 'learner-install' "$UPD" \
  && ok "update.md points package-managed installs at learner-install" \
  || ko "update.md points package-managed installs at learner-install"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -E 'update.md|FAIL'`
Expected: the four new assertions `FAIL` (none of those strings exist in `update.md` yet).

- [ ] **Step 3: Rewrite `update.md`**

Replace the entire contents of `skills/learner/references/update.md` with:

```markdown
# Update mode

`learner update` — check the remote version, and if it is newer, re-run the installer pinned
to it. Read-only until step 1 decides an update is actually needed: nothing is written,
locally or remotely, when the dev is already current.

## 1. Read, validate and compare

```bash
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOCAL=$(cat "$CFG/skills/learner/VERSION" 2>/dev/null)
REMOTE=$(curl -fsSL --max-time 5 "${LEARNER_VERSION_URL:-https://raw.githubusercontent.com/Tykok/learning-with-claude/main/VERSION}")
. "$CFG/hooks/learner-config.sh"
learner_version_valid "$REMOTE" || { echo "remote VERSION is malformed: '$REMOTE'"; exit 1; }
if [ -n "$LOCAL" ] && ! learner_version_gt "$REMOTE" "$LOCAL"; then
  echo "already on the latest version (v$LOCAL)"
  exit 0
fi
```

Compare with the same helpers `hooks/learner-update-check.sh` uses, sourced from the install
rather than re-implemented: `learner_version_gt` compares the `X.Y.Z` components as integers,
so "0.9.0" vs "0.10.0" comes out right where reading the two strings as text would not. An
empty `$LOCAL` means this install predates versioning — treat it as older than anything, which
is exactly what the `[ -n "$LOCAL" ]` guard does: it skips the comparison and falls straight
through to step 3. Validate before comparing, and before anything else touches `$REMOTE`: step
3 builds a URL out of it, and a malformed value must never reach that unchecked. A `curl`
failure on the fetch above is not silence, unlike the background check — the dev asked for
this directly, so report it in one line and stop rather than falling through with an empty
`$REMOTE` that `learner_version_valid` would then (correctly) reject anyway.

## 2. Check the install origin

```bash
ORIGIN=$(cat "$CFG/skills/learner/INSTALL_ORIGIN" 2>/dev/null); ORIGIN="${ORIGIN:-curl}"
```

An install from before this file existed has no marker at all — treat a missing file the same
as `curl`, since curl or a bare clone is exactly what every install predating it used.

- **`curl`** → continue to step 3, unchanged.
- **`brew`** → print, and stop. Nothing is written — `brew` owns the payload on disk, not this
  protocol:
  ```
  Installed via Homebrew. Run: brew upgrade learner && learner-install
  ```
- **`apt`** → print, and stop, naming the exact asset so the dev isn't left guessing at a
  filename:
  ```
  Installed via apt. Download learner_$REMOTE_all.deb from
  https://github.com/Tykok/learning-with-claude/releases/tag/v$REMOTE, then:
    sudo apt install ./learner_$REMOTE_all.deb && learner-install
  ```

Both guidance branches point at `learner-install` rather than re-deriving `install.sh`'s own
flags here — a third copy of "here's how to pass --level" would drift from the other two the
same way two implementations of the installer itself would.

## 3. Re-run the installer, pinned (origin: curl only)

```bash
if ! curl -fsSL "https://raw.githubusercontent.com/Tykok/learning-with-claude/v$REMOTE/bootstrap.sh" -o /tmp/learner-bootstrap.sh 2>/dev/null; then
  echo "no released tag v$REMOTE yet (VERSION on main is ahead of the tags) — try again later"
  exit 1
fi
LEARNER_REF="v$REMOTE" sh /tmp/learner-bootstrap.sh
rm -f /tmp/learner-bootstrap.sh
```

Fetched to a file and run as two separate steps, not a streamed `curl | sh` pipe: in a pipe, a
failed fetch leaves the right-hand side reading empty stdin, and `sh` on empty stdin exits 0 —
a silent no-op with no error, not a failure Claude can see and report. That gap is real here
specifically, not theoretical: `VERSION` on `main` and the release tag `vX.Y.Z` are two
separate git pushes, so the file can say a version is out before the matching tag exists to
back it up. CI's tag-vs-VERSION guard only runs on the tag push, so it structurally cannot
catch that window from the other side. Report the named reason above instead of "nothing
happened." Carry `LEARNER_REF="v$REMOTE"` over onto the direct `sh` call above — it is no
longer free the way it was as a prefix on the one `sh` in the old pipe. Drop it here and the
fetched `bootstrap.sh` would default its payload fetch back to `main` while the script itself
stayed pinned to `v$REMOTE`: two different refs, silently.

No other flags are needed: `learner.json` already exists — this is always a re-install, never
a first one — so `install.sh`'s onboarding prompts stay gated off regardless, and
`bootstrap.sh`'s no-tty guard only fires when `learner.json` is absent.

## 4. Confirm (origin: curl only)

Re-read `$CFG/skills/learner/VERSION`. If it now reads `$REMOTE`, report the new version in one
line. If it still reads the old value, say the update did not take — never claim success on an
assumption. Step 2's `brew`/`apt` branches already stopped before this point — there is
nothing here to confirm for them.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -30`
Expected: `Failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add skills/learner/references/update.md test.sh
git commit -m "feat(skill): make learner update defer to brew/apt when package-managed"
```

---

### Task 3: Homebrew formula and the formula-bump helper

**Files:**
- Create: `Formula/learner.rb`
- Create: `scripts/bump-formula.sh`
- Modify: `.github/workflows/ci.yml` (shellcheck glob), `README.md` (Development section shellcheck line, plus the same list in `test.sh`'s `LIC_SCAN`/SPDX loop)
- Modify: `test.sh`

**Interfaces:**
- Consumes: Task 1's `--origin brew` flag on `install.sh`.
- Produces: `Formula/learner.rb` with real `url`/`sha256` for `v0.1.0` (the tag that already
  exists in this repo) — not a placeholder. `bin/learner-install`, `bin/learner-uninstall` once
  the formula is installed.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, add a new section near the end (after the licence-scan block, before the
`# --- summary ---` footer):

```bash
# --- Homebrew formula --------------------------------------------------------
FORMULA="$ROOT/Formula/learner.rb"

[ -f "$FORMULA" ] && ok "Formula/learner.rb exists" || ko "Formula/learner.rb exists"

grep -qF 'depends_on "jq"' "$FORMULA" \
  && ok "the formula depends on jq" \
  || ko "the formula depends on jq"

grep -qF '"#{pkgshare}/install.sh" --origin brew' "$FORMULA" \
  && ok "the formula's learner-install wrapper passes --origin brew" \
  || ko "the formula's learner-install wrapper passes --origin brew"

grep -qE 'sha256 "[0-9a-f]{64}"' "$FORMULA" \
  && ok "the formula's sha256 is a real 64-hex-char digest, not a placeholder" \
  || ko "the formula's sha256 is a real 64-hex-char digest, not a placeholder"

[ -x "$ROOT/scripts/bump-formula.sh" ] \
  && ok "scripts/bump-formula.sh is executable" \
  || ko "scripts/bump-formula.sh is executable"
```

Extend the existing SPDX-tag loop — find:

```bash
for f in hooks/learner-config.sh hooks/learner-onboard.sh hooks/learner-record-edit.sh \
         hooks/learner-quiz.sh hooks/learner-cleanup.sh hooks/learner-update-check.sh \
         install.sh uninstall.sh bootstrap.sh test.sh; do
```

and change it to:

```bash
for f in hooks/learner-config.sh hooks/learner-onboard.sh hooks/learner-record-edit.sh \
         hooks/learner-quiz.sh hooks/learner-cleanup.sh hooks/learner-update-check.sh \
         install.sh uninstall.sh bootstrap.sh test.sh Formula/learner.rb \
         scripts/bump-formula.sh; do
```

Extend `LIC_SCAN` — find:

```bash
LIC_SCAN="README.md docs/ hooks/learner-config.sh hooks/learner-onboard.sh
hooks/learner-record-edit.sh hooks/learner-quiz.sh hooks/learner-cleanup.sh
hooks/learner-update-check.sh install.sh uninstall.sh bootstrap.sh"
```

and change it to:

```bash
LIC_SCAN="README.md docs/ hooks/learner-config.sh hooks/learner-onboard.sh
hooks/learner-record-edit.sh hooks/learner-quiz.sh hooks/learner-cleanup.sh
hooks/learner-update-check.sh install.sh uninstall.sh bootstrap.sh
Formula/learner.rb scripts/bump-formula.sh"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -iE 'formula|FAIL'`
Expected: every new `Formula`/`bump-formula` assertion fails (`No such file or directory`).

- [ ] **Step 3: Create `Formula/learner.rb`**

```ruby
# SPDX-License-Identifier: GPL-3.0-or-later
class Learner < Formula
  desc "Turns Claude Code into a learning loop: quizzes you on your own diffs"
  homepage "https://github.com/Tykok/learning-with-claude"
  url "https://github.com/Tykok/learning-with-claude/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "GPL-3.0-or-later"

  depends_on "jq"

  def install
    pkgshare.install "hooks", "skills", "install.sh", "uninstall.sh", "VERSION", "LICENSE"

    (bin/"learner-install").write <<~SH
      #!/bin/sh
      exec "#{pkgshare}/install.sh" --origin brew "$@"
    SH
    (bin/"learner-uninstall").write <<~SH
      #!/bin/sh
      exec "#{pkgshare}/uninstall.sh" "$@"
    SH
    chmod 0755, bin/"learner-install"
    chmod 0755, bin/"learner-uninstall"
  end

  def caveats
    <<~EOS
      Learner is staged but not yet active. Wire it into ~/.claude with:
        learner-install --level S --synthesis normal --blanks 2
      See `learner-install --help` for every flag.
    EOS
  end

  test do
    system "#{bin}/learner-install", "--help"
  end
end
```

(The `sha256` above is a 64-character stand-in — Step 5 replaces it with the real digest before
this task is committed. It exists so the file is syntactically complete for Step 4's tests to
run against.)

- [ ] **Step 4: Run the content tests to verify they pass, except the sha256 one**

Run: `./test.sh 2>&1 | grep -iE 'formula|bump-formula'`
Expected: every line passes except "the formula's sha256 is a real 64-hex-char digest, not a
placeholder" — that one still fails, because the stand-in above, while 64 hex-*looking*
characters, is intentionally all zeros. (If your regex also passes on all-zero input, that's
fine — Step 5 replaces the value for real either way.)

- [ ] **Step 5: Create `scripts/bump-formula.sh` and run it against the existing `v0.1.0` tag**

```bash
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
sed -E \
  -e "s#^(  url \").*(\")\$#\1${URL}\2#" \
  -e "s#^(  sha256 \").*(\")\$#\1${SHA}\2#" \
  "$FORMULA" > "$TMP"
mv "$TMP" "$FORMULA"

echo "Formula/learner.rb updated for $TAG:"
echo "  url:    $URL"
echo "  sha256: $SHA"
echo "Review the diff, then commit it yourself."
```

Make it executable and run it:

```bash
chmod +x scripts/bump-formula.sh
./scripts/bump-formula.sh v0.1.0
git diff Formula/learner.rb   # confirm url still says v0.1.0.tar.gz, sha256 changed to a real digest
```

- [ ] **Step 6: Extend the shellcheck glob (README.md's Development section AND ci.yml, together)**

In `.github/workflows/ci.yml`, find:

```yaml
      - name: shellcheck
        run: shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh
```

Change the `run:` line to:

```yaml
        run: shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh scripts/bump-formula.sh
```

In `README.md`'s Development section, find:

```
shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh
```

and change it to the identical new line:

```
shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh scripts/bump-formula.sh
```

- [ ] **Step 7: Run the full test suite and shellcheck**

Run: `./test.sh 2>&1 | tail -5 && shellcheck --severity=warning scripts/bump-formula.sh`
Expected: `Failed: 0`; shellcheck prints nothing.

- [ ] **Step 8: Commit**

```bash
git add Formula/learner.rb scripts/bump-formula.sh test.sh README.md .github/workflows/ci.yml
git commit -m "feat(brew): add a Homebrew formula and a formula-bump helper"
```

---

### Task 4: Debian package build script

**Files:**
- Create: `packaging/deb/build.sh`
- Modify: `.github/workflows/ci.yml` (shellcheck glob), `README.md` (same shellcheck line)
- Modify: `test.sh`

**Interfaces:**
- Consumes: Task 1's `--origin apt` flag on `install.sh`.
- Produces: `packaging/deb/build.sh`, which writes `learner_<VERSION>_all.deb` into the current
  directory when run. Task 5's CI step calls it as `bash packaging/deb/build.sh`.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, right after the Homebrew section added in Task 3, add:

```bash
# --- Debian package -----------------------------------------------------------
DEBBUILD="$ROOT/packaging/deb/build.sh"

[ -f "$DEBBUILD" ] && ok "packaging/deb/build.sh exists" || ko "packaging/deb/build.sh exists"

if command -v dpkg-deb >/dev/null 2>&1; then
  DEBWORK="$(mktemp -d)"
  ( cd "$DEBWORK" && bash "$DEBBUILD" ) >/dev/null 2>&1
  DEBFILE="$DEBWORK/learner_$(cat "$ROOT/VERSION")_all.deb"
  [ -f "$DEBFILE" ] \
    && ok "build.sh produces learner_<VERSION>_all.deb" \
    || ko "build.sh produces learner_<VERSION>_all.deb"
  dpkg-deb -I "$DEBFILE" 2>/dev/null | grep -qF 'Depends: bash, jq' \
    && ok "the .deb declares bash and jq as Depends" \
    || ko "the .deb declares bash and jq as Depends"
  rm -rf "$DEBWORK"
else
  skip "packaging/deb/build.sh smoke test (dpkg-deb not on PATH)"
fi
```

Extend the SPDX-tag loop (from Task 3) — find:

```bash
for f in hooks/learner-config.sh hooks/learner-onboard.sh hooks/learner-record-edit.sh \
         hooks/learner-quiz.sh hooks/learner-cleanup.sh hooks/learner-update-check.sh \
         install.sh uninstall.sh bootstrap.sh test.sh Formula/learner.rb \
         scripts/bump-formula.sh; do
```

and change it to:

```bash
for f in hooks/learner-config.sh hooks/learner-onboard.sh hooks/learner-record-edit.sh \
         hooks/learner-quiz.sh hooks/learner-cleanup.sh hooks/learner-update-check.sh \
         install.sh uninstall.sh bootstrap.sh test.sh Formula/learner.rb \
         scripts/bump-formula.sh packaging/deb/build.sh; do
```

Extend `LIC_SCAN` (from Task 3) the same way, appending `packaging/deb/build.sh` to its final
line.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -iE 'deb|FAIL'`
Expected: the new assertions fail (file doesn't exist yet), unless `dpkg-deb` is absent, in
which case the smoke test reports `skip` instead — that's expected on a machine without it, not
a failure.

- [ ] **Step 3: Create `packaging/deb/build.sh`**

```bash
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
trap 'rm -rf "$PKGROOT"' EXIT

mkdir -p "$PKGROOT/DEBIAN" "$PKGROOT/usr/share/learner" "$PKGROOT/usr/bin"

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
```

```bash
chmod +x packaging/deb/build.sh
```

- [ ] **Step 4: Extend the shellcheck glob again (README.md and ci.yml, together)**

In `.github/workflows/ci.yml`, change the `shellcheck` step's `run:` line (last touched in
Task 3) to:

```yaml
        run: shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh scripts/bump-formula.sh packaging/deb/build.sh
```

In `README.md`'s Development section, change the shellcheck line to the identical string:

```
shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh scripts/bump-formula.sh packaging/deb/build.sh
```

- [ ] **Step 5: Run the tests and shellcheck**

Run: `./test.sh 2>&1 | tail -5 && shellcheck --severity=warning packaging/deb/build.sh`
Expected: `Failed: 0`; shellcheck prints nothing.

- [ ] **Step 6: Commit**

```bash
git add packaging/deb/build.sh test.sh README.md .github/workflows/ci.yml
git commit -m "feat(apt): add the .deb build script"
```

---

### Task 5: CI publishes the `.deb` on a tag push

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `packaging/deb/build.sh` (Task 4).
- Produces: a GitHub Release, with `learner_<VERSION>_all.deb` attached, on every `v*` tag push
  that passes the existing tag-vs-VERSION guard.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, right after the existing CI-shape assertions (the ones reading `$CI_YML`), add:

```bash
grep -qF 'contents: write' "$CI_YML" \
  && ok "CI grants contents:write, needed to publish a release asset" \
  || ko "CI grants contents:write, needed to publish a release asset"

grep -qF 'packaging/deb/build.sh' "$CI_YML" \
  && ok "CI builds the .deb on a tag push" \
  || ko "CI builds the .deb on a tag push"

grep -qF 'softprops/action-gh-release' "$CI_YML" \
  && grep -qF 'learner_*_all.deb' "$CI_YML" \
  && ok "CI publishes the .deb as a release asset" \
  || ko "CI publishes the .deb as a release asset"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -iE 'release asset|tag push|contents:write|FAIL'`
Expected: the three new assertions fail.

- [ ] **Step 3: Edit `.github/workflows/ci.yml`**

Find:

```yaml
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
```

Change to:

```yaml
jobs:
  ci:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
```

Find the tag-matches-VERSION step (the last one in the file) and add two new steps after it:

```yaml
      - name: build .deb
        if: startsWith(github.ref, 'refs/tags/')
        run: bash packaging/deb/build.sh

      - name: publish release asset
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          files: learner_*_all.deb
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh 2>&1 | tail -5`
Expected: `Failed: 0`.

- [ ] **Step 5: Validate the YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo OK`
(Any YAML parser on the machine works — this just catches a bad indent before pushing a tag to
find out.)
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml test.sh
git commit -m "ci: publish the .deb as a release asset on every tag push"
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md` (Install section, Requirements section)
- Modify: `docs/install.html` (Platforms section, new "Homebrew and apt" section, installed-files table)
- Modify: `test.sh`

**Interfaces:**
- Consumes: everything above — this task documents the finished feature.
- Produces: nothing consumed by another task; terminal.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, near the existing README-content assertions, add:

```bash
grep -qF 'brew install learner' "$RM" \
  && ok "README documents the Homebrew install path" \
  || ko "README documents the Homebrew install path"

grep -qF 'sudo apt install ./learner_' "$RM" \
  && ok "README documents the apt/.deb install path" \
  || ko "README documents the apt/.deb install path"

grep -qF 'learner-install' "$RM" \
  && ok "README documents the learner-install activation command" \
  || ko "README documents the learner-install activation command"
```

Near the existing `docs/install.html` assertions (using the already-defined `$SITE_INSTALL`
variable), add:

```bash
grep -qF 'do not exist yet' "$SITE_INSTALL" \
  && ko "install.html no longer claims Homebrew/apt packages don't exist" \
  || ok "install.html no longer claims Homebrew/apt packages don't exist"

grep -qF 'brew install learner' "$SITE_INSTALL" \
  && ok "install.html documents the Homebrew install path" \
  || ko "install.html documents the Homebrew install path"

grep -qF 'sudo apt install ./learner_' "$SITE_INSTALL" \
  && ok "install.html documents the apt/.deb install path" \
  || ko "install.html documents the apt/.deb install path"

grep -qF 'INSTALL_ORIGIN' "$SITE_INSTALL" \
  && ok "install.html's file table documents INSTALL_ORIGIN" \
  || ko "install.html's file table documents INSTALL_ORIGIN"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -iE 'homebrew|apt/\.deb|INSTALL_ORIGIN|FAIL'`
Expected: the new README/install.html assertions fail; the "no longer claims" one currently
`ko`s too, since the stale sentence is still there.

- [ ] **Step 3: Edit `README.md`**

In the Requirements section, after the existing `curl` run-time bullet and before the
POSIX-shell bullet, add:

```markdown
- **Installed via Homebrew or apt?** Use `learner-install` / `learner-uninstall` instead of
  `install.sh` / `uninstall.sh` — same flags, just staged by the package rather than a clone.
```

In the Install section, after the closing clone bullet list (`--yes (-y) — never prompt...`)
and before the "The installer is idempotent..." paragraph, add:

```markdown
On macOS via Homebrew, or on Debian/Ubuntu via a downloaded `.deb`, the package only stages
the files and drops `learner-install`/`learner-uninstall` on `PATH` — it never touches
`~/.claude` by itself. Run `learner-install` afterward, same flags as `install.sh` above.

```bash
# Homebrew — a personal tap, not homebrew-core
brew tap Tykok/learning-with-claude https://github.com/Tykok/learning-with-claude
brew install learner
learner-install --level S --synthesis normal --blanks 2

# apt — a .deb downloaded from GitHub Releases; there is no hosted apt repository
curl -LO https://github.com/Tykok/learning-with-claude/releases/download/v0.2.0/learner_0.2.0_all.deb
sudo apt install ./learner_0.2.0_all.deb
learner-install --level S --synthesis normal --blanks 2
```

(`v0.2.0` above is illustrative — substitute the version you actually want from
[Releases](https://github.com/Tykok/learning-with-claude/releases); the currently-tagged
`v0.1.0` predates this feature and has no `.deb` attached to it.)
```

- [ ] **Step 4: Edit `docs/install.html`**

Replace the Platforms section's closing paragraph — find:

```html
  <p>Native Windows is a genuine gap rather than an untested platform. Every hook is a
  POSIX <code>sh</code> script and each is wired as <code>sh "…"</code>, so without a
  POSIX shell on the machine there is nothing for Claude Code to execute. WSL and Git
  Bash both supply one, and on either of them Learner behaves exactly as it does on
  Linux. Homebrew and <code>apt</code> packages do not exist yet; the one-liner and the
  clone are the two ways in.</p>
```

with:

```html
  <p>Native Windows is a genuine gap rather than an untested platform. Every hook is a
  POSIX <code>sh</code> script and each is wired as <code>sh "…"</code>, so without a
  POSIX shell on the machine there is nothing for Claude Code to execute. WSL and Git
  Bash both supply one, and on either of them Learner behaves exactly as it does on
  Linux.</p>

  <h2 id="packages">Homebrew and apt</h2>

  <p>Both stage the payload and drop <code>learner-install</code> /
  <code>learner-uninstall</code> on <code>PATH</code> — neither touches
  <code>~/.claude</code> on its own. Run <code>learner-install</code> afterward, same flags
  as <a href="#clone"><code>install.sh</code></a> above.</p>

<pre><code># Homebrew — a personal tap, not homebrew-core
brew tap Tykok/learning-with-claude https://github.com/Tykok/learning-with-claude
brew install learner
learner-install --level S --synthesis normal --blanks 2</code></pre>

<pre><code># apt — a .deb downloaded from GitHub Releases; there is no hosted apt repository
curl -LO https://github.com/Tykok/learning-with-claude/releases/download/v0.2.0/learner_0.2.0_all.deb
sudo apt install ./learner_0.2.0_all.deb
learner-install --level S --synthesis normal --blanks 2</code></pre>

  <p><code>v0.2.0</code> above is illustrative — substitute the version you want from
  <a href="https://github.com/Tykok/learning-with-claude/releases">Releases</a>.</p>
```

Add the matching table-of-contents entry — find:

```html
      <li><a href="#platforms">Platforms</a></li>
    </ol>
  </nav>
```

and change it to:

```html
      <li><a href="#platforms">Platforms</a></li>
      <li><a href="#packages">Homebrew and apt</a></li>
    </ol>
  </nav>
```

Add the new installed-file row — find:

```html
      <tr><td><code>$CFG/skills/learner/VERSION</code></td><td>The installed version string; re-copied unconditionally on every install/re-install, so it always matches what's on disk</td></tr>
```

and add immediately after it:

```html
      <tr><td><code>$CFG/skills/learner/INSTALL_ORIGIN</code></td><td>How this install got here — <code>curl</code>, <code>brew</code> or <code>apt</code>; re-stamped on every install/re-install</td></tr>
```

- [ ] **Step 5: Run the full test suite**

Run: `./test.sh 2>&1 | tail -10`
Expected: `Failed: 0`, including the generic per-page "table of contents matches its N
sections" check for `install.html` (now 6 sections) — that check is automatic and needs no new
assertion, only the matching `<li>` added above.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/install.html test.sh
git commit -m "docs: document the Homebrew and apt install paths"
```

---

## Post-plan note (not a task)

The doc examples in Task 6 use `v0.2.0` as an illustrative version, deliberately not the
already-tagged `v0.1.0` — no GitHub Release exists for `v0.1.0` (Task 5's automation only
starts firing on the *next* tag push), so a `v0.1.0` example would 404 today. The next real
`vX.Y.Z` tag pushed after this feature merges is what actually exercises the full pipeline
(build `.deb`, publish the Release) for the first time; run `scripts/bump-formula.sh vX.Y.Z`
by hand right after that push to catch the formula up.
