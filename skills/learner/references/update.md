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
through to step 2. Validate before comparing, and before anything else touches `$REMOTE`: step
2 builds a URL out of it, and a malformed value must never reach that unchecked. A `curl`
failure on the fetch above is not silence, unlike the background check — the dev asked for
this directly, so report it in one line and stop rather than falling through with an empty
`$REMOTE` that `learner_version_valid` would then (correctly) reject anyway.

## 2. Re-run the installer, pinned

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

## 3. Confirm

Re-read `$CFG/skills/learner/VERSION`. If it now reads `$REMOTE`, report the new version in one
line. If it still reads the old value, say the update did not take — never claim success on an
assumption.
