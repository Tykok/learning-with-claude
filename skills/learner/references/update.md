# Update mode

`learner update` — check the remote version, and if it is newer, re-run the installer pinned
to it. Read-only until step 2 decides an update is actually needed: nothing is written,
locally or remotely, when the dev is already current.

## 1. Read both versions

```bash
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOCAL=$(cat "$CFG/skills/learner/VERSION" 2>/dev/null)
REMOTE=$(curl -fsSL --max-time 5 https://raw.githubusercontent.com/Tykok/learning-with-claude/main/VERSION)
```

An empty `$LOCAL` means this install predates versioning — treat it as older than anything. A
`curl` failure here is not silence, unlike the background check: the dev asked for this
directly, so report the fetch failure in one line and stop.

## 2. Compare

`$REMOTE` newer than `$LOCAL` (or `$LOCAL` empty) → step 3. Otherwise say "already on the
latest version (vX.Y.Z)" in one line and stop — no re-install for nothing.

## 3. Re-run the installer, pinned

```bash
curl -fsSL "https://raw.githubusercontent.com/Tykok/learning-with-claude/v$REMOTE/bootstrap.sh" \
  | LEARNER_REF="v$REMOTE" sh
```

No flags needed: `learner.json` already exists — this is always a re-install, never a first
one — so `install.sh`'s onboarding prompts stay gated off regardless, and `bootstrap.sh`'s
no-tty guard only fires when `learner.json` is absent.

## 4. Confirm

Re-read `$CFG/skills/learner/VERSION`. If it now reads `$REMOTE`, report the new version in one
line. If it still reads the old value, say the update did not take — never claim success on an
assumption.
