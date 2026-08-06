# Claude Learner — brew and apt packaging

Date: 2026-08-06
Status: approved design, not yet implemented

## Goal

Today Learner has exactly two ways in: the `curl | sh` one-liner and clone-and-run.
`docs/install.html` already flags the gap itself ("Homebrew and apt packages do not exist
yet"). Give devs `brew install` and a downloadable `.deb` as a third and fourth path, without
turning package management into a second implementation of `install.sh` — and without letting
`learner update` silently fight the package manager once one is in the picture.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | apt ships a `.deb` artifact attached to GitHub Releases — not a hosted apt repository. No GPG signing key, no `reprepro`/`aptly`, no ongoing repo maintenance. |
| 2 | Homebrew ships via a personal tap (`Formula/learner.rb` in this repo, tapped by explicit URL) — not a homebrew-core submission. No external review gate. |
| 3 | Neither package wires learner into `~/.claude` automatically. `brew install`/`apt install` only stage files and drop `learner-install`/`learner-uninstall` on `PATH`; the dev runs `learner-install` themself, same flags `install.sh` already takes. Avoids running as root (apt) or mutating another app's dotfiles as a package-manager side effect. |
| 4 | `learner update` becomes origin-aware. An install stamps how it got there (`curl`/`brew`/`apt`); package-managed installs get told to use their package manager instead of being silently curl-reinstalled behind its back. |

## 1. Install origin marker

`install.sh` gains one new flag, parsed alongside the existing ones:

```
--origin curl|brew|apt   Who is calling this. Defaults to "curl" — every existing
                          invocation (the one-liner, a bare clone) is unaffected.
```

Validated the same way `--synthesis` already is (a `case` over the three literal words;
anything else is `error: --origin must be curl | brew | apt`). Written unconditionally, first
install and every re-install alike — the same treatment `VERSION` already gets, and for the
same reason: this is install-plumbing describing what's on disk right now, not user
preference, so it must never go stale the way `learner.json` deliberately does.

```sh
printf '%s' "$ORIGIN" > "$CFG_DIR/skills/learner/INSTALL_ORIGIN"
```

Lives beside `VERSION`, not inside `learner.json` — it never needs to round-trip through the
skill's config editor or its validation rules, and `uninstall.sh` already deletes it for free:
it does `rm -rf "$CFG_DIR/skills/learner"`, which the new file sits under.

`bootstrap.sh` needs no change: it forwards `"$@"` to `install.sh` untouched, so `--origin`
flows through if a caller ever passes it, and the curl path's default stays `curl` either way.

## 2. Homebrew formula

New `Formula/learner.rb` in this repo. No second repo needed: since this repo isn't named
`homebrew-*`, the tap command just names the URL explicitly —

```
brew tap Tykok/learning-with-claude https://github.com/Tykok/learning-with-claude
brew install learner
```

```ruby
class Learner < Formula
  desc "Turns Claude Code into a learning loop: quizzes you on your own diffs"
  homepage "https://github.com/Tykok/learning-with-claude"
  url "https://github.com/Tykok/learning-with-claude/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "…"
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
    EOS
  end

  test do
    system "#{bin}/learner-install", "--help"
  end
end
```

`test do` runs `--help` specifically: it is the one flag `install.sh` handles inside its
argument-parsing loop, before the "Claude Code must exist" preflight check — the only
invocation guaranteed to exit 0 in a bare CI sandbox with no `claude` on `PATH` and no
`~/.claude`.

Bumping the formula for a new tag is a manual step, mirroring the existing manual
`VERSION`-bump-then-tag discipline (no CI-pushes-to-main). A new helper does the tedious part:

```
scripts/bump-formula.sh v0.2.0
```

Downloads that tag's tarball, computes its `sha256`, rewrites the `url`/`sha256` lines in
`Formula/learner.rb` in place. The maintainer reviews the diff and commits it themself.

## 3. Debian package

New `packaging/deb/build.sh`, run by CI (§4) on every tag push. Lays out:

```
/usr/share/learner/{hooks,skills,install.sh,uninstall.sh,VERSION,LICENSE}
/usr/bin/learner-install   → exec /usr/share/learner/install.sh --origin apt "$@"
/usr/bin/learner-uninstall → exec /usr/share/learner/uninstall.sh "$@"
```

`DEBIAN/control`: `Package: learner`, `Version:` from the repo's `VERSION` file,
`Architecture: all` (no compiled code), `Depends: bash, jq`, `Recommends: curl` — the same
three-tier requirement `README.md`'s Requirements section already states for the curl/clone
paths. Built with `dpkg-deb --build --root-owner-group`.

Install:

```
curl -LO https://github.com/Tykok/learning-with-claude/releases/download/v0.2.0/learner_0.2.0_all.deb
sudo apt install ./learner_0.2.0_all.deb
learner-install --level S --synthesis normal --blanks 2
```

## 4. CI: release automation

`.github/workflows/ci.yml`'s existing tag-push job gains two conditional steps, after the
existing "tag matches VERSION" guard so a mismatched tag never gets this far:

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

Needs `permissions: contents: write` on the job — no GitHub Release object exists for any tag
today (`bootstrap.sh` fetches the tag's auto-generated source tarball directly, never a
Release), so this is new: the `.deb` is the first thing that actually needs one, since it has
to live at a stable URL rather than be rebuilt client-side the way the tarball is.

The shellcheck step's glob extends to cover the new script:

```
shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh packaging/deb/build.sh
```

`README.md`'s Development section carries the same line verbatim — `test.sh` already asserts
the two match character-for-character, so both are edited together.

## 5. `learner update` becomes origin-aware

`references/update.md` step 1 (read local + remote version, compare) is unchanged — a
package-managed dev still gets an accurate "you're current" / "vX.Y.Z is out" answer. Only
step 2 (what to do about a newer version) branches on `$CFG/skills/learner/INSTALL_ORIGIN`:

- **`curl`, or the file is absent** (pre-existing installs) — today's behavior, unchanged:
  curl the pinned `bootstrap.sh` and re-run it.
- **`brew`** — print, and stop (no network write of its own):
  ```
  Installed via Homebrew. Run: brew upgrade learner && learner-install
  ```
- **`apt`** — print, and stop:
  ```
  Installed via apt. Download the new .deb from
  https://github.com/Tykok/learning-with-claude/releases, then:
    sudo apt install ./learner_vX.Y.Z_all.deb && learner-install
  ```

Step 3 (re-read `VERSION`, confirm it moved) only applies to the `curl` branch — the other two
never touch `~/.claude`, so there is nothing to confirm.

The `SessionStart` notifier (`hooks/learner-update-check.sh`) needs no change: its message
already just says "run `learner update`", and that command is now the single place the origin
branch lives.

## 6. Docs and README

- `docs/install.html` §Platforms: drop "Homebrew and apt packages do not exist yet"; add a
  `brew tap` / `apt install ./….deb` block alongside the existing one-liner and clone sections,
  same shape as those two.
- `README.md`: same two blocks added to the Install section; Requirements section notes
  `learner-install`/`learner-uninstall` as the entry points once package-managed (curl/clone
  keep using `install.sh`/`uninstall.sh` directly, unchanged).
- `docs/install.html` §"What gets installed, and where": new row for
  `$CFG/skills/learner/INSTALL_ORIGIN`.
- Uninstall note (both docs): `brew uninstall learner` / removing the `.deb` only removes the
  *staged* copy and the two wrapper binaries — the payload under `~/.claude` still needs
  `learner-uninstall` (or `uninstall.sh`), exactly as it does today regardless of how it got
  there.

## Known limitations

- **No end-to-end `brew install`/`apt install` test in CI.** The existing CI runner is
  `ubuntu-latest` with no Homebrew, and there is no sandboxed apt install either. Both packages
  are verified manually by the maintainer after cutting a release, the same trust boundary the
  curl one-liner already has no automated proof of, either.
- **The formula bump is a separate manual step from the tag push.** A tag can exist briefly
  before `Formula/learner.rb` catches up. Acceptable — it mirrors the existing "bump `VERSION`,
  commit, then tag" discipline, which has the identical brief-lag property already.

## Files touched

| File | Change |
|---|---|
| `install.sh` | `--origin curl\|brew\|apt` flag (default `curl`), validated; writes `INSTALL_ORIGIN` unconditionally |
| `Formula/learner.rb` | new — §2 |
| `scripts/bump-formula.sh` | new — §2 |
| `packaging/deb/build.sh` | new — §3 |
| `.github/workflows/ci.yml` | two new tag-push steps (§4); shellcheck glob extended |
| `skills/learner/references/update.md` | origin branch in step 2 (§5) |
| `docs/install.html` | new install path, `INSTALL_ORIGIN` row, drop the "doesn't exist yet" line |
| `README.md` | same two blocks; shellcheck line kept in sync with CI |
| `test.sh` | assertions below |

## Tests

1. **`--origin` accepted values** write the matching `INSTALL_ORIGIN` content (`curl`, `brew`,
   `apt`), each on a fresh install.
2. **Omitting `--origin` defaults to `curl`** — regression check that every existing call site
   (the one-liner, a bare clone) is unaffected.
3. **An invalid `--origin` value** (`--origin foo`) errors and exits non-zero, same shape as
   the existing `--synthesis` validation.
4. **Re-install refreshes `INSTALL_ORIGIN`** unconditionally, same pattern already covering
   `VERSION` (`test.sh:483-487`) — install once as `curl`, re-install as `brew`, confirm it
   changed.
5. **`uninstall.sh` removes `INSTALL_ORIGIN`** — folds into whatever existing assertion already
   covers `rm -rf "$CFG_DIR/skills/learner"` removing `VERSION`.
6. **`references/update.md` contains all three branches** — grep for the `brew upgrade` and
   `apt install` guidance lines, mirroring how `test.sh` already greps `SKILL.md` for content
   rather than executing the skill.
7. **`packaging/deb/build.sh` shellcheck-clean**, added to the existing shellcheck invocation
   `test.sh` reads back out of `README.md`/`ci.yml` to keep the two in step.
8. **`packaging/deb/build.sh` produces a well-formed control file** when `dpkg-deb` is on
   `PATH`; skipped (reported, not failed) when it isn't — the same soft-dependency pattern
   `test.sh` already uses for `curl`-absent cases, since most dev machines here are macOS
   without `dpkg-deb`.
9. **`Formula/learner.rb` sanity**: file exists, contains `depends_on "jq"`, and both wrapper
   heredocs contain their respective `--origin brew` / (uninstall has none) strings — static
   `grep`, no actual `brew install`.
10. **CI workflow shape**: extend the existing `ci.yml`-reading assertions
    (`test.sh:993-1014`) to also check for the two new tag-push steps and the extended
    shellcheck glob, rather than trusting the YAML by eye.
11. **`SKILL.md` still ≤ 120 lines** — no dispatch-table change in this feature, but the
    existing cap is re-run as a matter of course.

## Out of scope

- **A hosted apt repository.** Decision #1 — no signing key, no repo metadata tooling, no
  `apt upgrade` channel. A `.deb` download is the whole apt story here.
- **homebrew-core submission.** Decision #2 — the tap stays this repo's own.
- **Auto-wiring `~/.claude` from `brew install`/`apt install`.** Decision #3 — always a manual
  `learner-install` afterward.
- **Windows packaging** (Scoop, Chocolatey, winget). Not asked for; native Windows already has
  no supported path per `docs/install.html`'s Platforms section, and this feature doesn't
  reopen that.
- **A real `brew install`/`apt install` CI smoke test.** Known limitation, above — no
  Homebrew or apt sandbox available in the current CI runner.

## Traceability

| Request | Section |
|---|---|
| Learner installable via brew | 2 |
| Learner installable via apt | 3 |
| Keep `learner update` correct once a package manager owns the install | 1, 5 |
