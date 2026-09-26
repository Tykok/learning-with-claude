---
description: Check whether a newer Learner version is out and say how to refresh the install, honouring how it was installed (plugin, curl, Homebrew, apt). Use for "learner update", "mets à jour learner".
allowed-tools: Read, Bash(cat *), Bash(curl -fsSL --max-time 5 *)
---

# Update mode

`learner update` — check the remote version, and if it is newer, tell the dev how to update
for the way Learner was installed. Read-only throughout: nothing is written, locally or
remotely, and nothing is downloaded but the one-line `VERSION` file.

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
past this check would either misreport "no version installed" or, worse, point the dev at a
second, traditional install on top of a plugin install that already works.

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
4 prints a tag and a command out of it, and a malformed value must never reach that unchecked. A `curl`
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

## 4. Print the re-install command (origin: curl only)

Print, and stop. Nothing is fetched and nothing is run — this protocol never downloads code
and executes it; the dev runs the release's own `install.sh`, read from a pinned checkout:

```
Installed via curl or a clone. v$REMOTE is out. To update, run:
  git clone --depth 1 --branch v$REMOTE https://github.com/Tykok/learning-with-claude.git learner-v$REMOTE
  bash learner-v$REMOTE/install.sh
```

Pin the tag `v$REMOTE` — never `main` — which is why step 2 validated `$REMOTE` before it got
here. If the clone fails with `Remote branch v$REMOTE not found`, the gap is real, not
theoretical: `VERSION` on `main` and the release tag are two separate git pushes, so the file
can say a version is out before the matching tag exists — try again later.

No flags are needed: `learner.json` already exists — this is always a re-install, never a
first one — so `install.sh`'s onboarding prompts stay gated off.
