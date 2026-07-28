#!/usr/bin/env bash
# Tests for the learning-mode hooks + installer.
# Plain sh/bash, no framework. Requires: jq, git. Run: ./test.sh
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
REC="$ROOT/hooks/learner-record-edit.sh"
QUIZ="$ROOT/hooks/learner-quiz.sh"
ONB="$ROOT/hooks/learner-onboard.sh"
CLEAN="$ROOT/hooks/learner-cleanup.sh"

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

NOJQ_ONB_PATH="$WORK/tmp/no-jq-onb-path"
mkdir -p "$NOJQ_ONB_PATH"
out=$(printf '{}' | PATH="$NOJQ_ONB_PATH" /bin/sh "$ONB" 2>/dev/null)
printf '%s' "$out" | grep -q 'jq.*is not on PATH' \
  && ok "onboard warns when jq is missing" \
  || ko "onboard warns when jq is missing"

rm -f "$GCFG" "$PCFG"
out=$(printf '{}' | CLAUDE_PROJECT_DIR="$WORK/tmp" sh "$ONB")
[ -z "$out" ] && ok "onboard silent outside a git repo" \
             || ko "onboard silent outside a git repo"
echo '{"level":"S"}' > "$GCFG"

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

# --- cleanup hook -----------------------------------------------------------
SID3=cln1
printf '{"session_id":"%s","tool_input":{"file_path":"%s/src/Baz.kt"}}' "$SID3" "$WORK" | sh "$REC"
printf '{"session_id":"%s"}' "$SID3" | sh "$CLEAN"
[ -e "$(edits "$SID3")" ] \
  && ko "cleanup removes this session's scratch files" \
  || ok "cleanup removes this session's scratch files"

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

grep -qE 'recapEvery|trouBlanks|(^|[^A-Za-z])trackGlobs|"language"' "$SK" "$REFS"/*.md \
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

# --- summary ----------------------------------------------------------------
echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
