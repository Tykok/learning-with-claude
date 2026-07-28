# Learner Global Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Learner from a per-project copy into a single Claude Code user-level install with a two-layer config, English content, letter levels, exclusion-list file tracking, and a two-line hook footprint.

**Architecture:** All paths resolve from `CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`. A new sourced helper, `hooks/learner-config.sh`, owns config merging (defaults < global < project), level normalisation and the activation predicate; the other hooks become thin consumers. The quiz protocol moves out of `learner-quiz.sh` into `skills/learner/references/*.md`, so the Stop-hook block reason — which Claude Code renders in the console — stays two lines.

**Tech Stack:** POSIX `sh` (hooks), `bash` (install/uninstall/test), `jq`, `git`. No framework: `test.sh` is a hand-rolled pass/fail harness.

**Spec:** [docs/superpowers/specs/2026-07-28-global-install-design.md](../specs/2026-07-28-global-install-design.md)

## Global Constraints

- Hooks are POSIX `sh` — no bashisms, no process substitution, no arrays. `install.sh`, `uninstall.sh`, `test.sh` stay `#!/usr/bin/env bash` with `set -euo pipefail` (test.sh: `set -u`).
- `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh test.sh` must pass; suppress only with a targeted `# shellcheck disable=SCxxxx` plus a reason.
- Every path resolves from `CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`. Never hardcode `~/.claude`.
- `jq` is required by every hook; a hook without `jq` exits 0 silently (only `learner-onboard.sh` reports it).
- Installers write **nothing** into any repository. The single exception is the skill's `learner off` / `learner config project`, which is dev-invoked.
- All shipped content (hooks, skill, references, README, prompts) is written in English. Questions are asked in whatever language the dev writes in — this is an instruction inside the skill, not a config key.
- Canonical levels are the letters `D` / `J` / `C` / `S` / `E`; matching is case-insensitive and accepts the full word (`senior` → `S`).
- Config keys, exactly: `level`, `enabled`, `questionStyles`, `synthesisFrequency`, `blanksPerExercise`, `untrackGlobs`, `disabledPaths`. Removed for good: `language`, `trackGlobs`, `recapEvery`, `trouBlanks`.
- `synthesisFrequency` maps `off`→0, `rare`→8, `normal`→4, `often`→2. Unknown values fall back to 4.
- Question styles: `code`, `architecture` (alias `archi`), `fill`.
- No migration code. `uninstall.sh --project <repo>` is the only concession to the old layout.
- Commit after every task, Conventional Commits, English subject ≤ 72 chars.

## File Structure

| Path | Responsibility | Action |
|------|----------------|--------|
| `hooks/learner-config.sh` | Config merge, level/synthesis normalisation, repo root, activation predicate. Sourced by every other hook and by `install.sh`. | Create |
| `hooks/learner-record-edit.sh` | PostToolUse: decide whether an edited path is quiz material, append to session scratch. | Rewrite |
| `hooks/learner-quiz.sh` | Stop: `LEARNER-TODO` guardrail, then a two-line quiz trigger. | Rewrite |
| `hooks/learner-onboard.sh` | SessionStart: report a broken install only. | Rewrite (shrinks) |
| `hooks/learner-cleanup.sh` | SessionEnd: delete scratch files. | Unchanged |
| `hooks/settings.snippet.json` | Hook wiring with user-level command paths. | Rewrite |
| `skills/learner/SKILL.md` | Dispatch table, level table, config params. Always loaded — keep it short. | Rewrite |
| `skills/learner/references/hook-quiz.md` | Protocol for the hook-triggered quiz. | Create |
| `skills/learner/references/quiz.md` | On-demand quiz over the branch diff. | Create |
| `skills/learner/references/improve.md` | Coaching loop to mastery. | Create |
| `skills/learner/references/data.md` | `memory.md` / `recap.md` formats and write rules, shared by the three modes above. | Create |
| `install.sh` | User-level install + onboarding + preflight. | Rewrite |
| `uninstall.sh` | User-level removal, `--purge`, `--project` legacy cleanup. | Rewrite |
| `test.sh` | Sandboxed `CLAUDE_CONFIG_DIR` harness. | Rewrite |
| `learner.json.example` | Example global config. | Create (replaces `learner.local.json.example`) |
| `README.md` | Rewritten around the global install. | Rewrite |

---

### Task 1: Config resolution helper

**Files:**
- Create: `hooks/learner-config.sh`
- Test: `test.sh` (new "config resolution" section, replacing nothing yet)

**Interfaces:**
- Consumes: nothing.
- Produces, for Tasks 2–4 and 6:
  - `LEARNER_CFG_DIR` — resolved config dir.
  - `learner_config` → prints merged config as one-line JSON on stdout.
  - `learner_level RAW` → prints `D|J|C|S|E`, or empty string when invalid.
  - `learner_level_name LETTER` → prints `Discovering|Junior|Competent|Senior|Expert`.
  - `learner_synthesis_n WORD` → prints `0|2|4|8`.
  - `learner_repo_root` → prints the git toplevel of `$CLAUDE_PROJECT_DIR`, empty when not a repo.
  - `learner_path_disabled ROOT CFG_JSON` → exit 0 when ROOT is under a `disabledPaths` entry.
  - `learner_active CFG_JSON ROOT` → exit 0 when the automatic quiz should run.

- [ ] **Step 1: Write the failing tests**

Replace the harness preamble in `test.sh` (currently lines 19–26) with a sandboxed config dir, and add the new section right after it:

```bash
# Isolated config dir + project repo + tmp so nothing collides with a real session.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cfg" "$WORK/proj/.claude" "$WORK/tmp"
git -C "$WORK/proj" init -q
export CLAUDE_CONFIG_DIR="$WORK/cfg"
export CLAUDE_PROJECT_DIR="$WORK/proj"
export TMPDIR="$WORK/tmp"
GCFG="$WORK/cfg/learner.json"
PCFG="$WORK/proj/.claude/learner.local.json"
edits() { echo "$TMPDIR/claude-learner-$1.edits"; }

# Run a snippet with learner-config.sh sourced.
cfgsh() { sh -c '. "$1"; shift; eval "$@"' _ "$ROOT/hooks/learner-config.sh" "$@"; }

# --- config resolution ------------------------------------------------------
echo '{"level":"senior","blanksPerExercise":3}' > "$GCFG"
rm -f "$PCFG"
out=$(cfgsh 'learner_config')
{ [ "$(echo "$out" | jq -r .level)" = "senior" ] \
  && [ "$(echo "$out" | jq -r .blanksPerExercise)" = "3" ] \
  && [ "$(echo "$out" | jq -r .synthesisFrequency)" = "normal" ]; } \
  && ok "global config merges over defaults" \
  || ko "global config merges over defaults"

echo '{"blanksPerExercise":1,"enabled":false}' > "$PCFG"
out=$(cfgsh 'learner_config')
{ [ "$(echo "$out" | jq -r .blanksPerExercise)" = "1" ] \
  && [ "$(echo "$out" | jq -r .enabled)" = "false" ] \
  && [ "$(echo "$out" | jq -r .level)" = "senior" ]; } \
  && ok "project config wins key by key, keeps enabled=false" \
  || ko "project config wins key by key, keeps enabled=false"

echo '{"level":"S","untrackGlobs":["*.md"]}' > "$GCFG"
echo '{"untrackGlobs":["*.sql"]}' > "$PCFG"
out=$(cfgsh 'learner_config' | jq -c '.untrackGlobs')
[ "$out" = '["*.sql"]' ] \
  && ok "arrays are replaced by the project layer, not merged" \
  || ko "arrays are replaced by the project layer, not merged (got $out)"

printf '{ not json' > "$GCFG"
out=$(cfgsh 'learner_config' | jq -r '.synthesisFrequency')
[ "$out" = "normal" ] \
  && ok "invalid global config falls back to defaults" \
  || ko "invalid global config falls back to defaults"

echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"

for pair in "d:D" "junior:J" "JUNIOR:J" "c:C" "senior:S" "Expert:E" "wizard:"; do
  raw="${pair%%:*}"; want="${pair##*:}"
  got=$(cfgsh "learner_level $raw")
  [ "$got" = "$want" ] \
    && ok "level '$raw' normalises to '$want'" \
    || ko "level '$raw' normalises to '$want' (got '$got')"
done

for pair in "off:0" "rare:8" "normal:4" "often:2" "banana:4"; do
  raw="${pair%%:*}"; want="${pair##*:}"
  got=$(cfgsh "learner_synthesis_n $raw")
  [ "$got" = "$want" ] \
    && ok "synthesisFrequency '$raw' -> $want" \
    || ko "synthesisFrequency '$raw' -> $want (got '$got')"
done

out=$(cfgsh 'learner_repo_root')
[ "$out" = "$(cd "$WORK/proj" && pwd -P)" ] \
  && ok "repo root resolves inside a git repo" \
  || ko "repo root resolves inside a git repo (got '$out')"

out=$(CLAUDE_PROJECT_DIR="$WORK/tmp" cfgsh 'learner_repo_root')
[ -z "$out" ] \
  && ok "repo root is empty outside a git repo" \
  || ko "repo root is empty outside a git repo (got '$out')"

cfgsh 'learner_path_disabled "/a/b/c" "{\"disabledPaths\":[\"/a/b\"]}"' \
  && ok "disabledPaths matches a parent prefix" \
  || ko "disabledPaths matches a parent prefix"

cfgsh 'learner_path_disabled "/a/bee" "{\"disabledPaths\":[\"/a/b\"]}"' \
  && ko "disabledPaths does not match a sibling with a shared prefix" \
  || ok "disabledPaths does not match a sibling with a shared prefix"

cfgsh 'learner_active "{\"level\":\"S\",\"enabled\":true}" "/a/b"' \
  && ok "learner_active passes with a level, enabled, inside a repo" \
  || ko "learner_active passes with a level, enabled, inside a repo"

cfgsh 'learner_active "{\"enabled\":true}" "/a/b"' \
  && ko "learner_active fails without a valid level" \
  || ok "learner_active fails without a valid level"

cfgsh 'learner_active "{\"level\":\"S\",\"enabled\":false}" "/a/b"' \
  && ko "learner_active fails when enabled is false" \
  || ok "learner_active fails when enabled is false"

cfgsh 'learner_active "{\"level\":\"S\",\"enabled\":true}" ""' \
  && ko "learner_active fails outside a git repo" \
  || ok "learner_active fails outside a git repo"

cfgsh 'learner_active "{\"level\":\"S\",\"disabledPaths\":[\"/a\"]}" "/a/b"' \
  && ko "learner_active fails under a disabled path" \
  || ok "learner_active fails under a disabled path"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: the `config resolution` assertions FAIL (`hooks/learner-config.sh` does not exist yet, `cfgsh` errors), and the summary line reports a non-zero `Failed:` count.

- [ ] **Step 3: Write the helper**

Create `hooks/learner-config.sh`:

```sh
#!/bin/sh
# Shared config resolution for the learner hooks. SOURCED, never executed.
#
# Exposes:
#   LEARNER_CFG_DIR                 resolved Claude config dir
#   learner_config                  merged config as one-line JSON
#   learner_level RAW               canonical level letter, empty when invalid
#   learner_level_name LETTER       human name for a level letter
#   learner_synthesis_n WORD        questions between synthesis questions (0 = off)
#   learner_repo_root               git toplevel of the project dir, empty if none
#   learner_path_disabled ROOT CFG  true when ROOT sits under a disabledPaths entry
#   learner_active CFG ROOT         true when the automatic quiz should run here

LEARNER_CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

LEARNER_DEFAULTS='{"enabled":true,"questionStyles":"auto","synthesisFrequency":"normal","blanksPerExercise":2,"untrackGlobs":[],"disabledPaths":[]}'

# A JSON object from a file, or {} when the file is missing, unreadable or not an object.
_learner_read_json() {
  if [ ! -f "$1" ]; then
    printf '{}'
    return 0
  fi
  _lj=$(jq -c 'if type == "object" then . else {} end' "$1" 2>/dev/null) || _lj=''
  [ -n "$_lj" ] || _lj='{}'
  printf '%s' "$_lj"
}

# defaults < global < project, key by key. `*` is used rather than `//` because
# `//` treats `false` as absent, which would break "enabled": false.
# `*` also replaces arrays instead of concatenating them — intentional.
learner_config() {
  _lg=$(_learner_read_json "$LEARNER_CFG_DIR/learner.json")
  _lp=$(_learner_read_json "${CLAUDE_PROJECT_DIR:-.}/.claude/learner.local.json")
  jq -nc --argjson d "$LEARNER_DEFAULTS" --argjson g "$_lg" --argjson p "$_lp" \
    '$d * $g * $p'
}

learner_level() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    d|discovering) printf 'D' ;;
    j|junior)      printf 'J' ;;
    c|competent)   printf 'C' ;;
    s|senior)      printf 'S' ;;
    e|expert)      printf 'E' ;;
    *)             printf '' ;;
  esac
}

learner_level_name() {
  case "${1:-}" in
    D) printf 'Discovering' ;;
    J) printf 'Junior' ;;
    C) printf 'Competent' ;;
    S) printf 'Senior' ;;
    E) printf 'Expert' ;;
    *) printf '' ;;
  esac
}

learner_synthesis_n() {
  case "${1:-}" in
    off)   printf '0' ;;
    rare)  printf '8' ;;
    often) printf '2' ;;
    *)     printf '4' ;;
  esac
}

learner_repo_root() {
  git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || printf ''
}

# Prefix match on path components, so /a/b disables /a/b/c but not /a/bee.
learner_path_disabled() {
  _lroot="$1"
  _lcfg="$2"
  printf '%s' "$_lcfg" | jq -r '(.disabledPaths // [])[]' 2>/dev/null | (
    while IFS= read -r _lp; do
      [ -n "$_lp" ] || continue
      case "$_lp" in "~/"*) _lp="$HOME/${_lp#\~/}" ;; esac
      _lp="${_lp%/}"
      case "$_lroot/" in "$_lp"/*) exit 0 ;; esac
    done
    exit 1
  )
}

# The five activation conditions, in one place.
learner_active() {
  _lacfg="$1"
  _laroot="$2"
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$_laroot" ] || return 1
  [ -n "$(learner_level "$(printf '%s' "$_lacfg" | jq -r '.level // empty')")" ] || return 1
  [ "$(printf '%s' "$_lacfg" | jq -r '.enabled')" = "false" ] && return 1
  learner_path_disabled "$_laroot" "$_lacfg" && return 1
  return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh`
Expected: every `config resolution` assertion prints `ok`. Assertions from other sections may still fail — Tasks 2–7 fix those.

Run: `shellcheck --severity=warning hooks/learner-config.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add hooks/learner-config.sh test.sh
git commit -m "feat(hooks): add shared config resolution helper"
```

---

### Task 2: Record-edit hook on exclusion lists

**Files:**
- Rewrite: `hooks/learner-record-edit.sh`
- Test: `test.sh` (replace the `record-edit` section, currently lines 39–63)

**Interfaces:**
- Consumes: `learner_config`, `learner_repo_root`, `learner_active` from Task 1.
- Produces: `$TMPDIR/claude-learner-<sid>.edits` and `.session`, newline-separated absolute paths — read by Task 3.

- [ ] **Step 1: Write the failing tests**

Replace the `--- record-edit` section of `test.sh` with:

```bash
# --- record-edit ------------------------------------------------------------
echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"
rec() { printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" | sh "$REC"; }

SID=rec1
rec "$SID" "$WORK/proj/src/Foo.kt"
grep -q 'Foo.kt' "$(edits "$SID")" 2>/dev/null \
  && ok "records an ordinary source file" \
  || ko "records an ordinary source file"

rec "$SID" "$WORK/proj/docs/notes.md"
grep -q 'notes.md' "$(edits "$SID")" 2>/dev/null \
  && ok "records any extension by default (exclusion-list model)" \
  || ko "records any extension by default (exclusion-list model)"

for p in build/Gen.kt node_modules/x/index.js dist/app.js vendor/lib.php \
         coverage/report.html __snapshots__/a.snap pnpm-lock.yaml app.min.js \
         schema.generated.ts Cargo.lock; do
  SIDF="floor-$(echo "$p" | tr '/.' '--')"
  rec "$SIDF" "$WORK/proj/$p"
  [ -s "$(edits "$SIDF")" ] \
    && ko "exclusion floor drops $p" \
    || ok "exclusion floor drops $p"
done

echo '{"level":"S","untrackGlobs":["*.md","*/generated/*"]}' > "$GCFG"
SID3=rec3
rec "$SID3" "$WORK/proj/README.md"
rec "$SID3" "$WORK/proj/src/generated/api.ts"
rec "$SID3" "$WORK/proj/src/Real.kt"
{ ! grep -q 'README.md' "$(edits "$SID3")" 2>/dev/null \
  && ! grep -q 'generated/api.ts' "$(edits "$SID3")" 2>/dev/null \
  && grep -q 'Real.kt' "$(edits "$SID3")" 2>/dev/null; } \
  && ok "untrackGlobs excludes on top of the floor" \
  || ko "untrackGlobs excludes on top of the floor"
echo '{"level":"S"}' > "$GCFG"

SID4=rec4
rm -f "$GCFG"
rec "$SID4" "$WORK/proj/src/Bar.kt"
[ -s "$(edits "$SID4")" ] \
  && ko "no-op when no level is configured" \
  || ok "no-op when no level is configured"
echo '{"level":"S"}' > "$GCFG"

SID5=rec5
printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$SID5" "$WORK/tmp/loose.kt" \
  | CLAUDE_PROJECT_DIR="$WORK/tmp" sh "$REC"
[ -s "$(edits "$SID5")" ] \
  && ko "no-op outside a git repo" \
  || ok "no-op outside a git repo"

SID6=rec6
echo '{"level":"S","disabledPaths":["'"$WORK/proj"'"]}' > "$GCFG"
rec "$SID6" "$WORK/proj/src/Baz.kt"
[ -s "$(edits "$SID6")" ] \
  && ko "no-op when the repo is under disabledPaths" \
  || ok "no-op when the repo is under disabledPaths"
echo '{"level":"S"}' > "$GCFG"
```

Also add `CONF="$ROOT/hooks/learner-config.sh"` next to the other hook path variables at the top of `test.sh` (currently lines 7–10) so later tasks can reference it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: `records any extension by default`, the `untrackGlobs` case, `no-op outside a git repo` and the `disabledPaths` case FAIL — the current hook uses an include-list (`trackGlobs`) and a project config path.

- [ ] **Step 3: Rewrite the hook**

```sh
#!/bin/sh
# PostToolUse Write|Edit: record the files edited this session so the Stop hook
# can quiz on them.
#
# Exclusion-list model: everything the dev edits is quiz material, minus a
# built-in floor (generated / vendored / lock artefacts) and the user's
# `untrackGlobs`. No-op unless the learner is active here.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

CFG=$(learner_config)
ROOT=$(learner_repo_root)
learner_active "$CFG" "$ROOT" || exit 0

DATA=$(cat)
SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""')
FP=$(printf '%s' "$DATA" | jq -r '.tool_input.file_path // ""')
[ -n "$SID" ] || exit 0
[ -n "$FP" ] || exit 0

# Built-in floor, not overridable through config: without it, every
# package-lock.json and generated file would become quiz material.
case "$FP" in
  */node_modules/*|*/build/*|*/dist/*|*/out/*|*/target/*|*/vendor/*) exit 0 ;;
  */.git/*|*/.gradle/*|*/__pycache__/*|*/.venv/*|*/coverage/*|*/__snapshots__/*) exit 0 ;;
esac
case "$FP" in
  *.lock|*-lock.json|*.min.*|*.generated.*|*.snap) exit 0 ;;
esac

# User exclusions on top of the floor. Globs are whitespace-separated, so a glob
# containing a space is not supported (documented in README).
GLOBS=$(printf '%s' "$CFG" | jq -r '(.untrackGlobs // [])[]' 2>/dev/null)
# shellcheck disable=SC2086,SC2254  # intentional word splitting + glob patterns
for g in $GLOBS; do
  [ -n "$g" ] || continue
  case "$FP" in $g) exit 0 ;; esac
done

# Pending edits since the last quiz, plus a session-wide log that is never
# cleared (the synthesis question uses it).
STATE="${TMPDIR:-/tmp}/claude-learner-${SID}.edits"
SESSION="${TMPDIR:-/tmp}/claude-learner-${SID}.session"
echo "$FP" >> "$STATE"
echo "$FP" >> "$SESSION"
exit 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh`
Expected: every `record-edit` assertion prints `ok`.

Run: `shellcheck --severity=warning hooks/learner-record-edit.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add hooks/learner-record-edit.sh test.sh
git commit -m "feat(hooks): track edits by exclusion list, not include list"
```

---

### Task 3: Stop hook becomes a two-line trigger

**Files:**
- Rewrite: `hooks/learner-quiz.sh`
- Test: `test.sh` (replace the `quiz (Stop hook)` and `trou guardrail` sections, currently lines 65–87 and 109–120)

**Interfaces:**
- Consumes: `learner_config`, `learner_level`, `learner_synthesis_n`, `learner_repo_root`, `learner_active` (Task 1); the scratch files from Task 2.
- Produces: a Stop-hook JSON `{decision:"block", reason:…}` whose reason names the `learner` skill and `references/hook-quiz.md`, and carries `level`, `mode` (`granular`|`synthesis`), `styles`, `blanks` and the file list. Task 5's `references/hook-quiz.md` must parse exactly those field names.

- [ ] **Step 1: Write the failing tests**

Replace both sections with:

```bash
# --- quiz (Stop hook) -------------------------------------------------------
quiz() { printf '{"session_id":"%s","stop_hook_active":%s}' "$1" "${2:-false}" | sh "$QUIZ"; }

echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"
SIDQ=quiz1
rec "$SIDQ" "$WORK/proj/src/Foo.kt"
out=$(quiz "$SIDQ")
echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && ok "quiz blocks once when edits are pending" \
  || ko "quiz blocks once when edits are pending"

reason=$(echo "$out" | jq -r '.reason')
lines=$(printf '%s\n' "$reason" | wc -l | tr -d ' ')
[ "$lines" -le 3 ] \
  && ok "block reason stays within 3 lines (console stays quiet)" \
  || ko "block reason stays within 3 lines (got $lines)"

printf '%s' "$reason" | grep -q 'references/hook-quiz.md' \
  && ok "block reason points at the skill protocol" \
  || ko "block reason points at the skill protocol"

printf '%s' "$reason" | grep -qiE 'memory\.md|recap\.md|spaced repetition' \
  && ko "block reason carries no protocol prose" \
  || ok "block reason carries no protocol prose"

printf '%s' "$reason" | grep -q 'level: S' \
  && ok "block reason carries the canonical level letter" \
  || ko "block reason carries the canonical level letter"

printf '%s' "$reason" | grep -q 'mode: granular' \
  && ok "first question is granular" \
  || ko "first question is granular"

# often = every 2nd question is a synthesis
echo '{"level":"S","synthesisFrequency":"often"}' > "$GCFG"
SIDS=quiz2
rec "$SIDS" "$WORK/proj/src/A.kt"
quiz "$SIDS" >/dev/null
rec "$SIDS" "$WORK/proj/src/B.kt"
printf '%s' "$(quiz "$SIDS" | jq -r .reason)" | grep -q 'mode: synthesis' \
  && ok "synthesisFrequency=often makes question 2 a synthesis" \
  || ko "synthesisFrequency=often makes question 2 a synthesis"

# off = never a synthesis
echo '{"level":"S","synthesisFrequency":"off"}' > "$GCFG"
SIDO=quiz3
for i in 1 2 3 4 5; do rec "$SIDO" "$WORK/proj/src/O$i.kt"; quiz "$SIDO" > "$WORK/o$i.json"; done
grep -l 'mode: synthesis' "$WORK"/o*.json >/dev/null 2>&1 \
  && ko "synthesisFrequency=off never triggers a synthesis" \
  || ok "synthesisFrequency=off never triggers a synthesis"

echo '{"level":"S","blanksPerExercise":4}' > "$GCFG"
SIDB=quiz4
rec "$SIDB" "$WORK/proj/src/C.kt"
printf '%s' "$(quiz "$SIDB" | jq -r .reason)" | grep -q 'blanks: 4' \
  && ok "blanksPerExercise reaches the trigger" \
  || ko "blanksPerExercise reaches the trigger"

echo '{"level":"S"}' > "$GCFG"
SIDL=quiz5
rec "$SIDL" "$WORK/proj/src/D.kt"
out=$(quiz "$SIDL" true)
[ -z "$out" ] && ok "quiz respects stop_hook_active (no loop)" \
             || ko "quiz respects stop_hook_active (no loop)"

echo '{"level":"S","enabled":false}' > "$GCFG"
SIDE=quiz6
rec "$SIDE" "$WORK/proj/src/E.kt"    # record-edit is inert too, so pre-arm by hand
echo "$WORK/proj/src/E.kt" > "$(edits "$SIDE")"
out=$(quiz "$SIDE")
[ -z "$out" ] && ok "enabled=false silences the quiz" \
             || ko "enabled=false silences the quiz"
echo '{"level":"S"}' > "$GCFG"

out=$(quiz "no-edits-sid")
[ -z "$out" ] && ok "quiz silent when nothing was edited" \
             || ko "quiz silent when nothing was edited"

# --- LEARNER-TODO guardrail -------------------------------------------------
G="$(mktemp -d)"; git -C "$G" init -q; mkdir -p "$G/tmp"
printf 'fun f() {\n  // LEARNER-TODO: body\n}\n' > "$G/A.kt"
git -C "$G" add A.kt
git -C "$G" -c user.email=t@t -c user.name=t commit -qm init

guard() { printf '{"session_id":"g","stop_hook_active":false}' \
  | CLAUDE_PROJECT_DIR="$G" TMPDIR="$G/tmp" CLAUDE_CONFIG_DIR="$1" sh "$QUIZ"; }

out=$(guard "$WORK/cfg")
echo "$out" | jq -e '.decision == "block" and (.reason | test("LEARNER-TODO"))' >/dev/null 2>&1 \
  && ok "guardrail blocks while a LEARNER-TODO marker survives" \
  || ko "guardrail blocks while a LEARNER-TODO marker survives"

echo '{"level":"S","enabled":false}' > "$GCFG"
out=$(guard "$WORK/cfg")
echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && ok "guardrail fires even when enabled is false" \
  || ko "guardrail fires even when enabled is false"

out=$(guard "$WORK/empty-cfg")
echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && ok "guardrail fires even with no config at all" \
  || ko "guardrail fires even with no config at all"
echo '{"level":"S"}' > "$GCFG"
rm -rf "$G"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: the reason-size, `references/hook-quiz.md`, `mode:`, `blanks:`, `synthesisFrequency` and both "guardrail without config" assertions FAIL — today the hook emits ~40 lines of French protocol and requires a project config file.

- [ ] **Step 3: Rewrite the hook**

```sh
#!/bin/sh
# Stop hook, two jobs.
#
# 1. Guardrail — runs unconditionally, even with no config or enabled=false:
#    while any `// LEARNER-TODO` marker survives in the repo, block and force a
#    restore, so a crashed fill-in exercise can never leave source broken.
# 2. Quiz trigger — when the session edited tracked files, block once with a
#    SHORT trigger. The protocol lives in the skill (references/hook-quiz.md),
#    never here: this reason is rendered in the console.

. "$(dirname "$0")/learner-config.sh"

command -v jq >/dev/null 2>&1 || exit 0

ROOT=$(learner_repo_root)

if [ -n "$ROOT" ]; then
  HOLES=$(git -C "$ROOT" grep -l 'LEARNER-TODO' 2>/dev/null | head -n 20 | tr '\n' ' ')
  if [ -n "$HOLES" ]; then
    GR="🎓 Learner — an unfinished fill-in exercise left // LEARNER-TODO markers in: $HOLES
Before anything else: restore the correct implementation, remove every // LEARNER-TODO, and verify it compiles/lints/tests. Do not finish while a marker remains."
    jq -n --arg r "$GR" '{decision:"block", reason:$r}'
    exit 0
  fi
fi

CFG=$(learner_config)
learner_active "$CFG" "$ROOT" || exit 0

DATA=$(cat)

# Don't re-block while already continuing from this hook, else Claude never waits
# for the dev and we risk an infinite stop loop.
ACTIVE=$(printf '%s' "$DATA" | jq -r '.stop_hook_active // false')
[ "$ACTIVE" = "true" ] && exit 0

SID=$(printf '%s' "$DATA" | jq -r '.session_id // ""')
[ -n "$SID" ] || exit 0

STATE="${TMPDIR:-/tmp}/claude-learner-${SID}.edits"
[ -s "$STATE" ] || exit 0
SESSION="${TMPDIR:-/tmp}/claude-learner-${SID}.session"
COUNT="${TMPDIR:-/tmp}/claude-learner-${SID}.count"

LEVEL=$(learner_level "$(printf '%s' "$CFG" | jq -r '.level // empty')")
STYLES=$(printf '%s' "$CFG" | jq -r '
  if (.questionStyles | type) == "array"
  then (.questionStyles | join(","))
  else (.questionStyles // "auto") end')
case "$STYLES" in ''|null) STYLES=auto ;; esac
BLANKS=$(printf '%s' "$CFG" | jq -r '.blanksPerExercise // 2')
case "$BLANKS" in ''|*[!0-9]*) BLANKS=2 ;; esac
[ "$BLANKS" -lt 1 ] && BLANKS=1
EVERY=$(learner_synthesis_n "$(printf '%s' "$CFG" | jq -r '.synthesisFrequency // "normal"')")

# Per-session question counter drives the synthesis cadence.
N=$(cat "$COUNT" 2>/dev/null); case "$N" in ''|*[!0-9]*) N=0 ;; esac
N=$((N + 1)); echo "$N" > "$COUNT"

MODE=granular
FILES=$(sort -u "$STATE" | head -n 20 | tr '\n' ' ')
if [ "$EVERY" -gt 0 ] && [ $((N % EVERY)) -eq 0 ] && [ -s "$SESSION" ]; then
  MODE=synthesis
  FILES=$(sort -u "$SESSION" | head -n 40 | tr '\n' ' ')
fi

REASON="🎓 Learner (level: $LEVEL, mode: $MODE, styles: $STYLES, blanks: $BLANKS) — files: $FILES
Invoke the \`learner\` skill, follow references/hook-quiz.md for this mode. Ask ONE question, then wait for the dev's answer."

# Consume the pending edits: one granular question per batch, not per stop.
: > "$STATE"

jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh`
Expected: every `quiz (Stop hook)` and `LEARNER-TODO guardrail` assertion prints `ok`.

Run: `shellcheck --severity=warning hooks/learner-quiz.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add hooks/learner-quiz.sh test.sh
git commit -m "feat(hooks): emit a two-line quiz trigger instead of the protocol"
```

---

### Task 4: SessionStart hook reports only a broken install

**Files:**
- Rewrite: `hooks/learner-onboard.sh`
- Test: `test.sh` (replace the `onboarding` section, currently lines 28–37)

**Interfaces:**
- Consumes: `learner_config`, `learner_level`, `learner_repo_root` (Task 1).
- Produces: `hookSpecificOutput.additionalContext` only when `jq` is missing or no valid level is set. Silence otherwise.

- [ ] **Step 1: Write the failing tests**

```bash
# --- onboarding -------------------------------------------------------------
rm -f "$GCFG" "$PCFG"
out=$(printf '{}' | sh "$ONB")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("learner config")' >/dev/null 2>&1 \
  && ok "onboard nags when no level is configured" \
  || ko "onboard nags when no level is configured"

printf '%s' "$out" | grep -qiE 'recapEvery|trouBlanks|language|trackGlobs' \
  && ko "onboard mentions no removed config key" \
  || ok "onboard mentions no removed config key"

echo '{"level":"S"}' > "$GCFG"
out=$(printf '{}' | sh "$ONB")
[ -z "$out" ] && ok "onboard silent once a level is set" \
             || ko "onboard silent once a level is set"

echo '{"level":"S","enabled":false}' > "$GCFG"
out=$(printf '{}' | sh "$ONB")
[ -z "$out" ] && ok "onboard silent when deliberately disabled" \
             || ko "onboard silent when deliberately disabled"

out=$(printf '{}' | CLAUDE_PROJECT_DIR="$WORK/tmp" sh "$ONB")
[ -z "$out" ] && ok "onboard silent outside a git repo" \
             || ko "onboard silent outside a git repo"
echo '{"level":"S"}' > "$GCFG"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: `onboard nags when no level is configured` FAILS (current text says "learning mode is not configured", not `learner config`), `onboard mentions no removed config key` FAILS (the current context lists `recapEvery`, `language`, `trouBlanks`, `trackGlobs`), and `silent outside a git repo` FAILS.

- [ ] **Step 3: Rewrite the hook**

```sh
#!/bin/sh
# SessionStart: report a broken learner install and nothing else.
#
# install.sh does the onboarding now, so there is no conversational setup here.
# Output goes to additionalContext, which is not rendered in the console.

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Learner is installed but `jq` is not on PATH, so all of its hooks are inert. Tell the user, in one line, to install jq (brew install jq / apt-get install jq), then continue with their request."}}'
  exit 0
fi

. "$(dirname "$0")/learner-config.sh"

ROOT=$(learner_repo_root)
[ -n "$ROOT" ] || exit 0

CFG=$(learner_config)
LEVEL=$(learner_level "$(printf '%s' "$CFG" | jq -r '.level // empty')")
[ -n "$LEVEL" ] && exit 0

CTX="Learner is installed but has no valid level, so it will never ask a question. Tell the user, in one line, to run \`learner config level=<D|J|C|S|E>\`, then continue with their request."
jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh`
Expected: every `onboarding` assertion prints `ok`.

Run: `shellcheck --severity=warning hooks/learner-onboard.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add hooks/learner-onboard.sh test.sh
git commit -m "refactor(hooks): SessionStart reports broken installs only"
```

---

### Task 5: Split and translate the skill

**Files:**
- Rewrite: `skills/learner/SKILL.md`
- Create: `skills/learner/references/hook-quiz.md`, `references/quiz.md`, `references/improve.md`, `references/data.md`
- Test: `test.sh` (new "skill content" section)

**Interfaces:**
- Consumes: the trigger field names emitted in Task 3 — `level:`, `mode: granular|synthesis`, `styles:`, `blanks:`, `files:`.
- Produces: the `learner` skill contract used by `install.sh` (Task 6) and `uninstall.sh` (Task 7): a `SKILL.md` plus a `references/` directory, both copied wholesale.

- [ ] **Step 1: Write the failing tests**

```bash
# --- skill content ----------------------------------------------------------
SK="$ROOT/skills/learner/SKILL.md"
REFS="$ROOT/skills/learner/references"

for f in hook-quiz.md quiz.md improve.md data.md; do
  [ -f "$REFS/$f" ] && ok "references/$f exists" || ko "references/$f exists"
done

n=$(wc -l < "$SK" | tr -d ' ')
[ "$n" -le 120 ] \
  && ok "SKILL.md stays under 120 lines (it is always loaded)" \
  || ko "SKILL.md stays under 120 lines (got $n)"

grep -qE 'recapEvery|trouBlanks|trackGlobs|"language"' "$SK" "$REFS"/*.md \
  && ko "skill mentions no removed config key" \
  || ok "skill mentions no removed config key"

grep -q 'learner-memory.md\|learner-recap.md' "$SK" "$REFS"/*.md \
  && ko "skill uses the new data paths, not the old per-project names" \
  || ok "skill uses the new data paths, not the old per-project names"

for k in level enabled questionStyles synthesisFrequency blanksPerExercise untrackGlobs disabledPaths; do
  grep -q "$k" "$SK" && ok "SKILL.md documents $k" || ko "SKILL.md documents $k"
done

for l in D J C S E; do
  grep -qE "^\| \`?$l\`? " "$SK" && ok "SKILL.md documents level $l" || ko "SKILL.md documents level $l"
done

grep -q 'references/hook-quiz.md' "$SK" \
  && ok "SKILL.md routes the hook trigger to references/hook-quiz.md" \
  || ko "SKILL.md routes the hook trigger to references/hook-quiz.md"

grep -q 'references/data.md' "$REFS/hook-quiz.md" \
  && grep -q 'references/data.md' "$REFS/quiz.md" \
  && grep -q 'references/data.md' "$REFS/improve.md" \
  && ok "the three quiz modes all defer to references/data.md" \
  || ko "the three quiz modes all defer to references/data.md"

grep -q 'CLAUDE_CONFIG_DIR' "$REFS/data.md" \
  && ok "data.md resolves the config dir from CLAUDE_CONFIG_DIR" \
  || ko "data.md resolves the config dir from CLAUDE_CONFIG_DIR"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: every `skill content` assertion FAILS except the removed-key check — `references/` does not exist and `SKILL.md` is 258 French lines.

- [ ] **Step 3: Write `SKILL.md`**

```markdown
---
description: Learning mode. Invoke as "learner" with a subcommand — "quiz" (Q&A on the current branch), "status" (what to improve + level), "improve" (coach one weak spot to mastery), "config" (settings, incl. "off"/"on" for this repo), "help". Also invoked by the Stop hook, which passes a trigger line. Trigger on "learner", "learner quiz", "learner status", "learner improve", "learner config", "learner off", "quiz me", "quiz me on the branch", "what should I improve", "my level", "level me up", "mode apprentissage", "interroge-moi", "quiz sur la branche", "ce que je dois améliorer", "mon niveau", "m'améliorer sur".
allowed-tools: Read Write Edit Grep Bash
---

# Learner

Ask the dev questions about the code they just wrote, at their level, and keep a
record of what they should level up on.

**Language: mirror the dev.** Write every question, feedback line and summary in the
language the dev is using in this conversation. There is no language setting.

## Dispatch

`learner <subcommand> [args]` — the subcommand is the first token of `$ARGUMENTS`.

| Subcommand | Mode | Read |
|------------|------|------|
| `quiz [base-ref] [count]` | Q&A over the current branch diff | `references/quiz.md` |
| `status` | Read-only summary: level + what to improve | this file, § Status |
| `improve [topic]` | Coach one weak spot to mastery | `references/improve.md` |
| `config [key=value …]` | View/edit settings; `config project …` scopes to this repo | this file, § Config |
| `off` / `on` | Disable/enable the automatic quiz in this repo | this file, § Config |
| `help` (or `-h`, `--help`) | Print this dispatch table + the parameter table, then stop | — |
| *(empty)* | Same as `config` with no pairs: show current settings | this file, § Config |

A bare config instruction with no subcommand (`level=S`, `disable`) is `config` shorthand.

**Invoked by the Stop hook.** The hook blocks with a trigger line of the form
`🎓 Learner (level: S, mode: granular, styles: auto, blanks: 2) — files: a.kt b.kt`.
When you see it, read `references/hook-quiz.md` and follow it with those values. Do not
treat the trigger as the protocol — it is only parameters.

## Levels

The canonical value is the letter. Accept the full word and any case as an alias.

| Letter | Name | What a question targets |
|--------|------|-------------------------|
| `D` | Discovering | syntax, what a block is for, basic vocabulary |
| `J` | Junior | what the function does, where the code lives |
| `C` | Competent | why this split, edge cases, error handling |
| `S` | Senior | trade-offs, rejected alternatives, perf and coupling impact |
| `E` | Expert | invariants, failure modes, what breaks at scale |

## Config

Two layers, later wins key by key:

1. `$CLAUDE_CONFIG_DIR/learner.json` (default `~/.claude/learner.json`) — the dev's
   defaults for every repo.
2. `<repo>/.claude/learner.local.json` — optional, gitignored, partial override.

| Key | Values | Default | Effect |
|-----|--------|---------|--------|
| `level` | `D`/`J`/`C`/`S`/`E` | — required | Question difficulty |
| `enabled` | bool | `true` | Master switch for the automatic quiz |
| `questionStyles` | `"auto"` or subset of `code`/`architecture`/`fill` | `"auto"` | Allowed formats |
| `synthesisFrequency` | `off`/`rare`/`normal`/`often` | `normal` | Synthesis question every 0/8/4/2 questions |
| `blanksPerExercise` | int ≥ 1 | `2` | `// LEARNER-TODO` holes in a `fill` exercise |
| `untrackGlobs` | array of globs | `[]` | Extra paths excluded from quiz material |
| `disabledPaths` | array of path prefixes | `[]` | Repos where learner stays silent |

Styles: `code` = what a changed function does; `architecture` (alias `archi`) = which
module/layer it lives in and why; `fill` = interactive fill-in exercise in the real
source file (see `references/hook-quiz.md`).

To edit: read the target file, merge the new values over the existing ones, validate
(`level` in the five letters; `enabled` boolean; `questionStyles` `"auto"` or a subset;
`synthesisFrequency` one of the four words; ints ≥ 1; the two glob keys arrays of
non-empty strings), write it, then confirm with
`jq -e . <file> >/dev/null && echo OK`. Reject invalid values and re-ask instead of
writing them. `config` alone edits the global file; `config project …`, `off` and `on`
edit `<repo>/.claude/learner.local.json` and add that path to the repo's `.gitignore`
if it is missing. Those are the only writes into a repo.

## Status

Read-only: no quiz, no config write, no data-file update.

1. Level: `jq -r '.level // "not set"' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/learner.json"`
   (a project override wins if present).
2. Open weak spots: read the `To improve` sections of the recap (see
   `references/data.md` for paths). If nothing is recorded, say so and suggest `learner quiz`.
3. Print one line for the level, then a handful of bullets — broad competency themes
   grouped by domain, skipping anything already under `Mastered`. Summarise; never dump
   the file. No tables, no history.
```

- [ ] **Step 4: Write `references/data.md`**

Translate and merge the three current French descriptions of the learning files — `SKILL.md:119-138`, `hooks/learner-quiz.sh:96-99` (`PROGRESS_DIRECTIVE`) and `SKILL.md:244-248` — into one English file. It must state:

- Paths: `CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`, then `$CFG/learner/memory.md` and `$CFG/learner/recap.md`. Create them if missing (`mkdir -p "$CFG/learner"`).
- Repo tag: `basename "$(git rev-parse --show-toplevel)"`. Today's date: `date +%F`.
- `memory.md` — working memory, the **only** file read to pick a question. One weak spot per line: `- [Domain][repo] concept — seen: YYYY-MM-DD`. Read it before choosing a question and prefer a still-open entry when relevant (spaced repetition). Add a line when the dev misses or hesitates; remove it when they demonstrate mastery.
- `recap.md` — dashboard, written but **never read** to pick a question. Sections `To improve` and `Mastered`, grouped by domain (`Code`, `Architecture`, `Tests`, `CI/Build`, `Data & DB`, `Integrations`), phrased as **broad competency themes** ("Data access and query performance", "Error and exception handling", "Layering and module responsibilities"), never the precise concept of a single question. Roll related weak spots under one theme; aim for a handful per domain. No repo tag in these two sections — a cross-repo view is the point.
- `recap.md` third section `Session history`, a table `| Date | Repo | Domain | Style | Verdict | Note |`, verdicts `✅ ok` / `⚠️ revisit` / `⏭️ skip`. This is the only place per-question detail lives.
- After **every** answer, update both files: the precise weak spot in `memory.md`, and in `recap.md` a history row plus attaching the point to its broad theme under `To improve` or `Mastered` (create the theme only if absent). Keep it concise.

- [ ] **Step 5: Write `references/hook-quiz.md`**

Translate `hooks/learner-quiz.sh:80-133` (the `TROU_DESC`, `STYLE_DIRECTIVE` and both `REASON` bodies). It must state:

- Read the trigger's `level`, `mode`, `styles`, `blanks` and `files`.
- **`mode: granular`** — one short question about the listed files, difficulty per the level table in `SKILL.md`. Never quiz on code you have not read: read the files first.
- **`mode: synthesis`** — one question about how the session's work fits together, not a detail: how the edited pieces connect (data flow, calls across layers), which responsibility lives where and why, or a 2–3 sentence summary for a colleague.
- Style meanings, and `auto` = vary from one question to the next, picking the most relevant.
- The `fill` protocol, in full: pick ONE short function among the listed files; before cutting, memorise the correct version (it is in git); edit the real file to replace `blanks` key part(s) of its body with `// LEARNER-TODO: <hint>` comments, keeping the signature and surrounding code; cut only that function; tell the dev the file and function and ask them to write the missing code **directly in the file**; wait — never write it for them; when they finish or say `skip`, compare with the correct implementation, give brief feedback, then restore a correct version and verify it is valid (focused compile/lint/test for the language). Never end a turn with the file broken or with a leftover `// LEARNER-TODO`: the Stop hook re-blocks while any marker remains. Prefer another style when the dev cannot edit locally.
- Ask ONE question, then wait for the answer. `skip` moves on without insisting. Give brief feedback (correct / to fix + the missing bit) before continuing.
- Then apply `references/data.md`.

- [ ] **Step 6: Write `references/quiz.md`**

Translate `SKILL.md:190-257`. It must state: load config the same way as `SKILL.md` § Config (an explicit `learner quiz` runs even when `enabled` is `false` — the dev asked for it); compute the branch diff with the existing base-ref cascade:

```bash
BASE=$(git merge-base origin/develop HEAD 2>/dev/null \
  || git merge-base develop HEAD 2>/dev/null \
  || git merge-base origin/main HEAD 2>/dev/null \
  || git merge-base main HEAD 2>/dev/null \
  || git merge-base master HEAD)
git diff --stat "$BASE"..HEAD
git diff "$BASE"..HEAD
```

Honour a base ref and/or a count from `$ARGUMENTS` (`quiz`, `quiz 5`, `quiz origin/develop`, `quiz develop 4`); read the diff so every question is grounded in real code; ignore pure-docs and test-scaffolding churn unless it is the point of the branch; one question at a time, wait for each answer, brief feedback; spread coverage across the branch's distinct areas (data model, persistence, core logic, error handling, external integrations, config/build) rather than re-asking about one file; default ~5 questions then a synthesis question; stop on repeated `skip` or on `stop`; the `fill` protocol is the one in `references/hook-quiz.md`; then apply `references/data.md`; close with a one-line recap of what looked solid and what is worth revisiting.

- [ ] **Step 7: Write `references/improve.md`**

Translate `SKILL.md:68-89`. It must state: load config; read `memory.md` (open weak spots) and the recap's `To improve` plus `Session history`; pick the target — the topic in `$ARGUMENTS` (fuzzy-match a bullet), else the most relevant open one (recurring or oldest), else ask; confirm which one; use the history rows for that topic to see *how* the dev struggled and read the real source files the concept lives in — ground everything in this repo's actual code, never abstractly; then loop: a concise explanation with the *why*, a worked example pulled from the real codebase, and an active-recall step (a targeted question or a `fill` exercise honouring `questionStyles`/`blanksPerExercise`), waiting for the dev and giving brief feedback each time, until they demonstrate understanding or say `stop`. On mastery, update both data files per `references/data.md`: remove the weak spot from `memory.md`, move the theme to `Mastered` in the recap, and append a history row with style `improve`. If not yet mastered, leave it open and note what still needs work.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `./test.sh`
Expected: every `skill content` assertion prints `ok`.

- [ ] **Step 9: Commit**

```bash
git add skills/learner test.sh
git commit -m "refactor(skill): split into references, translate to English"
```

---

### Task 6: User-level installer with onboarding

**Files:**
- Rewrite: `hooks/settings.snippet.json`, `install.sh`
- Create: `learner.json.example`
- Delete: `learner.local.json.example`
- Test: `test.sh` (replace the two installer sections, currently lines 89–99 and 122–128)

**Interfaces:**
- Consumes: `learner_level` from Task 1 (sourced for validation); the hook and skill files from Tasks 1–5.
- Produces: a populated `$CFG` — `$CFG/hooks/learner-{config,onboard,record-edit,quiz,cleanup}.sh`, `$CFG/skills/learner/SKILL.md` + `references/`, `$CFG/learner.json`, and five `learner-` hook entries in `$CFG/settings.json`. Task 7 reverses exactly this list.

- [ ] **Step 1: Write the failing tests**

```bash
# --- installer --------------------------------------------------------------
inst() { CLAUDE_CONFIG_DIR="$1" bash "$ROOT/install.sh" "${@:2}"; }
hookcount() { jq '[.. | .command? // empty | select(contains("learner-"))] | length' "$1/settings.json"; }

I="$WORK/inst"; mkdir -p "$I"
inst "$I" --level S --synthesis often --blanks 3 >/dev/null 2>&1
{ [ -f "$I/hooks/learner-config.sh" ] \
  && [ -f "$I/hooks/learner-quiz.sh" ] \
  && [ -f "$I/skills/learner/SKILL.md" ] \
  && [ -f "$I/skills/learner/references/data.md" ]; } \
  && ok "install copies hooks, skill and references" \
  || ko "install copies hooks, skill and references"

jq -e '.level == "S" and .synthesisFrequency == "often" and .blanksPerExercise == 3' \
  "$I/learner.json" >/dev/null 2>&1 \
  && ok "install writes the global config from flags" \
  || ko "install writes the global config from flags"

n=$(find "$I/hooks" -name 'learner-*.sh' | wc -l | tr -d ' ')
[ "$n" = 5 ] \
  && ok "install lays down 5 hook files" \
  || ko "install lays down 5 hook files (got $n)"

# Only 4 are wired: learner-config.sh is sourced, never invoked by Claude Code.
n1=$(hookcount "$I")
inst "$I" --level S >/dev/null 2>&1
n2=$(hookcount "$I")
{ [ "$n1" = 4 ] && [ "$n2" = 4 ]; } \
  && ok "hook merge is idempotent (4 wired hooks)" \
  || ko "hook merge is idempotent (got $n1 then $n2, want 4/4)"

jq -e '[.. | .command? // empty | select(contains("learner-"))]
       | all(contains("CLAUDE_CONFIG_DIR"))' "$I/settings.json" >/dev/null 2>&1 \
  && ok "hook commands resolve CLAUDE_CONFIG_DIR at run time" \
  || ko "hook commands resolve CLAUDE_CONFIG_DIR at run time"

I2="$WORK/inst2"; mkdir -p "$I2"
inst "$I2" --level senior >/dev/null 2>&1
jq -e '.level == "S"' "$I2/learner.json" >/dev/null 2>&1 \
  && ok "install normalises --level senior to S" \
  || ko "install normalises --level senior to S"

I3="$WORK/inst3"; mkdir -p "$I3"
inst "$I3" --level wizard >/dev/null 2>&1 \
  && ko "install rejects an invalid level" \
  || ok "install rejects an invalid level"

I4="$WORK/inst4"; mkdir -p "$I4"
inst "$I4" >/dev/null 2>&1 </dev/null \
  && ko "install aborts non-interactively without --level" \
  || ok "install aborts non-interactively without --level"

I5="$WORK/inst5"; mkdir -p "$I5"
echo '{ broken' > "$I5/settings.json"
inst "$I5" --level S >/dev/null 2>&1 \
  && ko "install aborts on invalid settings.json" \
  || ok "install aborts on invalid settings.json"
grep -q 'broken' "$I5/settings.json" \
  && ok "install leaves an invalid settings.json untouched" \
  || ko "install leaves an invalid settings.json untouched"

I6="$WORK/inst6"; mkdir -p "$I6"
inst "$I6" --level S --dry-run >/dev/null 2>&1
{ [ ! -e "$I6/learner.json" ] && [ ! -e "$I6/hooks" ]; } \
  && ok "--dry-run writes nothing" \
  || ko "--dry-run writes nothing"

I7="$WORK/inst7"
out=$(PATH="/usr/bin:/bin" HOME="$WORK/nohome" CLAUDE_CONFIG_DIR="$I7" \
      bash "$ROOT/install.sh" --level S 2>&1) \
  && ko "install aborts when Claude Code is absent" \
  || ok "install aborts when Claude Code is absent"
printf '%s' "$out" | grep -qi 'claude' \
  && ok "the abort message names Claude Code" \
  || ko "the abort message names Claude Code"

I8="$WORK/inst8"; mkdir -p "$I8"
inst "$I8" --level S >/dev/null 2>&1
inst "$I8" --level D >/dev/null 2>&1
jq -e '.level == "S"' "$I8/learner.json" >/dev/null 2>&1 \
  && ok "re-install keeps an existing config" \
  || ko "re-install keeps an existing config"

jq -e 'keys - ["level","enabled","questionStyles","synthesisFrequency","blanksPerExercise","untrackGlobs","disabledPaths"] | length == 0' \
  "$ROOT/learner.json.example" >/dev/null 2>&1 \
  && ok "learner.json.example carries only supported keys" \
  || ko "learner.json.example carries only supported keys"

[ ! -e "$ROOT/learner.local.json.example" ] \
  && ok "the old example file is gone" \
  || ko "the old example file is gone"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: every `installer` assertion FAILS — `install.sh` still takes a target repo, writes `.claude/learner.local.json` with old keys, has no `--dry-run`, no `--synthesis`, no `--blanks`, and no Claude-presence check.

- [ ] **Step 3: Rewrite `hooks/settings.snippet.json`**

Commands expand `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` in the shell at hook run time, so a
dev who moves their config dir keeps working with no reinstall:

```json
{
  "hooks": {
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
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/learner-record-edit.sh\"",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/learner-quiz.sh\"",
            "timeout": 10,
            "statusMessage": "Learner: checking understanding..."
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/learner-cleanup.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

`learner-config.sh` is sourced by the other hooks, never wired — that is why the wiring has 4 entries while the install lays down 5 hook files. The Step 1 assertions already split those two counts.

- [ ] **Step 4: Write `learner.json.example`**

```json
{
  "level": "C",
  "enabled": true,
  "questionStyles": "auto",
  "synthesisFrequency": "normal",
  "blanksPerExercise": 2,
  "untrackGlobs": ["*.md", "*.json"],
  "disabledPaths": []
}
```

```bash
git rm learner.local.json.example
```

- [ ] **Step 5: Rewrite `install.sh`**

```bash
#!/usr/bin/env bash
# Install the learner skill + hooks at Claude Code user level (all repos).
#
# Usage:
#   ./install.sh [--level D|J|C|S|E] [--synthesis off|rare|normal|often]
#                [--blanks N] [--dry-run] [--yes]
#
#   --level L      Your level. Full words (junior, senior, …) are accepted.
#   --synthesis W  How often a synthesis question replaces a granular one.
#   --blanks N     Holes left in a fill-in exercise.
#   --dry-run      Print what would be written, write nothing.
#   --yes          Never prompt; use defaults for anything not passed.
#
# Idempotent: re-running re-copies the files and re-merges the hook wiring
# without duplicating entries, and never overwrites an existing config.
# Requires: Claude Code. Strongly recommends: jq.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# shellcheck source=hooks/learner-config.sh
. "$SRC_DIR/hooks/learner-config.sh"

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
    -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unexpected argument '$1' (learner installs globally, not per repo)"; exit 1 ;;
  esac
done

# 1) Claude Code must exist — installing without it does nothing useful.
if ! command -v claude >/dev/null 2>&1 && [ ! -d "$CFG_DIR" ]; then
  echo "error: Claude Code not found (no 'claude' on PATH and no $CFG_DIR)."
  echo "       Install it first: https://claude.com/claude-code"
  exit 1
fi

# 2) jq is required by every hook, but its absence is recoverable.
HAVE_JQ=1
command -v jq >/dev/null 2>&1 || HAVE_JQ=0

# 3) A settings.json we cannot parse is a hard stop, before touching anything.
SETTINGS="$CFG_DIR/settings.json"
if [ -f "$SETTINGS" ] && [ "$HAVE_JQ" = 1 ]; then
  jq -e . "$SETTINGS" >/dev/null 2>&1 || {
    echo "error: $SETTINGS is not valid JSON — fix or move it, then re-run."
    exit 1
  }
fi
if [ "$HAVE_JQ" = 0 ]; then
  echo "error: jq is required to merge the hook wiring (brew install jq / apt install jq)."
  exit 1
fi

CONFIG="$CFG_DIR/learner.json"
CONFIG_EXISTS=0
[ -f "$CONFIG" ] && CONFIG_EXISTS=1

# 4) Onboarding — only for values not passed as flags, only when we have a TTY.
if [ "$CONFIG_EXISTS" = 0 ]; then
  if [ -z "$LEVEL" ] && [ -t 0 ] && [ "$YES" = 0 ]; then
    echo "Your level on the code you will be writing:"
    echo "  D Discovering   J Junior   C Competent   S Senior   E Expert"
    printf 'level [C]: '; read -r LEVEL || LEVEL=""
    LEVEL="${LEVEL:-C}"
  fi
  if [ -z "$SYNTH" ] && [ -t 0 ] && [ "$YES" = 0 ]; then
    printf 'synthesis question every … (off / rare / normal / often) [normal]: '
    read -r SYNTH || SYNTH=""
  fi
  if [ -z "$BLANKS" ] && [ -t 0 ] && [ "$YES" = 0 ]; then
    printf 'holes per fill-in exercise [2]: '
    read -r BLANKS || BLANKS=""
  fi
  SYNTH="${SYNTH:-normal}"
  BLANKS="${BLANKS:-2}"
  [ -n "$LEVEL" ] || { echo "error: --level is required (D|J|C|S|E)"; exit 1; }
fi

# 5) Validate.
if [ "$CONFIG_EXISTS" = 0 ]; then
  NORM="$(learner_level "$LEVEL")"
  [ -n "$NORM" ] || { echo "error: --level must be D|J|C|S|E (or the full word)"; exit 1; }
  case "$SYNTH" in off|rare|normal|often) ;;
    *) echo "error: --synthesis must be off | rare | normal | often"; exit 1 ;;
  esac
  case "$BLANKS" in ''|*[!0-9]*) echo "error: --blanks must be an integer >= 1"; exit 1 ;; esac
  [ "$BLANKS" -ge 1 ] || { echo "error: --blanks must be an integer >= 1"; exit 1; }
fi

echo "→ Installing learner into: $CFG_DIR"
if [ "$DRY" = 1 ]; then
  echo "  (dry run — nothing will be written)"
  echo "  would copy 5 hooks    → $CFG_DIR/hooks/"
  echo "  would copy the skill  → $CFG_DIR/skills/learner/"
  echo "  would merge 4 hooks   → $SETTINGS"
  if [ "$CONFIG_EXISTS" = 1 ]; then
    echo "  would keep existing   → $CONFIG"
  else
    echo "  would write config    → $CONFIG (level=$NORM, synthesis=$SYNTH, blanks=$BLANKS)"
  fi
  exit 0
fi

mkdir -p "$CFG_DIR/hooks" "$CFG_DIR/skills/learner/references" "$CFG_DIR/learner"

for h in learner-config.sh learner-onboard.sh learner-record-edit.sh \
         learner-quiz.sh learner-cleanup.sh; do
  cp "$SRC_DIR/hooks/$h" "$CFG_DIR/hooks/$h"
  chmod +x "$CFG_DIR/hooks/$h"
done
echo "  ✓ hooks → $CFG_DIR/hooks/"

cp "$SRC_DIR/skills/learner/SKILL.md" "$CFG_DIR/skills/learner/SKILL.md"
cp "$SRC_DIR"/skills/learner/references/*.md "$CFG_DIR/skills/learner/references/"
echo "  ✓ skill → $CFG_DIR/skills/learner/"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak"
TMP="$(mktemp)"
jq -n \
  --argjson base "$(cat "$SETTINGS")" \
  --argjson add "$(cat "$SRC_DIR/hooks/settings.snippet.json")" '
  # For each event the snippet defines, drop existing "learner-" entries then
  # append the fresh ones, so re-running never duplicates.
  reduce ($add.hooks | keys[]) as $ev (
    $base;
    .hooks[$ev] = (
      ((.hooks[$ev] // [])
        | map(select(any(.hooks[]; .command | contains("learner-")) | not)))
      + $add.hooks[$ev]
    )
  )
' > "$TMP"
mv "$TMP" "$SETTINGS"
echo "  ✓ hook wiring merged → $SETTINGS (backup: settings.json.bak)"

if [ "$CONFIG_EXISTS" = 1 ]; then
  echo "  • $CONFIG already exists — left untouched"
else
  jq -n --arg lvl "$NORM" --arg syn "$SYNTH" --argjson bl "$BLANKS" '{
    level: $lvl, enabled: true, questionStyles: "auto",
    synthesisFrequency: $syn, blanksPerExercise: $bl,
    untrackGlobs: [], disabledPaths: []
  }' > "$CONFIG"
  echo "  ✓ config → $CONFIG (level=$NORM, synthesis=$SYNTH, blanks=$BLANKS)"
fi

echo
echo "Done. Learner is active in every git repo you open with Claude Code."
echo "  learner status        what to improve"
echo "  learner quiz          quiz me on this branch"
echo "  learner off           silence it in the current repo"
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./test.sh`
Expected: every `installer` assertion prints `ok`.

Run: `shellcheck --severity=warning install.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add install.sh hooks/settings.snippet.json learner.json.example test.sh
git rm --cached learner.local.json.example 2>/dev/null || true
git commit -m "feat(install): install at Claude Code user level with onboarding"
```

---

### Task 7: User-level uninstall plus legacy repo cleanup

**Files:**
- Rewrite: `uninstall.sh`
- Test: `test.sh` (replace the `uninstall` section, currently lines 130–140)

**Interfaces:**
- Consumes: the install layout produced by Task 6.
- Produces: nothing consumed by later tasks. `--project <repo>` removes the old per-project layout (`<repo>/.claude/hooks/learner-*.sh`, `<repo>/.claude/skills/learner`, learner entries in `<repo>/.claude/settings.json`, the three `.gitignore` lines).

- [ ] **Step 1: Write the failing tests**

```bash
# --- uninstall --------------------------------------------------------------
U="$WORK/uninst"; mkdir -p "$U"
CLAUDE_CONFIG_DIR="$U" bash "$ROOT/install.sh" --level S >/dev/null 2>&1
printf '# notes\n' > "$U/learner/memory.md"
CLAUDE_CONFIG_DIR="$U" bash "$ROOT/uninstall.sh" >/dev/null 2>&1
left=$(jq '[.. | .command? // empty | select(contains("learner-"))] | length' "$U/settings.json" 2>/dev/null || echo 0)
{ [ "$left" = 0 ] \
  && [ ! -e "$U/hooks/learner-quiz.sh" ] \
  && [ ! -e "$U/hooks/learner-config.sh" ] \
  && [ ! -d "$U/skills/learner" ]; } \
  && ok "uninstall removes hooks, skill and wiring" \
  || ko "uninstall removes hooks, skill and wiring (left=$left)"

{ [ -f "$U/learner.json" ] && [ -f "$U/learner/memory.md" ]; } \
  && ok "uninstall keeps config and progress data by default" \
  || ko "uninstall keeps config and progress data by default"

CLAUDE_CONFIG_DIR="$U" bash "$ROOT/uninstall.sh" --purge >/dev/null 2>&1
{ [ ! -e "$U/learner.json" ] && [ ! -e "$U/learner" ]; } \
  && ok "--purge deletes config and progress data" \
  || ko "--purge deletes config and progress data"

# legacy per-project layout
L="$(mktemp -d)"; git -C "$L" init -q
mkdir -p "$L/.claude/hooks" "$L/.claude/skills/learner"
touch "$L/.claude/hooks/learner-quiz.sh" "$L/.claude/skills/learner/SKILL.md"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh .claude/hooks/learner-quiz.sh"}]}]}}\n' \
  > "$L/.claude/settings.json"
printf '.claude/learner.local.json\n.claude/learner-memory.md\nbuild/\n' > "$L/.gitignore"
bash "$ROOT/uninstall.sh" --project "$L" >/dev/null 2>&1
left=$(jq '[.. | .command? // empty | select(contains("learner-"))] | length' "$L/.claude/settings.json")
{ [ "$left" = 0 ] \
  && [ ! -e "$L/.claude/hooks/learner-quiz.sh" ] \
  && [ ! -d "$L/.claude/skills/learner" ] \
  && ! grep -q 'learner-memory' "$L/.gitignore" \
  && grep -q 'build/' "$L/.gitignore"; } \
  && ok "--project cleans the legacy per-repo layout, keeps other gitignore lines" \
  || ko "--project cleans the legacy per-repo layout, keeps other gitignore lines (left=$left)"
rm -rf "$L"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: all four `uninstall` assertions FAIL — the current script only knows the per-project layout and has no `--project` flag.

- [ ] **Step 3: Rewrite `uninstall.sh`**

```bash
#!/usr/bin/env bash
# Remove learner from Claude Code (reverse of install.sh).
#
# Usage:
#   ./uninstall.sh [--purge]
#   ./uninstall.sh --project REPO
#
#   --purge          Also delete your config and progress data
#                    ($CLAUDE_CONFIG_DIR/learner.json and learner/).
#                    Without it they survive a reinstall.
#   --project REPO   Clean a repo that still carries the old per-project layout
#                    (learner hooks, skill, settings entries and .gitignore lines).
#
# Requires: jq.
set -euo pipefail

PURGE=0
PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unexpected argument '$1'"; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required"; exit 1; }

# Strip every learner hook entry from a settings.json, dropping events left empty.
strip_wiring() {
  local settings="$1"
  [ -f "$settings" ] || return 0
  local tmp
  tmp="$(mktemp)"
  jq '
    if .hooks then
      .hooks |= (
        (with_entries(.value |= map(select(any(.hooks[]?; .command | contains("learner-")) | not))))
        | with_entries(select(.value | length > 0))
      )
      | (if (.hooks | length) == 0 then del(.hooks) else . end)
    else . end
  ' "$settings" > "$tmp"
  mv "$tmp" "$settings"
}

if [ -n "$PROJECT" ]; then
  TARGET="$(cd "$PROJECT" && pwd)"
  echo "→ Cleaning the legacy per-project install in: $TARGET"
  rm -f "$TARGET/.claude/hooks/learner-onboard.sh" \
        "$TARGET/.claude/hooks/learner-record-edit.sh" \
        "$TARGET/.claude/hooks/learner-quiz.sh" \
        "$TARGET/.claude/hooks/learner-cleanup.sh" \
        "$TARGET/.claude/hooks/learner-config.sh"
  rm -rf "$TARGET/.claude/skills/learner"
  strip_wiring "$TARGET/.claude/settings.json"
  GI="$TARGET/.gitignore"
  if [ -f "$GI" ]; then
    TMP="$(mktemp)"
    grep -vE '^\.claude/(learner\.local\.json|learner-memory\.md|learner-recap\.md)$' "$GI" > "$TMP" || true
    mv "$TMP" "$GI"
  fi
  echo "  ✓ hooks, skill, wiring and .gitignore entries removed"
  echo "  • .claude/learner.local.json (if any) left in place — delete it by hand if you want it gone"
  echo
  echo "Done."
  exit 0
fi

CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
echo "→ Removing learner from: $CFG_DIR"

rm -f "$CFG_DIR/hooks/learner-config.sh" \
      "$CFG_DIR/hooks/learner-onboard.sh" \
      "$CFG_DIR/hooks/learner-record-edit.sh" \
      "$CFG_DIR/hooks/learner-quiz.sh" \
      "$CFG_DIR/hooks/learner-cleanup.sh"
rm -rf "$CFG_DIR/skills/learner"
echo "  ✓ hooks + skill removed"

strip_wiring "$CFG_DIR/settings.json"
echo "  ✓ hook wiring stripped from settings.json"

if [ "$PURGE" -eq 1 ]; then
  rm -f "$CFG_DIR/learner.json"
  rm -rf "$CFG_DIR/learner"
  echo "  ✓ config + progress data purged"
else
  echo "  • config and progress data kept ($CFG_DIR/learner.json, $CFG_DIR/learner/) — pass --purge to delete"
fi

echo "  • per-repo overrides (.claude/learner.local.json) are not enumerable — remove them yourself,"
echo "    or run: ./uninstall.sh --project <repo>"
echo
echo "Done."
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test.sh`
Expected: every `uninstall` assertion prints `ok`, and the final summary shows `Failed: 0`.

Run: `shellcheck --severity=warning uninstall.sh test.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add uninstall.sh test.sh
git commit -m "feat(uninstall): remove the user-level install, keep legacy cleanup"
```

---

### Task 8: README

**Files:**
- Rewrite: `README.md`
- Test: `test.sh` (new "docs" section)

**Interfaces:**
- Consumes: the flags and paths from Tasks 6–7, the config table from Task 5.
- Produces: nothing.

- [ ] **Step 1: Write the failing tests**

```bash
# --- docs -------------------------------------------------------------------
RM="$ROOT/README.md"
grep -qE 'recapEvery|trouBlanks|trackGlobs|"language"|junior\|intermediaire\|senior' "$RM" \
  && ko "README mentions no removed key or old level" \
  || ok "README mentions no removed key or old level"

for s in CLAUDE_CONFIG_DIR untrackGlobs disabledPaths synthesisFrequency blanksPerExercise 'learner off'; do
  grep -qF "$s" "$RM" && ok "README documents $s" || ko "README documents $s"
done

grep -qF -- '--project' "$RM" \
  && ok "README documents the legacy cleanup flag" \
  || ko "README documents the legacy cleanup flag"

grep -qE '^\| \`?[DJCSE]\`? ' "$RM" \
  && ok "README documents the letter levels" \
  || ko "README documents the letter levels"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test.sh`
Expected: the `docs` assertions FAIL — the README still documents `trackGlobs`, `language`, word levels and a per-repo install.

- [ ] **Step 3: Rewrite the README**

Keep the badges (lines 1–6) and the MIT footer. Rewrite the body around:

- **What it does** — one user-level install, active in every git repo; SessionStart reports a broken install; PostToolUse records edited files; Stop asks one question (or a synthesis question) about what was just built; the `learner` skill for `quiz` / `status` / `improve` / `config` / `off`.
- **Three question styles** — `code`, `architecture`, `fill`, with the `LEARNER-TODO` guardrail paragraph.
- **Requirements** — `jq`, POSIX `sh` (macOS / Linux / WSL), Claude Code installed.
- **Install** — `./install.sh`, `./install.sh --level S --synthesis normal --blanks 2`, `--dry-run`, `--yes`. State explicitly that nothing is written into any repo and that `CLAUDE_CONFIG_DIR` is honoured.
- **Levels** — the five-row `D`/`J`/`C`/`S`/`E` table from `SKILL.md`.
- **Turning it off** — the three ways: global `enabled`, `learner off` in a repo, `disabledPaths` for a repo you do not own.
- **Settings** — the seven-key table, the two-layer precedence (project wins key by key, arrays replace), the built-in exclusion floor, and the note that a glob containing a space is unsupported.
- **Files installed** — `$CFG/skills/learner/{SKILL.md,references/}`, `$CFG/hooks/learner-*.sh` (five, four wired), `$CFG/settings.json`, `$CFG/learner.json`, `$CFG/learner/{memory,recap}.md`.
- **Uninstall** — `./uninstall.sh`, `--purge`, and `--project <repo>` for a repo left over from the per-project beta.
- **Development** — `./test.sh`, the shellcheck line including `hooks/learner-config.sh`.

- [ ] **Step 4: Run the full suite**

Run: `./test.sh`
Expected: `Failed: 0`.

Run: `shellcheck --severity=warning hooks/*.sh install.sh uninstall.sh test.sh`
Expected: no output.

- [ ] **Step 5: Verify the real thing end to end**

```bash
TMPCFG="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$TMPCFG" ./install.sh --level S --synthesis often --blanks 2
find "$TMPCFG" -type f | sort
jq . "$TMPCFG/learner.json"
jq '[.. | .command? // empty | select(contains("learner-"))]' "$TMPCFG/settings.json"
CLAUDE_CONFIG_DIR="$TMPCFG" ./uninstall.sh --purge
find "$TMPCFG" -type f | sort
rm -rf "$TMPCFG"
```

Expected: the first `find` lists 5 hooks, `SKILL.md`, 4 references, `learner.json`, `settings.json` and `settings.json.bak`; the command list has 4 entries all containing `CLAUDE_CONFIG_DIR`; after `--purge` only `settings.json` (+ `.bak`) remain, with no learner entries.

- [ ] **Step 6: Commit**

```bash
git add README.md test.sh
git commit -m "docs: rewrite the README around the user-level install"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|--------------|------|
| §1 Layout | 6 (installer creates it), 7 (uninstaller reverses it) |
| §2 Config resolution, activation predicate, three ways to disable | 1, 2, 3, 8 (docs) |
| §3 Schema, levels, `synthesisFrequency`, styles, exclusion floor | 1 (normalisation), 2 (floor + `untrackGlobs`), 3 (styles/blanks), 5 (skill tables), 6 (example + flags) |
| §4 Thin hooks, hook table | 2, 3, 4, 6 (`settings.snippet.json`) |
| §5 Skill file layout, `learner off` | 5 |
| §6 Data files, repo tag, history column | 5 (`references/data.md`) |
| §7 install/uninstall, preflight, `--project` | 6, 7 |
| §8 Tests | every task; the reason-size regression is Task 3 |
| §9 Docs, example rename | 6 (example), 8 (README) |

**Known deviations, both deliberate:**
- The wired hook count is 4 while 5 hook files ship: `learner-config.sh` is sourced by the others, never invoked by Claude Code. Task 6 asserts the two counts separately.
- `hooks/learner-cleanup.sh` is untouched, so it has no task of its own. Its existing test stays in `test.sh`, and Task 8's end-to-end check covers it in the install round trip.
