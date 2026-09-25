---
description: Check whether a newer Learner version is out and refresh the install, honouring how it was installed (plugin, curl, Homebrew, apt). Use for "learner update", "mets à jour learner".
allowed-tools: Read, Bash
---

# Update mode

`learner update` — check the remote version, and if it is newer, re-run the installer pinned
to it. Read-only until step 2 decides an update is actually needed: nothing is written,
locally or remotely, when the dev is already current.

## 1. Check whether this is a Claude Code plugin install

Before anything else — including the network fetch in step 2 — check whether this skill was
loaded as a Claude Code plugin rather than a traditional install. The base directory this
`SKILL.md` was read from is already visible in your own context (it was named when the skill
loaded); if that path contains `/plugins/`, this is a plugin install.

If so, stop here — report and go no further:

```
Installed as a Claude Code plugin. Run `/plugin update learner` (or
`claude plugin update learner`) instead — Claude Code manages this install's version, not
this file.
```

A plugin install never runs `install.sh`, so `$CFG/skills/learner/VERSION` and
`$CFG/skills/learner/INSTALL_ORIGIN` (steps 2 and 3 below) never exist for it — proceeding
past this check would either misreport "no version installed" or, worse, curl-bootstrap a
second, traditional install directly on top of a plugin install that already works.

## 2. Read, validate and compare

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
through to step 4. Validate before comparing, and before anything else touches `$REMOTE`: step
4 builds a URL out of it, and a malformed value must never reach that unchecked. A `curl`
failure on the fetch above is not silence, unlike the background check — the dev asked for
this directly, so report it in one line and stop rather than falling through with an empty
`$REMOTE` that `learner_version_valid` would then (correctly) reject anyway.

## 3. Check the install origin

```bash
ORIGIN=$(cat "$CFG/skills/learner/INSTALL_ORIGIN" 2>/dev/null); ORIGIN="${ORIGIN:-curl}"
```

An install from before this file existed has no marker at all — treat a missing file the same
as `curl`, since curl or a bare clone is exactly what every install predating it used.

- **`curl`** → continue to step 4, unchanged.
- **`brew`** → print, and stop. Nothing is written — `brew` owns the payload on disk, not this
  protocol:
  ```
  Installed via Homebrew. Run: brew upgrade learner && learner-install
  ```
- **`apt`** → print, and stop, naming the exact asset so the dev isn't left guessing at a
  filename:
  ```
  Installed via apt. Download learner_${REMOTE}_all.deb from
  https://github.com/Tykok/learning-with-claude/releases/tag/v$REMOTE, then:
    sudo apt install ./learner_${REMOTE}_all.deb && learner-install
  ```

Both guidance branches point at `learner-install` rather than re-deriving `install.sh`'s own
flags here — a third copy of "here's how to pass --level" would drift from the other two the
same way two implementations of the installer itself would.

## 4. Re-run the installer, pinned (origin: curl only)

```bash
sh "$CFG/hooks/learner-self-update.sh" "$REMOTE"
```

`learner-self-update.sh` ships with the install, beside the other hooks: this step runs a
local, readable file rather than fetching a script from the network and executing it. It
downloads the release tarball for tag `v$REMOTE` — never `main` — and runs that tarball's
`install.sh`. It fetches to a file before extracting, not a streamed pipe: without
`pipefail`, a failed fetch would read as an empty archive and surface as the wrong error.

If it exits non-zero, relay its `error:` line in one sentence. The likeliest one is
`no released tag vX.Y.Z yet`, and that gap is real, not theoretical: `VERSION` on `main` and
the release tag are two separate git pushes, so the file can say a version is out before the
matching tag exists. CI's tag-vs-VERSION guard only runs on the tag push, so it cannot catch
that window from the other side. Report the named reason instead of "nothing happened."

No flags are needed: `learner.json` already exists — this is always a re-install, never a
first one — so `install.sh`'s onboarding prompts stay gated off and no terminal is needed.

## 5. Confirm (origin: curl only)

Re-read `$CFG/skills/learner/VERSION`. If it now reads `$REMOTE`, report the new version in one
line. If it still reads the old value, say the update did not take — never claim success on an
assumption. Step 3's `brew`/`apt` branches, and step 1's plugin branch, already stopped before
this point — there is nothing here to confirm for them.
