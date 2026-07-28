#!/usr/bin/env bash
# Tests for the learning-mode hooks + installer.
# Plain sh/bash, no framework. Requires: jq, git. Run: ./test.sh
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
REC="$ROOT/hooks/learner-record-edit.sh"
QUIZ="$ROOT/hooks/learner-quiz.sh"
ONB="$ROOT/hooks/learner-onboard.sh"
CLEAN="$ROOT/hooks/learner-cleanup.sh"
# shellcheck disable=SC2034  # consumed once tasks 3-4 rewrite the quiz/onboarding sections
CONF="$ROOT/hooks/learner-config.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
ko()  { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

command -v jq  >/dev/null 2>&1 || { echo "jq required"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

# Isolated config dir + project repo + tmp so nothing collides with a real session.
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"  # Resolve symlinks (macOS /tmp → /private/tmp)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cfg" "$WORK/proj/.claude" "$WORK/tmp"
git -C "$WORK/proj" init -q
export CLAUDE_CONFIG_DIR="$WORK/cfg"
export CLAUDE_PROJECT_DIR="$WORK/proj"
export TMPDIR="$WORK/tmp"
GCFG="$WORK/cfg/learner.json"
PCFG="$WORK/proj/.claude/learner.local.json"
# Alias kept for the pre-existing sections below (Tasks 2-4 own their rewrite).
CFG="$PCFG"
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

# learner_config must fail clean (no stderr noise, empty stdout, nonzero exit)
# when jq is not on PATH, so a `set -u` caller can tell "no config" apart from
# a real merge without ever touching an unbound variable. sh must stay
# resolvable, so only jq is excluded from PATH (an empty dir), not the shell.
NOJQ_PATH="$WORK/tmp/no-jq-path"
mkdir -p "$NOJQ_PATH"
noJqErr="$WORK/tmp/no-jq.stderr"
out=$(PATH="$NOJQ_PATH" /bin/sh -c '. "$1"; learner_config' _ "$ROOT/hooks/learner-config.sh" 2>"$noJqErr")
rc=$?
err=$(cat "$noJqErr")
{ [ -z "$err" ] && [ -z "$out" ] && [ "$rc" -ne 0 ]; } \
  && ok "learner_config fails clean (no stderr, empty stdout) when jq is missing" \
  || ko "learner_config fails clean (no stderr, empty stdout) when jq is missing (out='$out' rc=$rc err='$err')"

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

# --- onboarding -------------------------------------------------------------
out=$(printf '{}' | sh "$ONB")
echo "$out" | grep -q 'additionalContext' \
  && ok "onboard prompts for level when unconfigured" \
  || ko "onboard prompts for level when unconfigured"

echo '{"level":"junior"}' > "$CFG"
out=$(printf '{}' | sh "$ONB")
[ -z "$out" ] && ok "onboard silent once a level is set" \
             || ko "onboard silent once a level is set"

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

# --- quiz (Stop hook) -------------------------------------------------------
out=$(printf '{"session_id":"%s","stop_hook_active":false}' "$SID" | sh "$QUIZ")
echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && ok "quiz blocks once when edits are pending" \
  || ko "quiz blocks once when edits are pending"

# re-arm edits, then a continuation (stop_hook_active=true) must NOT re-block
printf '{"session_id":"%s","tool_input":{"file_path":"%s/src/Foo.kt"}}' "$SID" "$WORK" | sh "$REC"
out=$(printf '{"session_id":"%s","stop_hook_active":true}' "$SID" | sh "$QUIZ")
[ -z "$out" ] && ok "quiz respects stop_hook_active (no loop)" \
             || ko "quiz respects stop_hook_active (no loop)"

# enabled=false silences the quiz
echo '{"level":"junior","enabled":false}' > "$CFG"
out=$(printf '{"session_id":"%s","stop_hook_active":false}' "$SID" | sh "$QUIZ")
[ -z "$out" ] && ok "enabled=false silences the quiz" \
             || ko "enabled=false silences the quiz"
echo '{"level":"junior"}' > "$CFG"

# no pending edits => no quiz
out=$(printf '{"session_id":"%s","stop_hook_active":false}' "fresh-sid" | sh "$QUIZ")
[ -z "$out" ] && ok "quiz silent when nothing was edited" \
             || ko "quiz silent when nothing was edited"

# --- installer idempotency --------------------------------------------------
R="$(mktemp -d)"; git -C "$R" init -q
bash "$ROOT/install.sh" "$R" >/dev/null 2>&1
count() { jq '[.. | .command? // empty | select(contains("learner-"))] | length' "$R/.claude/settings.json"; }
n1=$(count)
bash "$ROOT/install.sh" "$R" >/dev/null 2>&1
n2=$(count)
{ [ "$n1" = 4 ] && [ "$n2" = 4 ]; } \
  && ok "install merge is idempotent (4 learner hooks)" \
  || ko "install merge is idempotent (got $n1 then $n2, want 4/4)"
rm -rf "$R"

# --- cleanup hook -----------------------------------------------------------
SID3=cln1
printf '{"session_id":"%s","tool_input":{"file_path":"%s/src/Baz.kt"}}' "$SID3" "$WORK" | sh "$REC"
printf '{"session_id":"%s"}' "$SID3" | sh "$CLEAN"
[ -e "$(edits "$SID3")" ] \
  && ko "cleanup removes this session's scratch files" \
  || ok "cleanup removes this session's scratch files"

# --- trou guardrail ---------------------------------------------------------
G="$(mktemp -d)"; git -C "$G" init -q; mkdir -p "$G/.claude" "$G/tmp"
echo '{"level":"junior"}' > "$G/.claude/learner.local.json"
printf 'fun f() {\n  // LEARNER-TODO: body\n}\n' > "$G/A.kt"
git -C "$G" add A.kt
git -C "$G" -c user.email=t@t -c user.name=t commit -qm init
out=$(printf '{"session_id":"g","stop_hook_active":false}' \
  | CLAUDE_PROJECT_DIR="$G" TMPDIR="$G/tmp" sh "$QUIZ")
echo "$out" | jq -e '.decision == "block" and (.reason | test("LEARNER-TODO"))' >/dev/null 2>&1 \
  && ok "quiz blocks while a // LEARNER-TODO marker survives" \
  || ko "quiz blocks while a // LEARNER-TODO marker survives"
rm -rf "$G"

# --- install --level writes config immediately ------------------------------
R="$(mktemp -d)"; git -C "$R" init -q
bash "$ROOT/install.sh" --level senior "$R" >/dev/null 2>&1
jq -e '.level == "senior"' "$R/.claude/learner.local.json" >/dev/null 2>&1 \
  && ok "install --level writes learner.local.json" \
  || ko "install --level writes learner.local.json"
rm -rf "$R"

# --- uninstall reverses install ---------------------------------------------
R="$(mktemp -d)"; git -C "$R" init -q
bash "$ROOT/install.sh" "$R" >/dev/null 2>&1
bash "$ROOT/uninstall.sh" "$R" >/dev/null 2>&1
left=$(jq '[.. | .command? // empty | select(contains("learner-"))] | length' "$R/.claude/settings.json" 2>/dev/null || echo 0)
{ [ "$left" = 0 ] \
  && [ ! -e "$R/.claude/hooks/learner-quiz.sh" ] \
  && [ ! -d "$R/.claude/skills/learner" ]; } \
  && ok "uninstall removes hooks, skill and settings wiring" \
  || ko "uninstall removes hooks, skill and settings wiring (left=$left)"
rm -rf "$R"

# --- summary ----------------------------------------------------------------
echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
