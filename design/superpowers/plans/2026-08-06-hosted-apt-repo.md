# Hosted apt repository Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `sudo apt install learner` work directly (after a one-time repository add), the
same way `brew install learner` already does after a one-time tap — hosted on the existing
GitHub Pages site, fully automated, never committed to git.

**Architecture:** GitHub Pages switches from "Deploy from a branch" to "GitHub Actions". A new
`deploy-pages` CI job assembles the whole site on every relevant push: the five hand-written
pages copied verbatim, plus an apt repository tree (`Packages`/`Release`/`InRelease`, GPG-signed,
one `.deb`) rebuilt from whatever the current latest GitHub Release is. Nothing about the apt
repo — the `.deb`, the signed metadata, the public key — is ever committed to a branch.

**Tech Stack:** `bash` (the new assembler script), `dpkg-dev` (`dpkg-scanpackages`), `apt-utils`
(`apt-ftparchive`), `gnupg`, GitHub Actions (`actions/upload-pages-artifact`,
`actions/deploy-pages`), `gh` CLI.

## Global Constraints

- Spec: `design/superpowers/specs/2026-08-06-hosted-apt-repo-design.md` — every task implements one of its numbered sections.
- The apt repo lives on the same Pages site, under `apt/` — no second repo, no third-party package host.
- Repo generation and signing are 100% automated in CI — no manual per-release step.
- The apt repo carries only the current latest GitHub Release's `.deb` — no version history stored.
- Nothing about the apt repo (the `.deb`, `Packages`, `Release`, `InRelease`, the public key) is ever committed to a git branch — it is assembled fresh into a build artifact on every deploy.
- The GPG private key lives only in a GitHub Actions secret (`APT_SIGNING_KEY`) — no passphrase, no expiry (decision #5 in the spec).
- Every shipped shell script carries `# SPDX-License-Identifier: GPL-3.0-or-later`, joins `test.sh`'s SPDX-tag loop and `LIC_SCAN` list, and stays `shellcheck --severity=warning` clean — the glob in `.github/workflows/ci.yml`'s shellcheck step and the identical line in `README.md`'s Development section must stay byte-for-byte identical (existing `test.sh` assertion enforces this).
- Docs order, both `README.md` and `docs/install.html`: apt (repository) → Homebrew → clone-and-run → curl one-liner (labelled "Alternative"). The manual `.deb`-download method survives under the apt section, not removed.
- Two steps in this plan are deliberately **not** delegated to a subagent — Task 1 (generating and storing the GPG signing key) and Task 7 (flipping the Pages build-type setting) are sensitive, one-time, out-of-band actions the controller executes directly with explicit confirmation immediately before running them, per the spec's decision #5.

---

### Task 1: Generate the GPG signing key and store the secret

**Not delegated to a subagent.** The controller runs this directly, after confirming with the
human partner immediately beforehand — it creates a real cryptographic secret in the live
GitHub repository.

**Files:** none — nothing here is committed. The public key is re-derived from the secret at
deploy time (Task 2), never separately stored.

**Interfaces:**
- Produces: a GitHub Actions repository secret named `APT_SIGNING_KEY` (the full ASCII-armored
  private key block, no passphrase) that Task 2's script and Task 3's CI job both read by that
  exact name.

- [ ] **Step 1: Confirm with the human partner**

State plainly what is about to happen — a new GPG key pair will be generated locally, the
private half becomes a GitHub Actions secret on `Tykok/learning-with-claude`, and the public
half will eventually be published on the site — and wait for an explicit go-ahead before
running anything below.

- [ ] **Step 2: Generate the key pair in a throwaway keyring**

```bash
export GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
gpg --batch --gen-key <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Claude Learner Package Signing
Name-Email: 56304246+Tykok@users.noreply.github.com
Expire-Date: 0
EOF
```

- [ ] **Step 3: Export the private key and set the secret**

```bash
KEYID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5; exit}')
gpg --armor --export-secret-keys "$KEYID" > /tmp/apt-signing-key.asc
gh secret set APT_SIGNING_KEY --repo Tykok/learning-with-claude < /tmp/apt-signing-key.asc
```

- [ ] **Step 4: Verify the secret is set, then destroy every local copy of the private key**

```bash
gh secret list --repo Tykok/learning-with-claude | grep -F APT_SIGNING_KEY
shred -u /tmp/apt-signing-key.asc 2>/dev/null || rm -f /tmp/apt-signing-key.asc
rm -rf "$GNUPGHOME"
unset GNUPGHOME
```

Expected: `gh secret list` prints a line naming `APT_SIGNING_KEY` with a recent "Updated"
timestamp. No file under `/tmp` or elsewhere still holds the armored private key.

- [ ] **Step 5: Report to the human partner**

State that the secret is set, name the key's email identity
(`56304246+Tykok@users.noreply.github.com`) for their records, and that no further action is
needed from them for this task.

---

### Task 2: The site-and-apt-repo assembler script

**Files:**
- Create: `packaging/apt-repo/assemble-site.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: env var `APT_SIGNING_KEY` (required, the armored private key — Task 1 sets this as
  a real secret; tests use a locally-generated throwaway key instead, never the real one).
  Optional env var `APT_DEB_SOURCE` (a local path to a `.deb` file) — when set, the script uses
  that file directly instead of calling `gh release download`, exactly the way `bootstrap.sh`
  already supports `LEARNER_URL` and `hooks/learner-update-check.sh` supports
  `LEARNER_VERSION_URL` to keep `test.sh` off the network.
- Produces: given an output directory (default `_site`), a copy of `docs/*.html` +
  `docs/assets/` + `docs/.nojekyll`, plus (when a `.deb` source was found) an `apt/` subtree at
  `<output>/apt/{learner.gpg,dists/stable/{Release,InRelease,main/binary-all/{Packages,Packages.gz}},pool/main/l/learner/learner_<VERSION>_all.deb}`.
  Task 3's CI job calls this script as `packaging/apt-repo/assemble-site.sh` with no arguments
  (default output dir `_site`).

- [ ] **Step 1: Write the failing tests**

Add a new section to `test.sh`, after the existing `packaging/deb/build.sh` section (search for
`# --- Debian package`):

```bash
# --- apt repo assembler --------------------------------------------------------
ASSEMBLE="$ROOT/packaging/apt-repo/assemble-site.sh"

[ -f "$ASSEMBLE" ] && ok "packaging/apt-repo/assemble-site.sh exists" || ko "packaging/apt-repo/assemble-site.sh exists"

# A throwaway signing key, generated fresh for this test run only — never the
# real APT_SIGNING_KEY secret, which this file never has access to.
TESTGNUPGHOME="$(mktemp -d)"
chmod 700 "$TESTGNUPGHOME"
GNUPGHOME="$TESTGNUPGHOME" gpg --batch --gen-key <<'EOF' >/dev/null 2>&1
%no-protection
Key-Type: RSA
Key-Length: 2048
Key-Usage: sign
Name-Real: test key
Name-Email: test@example.invalid
Expire-Date: 0
EOF
TESTKEYID=$(GNUPGHOME="$TESTGNUPGHOME" gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5; exit}')
TESTSIGNINGKEY=$(GNUPGHOME="$TESTGNUPGHOME" gpg --armor --export-secret-keys "$TESTKEYID")

if command -v dpkg-scanpackages >/dev/null 2>&1 && command -v apt-ftparchive >/dev/null 2>&1; then
  ASMOUT="$(mktemp -d)"

  # No APT_DEB_SOURCE, and GH_REPO points `gh` at a repo that cannot exist —
  # this fails deterministically regardless of the machine's own `gh auth`
  # state (this repo itself has real releases, so leaving `gh` to infer the
  # remote from cwd would actually succeed and download the real .deb,
  # defeating the point of this test). Must still assemble the hand-written
  # site and must not fail the whole build over a missing package.
  ( APT_SIGNING_KEY="$TESTSIGNINGKEY" GH_REPO="Tykok/learner-apt-repo-test-fixture-does-not-exist" \
    bash "$ASSEMBLE" "$ASMOUT/no-release" )
  rc=$?
  { [ "$rc" = 0 ] && [ -f "$ASMOUT/no-release/index.html" ] && [ ! -d "$ASMOUT/no-release/apt" ]; } \
    && ok "assemble-site.sh ships the site with no apt/ tree when no release is available" \
    || ko "assemble-site.sh ships the site with no apt/ tree when no release is available (rc=$rc)"

  # A fixture .deb via APT_DEB_SOURCE, mirroring how test.sh keeps every other
  # network-touching script (bootstrap.sh, the update-check hook) offline.
  FIXDEB="$(mktemp -d)/learner_9.9.9_all.deb"
  FIXROOT="$(mktemp -d)"
  mkdir -p "$FIXROOT/DEBIAN"
  printf 'Package: learner\nVersion: 9.9.9\nArchitecture: all\nMaintainer: test\nDescription: test fixture\n' \
    > "$FIXROOT/DEBIAN/control"
  dpkg-deb --build --root-owner-group "$FIXROOT" "$FIXDEB" >/dev/null 2>&1

  APT_SIGNING_KEY="$TESTSIGNINGKEY" APT_DEB_SOURCE="$FIXDEB" bash "$ASSEMBLE" "$ASMOUT/with-release"
  rc=$?
  { [ "$rc" = 0 ] \
    && [ -f "$ASMOUT/with-release/index.html" ] \
    && [ -f "$ASMOUT/with-release/apt/pool/main/l/learner/learner_9.9.9_all.deb" ] \
    && [ -f "$ASMOUT/with-release/apt/dists/stable/main/binary-all/Packages" ] \
    && [ -f "$ASMOUT/with-release/apt/dists/stable/InRelease" ] \
    && [ -f "$ASMOUT/with-release/apt/learner.gpg" ]; } \
    && ok "assemble-site.sh builds the full apt tree from a fixture .deb" \
    || ko "assemble-site.sh builds the full apt tree from a fixture .deb (rc=$rc)"

  grep -qF 'learner_9.9.9_all.deb' "$ASMOUT/with-release/apt/dists/stable/main/binary-all/Packages" \
    && ok "the generated Packages file names the fixture package" \
    || ko "the generated Packages file names the fixture package"

  GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; chmod 700 "$GNUPGHOME"
  gpg --batch --import <(printf '%s' "$TESTSIGNINGKEY") >/dev/null 2>&1
  gpg --verify "$ASMOUT/with-release/apt/dists/stable/InRelease" >/dev/null 2>&1 \
    && ok "InRelease's signature verifies against the exported public key" \
    || ko "InRelease's signature verifies against the exported public key"
  unset GNUPGHOME

  # The private key text must never appear in what got written to disk.
  if grep -rqF "$TESTSIGNINGKEY" "$ASMOUT" 2>/dev/null; then
    ko "the private signing key never leaks into the assembled output"
  else
    ok "the private signing key never leaks into the assembled output"
  fi
else
  skip "packaging/apt-repo/assemble-site.sh tests (dpkg-scanpackages/apt-ftparchive not on PATH)"
fi
rm -rf "$TESTGNUPGHOME"
```

Extend the SPDX-tag loop and `LIC_SCAN` (both currently end in
`... scripts/bump-formula.sh packaging/deb/build.sh` from the earlier brew/apt packaging
feature) to also include `packaging/apt-repo/assemble-site.sh`, in both places, the same way
each earlier task in that feature added its own new script.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -iE 'assemble-site|apt repo|FAIL'`
Expected: every new assertion fails or the whole block reports `skip` only if
`dpkg-scanpackages`/`apt-ftparchive` are missing (unlikely on macOS with Xcode CLT or a Linux
dev box with `apt-utils`/`dpkg-dev` — if you see `skip`, install them or note the gap and move
on; the file-existence check still runs either way).

- [ ] **Step 3: Create `packaging/apt-repo/assemble-site.sh`**

```bash
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
```

```bash
mkdir -p packaging/apt-repo
chmod +x packaging/apt-repo/assemble-site.sh
```

- [ ] **Step 4: Extend the shellcheck glob (README.md and ci.yml, together)**

In `.github/workflows/ci.yml`, the `shellcheck` step's `run:` line currently ends in
`... scripts/bump-formula.sh packaging/deb/build.sh`. Append ` packaging/apt-repo/assemble-site.sh`
to that line. Make the identical change to the matching line in `README.md`'s Development
section, so the two stay byte-for-byte identical (the existing `test.sh` assertion checks this).

- [ ] **Step 5: Run the tests and shellcheck**

Run: `./test.sh 2>&1 | tail -10 && shellcheck --severity=warning packaging/apt-repo/assemble-site.sh`
Expected: `Failed: 0`; shellcheck prints nothing.

- [ ] **Step 6: Commit**

```bash
git add packaging/apt-repo/assemble-site.sh test.sh README.md .github/workflows/ci.yml
git commit -m "feat(apt): assemble the site and a signed apt repo at deploy time"
```

---

### Task 3: The `deploy-pages` CI job

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `packaging/apt-repo/assemble-site.sh` (Task 2); the `APT_SIGNING_KEY` secret
  (Task 1, not readable in this task's own tests — the job only needs to exist and be shaped
  correctly, not actually run end-to-end here).
- Produces: nothing further tasks in this plan consume — this is the job that, once Task 7
  flips the Pages setting, actually deploys the site.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, near the existing CI-shape assertions (the ones reading `$CI_YML`), add:

```bash
grep -qF 'deploy-pages:' "$CI_YML" \
  && ok "CI defines a deploy-pages job" \
  || ko "CI defines a deploy-pages job"

grep -qF 'packaging/apt-repo/assemble-site.sh' "$CI_YML" \
  && ok "deploy-pages runs the site assembler" \
  || ko "deploy-pages runs the site assembler"

grep -qF 'actions/upload-pages-artifact' "$CI_YML" \
  && grep -qF 'actions/deploy-pages' "$CI_YML" \
  && ok "deploy-pages uploads and deploys the Pages artifact" \
  || ko "deploy-pages uploads and deploys the Pages artifact"

grep -qF 'pages: write' "$CI_YML" \
  && grep -qF 'id-token: write' "$CI_YML" \
  && ok "deploy-pages grants pages:write and id-token:write" \
  || ko "deploy-pages grants pages:write and id-token:write"

grep -qF 'needs: [ci, release]' "$CI_YML" \
  && ok "deploy-pages runs after both ci and release" \
  || ko "deploy-pages runs after both ci and release"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh 2>&1 | grep -iE 'deploy-pages|FAIL'`
Expected: all five new assertions fail.

- [ ] **Step 3: Add the job to `.github/workflows/ci.yml`**

Add this job at the same indentation level as the existing `ci` and `release` jobs (after
`release`):

```yaml
  deploy-pages:
    needs: [ci, release]
    if: always() && needs.ci.result == 'success' && (needs.release.result == 'success' || needs.release.result == 'skipped')
    runs-on: ubuntu-latest
    permissions:
      pages: write
      id-token: write
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - uses: actions/checkout@v4
      - name: assemble the site
        env:
          GH_TOKEN: ${{ github.token }}
          APT_SIGNING_KEY: ${{ secrets.APT_SIGNING_KEY }}
        run: bash packaging/apt-repo/assemble-site.sh
      - uses: actions/upload-pages-artifact@v3
        with:
          path: _site
      - uses: actions/deploy-pages@v4
        id: deployment
```

- [ ] **Step 4: Run the tests and validate the YAML**

Run: `./test.sh 2>&1 | tail -10 && python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo OK`
Expected: `Failed: 0`; `OK`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml test.sh
git commit -m "ci: add the deploy-pages job (site + apt repo, Actions-built)"
```

Note for whoever runs Task 7: this job cannot actually deploy anything until GitHub Pages'
build type is switched to "GitHub Actions" (Task 7) — until then it will either not run (Pages
still watching the branch directly) or run and have nowhere to deploy to. That's expected;
Task 7 is deliberately sequenced last.

---

### Task 4: Reorder `README.md`'s Install section — apt first

**Files:**
- Modify: `README.md`
- Modify: `test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks (pure docs).
- Produces: nothing later tasks consume.

- [ ] **Step 1: Write the failing test**

In `test.sh`, near the other README content assertions, add:

```bash
apt_line=$(grep -n '^### apt (Debian/Ubuntu)$' "$RM" | head -1 | cut -d: -f1)
brew_line=$(grep -n '^### Homebrew' "$RM" | head -1 | cut -d: -f1)
clone_line=$(grep -n '^### Clone and run$' "$RM" | head -1 | cut -d: -f1)
alt_line=$(grep -n '^### Alternative: the curl one-liner$' "$RM" | head -1 | cut -d: -f1)

{ [ -n "$apt_line" ] && [ -n "$brew_line" ] && [ -n "$clone_line" ] && [ -n "$alt_line" ] \
  && [ "$apt_line" -lt "$brew_line" ] \
  && [ "$brew_line" -lt "$clone_line" ] \
  && [ "$clone_line" -lt "$alt_line" ]; } \
  && ok "README orders Install as apt, Homebrew, clone, then the curl alternative" \
  || ko "README orders Install as apt, Homebrew, clone, then the curl alternative"

grep -qF 'sudo apt install learner' "$RM" \
  && ok "README documents installing directly from the apt repository" \
  || ko "README documents installing directly from the apt repository"

grep -qF 'learner.gpg' "$RM" \
  && ok "README documents the apt repo's signing key setup" \
  || ko "README documents the apt repo's signing key setup"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./test.sh 2>&1 | grep -iE 'orders Install|apt repository|signing key setup|FAIL'`
Expected: all three fail — none of that content or heading structure exists yet.

- [ ] **Step 3: Rewrite the Install section**

Replace the entire `## Install` section of `README.md` (everything from the `## Install`
heading up to, but not including, the `## Development` heading) with:

```markdown
## Install

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
curl -LO https://github.com/Tykok/learning-with-claude/releases/download/v0.2.0/learner_0.2.0_all.deb
sudo apt install ./learner_0.2.0_all.deb
learner-install --level S --synthesis normal --blanks 2
```

(`v0.2.0` is this release. Check [Releases](https://github.com/Tykok/learning-with-claude/releases)
for the current version if you're reading this after a newer one has shipped.)

### Homebrew (macOS or Linux)

```bash
brew tap Tykok/learning-with-claude https://github.com/Tykok/learning-with-claude
brew install learner
learner-install --level S --synthesis normal --blanks 2
```

A personal tap, not homebrew-core.

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

The installer is idempotent: re-running re-copies the hooks and the skill and re-merges the
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./test.sh 2>&1 | tail -15`
Expected: `Failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add README.md test.sh
git commit -m "docs: reorder README Install — apt first, curl one-liner last"
```

---

### Task 5: Reorder `docs/install.html` — apt first, split from Homebrew

**Files:**
- Modify: `docs/install.html`
- Modify: `test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks (pure docs).
- Produces: nothing later tasks consume.

- [ ] **Step 1: Write the failing test**

In `test.sh`, near the other `docs/install.html` assertions (using the existing `$SITE_INSTALL`
variable), add:

```bash
apt_h2=$(grep -n '<h2 id="apt">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
homebrew_h2=$(grep -n '<h2 id="homebrew">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
clone_h2=$(grep -n '<h2 id="clone">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
alt_h2=$(grep -n '<h2 id="alternative">' "$SITE_INSTALL" | head -1 | cut -d: -f1)

{ [ -n "$apt_h2" ] && [ -n "$homebrew_h2" ] && [ -n "$clone_h2" ] && [ -n "$alt_h2" ] \
  && [ "$apt_h2" -lt "$homebrew_h2" ] \
  && [ "$homebrew_h2" -lt "$clone_h2" ] \
  && [ "$clone_h2" -lt "$alt_h2" ]; } \
  && ok "install.html orders sections as apt, Homebrew, clone, then the curl alternative" \
  || ko "install.html orders sections as apt, Homebrew, clone, then the curl alternative"

grep -qF 'sudo apt install learner' "$SITE_INSTALL" \
  && ok "install.html documents installing directly from the apt repository" \
  || ko "install.html documents installing directly from the apt repository"

grep -qF '<h2 id="packages">' "$SITE_INSTALL" \
  && ko "install.html no longer has the old combined packages section" \
  || ok "install.html no longer has the old combined packages section"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./test.sh 2>&1 | grep -iE 'orders sections|apt repository|combined packages|FAIL'`
Expected: the first two fail (nothing exists yet); the third currently passes as `ko` (the old
`id="packages"` section is still there) — after Step 3 it must flip to `ok`.

- [ ] **Step 3: Rewrite the affected sections**

First, the table of contents — find:

```html
    <ol>
      <li><a href="#requirements">Requirements</a></li>
      <li><a href="#one-line">One line</a></li>
      <li><a href="#clone">Clone and run</a></li>
      <li><a href="#installed">What gets installed, and where</a></li>
      <li><a href="#platforms">Platforms</a></li>
      <li><a href="#packages">Homebrew and apt</a></li>
    </ol>
```

Replace with:

```html
    <ol>
      <li><a href="#requirements">Requirements</a></li>
      <li><a href="#apt">apt (Debian/Ubuntu)</a></li>
      <li><a href="#homebrew">Homebrew</a></li>
      <li><a href="#clone">Clone and run</a></li>
      <li><a href="#alternative">Alternative: the curl one-liner</a></li>
      <li><a href="#installed">What gets installed, and where</a></li>
      <li><a href="#platforms">Platforms</a></li>
    </ol>
```

Next, find the existing `<h2 id="one-line">One line</h2>` section — it currently runs from
that heading through the paragraph ending "…which is why the ref appears in both places.</p>",
immediately before `<h2 id="clone">`. Replace that whole `<h2 id="one-line">…</h2>` block with
two new sections, `#apt` and `#homebrew`, placed in that order, immediately before the existing
`<h2 id="clone">Clone and run</h2>` (leave the `clone` section's own heading and content where
they are, unchanged, for now — Step 4 moves it):

```html
  <h2 id="apt">apt (Debian/Ubuntu)</h2>

<pre><code># one time
curl -fsSL https://tykok.github.io/learning-with-claude/apt/learner.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/learner.gpg
echo "deb [signed-by=/usr/share/keyrings/learner.gpg] https://tykok.github.io/learning-with-claude/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/learner.list

# from then on
sudo apt update && sudo apt install learner
learner-install --level S --synthesis normal --blanks 2</code></pre>

  <p>One <code>curl</code> remains — fetching the repository's trust anchor once, the same
  pattern Docker's and HashiCorp's own apt repos use. There is no keyless way to establish
  that first trust, but after this one-time step, <code>sudo apt update &amp;&amp; sudo apt
  upgrade learner</code> is the whole update story — no more <code>curl</code> involved,
  ever.</p>

  <p>Prefer not to add a repository? Grab the <code>.deb</code> directly from
  <a href="https://github.com/Tykok/learning-with-claude/releases">Releases</a> instead:</p>

<pre><code>curl -LO https://github.com/Tykok/learning-with-claude/releases/download/v0.2.0/learner_0.2.0_all.deb
sudo apt install ./learner_0.2.0_all.deb
learner-install --level S --synthesis normal --blanks 2</code></pre>

  <p><code>v0.2.0</code> is this release. Check
  <a href="https://github.com/Tykok/learning-with-claude/releases">Releases</a> for the
  current version if you're reading this after a newer one has shipped.</p>

  <h2 id="homebrew">Homebrew</h2>

<pre><code>brew tap Tykok/learning-with-claude https://github.com/Tykok/learning-with-claude
brew install learner
learner-install --level S --synthesis normal --blanks 2</code></pre>

  <p>A personal tap, not homebrew-core.</p>

  <p>Both apt and Homebrew only stage the files and drop <code>learner-install</code> /
  <code>learner-uninstall</code> on <code>PATH</code> — neither touches <code>~/.claude</code>
  on its own. Run <code>learner-install</code> afterward, same flags as
  <a href="#clone"><code>install.sh</code></a> below. Uninstalling reverses the same way:
  <code>sudo apt remove learner</code> / <code>brew uninstall learner</code> only remove those
  two wrapper binaries — the payload under <code>~/.claude</code> still needs
  <code>learner-uninstall</code> (same as <code>uninstall.sh</code>) to actually come out.</p>

```

- [ ] **Step 4: Move the `clone` section, and relabel `one-line`'s old content as the alternative**

The `<h2 id="clone">Clone and run</h2>` section is already immediately after the two new
sections from Step 3 (nothing to move — Step 3 inserted `#apt`/`#homebrew` directly before it).
Leave its content exactly as it is.

Immediately after the `clone` section's closing content (the paragraph ending "…quit and start
a new session for the hooks to take effect.</p>") and before `<h2 id="installed">`, insert a
new `#alternative` section carrying exactly what used to be `#one-line`'s content, relabelled:

```html
  <h2 id="alternative">Alternative: the curl one-liner</h2>

<pre><code>curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh</code></pre>

  <p>It asks for your level, how often a synthesis question should replace a granular
  one, and how many holes a <code>fill</code> exercise leaves, then writes everything
  under your Claude Code config directory — this is what it fetches and runs under the
  hood. To skip the prompts, pass the flags
  <code>install.sh</code> takes — <code>bootstrap.sh</code> forwards them through
  untouched and owns no defaults of its own:</p>

<pre><code>curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh \
  | sh -s -- --level S --synthesis normal --blanks 2</code></pre>

  <p>To install a specific revision rather than whatever <code>main</code> says today,
  name the ref twice — once in the URL your shell reads, once in <code>LEARNER_REF</code>
  for the payload that URL then fetches. Anything git resolves works: a release tag, a
  branch name, or a commit SHA.</p>

<pre><code>REF=v0.1.0   # a tag, a branch name, or a commit SHA
curl -fsSL "https://raw.githubusercontent.com/Tykok/learning-with-claude/$REF/bootstrap.sh" \
  | LEARNER_REF="$REF" sh</code></pre>

  <p><code>LEARNER_REF</code> pins the payload, not <code>bootstrap.sh</code> itself —
  your shell has already read that from the URL by the time the variable is visible.
  Pinning only one of the two still runs whatever <code>main</code> says, which is why
  the ref appears in both places.</p>

```

- [ ] **Step 5: Run the full test suite**

Run: `./test.sh 2>&1 | tail -15`
Expected: `Failed: 0`, including the generic per-page "table of contents matches its N
sections" structural check (now 7 sections for `install.html`, in the order: requirements, apt,
homebrew, clone, alternative, installed, platforms) — that check is automatic and needs no new
assertion beyond the TOC edit already made in Step 3.

- [ ] **Step 6: Commit**

```bash
git add docs/install.html test.sh
git commit -m "docs: reorder install.html — apt first, split from Homebrew"
```

---

### Task 6: `safety.html`'s Uninstall section gains the apt clause

**Files:**
- Modify: `docs/safety.html`
- Modify: `test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks (pure docs).
- Produces: nothing later tasks consume.

- [ ] **Step 1: Write the failing test**

In `test.sh`, right after the existing assertion `"safety.html's Uninstall section covers the
brew/apt path"` (which checks for `learner-uninstall`), add:

```bash
grep -qF 'apt remove learner' "$SITE_SAFETY" \
  && ok "safety.html's Uninstall section names apt remove specifically" \
  || ko "safety.html's Uninstall section names apt remove specifically"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./test.sh 2>&1 | grep -iE 'apt remove|FAIL'`
Expected: fails — the current text says "Installed via Homebrew or apt?" and "brew uninstall
learner" but never the literal string `apt remove learner`.

- [ ] **Step 3: Edit `docs/safety.html`**

Find the paragraph added by the earlier brew/apt packaging feature:

```html
  <p>Installed via Homebrew or apt? Run <code>learner-uninstall</code> instead of
  <code>./uninstall.sh</code> — same flags, <code>learner-uninstall --purge</code> included.
  <code>brew uninstall learner</code> / removing the <code>.deb</code> only removes
  <code>learner-install</code> and <code>learner-uninstall</code> themselves; it does not
  touch <code>~/.claude</code>. Run <code>learner-uninstall</code> first if you want that
  cleaned up too — do it before the package step if you can, since afterward the binary
  that does it is gone.</p>
```

Replace with (the only change is naming `apt remove learner` alongside `brew uninstall
learner`, since apt now manages this as a real installed package rather than only a one-off
local `.deb`):

```html
  <p>Installed via Homebrew or apt? Run <code>learner-uninstall</code> instead of
  <code>./uninstall.sh</code> — same flags, <code>learner-uninstall --purge</code> included.
  <code>sudo apt remove learner</code> / <code>brew uninstall learner</code> only remove
  <code>learner-install</code> and <code>learner-uninstall</code> themselves; neither touches
  <code>~/.claude</code>. Run <code>learner-uninstall</code> first if you want that cleaned up
  too — do it before the package step if you can, since afterward the binary that does it is
  gone.</p>
```

- [ ] **Step 4: Run the tests**

Run: `./test.sh 2>&1 | tail -10`
Expected: `Failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add docs/safety.html test.sh
git commit -m "docs(safety): name apt remove alongside brew uninstall"
```

---

### Task 7: Switch GitHub Pages to "GitHub Actions" build type

**Not delegated to a subagent.** The controller runs this directly, after confirming with the
human partner immediately beforehand — it is a live repository setting change, and per the
spec (§4) it must happen only after Tasks 1–6 are merged to `main` and `deploy-pages` (Task 3)
has been reviewed as correct. Flipping this before then leaves Pages with no configured
deployment source at all.

**Files:** none — a repository setting, not a commit.

**Interfaces:**
- Consumes: Task 3's `deploy-pages` job must already exist on `main`.
- Produces: nothing further in this plan — this is the last task.

- [ ] **Step 1: Confirm with the human partner**

State plainly: this flips `Tykok/learning-with-claude`'s Pages source from "Deploy from a
branch" to "GitHub Actions", live, right now — and that rollback is the same toggle in
reverse, instant. Wait for an explicit go-ahead.

- [ ] **Step 2: Verify Task 3 is actually on `main`**

Run from the repo root, on `main`, up to date with `origin/main`:

```bash
git log --oneline -1 -- .github/workflows/ci.yml
grep -qF 'deploy-pages:' .github/workflows/ci.yml && echo "present"
```

Expected: `present`. If not, stop — do not flip the setting yet.

- [ ] **Step 3: Flip the setting**

```bash
gh api -X PUT repos/Tykok/learning-with-claude/pages -f build_type=workflow
```

- [ ] **Step 4: Watch the resulting deploy**

```bash
gh run list --limit 3
```

Find the newest `deploy-pages`-containing run (it fires once the setting change itself
registers, or on the next push — if nothing triggers within a couple of minutes, an empty
`git commit --allow-empty -m "chore(pages): trigger the first Actions-based deploy" && git push`
gives it something to react to). Watch it to completion:

```bash
gh run watch <run-id> --exit-status
```

Expected: success. If it fails, read the failed step's log (`gh run view <run-id>
--log-failed`) before touching the Pages setting again — the rollback in Step 1 is always
available if something is structurally wrong and needs more than a quick fix.

- [ ] **Step 5: Verify the live site**

```bash
curl -sI https://tykok.github.io/learning-with-claude/ | head -5
curl -sI https://tykok.github.io/learning-with-claude/apt/learner.gpg | head -5
curl -s https://tykok.github.io/learning-with-claude/apt/dists/stable/InRelease | head -3
```

Expected: `200`/`HTTP/2 200` on all three, and the `InRelease` file's content looks like a
PGP-signed message (`-----BEGIN PGP SIGNED MESSAGE-----`).

- [ ] **Step 6: End-to-end apt verification (do this once, by hand — not a permanent test)**

In a `debian:stable-slim` container (or any Debian/Ubuntu box), run the real one-time setup
from `README.md`'s new apt section against the live site, then `sudo apt update && sudo apt
install learner`, then `dpkg -s learner`. Confirm it resolves and installs from the repository
itself, not a local file, and reports the expected version.

- [ ] **Step 7: Report to the human partner**

State that the switch is live, the first deploy succeeded, and the end-to-end apt install was
verified for real — with the version it installed and the run URL for their own records.

---

## Post-plan note (not a task)

`Task 1`'s key generation and `Task 7`'s setting flip are the two places this plan asks the
controller to act directly rather than dispatch a subagent, and both are gated on an explicit
go-ahead immediately before the sensitive step — not a blanket "the human approved this plan
at the start." Re-confirm at the moment, even if the plan itself was already approved.
