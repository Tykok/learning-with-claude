# Claude Learner — a real hosted apt repository

Date: 2026-08-06
Status: approved design, not yet implemented

## Goal

`docs/superpowers/specs/2026-08-06-brew-apt-packaging-design.md` deliberately shipped apt as
a downloaded `.deb` only — no repository, no signing key, no ongoing maintenance. That
decision is reopened here on request: `sudo apt install learner` should work directly, after
a one-time repository setup, the same way `brew install learner` already does after a one-time
`brew tap`. `curl` stops being how you install and becomes one alternative among several,
listed last.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | The apt repo is hosted on the same GitHub Pages site, under a new `apt/` path — no third-party package-hosting service, no second repo. |
| 2 | Repository generation and signing are 100% automated in CI, on every relevant deploy — no manual per-release step. |
| 3 | GitHub Pages switches from "Deploy from a branch" (legacy) to "GitHub Actions" build type. The whole site (hand-written pages + the generated apt tree) is assembled and published as a build artifact — **nothing about the apt repo is ever committed to git**. This also retires the `report-build-status` flakiness the legacy build type carried (a separate, already-observed problem this decision incidentally fixes). |
| 4 | The apt repo carries only the current latest GitHub Release's `.deb` — no version history inside the repo itself (matches today's single-version `.deb`-download behavior; not a regression). |
| 5 | A dedicated GPG key signs the repo — not tied to any personal identity. Private key lives only in a GitHub Actions secret; the public key is published on the site. Generating this key and setting the secret is a **separate, explicitly-confirmed action** at execution time, not silently done as part of a code change. |
| 6 | Docs reorder to: apt (repository) first, Homebrew second, clone-and-run third, the `curl \| sh` one-liner last, explicitly labelled an alternative. The existing manual `.deb`-download method survives as a documented fallback for anyone who doesn't want to add a repository. |

## 1. The GPG signing key

Generated once, out of band (not by any script in this repo):

```bash
export GNUPGHOME="$(mktemp -d)"
gpg --batch --gen-key <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Claude Learner Package Signing
Name-Email: 56304246+Tykok@users.noreply.github.com
Expire-Date: 0
EOF
KEYID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5; exit}')
gpg --armor --export-secret-keys "$KEYID"   # → GitHub Actions secret APT_SIGNING_KEY
gpg --armor --export "$KEYID"               # → kept for reference; CI re-derives this at build time
```

`Name-Email` uses the GitHub-provided noreply address for the repo owner, not a personal
address — this key's identity only needs to be verifiable as "belongs to this project," not
tied to any one inbox. `Expire-Date: 0` (never expires): rotation would mean re-publishing
the public key at the same URL and asking every existing install to redo the one-time trust
step, which is manual regardless of expiry — an expiring key would only add a forced-rotation
failure mode with no corresponding safety benefit for a low-traffic personal project. §7 covers
compromise/rotation as a residual manual process, not something this design automates.

The private key becomes a repository secret, `APT_SIGNING_KEY` (the full armored block,
newlines intact). No passphrase (`%no-protection`) — a passphrase on a key whose only holder
is a CI secret store adds no protection, only a chance to lock the key out of its own pipeline.

## 2. Repository layout

Standard apt layout, single suite, single component, one architecture:

```
docs/apt/
  learner.gpg                              # public key, ASCII-armored
  dists/stable/
    InRelease                              # clear-signed Release — what modern apt reads
    Release                                # same content, unsigned — kept for older apt
    main/binary-all/
      Packages
      Packages.gz
  pool/main/l/learner/
    learner_<VERSION>_all.deb              # always exactly one file: the current release
```

`stable`/`main`/`binary-all` are the conventional names, not meaningful choices — `all` is the
one real fact here: this package is architecture-independent, so users add the source with no
arch qualifier and it resolves everywhere.

## 3. Deploy pipeline (`.github/workflows/ci.yml`)

A third job, `deploy-pages`, added alongside the existing `ci` and `release` jobs. It runs
whenever `ci` succeeds — on a push to `main` (keep the hand-written pages current) and on a
tag push (pick up the release `release` just cut) — regardless of whether `release` itself ran
or was skipped (it's `if`-gated to tag pushes only, same as today):

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

`assemble-site.sh` (new):

1. `mkdir -p _site && cp -r docs/*.html docs/assets docs/.nojekyll _site/` — the hand-written
   site, byte-for-byte, unchanged. Nothing here is templated or transformed.
2. Fetch the current release: `gh release download --pattern 'learner_*_all.deb' --dir /tmp/pool latest` (falls through cleanly with a clear log line and an empty `apt/` tree if no release exists yet — e.g. the very first deploy after this lands, before any tag carries a `.deb`; the hand-written site still deploys either way, since a missing apt tree must never block the rest of the site from going out).
3. Build the pool and run `dpkg-scanpackages`/`gzip` for `Packages`/`Packages.gz` (§2's layout,
   rooted at `_site/apt`).
4. `apt-ftparchive release _site/apt/dists/stable > _site/apt/dists/stable/Release` (computes
   the file lists and checksums; hand-rolling those invites exactly the kind of subtle checksum
   bug a real tool exists to avoid).
5. Import `APT_SIGNING_KEY` into a throwaway `GNUPGHOME`, `gpg --clearsign` the `Release` file
   into `InRelease`, then `gpg --armor --export` the same key to `_site/apt/learner.gpg` — the
   public key is re-derived from the secret every run rather than separately maintained, so
   there is only one place it can ever drift from what actually signed the repo.
6. `rm -rf "$GNUPGHOME"` before the step ends — the private key must not persist in the
   runner's filesystem past this one step, even though the runner itself is ephemeral.

`ubuntu-latest` already carries `dpkg-dev` (→ `dpkg-scanpackages`), `apt-utils`
(→ `apt-ftparchive`), and `gnupg` — no new runner dependency to install.

## 4. Repo settings change

GitHub Pages → Build and deployment → Source: **Deploy from a branch** → **GitHub Actions**.
One-time, done through the UI or `gh api -X PUT repos/Tykok/learning-with-claude/pages -f build_type=workflow`, and only *after* `deploy-pages` above exists and has been verified — flipping the
switch first would leave Pages with no configured Actions workflow to deploy from. Rollback is
the same toggle in reverse: instant, and covered in §7.

## 5. What ships to users

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

One `curl` remains — fetching the trust anchor once, the same pattern Docker's and
HashiCorp's own apt repos use, and not something a signed repository can avoid: apt needs the
key on disk before it can verify anything served over that connection, and there is no
keyless way to establish that first trust.

`learner-uninstall` still does the `~/.claude` teardown; `sudo apt remove learner` (now a real
dpkg-managed package, not a one-off local install) removes the wrapper binaries — the
ordering note already on `safety.html` (§6) gets a one-clause update for the same reason.

## 6. Docs

`README.md` and `docs/install.html`'s Install sections reorder to: apt (repository, §5) →
Homebrew (unchanged from the existing packaging feature) → clone-and-run → curl one-liner,
labelled "Alternative: the curl one-liner." The existing manual `.deb`-download instructions
move under the apt section as "prefer not to add a repository?" rather than being removed —
nobody asked for that path to go away, only for it to stop being the default framing.
`install.html`'s TOC (`<nav class="toc">`) and its `<h2 id>` order both move together — the
existing generic structural test (`test.sh`, "table of contents matches its N sections")
enforces exact document-order equality and will catch a mismatch either way.

`safety.html`'s Uninstall section (already covers `learner-uninstall` from the earlier
feature) gains one clause: `sudo apt remove learner` / `brew uninstall learner` both only
remove the wrapper binaries — run `learner-uninstall` first if you want `~/.claude` cleaned
up too, since the binary that does it is gone afterward either way.

## 7. Known limitations

- **No version history in the repo.** `apt-get install learner=0.1.0` does not resolve — only
  the current latest release is ever present. Decision #4; matches the existing `.deb`
  download's own single-version behavior.
- **Key rotation is a manual process.** A compromised or lost key means: generate a new one
  (§1), replace the `APT_SIGNING_KEY` secret, and every existing install must redo the
  one-time trust step (§5) — there is no push-based re-trust mechanism for a static file
  served over plain HTTPS. Acceptable for a personal-project-scale key; revisit if that scale
  changes.
- **The Pages build-type switch (§4) is a repository setting, not a code change** — it happens
  once, outside any commit, and needs to be sequenced after `deploy-pages` is merged and
  proven, never before. Rollback is the same setting toggled back to "Deploy from a branch" —
  instant, and reverts to exactly today's (already-working, if occasionally flaky) legacy
  behavior.
- **The very first deploy after this lands** has no release to fetch yet if none has been cut
  since the switch — `assemble-site.sh` degrades to publishing the hand-written site with no
  `apt/` tree at all (§3, step 2), rather than failing the whole deploy over a missing
  package. The next tag push fills it in.

## 8. Files touched

| File | Change |
|---|---|
| `packaging/apt-repo/assemble-site.sh` | new — §3 |
| `.github/workflows/ci.yml` | new `deploy-pages` job (§3); `permissions`/`environment` blocks |
| `README.md` | Install section reordered (§6) |
| `docs/install.html` | Install sections reordered; TOC reordered to match (§6) |
| `docs/safety.html` | Uninstall section gains the `apt remove` clause (§5) |
| `test.sh` | assertions below |
| *(repository setting, not a file)* | Pages build type: branch → Actions (§4) |
| *(one-time, out of band, not committed)* | GPG key generation; `APT_SIGNING_KEY` secret (§1) |

## 9. Tests

1. **`packaging/apt-repo/assemble-site.sh` shellcheck-clean**, added to the existing shellcheck
   glob (`ci.yml` and `README.md`'s Development line, kept byte-identical per the existing
   `test.sh` assertion).
2. **End-to-end verification, done once by hand during implementation** (not a permanent
   `test.sh` case — a full apt repository round-trip needs a container and real `gpg`/`apt`
   binaries, too heavy for every local test run): in a `debian:stable-slim` container, import
   the exported public key, add the generated `sources.list` entry against a locally-served
   copy of the generated `_site/apt` tree, `apt update`, then `apt install learner` — resolved
   from the repo itself, not a local file — and confirm it resolves, downloads, and installs
   correctly, with `dpkg -s learner` reporting the right version afterward.
3. **`gpg --verify` accepts `InRelease`** against the exported public key, run locally (no
   container needed) — confirms the sign step actually produced a valid signature over the
   exact `Release` content being served, not a stale or mismatched one.
4. **Missing-release degradation** (§7): running `assemble-site.sh` with `gh release download`
   pointed at a repo/tag with no releases yet must still populate `_site` with the hand-written
   pages and must not exit non-zero — a bad flag here would take down the entire site over an
   apt-only edge case.
5. **`README.md`/`install.html` ordering**: a positional assertion (e.g. compare `grep -n`
   line numbers of the apt, Homebrew, clone, and curl-one-liner section markers) confirming
   apt < Homebrew < clone < curl, in that order, in both files.
6. **`install.html`'s TOC-matches-h2-order check** (existing generic `test.sh` assertion,
   already covers any page) needs no new code, only for the reordered sections to actually
   satisfy it — it will fail loudly if they don't.
7. **`safety.html` documents `apt remove`**, alongside the existing `learner-uninstall`
   assertion from the earlier feature.

## Out of scope

- **A hosted repo for Homebrew.** Not requested, and `brew tap` already gives the same
  "add once, `install` forever" shape apt is gaining here — nothing to fix.
- **Multi-architecture packages.** `Architecture: all` already covers every target this
  project supports; there is no per-arch binary to begin with.
- **Automated key rotation.** §7 — a manual, documented process, not tooling.
- **Removing the curl-based `.deb` download or the `curl \| sh` one-liner.** Decision #6 —
  both stay, reordered and relabelled, not deleted.
- **Submitting to Debian/Ubuntu's own archives.** A different, much larger process (sponsor,
  ITP bug, archive policy) that was never in scope for either apt design.

## Traceability

| Request | Section |
|---|---|
| apt et brew disponibles directement sans passer via curl | 1–5 |
| Mettre apt en premier | 6 |
| Curl est une alternative | 5, 6 |
