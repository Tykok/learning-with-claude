# Claude Learner — versioning and self-update

Date: 2026-08-05
Status: approved design, not yet implemented

## Goal

Learner has shipped features across several tags (`v0.1.0` and unreleased work since), but a
dev who installed once has no way to know a newer version exists, and no way to pull it in
short of re-running the pinned-ref one-liner from memory. Give every install a version it can
report, a quiet check that notices when it is behind, and a command that catches it up —
without turning "update" into a second implementation of the installer.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | The check is notify-only. It never updates on its own; the dev runs `learner update`. |
| 2 | The remote version is read from a plain `VERSION` file on `main`, not the GitHub Releases API — no rate limit, no GitHub-specific dependency. |
| 3 | The check is throttled to once per 24h, not once per session. |
| 4 | `learner update` re-runs the existing `bootstrap.sh` pinned to the latest tag. No new fetch/install script — two implementations of the same install would drift, the same reasoning `bootstrap.sh` itself already states about `install.sh`. |
| 5 | The installed version lives at `$CFG_DIR/skills/learner/VERSION`, copied there by `install.sh` on every run (first install and update alike) — it travels with the skill files it describes, and a plain `uninstall.sh` (no `--purge` needed) removes it along with them. |
| 6 | The update-check hook has no hard dependency on `jq`. It reads a plain-text file and prints a fixed-shape JSON string by hand, so it still works on the machine `learner-onboard.sh` is already telling to install `jq`. |
| 7 | `curl` becomes a soft runtime dependency for this one hook. Its absence degrades to silence, never an error — unlike `jq`, which every other hook already treats as required. |

## 1. `VERSION` and the tag convention

A new file, `VERSION`, at the repo root: one line, bare semver, e.g. `0.2.0`. No `v` prefix —
that belongs on the git tag (`v0.2.0`, annotated, continuing the `v0.1.0` convention already in
use).

Bumping `VERSION` is part of cutting a release: the commit that gets tagged `vX.Y.Z` carries
`VERSION` containing `X.Y.Z`. §6 adds a CI check so the two cannot drift silently.

No pre-release or build-metadata suffixes (`-rc1`, `+build`) — out of scope, §9. The compare
helper in §4 assumes exactly three numeric dot-separated fields.

## 2. Installed version

`install.sh`'s existing copy loop gains one line, alongside `SKILL.md` and `references/*.md`:

```sh
cp "$SRC_DIR/VERSION" "$CFG_DIR/skills/learner/VERSION"
```

Unlike `learner.json`, this is **never** left alone on a re-run — it must always reflect what
is actually on disk, first install or update alike. `uninstall.sh` needs no change: it already
does `rm -rf "$CFG_DIR/skills/learner"`, which takes `VERSION` with it.

`learner status` (SKILL.md § Status) gains one line, read the same read-only way as the level:

```sh
cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/learner/VERSION" 2>/dev/null
```

Printed alongside the level line — "Level: S · v0.2.0" — not a new numbered step; the existing
"print one line for the level" instruction just names both.

## 3. The update-check hook

New file: `hooks/learner-update-check.sh`, wired as a second, independent `SessionStart` entry
in `hooks/settings.snippet.json` (own top-level array entry, same shape as `learner-onboard.sh`'s,
so both fire on every session start regardless of each other):

```json
"SessionStart": [
  { "hooks": [ { "type": "command", "command": "sh \"…/hooks/learner-onboard.sh\"", "timeout": 10 } ] },
  { "hooks": [ { "type": "command", "command": "sh \"…/hooks/learner-update-check.sh\"", "timeout": 10 } ] }
]
```

Flow, in order, every step fails closed (exit 0, no output) rather than ever blocking a session:

1. **Throttle, before anything else.** Read `$CFG_DIR/learner/.last-update-check` (a bare unix
   timestamp, `date +%s`). If it exists and is less than 86400 seconds old, exit 0 immediately —
   no `curl`, no comparison.
2. **Write the throttle stamp now, not after the fetch succeeds.** An offline machine must not
   pay the `curl` timeout on every single session for days — throttle to one *attempt* per 24h,
   not one *success* per 24h.
3. **Soft-require `curl`.** `command -v curl >/dev/null 2>&1 || exit 0`. No message: `curl` was
   never a documented hook-runtime requirement (only an install-time one, for `bootstrap.sh`),
   and this hook must not be the one that makes it a hard dependency for everyone who installed
   by cloning the repo.
4. **Fetch**, short timeout so a stalled network never stalls session start:
   ```sh
   URL="${LEARNER_VERSION_URL:-https://raw.githubusercontent.com/Tykok/learning-with-claude/main/VERSION}"
   REMOTE=$(curl -fsSL --max-time 2 "$URL" 2>/dev/null) || exit 0
   ```
   `LEARNER_VERSION_URL` mirrors `bootstrap.sh`'s own `LEARNER_URL` override, and exists for the
   same reason: `test.sh` must not reach the network, and reads this back through a `file://`
   URL instead.
5. **Read the local version.** `LOCAL=$(cat "$CFG_DIR/skills/learner/VERSION" 2>/dev/null)`. An
   install predating this feature has no such file; `LOCAL` is then empty. That is a deliberate
   signal, handled before the generic compare: empty `LOCAL` skips straight to step 7 and
   notifies — a real version always beats "none installed yet". `learner_version_gt` (§4) is
   not asked to make that call; its own empty-string case fails closed for a different reason
   (malformed input, §4), and conflating the two would make "no local file" silently report no
   update, which is the one case this feature exists to catch.
6. **Otherwise, compare** with `learner_version_gt "$REMOTE" "$LOCAL"` (§4). Malformed input on
   either side (not three numeric dot-separated fields) exits the whole hook silently — never
   crash a session over a remote file some fork or fat-fingered edit left malformed.
7. **Notify** — reached from step 5 directly, or from step 6 when it says yes — hand-built JSON
   (decision #6 — no `jq`):
   ```sh
   CTX="Learner v$REMOTE is available (installed: v${LOCAL:-none}) - run \`learner update\`."
   printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$CTX"
   ```
   Safe to hand-build here specifically because every value in `$CTX` is either static English
   text or a version string already validated as three numeric fields by step 6 — nothing
   user-controlled or free-text ever reaches this `printf`, which is what would make hand-built
   JSON a bug elsewhere in this codebase.

## 4. `learner_version_gt` — the compare helper

Added to `hooks/learner-config.sh`, next to `learner_level`, in the same pure-POSIX style — no
`sort -V` (a GNU extension `learner-config.sh` cannot assume; the project already runs its
tests on macOS and Linux/dash):

```sh
# learner_version_gt A B — true if A > B, both "X.Y.Z" with X/Y/Z decimal integers.
# Malformed input on either side returns false (fails closed: no update offered).
learner_version_gt() {
  case "$1" in *.*.*) ;; *) return 1 ;; esac
  case "$2" in *.*.*) ;; *) return 1 ;; esac
  a1=${1%%.*}; a_rest=${1#*.}; a2=${a_rest%%.*}; a3=${a_rest#*.}
  b1=${2%%.*}; b_rest=${2#*.}; b2=${b_rest%%.*}; b3=${b_rest#*.}
  case "$a1$a2$a3$b1$b2$b3" in *[!0-9]*) return 1 ;; esac
  [ "$a1" -gt "$b1" ] && return 0; [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0; [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -gt "$b3" ]
}
```

The digits-only guard runs once on the concatenation of all six fields rather than six separate
`case` statements — same check, a sixth the code.

## 5. `learner update`

One new Dispatch row in `SKILL.md`:

| `update` | Check the remote version, refresh via `bootstrap.sh` if newer | `references/update.md` |

`references/update.md` protocol:

1. Read local version (`$CFG_DIR/skills/learner/VERSION`) and remote version (same URL and
   fallback behaviour as the hook — offline or unreachable is reported, not swallowed, since
   this run was asked for).
2. Equal, or remote not newer → say so in one line, stop. No network write, no re-install for
   nothing.
3. Remote newer → run:
   ```sh
   curl -fsSL "https://raw.githubusercontent.com/Tykok/learning-with-claude/v$REMOTE/bootstrap.sh" \
     | LEARNER_REF="v$REMOTE" sh
   ```
   No flags needed: `learner.json` already exists (this is always a re-install, never a first
   one), so `install.sh`'s entire onboarding-prompt block is gated off regardless, and
   `bootstrap.sh`'s no-tty guard only fires when `learner.json` is absent.
4. Re-read `$CFG_DIR/skills/learner/VERSION` and report the new version. If it did not change,
   say the update did not take rather than claiming success.

## 6. CI guard: tag must match `VERSION`

`.github/workflows/ci.yml` gains a tag trigger and one conditional step:

```yaml
on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:

jobs:
  ci:
    steps:
      - uses: actions/checkout@v4
      - name: shellcheck
        run: shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh bootstrap.sh test.sh
      - name: tests
        run: ./test.sh
      - name: tag matches VERSION
        if: startsWith(github.ref, 'refs/tags/')
        run: |
          TAG="${GITHUB_REF_NAME#v}"
          FILE="$(cat VERSION)"
          if [ "$TAG" != "$FILE" ]; then
            echo "tag v$TAG does not match VERSION file ($FILE)"; exit 1
          fi
```

Catches "cut the tag, forgot to bump `VERSION`" (or the reverse) before anyone's update-check
hook reports a version nobody can actually `update` into, since `learner update` always
resolves to `vREMOTE`'s tag, not to a commit on `main`.

## 7. Known limitation

An install that predates this feature has no update-check hook wired in at all — there is no
retroactive way to notify a dev who is not already running a version that ships the notifier.
The first hop past this design still has to happen the way `README.md` already documents:
re-running the pinned-ref one-liner by hand. Every version from here on notifies forward.

## 8. Files touched

| File | Change |
|---|---|
| `VERSION` | new, repo root |
| `install.sh` | copy `VERSION` into `$CFG_DIR/skills/learner/VERSION`, unconditionally |
| `hooks/learner-config.sh` | `learner_version_gt` (§4) |
| `hooks/learner-update-check.sh` | new hook (§3) |
| `hooks/settings.snippet.json` | second `SessionStart` entry |
| `skills/learner/SKILL.md` | Dispatch row for `update`; one line in § Status |
| `skills/learner/references/update.md` | new — the protocol in §5 |
| `docs/usage.html` | `<dt>`/`<dd>` for `learner update` under "On demand" |
| `README.md` | `curl` noted as a soft runtime dependency (Requirements section) |
| `.github/workflows/ci.yml` | tag trigger + §6 step |
| `test.sh` | assertions in §9 |

`test.sh:674`'s 120-line cap on `SKILL.md` has 31 lines of headroom at 89/120 today; one
Dispatch row and one Status-section clause fit inside it. The existing dispatch-table-to-
`usage.html` cross-check (`test.sh:1261`) picks up the new `update` subcommand automatically —
no test change needed for that half, only the doc row itself.

## 9. Tests

1. **`learner_version_gt` correctness** — equal, patch/minor/major bump each direction, and the
   digits-only guard rejecting a non-numeric field (`1.x.0` vs `1.0.0`) by returning false.
2. **Throttle**: a fresh `.last-update-check` (just written) makes the hook exit with no output
   and no `curl` invocation; an absent or 25h-old one lets it proceed. (Fake "old" by writing a
   timestamp `date +%s` minus 90000, not by sleeping.)
3. **`curl` absent** → hook exits 0, no output — simulate by pointing `PATH` at a directory with
   every other coreutil symlinked in except `curl`.
4. **`LEARNER_VERSION_URL` override** honoured, read back through a `file://` fixture, mirroring
   `bootstrap.sh`'s own `LEARNER_URL` test (no network reached).
5. **Notification fires** when the fixture's version is newer than a fixture `VERSION` file, and
   the emitted line is valid JSON (`jq -e .`) with the expected `hookEventName`.
6. **Notification also fires when the local `VERSION` file is absent** (pre-feature install) —
   the empty-`LOCAL` path in step 5 of §3, kept distinct from the malformed-input path in item 8
   below.
7. **No notification** when versions are equal, and when the fixture is older.
8. **No notification when the fixture content is malformed** (fails closed, §4) — not to be
   confused with item 6: an *absent* file notifies, a *garbled* one does not.
9. **`install.sh` copies `VERSION`** into `$CFG_DIR/skills/learner/VERSION` on both a first
   install and a re-run over an existing config, and the copy always matches the source (never
   left stale the way `learner.json` deliberately is).
10. **`references/update.md` exists**, added to the hardcoded reference list `test.sh:668`
    already maintains.
11. **`SKILL.md` still ≤ 120 lines** — the existing check, now exercising the added headroom.
12. **CI workflow shape**: `test.sh` already reads `.github/workflows/ci.yml` to keep some
    assertion in step with it (per `README.md`'s "an assertion in `test.sh` reads that workflow
    file and keeps the two in step") — extend that same assertion to cover the new tag trigger
    and step name, rather than trusting the YAML by eye.

Patterns use bracket expressions or `-F`, never a backslash before an ordinary character — the
existing rule stated in the Notion-export spec's own Tests section, restated here because this
feature adds `grep`/`case` patterns of its own.

## Out of scope

- **Auto-apply.** Decision #1. The dev always runs `learner update` themself.
- **GitHub Releases API, changelog display, release notes in the notification.** Decision #2 —
  a plain `VERSION` file carries none of that, deliberately: no GitHub-specific dependency, no
  rate limit, one field to compare.
- **Homebrew/`apt` version awareness.** Out of scope in the bootstrap-installer design already;
  this feature does not reopen it.
- **Pre-release/build-metadata versions** (`-rc1`, `+build`). §1 — the compare helper assumes
  exactly three numeric fields; a fourth kind of version string is a separate design.
- **Retroactive notification for pre-feature installs.** §7 — structurally impossible, not
  deferred.
- **A `CHANGELOG.md`.** Not asked for; `VERSION` plus annotated tag messages (already the
  practice — see `v0.1.0`'s tag body) cover "what changed" today.

## Traceability

| Request | Section |
|---|---|
| Repo updatable based on a version, so anyone can update Learner | 2, 3, 5 |
| Put versioning in place | 1, 6 |
