# Versioning and Self-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every Learner install a version it can report (`VERSION`, stamped into
`$CFG_DIR/skills/learner/VERSION`), a throttled background check that notices when a newer one
exists, and a `learner update` subcommand that catches it up.

**Architecture:** A new `VERSION` file at the repo root is the single source of truth, copied
into the install by `install.sh` on every run. A new, `jq`-free `SessionStart` hook
(`learner-update-check.sh`) fetches that same file from `main` once per 24h and prints a one-line
notice through `additionalContext` when it is newer — it never updates anything itself.
`learner update` is a new skill subcommand whose protocol (`references/update.md`) re-runs the
existing `bootstrap.sh`, pinned to the latest tag, rather than reimplementing install logic. A
small POSIX semver-compare helper (`learner_version_valid` / `learner_version_gt`) lands in the
already-shared `hooks/learner-config.sh`. A CI step guards the one hand-maintained invariant —
tag name and `VERSION` content must agree.

**Tech Stack:** POSIX `sh`, `jq` (not used by the new hook — see Task 3), `curl`, `git`. Tests are
`./test.sh` — a plain shell assertion suite, no framework, that never reaches the network.

**Spec:** [`../specs/2026-08-05-versioning-update-design.md`](../specs/2026-08-05-versioning-update-design.md)

## Global Constraints

- `skills/learner/SKILL.md` must stay **≤ 120 lines** — it is always loaded (`test.sh:674`). It
  is at 89 lines today; this plan adds one Dispatch row, a few words to the front-matter
  description, and one clause in § Status — comfortably inside the cap.
- Grep patterns use **bracket expressions or `-F`**, never a backslash before an ordinary
  character — an undefined ERE escape has already broken this suite once, passing under ugrep
  and failing under GNU grep.
- **No new `learner.json` keys.** The installed version is state under
  `$CFG_DIR/skills/learner/`, not configuration; the throttle timestamp is state under
  `$CFG_DIR/learner/`. Neither is hand-edited.
- The only files this skill writes inside a repository remain `.claude/learner.local.json` and
  its `.gitignore` line. Everything this plan adds lives under `$CLAUDE_CONFIG_DIR` or at the
  repo root.
- **The new hook has no hard `jq` dependency** — unlike every other hook here. It must still run
  on the machine `learner-onboard.sh` is already telling to install `jq`. See Task 3.
- **`curl` is a soft run-time dependency** for the new hook only: absence degrades to silence,
  never an error, and never a message (`jq`'s absence, by contrast, is already reported by
  `learner-onboard.sh`).
- Two file lists in `test.sh` are hand-maintained and easy to forget when adding a sixth hook
  file: `LIC_SCAN` (`test.sh:1390-1392`) and the SPDX for-loop (`test.sh:1403-1405`). Task 3
  extends both — miss either and either the MIT-scan silently skips the new file, or its SPDX
  tag goes unchecked.
- Baseline before starting: `./test.sh` prints `Passed: 301   Failed: 0` in a few seconds
  (verified by running it).

---

## File Structure

| File | Responsibility |
|---|---|
| `VERSION` | **new** — repo root, one line, bare semver, the single source of truth |
| `hooks/learner-config.sh` | gains `learner_version_valid` and `learner_version_gt`, next to `learner_level` |
| `hooks/learner-update-check.sh` | **new** — the `SessionStart` notifier, throttled, `jq`-free |
| `hooks/settings.snippet.json` | a second `SessionStart` entry wiring the new hook |
| `install.sh` | copies `VERSION` into the install; copies the sixth hook file |
| `uninstall.sh` | removes the sixth hook file |
| `skills/learner/SKILL.md` | one Dispatch row, one Status-section clause, two description phrases |
| `skills/learner/references/update.md` | **new** — the `learner update` protocol |
| `docs/usage.html` | one `<dt>`/`<dd>` pair under `On demand` |
| `README.md` | one Requirements bullet, noting `curl`'s new soft run-time role |
| `.github/workflows/ci.yml` | a tag trigger and one conditional step |
| `test.sh` | the assertions in every task below |

---

### Task 1: The `VERSION` file

The source of truth everything else reads. Lands first and alone, so later tasks can assume it
exists.

**Files:**
- Create: `VERSION`
- Modify: `install.sh:127-129`
- Modify: `test.sh` — insert after the block ending `test.sh:366`
  (`|| ko "install copies hooks, skill and references"`)

**Interfaces:**
- Produces: `VERSION` at the repo root, and `$CFG_DIR/skills/learner/VERSION` after install —
  the exact path Task 2's hook and Task 4's `references/update.md` both read.

- [ ] **Step 1: Write the failing assertions**

In `test.sh`, immediately after the block ending
`|| ko "install copies hooks, skill and references"` (currently `test.sh:361-366`), insert:

```sh
[ -f "$I/skills/learner/VERSION" ] && [ "$(cat "$I/skills/learner/VERSION")" = "$(cat "$ROOT/VERSION")" ] \
  && ok "install stamps the installed VERSION" \
  || ko "install stamps the installed VERSION"

echo '9.9.9' > "$I/skills/learner/VERSION"
inst "$I" --level S >/dev/null 2>&1
[ "$(cat "$I/skills/learner/VERSION")" = "$(cat "$ROOT/VERSION")" ] \
  && ok "a re-install always refreshes VERSION, unlike learner.json" \
  || ko "a re-install always refreshes VERSION, unlike learner.json"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./test.sh 2>&1 | tail -3`

Expected: `Passed: 302   Failed: 1`. Only the second assertion is a real failure ("a re-install
always refreshes..." — `$I`'s file was forced to `9.9.9` and nothing yet overwrites it back).
The first assertion passes *vacuously*: `$ROOT/VERSION` does not exist yet either, so both sides
of the comparison are empty. Step 5 is what puts it under real load.

- [ ] **Step 3: Create `VERSION`**

```
0.1.0
```

This matches the existing `v0.1.0` tag, not a new release — `main` has drifted ahead of that tag
already (the Notion export, the five-page site, …), but bumping the number is a deliberate
release act (spec §1: tag and file move together), not something this plan does on its own.

- [ ] **Step 4: Copy it in `install.sh`**

In `install.sh`, replace (currently lines 127-129):

```sh
cp "$SRC_DIR/skills/learner/SKILL.md" "$CFG_DIR/skills/learner/SKILL.md"
cp "$SRC_DIR"/skills/learner/references/*.md "$CFG_DIR/skills/learner/references/"
echo "  ✓ skill → $CFG_DIR/skills/learner/"
```

with:

```sh
cp "$SRC_DIR/skills/learner/SKILL.md" "$CFG_DIR/skills/learner/SKILL.md"
cp "$SRC_DIR"/skills/learner/references/*.md "$CFG_DIR/skills/learner/references/"
cp "$SRC_DIR/VERSION" "$CFG_DIR/skills/learner/VERSION"
echo "  ✓ skill → $CFG_DIR/skills/learner/"
```

Unconditional, unlike `learner.json` a few lines below: the installed `VERSION` must always
match what is actually on disk, first install or update alike.

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`

Expected: `Passed: 303   Failed: 0`.

- [ ] **Step 6: Commit**

```bash
git add VERSION install.sh test.sh
git commit -m "$(cat <<'EOF'
feat: stamp the installed VERSION on every install

VERSION at the repo root is the single source of truth the rest of
the versioning feature reads. install.sh copies it unconditionally,
unlike learner.json a few lines below — it must always match what is
actually on disk, not what was there on a previous run.

Starts at 0.1.0, matching the existing tag: bumping it is a release
act for later, not part of introducing the plumbing.
EOF
)"
```

---

### Task 2: `learner_version_valid` and `learner_version_gt`

The compare logic, in isolation, before anything calls it. Split into two single-purpose
functions rather than the one combined helper the spec sketched: validity-checking is reused
as-is by Task 3's hook on both the remote value and (when present) the local one, and a
comparison function that may assume valid input is six lines shorter than one that has to guard
itself against garbage on every call.

**Files:**
- Modify: `hooks/learner-config.sh:63-70` (immediately after `learner_synthesis_n`)
- Modify: `test.sh` — insert after the `synthesisFrequency` loop ending at `test.sh:98`, before
  the `learner_repo_root` block at `test.sh:100`

**Interfaces:**
- Produces: `learner_version_valid V` (exit 0 if `V` is `X.Y.Z`, decimal integers, exit 1
  otherwise) and `learner_version_gt A B` (exit 0 if `A > B`; behaviour on invalid input is
  undefined — callers validate first). Task 3's hook calls both.

- [ ] **Step 1: Write the failing assertions**

In `test.sh`, immediately after the `for pair in "off:0" ...` loop (ending `test.sh:98`), insert:

```sh
for pair in "1.2.3:yes" "0.1.0:yes" "1.0:no" "1.x.0:no" "1.2.3.4:no"; do
  raw="${pair%%:*}"; want="${pair##*:}"
  if cfgsh "learner_version_valid $raw"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] \
    && ok "learner_version_valid '$raw' -> $want" \
    || ko "learner_version_valid '$raw' -> $want (got $got)"
done

for t in "1.2.3:1.2.3:no" "1.2.4:1.2.3:yes" "1.2.3:1.2.4:no" \
         "1.3.0:1.2.9:yes" "2.0.0:1.9.9:yes" "1.9.9:2.0.0:no"; do
  a=$(printf '%s' "$t" | cut -d: -f1)
  b=$(printf '%s' "$t" | cut -d: -f2)
  want=$(printf '%s' "$t" | cut -d: -f3)
  if cfgsh "learner_version_gt $a $b"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] \
    && ok "learner_version_gt $a vs $b -> $want" \
    || ko "learner_version_gt $a vs $b -> $want (got $got)"
done
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^  FAIL'; ./test.sh 2>&1 | tail -2`

Expected: `Passed: 309   Failed: 5` — five real failures: `learner_version_valid '1.2.3' -> yes`,
`learner_version_valid '0.1.0' -> yes`, and the three `learner_version_gt … -> yes` cases (patch,
minor, major bump). Neither function exists yet, so every call fails with "command not found"
and a nonzero status — which reads as `got=no` regardless of input. The six `-> no` cases pass
*vacuously* right now; Step 4 is what puts them under real load.

- [ ] **Step 3: Implement both functions**

In `hooks/learner-config.sh`, immediately after `learner_synthesis_n` (currently ending at line
70), insert:

```sh
# learner_version_valid V — true if V is "X.Y.Z" with X/Y/Z decimal integers.
learner_version_valid() {
  case "$1" in *.*.*) ;; *) return 1 ;; esac
  v1=${1%%.*}; v_rest=${1#*.}; v2=${v_rest%%.*}; v3=${v_rest#*.}
  case "$v1$v2$v3" in *[!0-9]*|'') return 1 ;; esac
}

# learner_version_gt A B — true if A > B. Both must already satisfy
# learner_version_valid; callers validate first (hooks/learner-update-check.sh does).
learner_version_gt() {
  a1=${1%%.*}; a_rest=${1#*.}; a2=${a_rest%%.*}; a3=${a_rest#*.}
  b1=${2%%.*}; b_rest=${2#*.}; b2=${b_rest%%.*}; b3=${b_rest#*.}
  [ "$a1" -gt "$b1" ] && return 0; [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0; [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -gt "$b3" ]
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`

Expected: `Passed: 314   Failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add hooks/learner-config.sh test.sh
git commit -m "$(cat <<'EOF'
feat(config): add a POSIX semver compare for version checks

No sort -V: it is a GNU extension this repo cannot assume (macOS and
Linux/dash both have to pass). Validity and comparison are split so a
caller with an already-known-good local version — install.sh wrote
it — never re-derives what it already trusts, and so the one caller
that does need to distinguish "no local version yet" from "garbage
local version" (the next task's hook) can do so without learner_version_gt
having to guess at that distinction itself.
EOF
)"
```

---

### Task 3: The update-check hook

The whole notify path: fetch, throttle, compare, print — wired into every session, never
blocking one. The biggest task here, but one reviewable unit: a reviewer accepts or rejects the
hook's behaviour as a whole, not fetch-vs-throttle-vs-print separately.

**Files:**
- Create: `hooks/learner-update-check.sh`
- Modify: `hooks/settings.snippet.json`
- Modify: `install.sh:120-121` (the hook-copy loop)
- Modify: `uninstall.sh:98-102` (the hook-removal list)
- Modify: `test.sh` — the top var block (`test.sh:8-11`), the installer section
  (`test.sh:373-376`, `:378-384`), the uninstall section (`test.sh:600-604`), the legacy count at
  `test.sh:643`, the licence lists at `test.sh:1390-1392` and `:1403-1405`, and a new section
  after the onboarding block ending `test.sh:180`

**Interfaces:**
- Consumes: `learner_version_valid` / `learner_version_gt` (Task 2), `$CFG_DIR/skills/learner/VERSION`
  (Task 1).
- Produces: nothing later tasks call directly — Task 4's `references/update.md` re-implements
  the same fetch inline (a foreground, explicit run, not this hook's throttled background one)
  rather than shelling out to it.

- [ ] **Step 1: Write the failing assertions**

In `test.sh`, add `UCHK="$ROOT/hooks/learner-update-check.sh"` to the top var block, next to the
existing `REC` / `QUIZ` / `ONB` / `CLEAN` lines (currently `test.sh:8-11`).

Immediately after the onboarding section's closing line (`test.sh:180`,
`echo '{"level":"S"}' > "$GCFG"`), before the `# --- record-edit` comment, insert:

```sh
# --- update-check hook -------------------------------------------------------
uchk() { printf '{}' | sh "$UCHK"; }
VFIX="$WORK/tmp/remote-version"

UC1="$WORK/uc1"; mkdir -p "$UC1/skills/learner"
echo '0.1.0' > "$UC1/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC1" LEARNER_VERSION_URL="file://$VFIX" uchk)
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("v0\\.2\\.0.*v0\\.1\\.0")' >/dev/null 2>&1 \
  && ok "update-check notifies with remote and installed version when remote is newer" \
  || ko "update-check notifies with remote and installed version when remote is newer (got '$out')"

UC2="$WORK/uc2"; mkdir -p "$UC2/skills/learner"
echo '0.2.0' > "$UC2/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC2" LEARNER_VERSION_URL="file://$VFIX" uchk)
[ -z "$out" ] \
  && ok "update-check silent when versions are equal" \
  || ko "update-check silent when versions are equal (got '$out')"

UC3="$WORK/uc3"; mkdir -p "$UC3/skills/learner"
echo '0.3.0' > "$UC3/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC3" LEARNER_VERSION_URL="file://$VFIX" uchk)
[ -z "$out" ] \
  && ok "update-check silent when the installed version is newer than remote" \
  || ko "update-check silent when the installed version is newer than remote (got '$out')"

UC4="$WORK/uc4"; mkdir -p "$UC4/skills/learner"
printf '0.2.0' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC4" LEARNER_VERSION_URL="file://$VFIX" uchk)
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("none installed")' >/dev/null 2>&1 \
  && ok "update-check notifies unconditionally when no local VERSION file exists" \
  || ko "update-check notifies unconditionally when no local VERSION file exists (got '$out')"

UC5="$WORK/uc5"; mkdir -p "$UC5/skills/learner"
echo '0.1.0' > "$UC5/skills/learner/VERSION"
printf 'not-a-version' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC5" LEARNER_VERSION_URL="file://$VFIX" uchk)
[ -z "$out" ] \
  && ok "update-check silent on malformed remote content" \
  || ko "update-check silent on malformed remote content (got '$out')"

UC6="$WORK/uc6"; mkdir -p "$UC6/skills/learner"
printf 'not-a-version' > "$VFIX"
out=$(CLAUDE_CONFIG_DIR="$UC6" LEARNER_VERSION_URL="file://$VFIX" uchk)
[ -z "$out" ] \
  && ok "update-check silent on malformed remote even with no local VERSION" \
  || ko "update-check silent on malformed remote even with no local VERSION (got '$out')"

# Everything except curl: date/mkdir/dirname/cat are the hook's other externals,
# and an empty PATH (the trick used for jq elsewhere in this suite) would break
# those too, before the curl check is ever reached.
NOCURL_PATH="$WORK/tmp/no-curl-path"; mkdir -p "$NOCURL_PATH"
for b in date mkdir dirname cat; do
  bp=$(command -v "$b") && ln -sf "$bp" "$NOCURL_PATH/$b"
done
UC7="$WORK/uc7"; mkdir -p "$UC7/skills/learner"
echo '0.1.0' > "$UC7/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
out=$(printf '{}' | CLAUDE_CONFIG_DIR="$UC7" LEARNER_VERSION_URL="file://$VFIX" PATH="$NOCURL_PATH" /bin/sh "$UCHK" 2>/dev/null)
rc=$?
{ [ -z "$out" ] && [ "$rc" = 0 ]; } \
  && ok "update-check hook is silent, not an error, when curl is missing" \
  || ko "update-check hook is silent, not an error, when curl is missing (out='$out' rc=$rc)"

UC8="$WORK/uc8"; mkdir -p "$UC8/skills/learner"
echo '0.1.0' > "$UC8/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
CLAUDE_CONFIG_DIR="$UC8" LEARNER_VERSION_URL="file://$VFIX" uchk >/dev/null
out=$(CLAUDE_CONFIG_DIR="$UC8" LEARNER_VERSION_URL="file://$VFIX" uchk)
[ -z "$out" ] \
  && ok "update-check is throttled: a second call within 24h is silent" \
  || ko "update-check is throttled: a second call within 24h is silent (got '$out')"

UC9="$WORK/uc9"; mkdir -p "$UC9/skills/learner" "$UC9/learner"
echo '0.1.0' > "$UC9/skills/learner/VERSION"
printf '0.2.0' > "$VFIX"
printf '%s' "$(( $(date +%s) - 90000 ))" > "$UC9/learner/.last-update-check"
out=$(CLAUDE_CONFIG_DIR="$UC9" LEARNER_VERSION_URL="file://$VFIX" uchk)
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("0\\.2\\.0")' >/dev/null 2>&1 \
  && ok "update-check proceeds again once the throttle stamp is 25h old" \
  || ko "update-check proceeds again once the throttle stamp is 25h old (got '$out')"

UC10="$WORK/uc10"; mkdir -p "$UC10/skills/learner"
echo '0.1.0' > "$UC10/skills/learner/VERSION"
CLAUDE_CONFIG_DIR="$UC10" LEARNER_VERSION_URL="file:///no/such/file" uchk >/dev/null 2>&1
[ -f "$UC10/learner/.last-update-check" ] \
  && ok "update-check writes the throttle stamp even when the fetch fails" \
  || ko "update-check writes the throttle stamp even when the fetch fails"
```

Then apply four small edits, all to numbers or lists, all still describing the *pre*-implementation
state (they will fail below, on purpose):

1. `test.sh:373-376` — change the expected count from `5` to `6`:
   ```sh
   n=$(find "$I/hooks" -name 'learner-*.sh' | wc -l | tr -d ' ')
   [ "$n" = 6 ] \
     && ok "install lays down 6 hook files" \
     || ko "install lays down 6 hook files (got $n)"
   ```
2. `test.sh:378-384` — change the comment and both expected counts from `4` to `5`:
   ```sh
   # Only 5 are wired: learner-config.sh is sourced, never invoked by Claude Code.
   n1=$(hookcount "$I")
   inst "$I" --level S >/dev/null 2>&1
   n2=$(hookcount "$I")
   { [ "$n1" = 5 ] && [ "$n2" = 5 ]; } \
     && ok "hook merge is idempotent (5 wired hooks)" \
     || ko "hook merge is idempotent (got $n1 then $n2, want 5/5)"
   ```
3. `test.sh:643` (inside the composite condition) — change `= 4` to `= 5`:
   ```sh
   { [ -f "$UE/hooks/learner-quiz.sh" ] && [ -f "$UE/learner.json" ] \
     && [ "$(hookcount "$UE")" = 5 ]; } \
   ```
4. `test.sh:600-604` (inside the composite condition) — add one more existence check:
   ```sh
   { [ "$left" = 0 ] \
     && [ ! -e "$U/hooks/learner-quiz.sh" ] \
     && [ ! -e "$U/hooks/learner-config.sh" ] \
     && [ ! -e "$U/hooks/learner-update-check.sh" ] \
     && [ ! -d "$U/skills/learner" ]; } \
   ```

Finally, extend the two hand-maintained licence lists:

5. `test.sh:1390-1392` — add the new file to `LIC_SCAN`:
   ```sh
   LIC_SCAN="README.md docs/ hooks/learner-config.sh hooks/learner-onboard.sh
   hooks/learner-record-edit.sh hooks/learner-quiz.sh hooks/learner-cleanup.sh
   hooks/learner-update-check.sh install.sh uninstall.sh bootstrap.sh"
   ```
6. `test.sh:1403-1405` — add it to the SPDX for-loop:
   ```sh
   for f in hooks/learner-config.sh hooks/learner-onboard.sh hooks/learner-record-edit.sh \
            hooks/learner-quiz.sh hooks/learner-cleanup.sh hooks/learner-update-check.sh \
            install.sh uninstall.sh bootstrap.sh test.sh; do
   ```

- [ ] **Step 2: Run it to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^  FAIL'; ./test.sh 2>&1 | tail -2`

Expected: `Passed: 316   Failed: 9` — nine real failures: `UC1`, `UC4`, `UC7`, `UC9`, `UC10` (the
hook file does not exist yet, so `sh` reports it missing and every case expecting a specific
notification finds none), `install lays down 6 hook files (got 5)`, `hook merge is idempotent
(got 4 then 4, want 5/5)`, the `test.sh:643` composite, and
`hooks/learner-update-check.sh carries an SPDX licence tag` (the SPDX for-loop, genuinely
failing on a file that does not exist — not vacuous). `UC2`, `UC3`, `UC5`, `UC6` and `UC8` pass
*vacuously* right now, each expecting silence and getting it only because nothing runs at all;
Step 4 is what puts them under real load. The `test.sh:600-604` composite and the `LIC_SCAN`
extension add no new pass/fail signal by themselves — the file they now also check for
already does not exist, either way.

- [ ] **Step 3: Write `hooks/learner-update-check.sh`**

```sh
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SessionStart: notify when a newer Learner version is available. Never blocks
# and never updates on its own — `learner update` (references/update.md) does
# the actual re-install.
#
# Throttled to once per 24h, and the stamp is written on every *attempt*, not
# only on success: an offline machine must not pay a curl timeout every
# session for days on end.
#
# No `jq` dependency, unlike every other hook here — this must still work on
# the machine `learner-onboard.sh` is already telling to go install jq. Every
# value that reaches the hand-built JSON below is a version string already
# validated by learner_version_valid, so there is no escaping risk to justify
# pulling jq in for one line of output.

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STAMP="$CFG/learner/.last-update-check"
NOW=$(date +%s)

if [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null)
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  [ $((NOW - LAST)) -lt 86400 ] && exit 0
fi

mkdir -p "$CFG/learner"
printf '%s' "$NOW" > "$STAMP"

command -v curl >/dev/null 2>&1 || exit 0

URL="${LEARNER_VERSION_URL:-https://raw.githubusercontent.com/Tykok/learning-with-claude/main/VERSION}"
REMOTE=$(curl -fsSL --max-time 2 "$URL" 2>/dev/null) || exit 0

. "$(dirname "$0")/learner-config.sh"
learner_version_valid "$REMOTE" || exit 0

LOCAL=$(cat "$CFG/skills/learner/VERSION" 2>/dev/null)

if [ -n "$LOCAL" ]; then
  learner_version_valid "$LOCAL" || exit 0
  learner_version_gt "$REMOTE" "$LOCAL" || exit 0
  INSTALLED="v$LOCAL"
else
  INSTALLED="none installed"
fi

CTX="Learner v$REMOTE is available ($INSTALLED) - run \`learner update\`."
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$CTX"
```

A garbled *local* file (present but not `learner_version_valid`) is treated the same as "no
update" rather than the same as "no local file" — the empty-`LOCAL` shortcut is specifically for
an install that predates this feature, not a licence to guess past corruption.

- [ ] **Step 4: Wire it into `settings.snippet.json`**

Replace the `SessionStart` array (currently a single entry):

```json
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/learner-onboard.sh\"",
            "timeout": 10
          }
        ]
      }
    ],
```

with two entries:

```json
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/learner-onboard.sh\"",
            "timeout": 10
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/learner-update-check.sh\"",
            "timeout": 10
          }
        ]
      }
    ],
```

- [ ] **Step 5: Copy and remove the new hook file, in `install.sh` and `uninstall.sh`**

In `install.sh`, replace (currently lines 120-121):

```sh
for h in learner-config.sh learner-onboard.sh learner-record-edit.sh \
         learner-quiz.sh learner-cleanup.sh; do
```

with:

```sh
for h in learner-config.sh learner-onboard.sh learner-record-edit.sh \
         learner-quiz.sh learner-cleanup.sh learner-update-check.sh; do
```

In `uninstall.sh`, replace (currently lines 98-102):

```sh
rm -f "$CFG_DIR/hooks/learner-config.sh" \
      "$CFG_DIR/hooks/learner-onboard.sh" \
      "$CFG_DIR/hooks/learner-record-edit.sh" \
      "$CFG_DIR/hooks/learner-quiz.sh" \
      "$CFG_DIR/hooks/learner-cleanup.sh"
```

with:

```sh
rm -f "$CFG_DIR/hooks/learner-config.sh" \
      "$CFG_DIR/hooks/learner-onboard.sh" \
      "$CFG_DIR/hooks/learner-record-edit.sh" \
      "$CFG_DIR/hooks/learner-quiz.sh" \
      "$CFG_DIR/hooks/learner-cleanup.sh" \
      "$CFG_DIR/hooks/learner-update-check.sh"
```

- [ ] **Step 6: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`

Expected: `Passed: 325   Failed: 0`.

- [ ] **Step 7: Commit**

```bash
git add hooks/learner-update-check.sh hooks/settings.snippet.json install.sh uninstall.sh test.sh
git commit -m "$(cat <<'EOF'
feat(hooks): notify when a newer Learner version is available

Throttled to once per 24h, and the stamp is written on every attempt
rather than only on success, so an offline machine never pays a curl
timeout more than once a day. No jq dependency: this hook has to keep
working on the exact machine learner-onboard.sh is already telling to
go install jq, and every value it prints is a version string already
validated, so hand-built JSON carries no escaping risk here.

Never updates anything itself — only prints a one-line notice. That
part is `learner update`, next.
EOF
)"
```

---

### Task 4: `learner update`

The subcommand a dev actually runs. Depends on Tasks 1-3 for the paths and the version format,
but is otherwise standalone — a protocol file the model follows, not new executable code.

**Files:**
- Create: `skills/learner/references/update.md`
- Modify: `skills/learner/SKILL.md` (front matter, Dispatch table, § Status)
- Modify: `docs/usage.html:64-70`
- Modify: `test.sh` — insert after the `for f in hook-quiz.md ... export.md` loop
  (`test.sh:669-671`), and near the `export` routing assertion (`test.sh:700-702`)

**Interfaces:**
- Consumes: `$CFG_DIR/skills/learner/VERSION` (Task 1); the same `LEARNER_VERSION_URL`-overridable
  raw-`VERSION` URL convention as the hook (Task 3), though `references/update.md` performs its
  own fetch rather than invoking the hook.
- Produces: the subcommand token `update`, picked up automatically by the existing
  dispatch-table-to-`usage.html` cross-check (`test.sh:1261`).

- [ ] **Step 1: Write the failing assertions**

In `test.sh`, extend the reference-file loop (currently `test.sh:669`):

```sh
for f in hook-quiz.md quiz.md improve.md data.md export.md update.md; do
```

Then, near the existing `export` routing assertion (`test.sh:700-702`), insert:

```sh
grep -q 'references/update.md' "$SK" \
  && ok "SKILL.md routes the update subcommand to references/update.md" \
  || ko "SKILL.md routes the update subcommand to references/update.md"

grep -qi 'skills/learner/VERSION' "$SK" \
  && ok "SKILL.md's Status section reads the installed VERSION file" \
  || ko "SKILL.md's Status section reads the installed VERSION file"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./test.sh 2>&1 | grep -E '^  FAIL'; ./test.sh 2>&1 | tail -2`

Expected: `Passed: 325   Failed: 3` — `references/update.md exists`, `SKILL.md routes the update
subcommand...`, and `SKILL.md's Status section reads the installed VERSION file`. The
`usage.html` cross-check does not fail yet: it derives its subcommand list from `SKILL.md`'s own
Dispatch table, and `update` is not a row there yet, so that loop simply has one fewer iteration
for now — Step 5 is where adding the row makes it fail *on purpose*, the same mechanism the
Notion-export feature exercised.

- [ ] **Step 3: Write `skills/learner/references/update.md`**

```markdown
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
```

- [ ] **Step 4: Add the Dispatch row, the description phrases, and the Status-section clause**

In `skills/learner/SKILL.md`, insert into the Dispatch table after the `export` row:

```markdown
| `update` | Check the remote version; re-run `bootstrap.sh` pinned to it if newer | `references/update.md` |
```

In the front-matter `description:` line, after `"export" (push the recap into a Notion
database)"`, add `, "update" (check for a newer version and refresh)`; and after `"learner
export"` in the trigger list, add `, "learner update"`.

In § Status, replace step 1:

```markdown
1. Level: `jq -r '.level // "not set"' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner.json"`
   (a project override wins if present).
```

with:

```markdown
1. Level and version: `jq -r '.level // "not set"' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner.json"`
   (a project override wins if present), and
   `cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/learner/VERSION" 2>/dev/null`.
```

and step 3's "Print one line for the level" to "Print one line for the level and version".

- [ ] **Step 5: Run the suite and confirm the deliberate new failure**

Run: `./test.sh 2>&1 | grep -E '^  FAIL'; ./test.sh 2>&1 | tail -2`

Expected: `Passed: 327   Failed: 1` — the three failures from Step 2 are gone, and exactly one
new one has appeared: `usage.html documents the 'learner update' subcommand`. This is
`test.sh:1261`'s existing cross-check reacting to the new Dispatch row, precisely as designed —
adding the row alone is meant to turn this red.

- [ ] **Step 6: Document it on the site**

In `docs/usage.html`, insert after the `learner export` `<dd>` (currently ending `usage.html:69`):

```html
    <dt><code>learner update</code></dt>
    <dd>Checks the remote version and, if it is newer, re-runs the installer pinned to it.
    Safe to run any time — a no-op when you are already current.</dd>
```

- [ ] **Step 7: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`

Expected: `Passed: 329   Failed: 0`.

- [ ] **Step 8: Check `SKILL.md` is still within budget**

Run: `wc -l < skills/learner/SKILL.md`

Expected: comfortably under 120 (89 plus one Dispatch row and one Status clause).

- [ ] **Step 9: Commit**

```bash
git add skills/learner/SKILL.md skills/learner/references/update.md docs/usage.html test.sh
git commit -m "$(cat <<'EOF'
feat(skill): add the learner update subcommand

Re-runs bootstrap.sh pinned to the latest tag rather than teaching
the protocol a second way to fetch and install — two implementations
of the same install logic would drift, same as bootstrap.sh already
says about install.sh.

No flags needed: by the time a dev can run this, learner.json already
exists, so install.sh's onboarding prompts are gated off regardless.
EOF
)"
```

---

### Task 5: CI guard — tag must match `VERSION`

The one hand-maintained invariant this feature adds: a tag `vX.Y.Z` and `VERSION`'s content must
agree, or `learner update` resolves to a tag whose payload does not match what it claims to be.

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md` (Requirements section)
- Modify: `test.sh` — insert after the README/CI shellcheck sync block ending `test.sh:872`

**Interfaces:**
- Consumes: `VERSION` (Task 1) and the tag-naming convention already in use (`v0.1.0`).

- [ ] **Step 1: Write the failing assertions**

In `test.sh`, immediately after the block ending
`|| ko "README's Development shellcheck line matches .github/workflows/ci.yml"`
(currently `test.sh:867-872`), insert:

```sh
grep -qE "tags:[[:space:]]*\['?v\*'?\]" "$CI_YML" \
  && ok "CI triggers on version tags, for the VERSION-vs-tag guard" \
  || ko "CI triggers on version tags, for the VERSION-vs-tag guard"

grep -qF 'startsWith(github.ref' "$CI_YML" \
  && grep -qF 'TAG="${GITHUB_REF_NAME#v}"' "$CI_YML" \
  && grep -qF 'FILE="$(cat VERSION)"' "$CI_YML" \
  && ok "CI guards a tag push against the VERSION file" \
  || ko "CI guards a tag push against the VERSION file"

grep -qF 'update-check hook' "$RM" \
  && ok "README notes curl as a soft run-time dependency for the update-check hook" \
  || ko "README notes curl as a soft run-time dependency for the update-check hook"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./test.sh 2>&1 | tail -3`

Expected: `Passed: 329   Failed: 3` — all three are real failures against files that do not yet
carry the new content.

- [ ] **Step 3: Add the tag trigger and guard step to `ci.yml`**

Replace the whole file:

```yaml
name: CI

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:

jobs:
  ci:
    runs-on: ubuntu-latest
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

`hooks/*.sh` already covers `learner-update-check.sh` as a glob — no shellcheck-target change
needed.

- [ ] **Step 4: Note `curl`'s new soft run-time role in `README.md`**

In the Requirements section, after the `curl` and `tar` bullet (currently `README.md:38-39`),
insert:

```markdown
- **`curl` is also used at run time**, by the update-check hook only, to look for a newer
  version once every 24h. Its absence there is silent, not an error — unlike `jq`, `curl` is
  never a hard requirement for anything already installed.
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./test.sh 2>&1 | tail -3`

Expected: `Passed: 332   Failed: 0`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml README.md test.sh
git commit -m "$(cat <<'EOF'
ci: fail a tag push whose VERSION does not match the tag

learner update always resolves a target version to the tag v$REMOTE
names, never to a commit on main — a mismatch between the two would
mean the tag's payload does not match what it claims to be, silently.
EOF
)"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Locked decisions 1 (notify-only) | 3 §3 (hook), 4 §3 (protocol never auto-applies) |
| Locked decision 2 (plain `VERSION` file, not the Releases API) | 1, 3 |
| Locked decision 3 (24h throttle, not per-session) | 3 (UC8/UC9/UC10) |
| Locked decision 4 (re-run `bootstrap.sh`, no new installer) | 4 §3 |
| Locked decision 5 (`VERSION` lives under `skills/learner/`, removed by a plain uninstall) | 1, 3 (uninstall list unchanged — already `rm -rf skills/learner`) |
| Locked decision 6 (no `jq` in the hook) | 3 Step 3 |
| Locked decision 7 (`curl` soft dependency) | 3 Step 3 (UC7), 5 Step 4 |
| §1 `VERSION` and tag convention | 1 |
| §2 installed version + `learner status` | 1, 4 Step 4 |
| §3 the hook, all seven flow steps | 3 Step 3 |
| §3 step 5's empty-`LOCAL` vs malformed-`LOCAL` distinction | 3 Step 3 (the `if [ -n "$LOCAL" ]` branch); tested by UC4/UC5/UC6 |
| §4 `learner_version_gt` (split into two functions, §4 of this plan's Task 2 note explains why) | 2 |
| §5 `learner update` | 4 |
| §6 CI guard | 5 |
| §7 known limitation | not a task — structurally true once shipped, stated in the spec, nothing to build |
| §8 files touched | File Structure above |
| §9 tests 1-12 | 1 (7,9), 2 (1), 3 (2,3,4,5,6,8), 4 (10,11), 5 (12) |

**Placeholder scan:** every code block is complete, runnable text — no "add validation", no
"similar to Task N". The `…` nowhere appears. Every `Expected:` line names an exact count or exact
failing-test name, not "some failures".

**Type consistency:** `learner_version_valid` / `learner_version_gt` are spelled identically in
Task 2's implementation, Task 2's tests, and Task 3's hook (both the prose and the `. "$(dirname
"$0")/learner-config.sh"` call). The env var is `LEARNER_VERSION_URL` everywhere it appears (Task
3's hook, Task 3's tests, Task 4's `references/update.md` prose). The path
`$CFG_DIR/skills/learner/VERSION` is spelled the same way in Tasks 1, 3, and 4. The subcommand
token is `update` everywhere it is asserted.

**Test-count chain**, computed rather than estimated, including the two easy-to-miss licence
lists in Task 3:

| Point | Passed | Failed | Total assertions |
|---|---|---|---|
| Baseline (verified by running `./test.sh`) | 301 | 0 | 301 |
| Task 1, Step 2 (red) | 302 | 1 | 303 |
| Task 1, Step 5 (green) | 303 | 0 | 303 |
| Task 2, Step 2 (red) | 309 | 5 | 314 |
| Task 2, Step 4 (green) | 314 | 0 | 314 |
| Task 3, Step 2 (red) | 316 | 9 | 325 |
| Task 3, Step 6 (green) | 325 | 0 | 325 |
| Task 4, Step 2 (red) | 325 | 3 | 328 |
| Task 4, Step 5 (red, on purpose) | 327 | 1 | 328 → 329 |
| Task 4, Step 7 (green) | 329 | 0 | 329 |
| Task 5, Step 2 (red) | 329 | 3 | 332 |
| Task 5, Step 5 (green) | 332 | 0 | 332 |

Task 4's total grows by one *between* its own red states (328 → 329): the `usage.html`
cross-check is a loop iteration that only exists once the Dispatch row is added in Step 4, not a
line written in Step 1 — the same mechanism, and the same reason for the jump, as the Notion
export plan's Task 3.
