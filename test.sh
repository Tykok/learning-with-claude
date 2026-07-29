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
skip() { printf '  skip - %s\n' "$1"; }

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

# The root an entry is compared against is physical (git rev-parse --show-toplevel),
# so an entry that reaches the repo through a symlink must still match — otherwise
# the only off-switch the guardrail honours fails silently. /a/b above covers the
# other half: an entry that does not exist on disk keeps its raw string.
SYMB="$WORK/symbase"; mkdir -p "$SYMB/real/repo"
ln -sfn "$SYMB/real" "$SYMB/link"
cfgsh "learner_path_disabled '$SYMB/real/repo' '{\"disabledPaths\":[\"$SYMB/link\"]}'" \
  && ok "disabledPaths matches an entry that points through a symlink" \
  || ko "disabledPaths matches an entry that points through a symlink"

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

# Quiz material is repo material: a `fill` hole cut outside the repo would sit
# where the Stop hook's guardrail can never see it.
SID7=rec7
rec "$SID7" "$WORK/outside.kt"
[ -s "$(edits "$SID7")" ] \
  && ko "an edit outside the repo is never recorded" \
  || ok "an edit outside the repo is never recorded"

SID8=rec8
rec "$SID8" "${WORK}/projX/src/Sibling.kt"
[ -s "$(edits "$SID8")" ] \
  && ko "a sibling directory sharing the repo's name prefix is not recorded" \
  || ok "a sibling directory sharing the repo's name prefix is not recorded"

# …but a repo opened through a symlink must still be recorded: the root is physical
# (git rev-parse --show-toplevel) while file_path is whatever path the session used.
# $WORK is pre-resolved at the top of this file, so this needs its own symlink, and
# a real directory, since resolving a path means visiting it.
SID9=rec9
mkdir -p "$WORK/proj/src"
ln -sfn "$WORK/proj" "$WORK/projlink"
printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$SID9" "$WORK/projlink/src/Sym.kt" \
  | CLAUDE_PROJECT_DIR="$WORK/projlink" sh "$REC"
[ -s "$(edits "$SID9")" ] \
  && ok "an edit reaching the repo through a symlink is still recorded" \
  || ko "an edit reaching the repo through a symlink is still recorded"

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

printf '%s' "$reason" | grep -q 'styles: auto' \
  && ok "block reason carries the styles field" \
  || ko "block reason carries the styles field"

printf '%s' "$reason" | grep -qF -- '— files:' \
  && ok "block reason carries the files field" \
  || ko "block reason carries the files field"

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

# $I has been installed into twice by now: the backup must still be the settings
# from before learner, not the already-merged file.
jq -e '[.. | .command? // empty | select(contains("learner-"))] | length == 0' \
  "$I/settings.json.bak" >/dev/null 2>&1 \
  && ok "the settings.json backup stays pristine across re-installs" \
  || ko "the settings.json backup stays pristine across re-installs"

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

I4B="$WORK/inst4b"; mkdir -p "$I4B"
out=$(inst "$I4B" --yes 2>&1 </dev/null) \
  && ko "install aborts with --yes and no --level" \
  || ok "install aborts with --yes and no --level"
printf '%s' "$out" | grep -qF -- '--level' \
  && ok "the --yes abort message names --level" \
  || ko "the --yes abort message names --level"

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
printf '{"session_id":"%s","tool_input":{"file_path":"%s/proj/src/Baz.kt"}}' "$SID3" "$WORK" | sh "$REC"
[ -s "$(edits "$SID3")" ] \
  && ok "the session scratch file exists before cleanup runs" \
  || ko "the session scratch file exists before cleanup runs"
printf '{"session_id":"%s"}' "$SID3" | sh "$CLEAN"
[ -e "$(edits "$SID3")" ] \
  && ko "cleanup removes this session's scratch files" \
  || ok "cleanup removes this session's scratch files"

# --- LEARNER-TODO guardrail -------------------------------------------------
# One throwaway repo per scenario: the guardrail is a HEAD-vs-working-tree diff,
# so what the fixture committed is the whole point.
gmk() {  # -> a repo with one committed, marker-free file
  _g="$(mktemp -d "$WORK/guard.XXXXXX")"
  mkdir -p "$_g/tmp"
  git -C "$_g" init -q
  printf 'fun f() {\n  return 1\n}\n' > "$_g/A.kt"
  git -C "$_g" add A.kt
  git -C "$_g" -c user.email=t@t -c user.name=t commit -qm init
  printf '%s' "$_g"
}
gcommit() { git -C "$1" add -A; git -C "$1" -c user.email=t@t -c user.name=t commit -qm "${2:-c}"; }
hole()    { printf 'fun f() {\n  // LEARNER-TODO: body\n}\n' > "$1/A.kt"; }
nohole()  { printf 'fun f() {\n  return 1\n}\n' > "$1/A.kt"; }
guard()   { printf '{"session_id":"%s","stop_hook_active":%s}' "${3:-g}" "${4:-false}" \
  | CLAUDE_PROJECT_DIR="$1" TMPDIR="$1/tmp" CLAUDE_CONFIG_DIR="$2" sh "$QUIZ"; }
blocks()  { echo "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

# A committed marker is repo content (this project documents the string in its own
# README, tests and skill files), never an unfinished exercise.
G=$(gmk); hole "$G"; gcommit "$G" marker
out=$(guard "$G" "$WORK/cfg")
blocks "$out" \
  && ko "a committed // LEARNER-TODO is repo content, not a leftover" \
  || ok "a committed // LEARNER-TODO is repo content, not a leftover"

G=$(gmk); hole "$G"
out=$(guard "$G" "$WORK/cfg")
{ blocks "$out" && echo "$out" | jq -e '.reason | test("A.kt")' >/dev/null 2>&1; } \
  && ok "guardrail blocks on a marker in a modified tracked file" \
  || ko "guardrail blocks on a marker in a modified tracked file"

# The primary case: the session just wrote the file, so git does not know it yet.
G=$(gmk); printf 'fun g() {\n  // LEARNER-TODO: body\n}\n' > "$G/NEW.kt"
out=$(guard "$G" "$WORK/cfg")
{ blocks "$out" && echo "$out" | jq -e '.reason | test("NEW.kt")' >/dev/null 2>&1; } \
  && ok "guardrail blocks on a marker in a brand-new untracked file" \
  || ko "guardrail blocks on a marker in a brand-new untracked file"

# A repo whose path is disabled must stay silent and untouched, guardrail included.
G=$(gmk); hole "$G"
DCFG="$G/cfg"; mkdir -p "$DCFG"
echo '{"level":"S","disabledPaths":["'"$G"'"]}' > "$DCFG/learner.json"
out=$(guard "$G" "$DCFG")
[ -z "$out" ] \
  && ok "guardrail stays silent in a repo under disabledPaths" \
  || ko "guardrail stays silent in a repo under disabledPaths"

G=$(gmk); hole "$G"
ECFG="$G/cfg"; mkdir -p "$ECFG"
echo '{"level":"S","enabled":false}' > "$ECFG/learner.json"
out=$(guard "$G" "$ECFG")
blocks "$out" \
  && ok "guardrail fires even when enabled is false" \
  || ko "guardrail fires even when enabled is false"

G=$(gmk); hole "$G"
out=$(guard "$G" "$WORK/empty-cfg")
blocks "$out" \
  && ok "guardrail fires even with no config at all" \
  || ko "guardrail fires even with no config at all"

# Claude says it fixed the file and stops again: the guardrail must re-check.
G=$(gmk); hole "$G"
out=$(guard "$G" "$WORK/cfg" active true)
blocks "$out" \
  && ok "guardrail re-checks even with stop_hook_active" \
  || ko "guardrail re-checks even with stop_hook_active"

# Bounded: two blocks, then the session is allowed to end.
G=$(gmk); hole "$G"
b1=$(guard "$G" "$WORK/cfg" cap); b2=$(guard "$G" "$WORK/cfg" cap); b3=$(guard "$G" "$WORK/cfg" cap)
{ blocks "$b1" && blocks "$b2" && [ -z "$b3" ]; } \
  && ok "guardrail blocks twice, then lets the session end" \
  || ko "guardrail blocks twice, then lets the session end"

# …and a clean stop restores the budget for the next exercise.
G=$(gmk); hole "$G"
guard "$G" "$WORK/cfg" rst >/dev/null; guard "$G" "$WORK/cfg" rst >/dev/null
nohole "$G"; clean=$(guard "$G" "$WORK/cfg" rst)
hole "$G";   again=$(guard "$G" "$WORK/cfg" rst)
{ [ -z "$clean" ] && blocks "$again"; } \
  && ok "a clean stop refreshes the guardrail budget" \
  || ko "a clean stop refreshes the guardrail budget"

# No commits yet: `git grep … HEAD` fails, and every marker is a leftover.
G="$(mktemp -d "$WORK/guard.XXXXXX")"; mkdir -p "$G/tmp"; git -C "$G" init -q
printf 'fun g() {\n  // LEARNER-TODO: body\n}\n' > "$G/NEW.kt"
out=$(guard "$G" "$WORK/cfg")
blocks "$out" \
  && ok "guardrail works in a repo with no commits yet" \
  || ko "guardrail works in a repo with no commits yet"

# The marker is a code comment: the bare word in prose is not an exercise.
G=$(gmk); printf 'the string LEARNER-TODO appears in this doc\n' > "$G/NOTES.md"
out=$(guard "$G" "$WORK/cfg")
[ -z "$out" ] \
  && ok "guardrail matches // LEARNER-TODO, not the bare word" \
  || ko "guardrail matches // LEARNER-TODO, not the bare word"

# Long lists are truncated but say so.
G=$(gmk); i=1; while [ "$i" -le 25 ]; do printf '// LEARNER-TODO: h\n' > "$G/F$i.kt"; i=$((i + 1)); done
out=$(guard "$G" "$WORK/cfg")
echo "$out" | jq -e '.reason | test("and 5 more")' >/dev/null 2>&1 \
  && ok "guardrail reports the overflow instead of dropping files silently" \
  || ko "guardrail reports the overflow instead of dropping files silently"

# The guardrail's scratch file is cleaned up with the rest of the session.
G=$(gmk); hole "$G"
guard "$G" "$WORK/cfg" cln >/dev/null
[ -f "$G/tmp/claude-learner-cln.guard" ] \
  && ok "guardrail records its budget in a per-session scratch file" \
  || ko "guardrail records its budget in a per-session scratch file"
printf '{"session_id":"cln"}' | TMPDIR="$G/tmp" sh "$CLEAN"
[ -e "$G/tmp/claude-learner-cln.guard" ] \
  && ko "cleanup removes the guardrail scratch file" \
  || ok "cleanup removes the guardrail scratch file"
echo '{"level":"S"}' > "$GCFG"

# --- uninstall reverses install ---------------------------------------------
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

# An unparsable settings.json must stop the uninstall BEFORE anything is deleted:
# hooks removed + wiring left behind breaks every session in every project.
UB="$WORK/uninst-bad"; mkdir -p "$UB"
CLAUDE_CONFIG_DIR="$UB" bash "$ROOT/install.sh" --level S >/dev/null 2>&1
echo '{ broken' > "$UB/settings.json"
CLAUDE_CONFIG_DIR="$UB" bash "$ROOT/uninstall.sh" >/dev/null 2>&1 \
  && ko "uninstall aborts on an invalid settings.json" \
  || ok "uninstall aborts on an invalid settings.json"
{ [ -f "$UB/hooks/learner-quiz.sh" ] && [ -d "$UB/skills/learner" ]; } \
  && ok "the aborted uninstall left the hooks and skill in place" \
  || ko "the aborted uninstall left the hooks and skill in place"
grep -q 'broken' "$UB/settings.json" \
  && ok "the aborted uninstall left the invalid settings.json untouched" \
  || ko "the aborted uninstall left the invalid settings.json untouched"

# `--project=` is a typo for "clean one repo", never permission to wipe the
# user-level install and every repo's progress data.
UE="$WORK/uninst-empty"; mkdir -p "$UE"
CLAUDE_CONFIG_DIR="$UE" bash "$ROOT/install.sh" --level S >/dev/null 2>&1
for flag in "--project=" "--project"; do
  out=$(CLAUDE_CONFIG_DIR="$UE" bash "$ROOT/uninstall.sh" "$flag" 2>&1) \
    && ko "uninstall rejects '$flag' with no repo path" \
    || ok "uninstall rejects '$flag' with no repo path"
  printf '%s' "$out" | grep -qF -- '--project' \
    && ok "the '$flag' error message names the flag" \
    || ko "the '$flag' error message names the flag (got '$out')"
done
{ [ -f "$UE/hooks/learner-quiz.sh" ] && [ -f "$UE/learner.json" ] \
  && [ "$(hookcount "$UE")" = 4 ]; } \
  && ok "a rejected --project leaves the user-level install untouched" \
  || ko "a rejected --project leaves the user-level install untouched"

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

# The trigger's field names are a contract between the hook and the protocol file:
# renaming one in the hook, or dropping it from hook-quiz.md, breaks the read with
# no other symptom. Assert both halves, and cross-check what is actually emitted.
echo '{"level":"S"}' > "$GCFG"; rm -f "$PCFG"
SIDT=triggerfields
rec "$SIDT" "$WORK/proj/src/T.kt"
trigger=$(quiz "$SIDT" | jq -r '.reason' | head -n 1)

for k in level mode styles blanks files; do
  printf '%s' "$trigger" | grep -qF "$k:" \
    && ok "the trigger emits the '$k' field" \
    || ko "the trigger emits the '$k' field"
  grep -qF "\`$k\`" "$REFS/hook-quiz.md" \
    && ok "hook-quiz.md reads the '$k' field" \
    || ko "hook-quiz.md reads the '$k' field"
done

undocumented=''
while IFS= read -r k; do
  [ -n "$k" ] || continue
  grep -qF "\`$k\`" "$REFS/hook-quiz.md" || undocumented="$undocumented $k"
done <<EOF
$(printf '%s' "$trigger" | grep -oE '[a-z]+:' | tr -d ':' | sort -u)
EOF
[ -z "$undocumented" ] \
  && ok "every field the trigger emits is documented in hook-quiz.md" \
  || ko "every field the trigger emits is documented in hook-quiz.md (missing:$undocumented)"

# The `fill` style edits real source files, so its protocol is the load-bearing
# part of hook-quiz.md: read the section itself, not the file as a whole.
fill=$(awk '/^## The `fill` protocol/{f=1;next} /^## /{f=0} f' "$REFS/hook-quiz.md")
[ -n "$fill" ] \
  && ok "hook-quiz.md carries the fill protocol" \
  || ko "hook-quiz.md carries the fill protocol"

printf '%s' "$fill" | grep -qF '`blanks`' \
  && ok "the fill protocol cuts as many holes as blanks says" \
  || ko "the fill protocol cuts as many holes as blanks says"

printf '%s' "$fill" | grep -qi 'restore' \
  && ok "the fill protocol restores the correct implementation" \
  || ko "the fill protocol restores the correct implementation"

{ printf '%s' "$fill" | grep -qi 'never end a turn' \
  && printf '%s' "$fill" | grep -qF 'LEARNER-TODO'; } \
  && ok "the fill protocol forbids ending a turn with a leftover marker" \
  || ko "the fill protocol forbids ending a turn with a leftover marker"

{ grep -qi 'multiple-choice' "$REFS/quiz.md" && grep -qi 'multiple-choice' "$REFS/hook-quiz.md"; } \
  && ok "both quiz protocols prefer plain chat over multiple choice" \
  || ko "both quiz protocols prefer plain chat over multiple choice"

# --- docs -------------------------------------------------------------------
RM="$ROOT/README.md"

# Boundary-aware on trackGlobs (untrackGlobs must not self-trip this). Only
# `intermediaire` is banned: `junior` and `senior` are supported level aliases, so
# a legitimate "aliases accepted" line must not trip this.
grep -qE 'recapEvery|trouBlanks|(^|[^A-Za-z])trackGlobs|"language"|intermediaire' "$RM" \
  && ko "README mentions no removed key or old level" \
  || ok "README mentions no removed key or old level"

for s in CLAUDE_CONFIG_DIR untrackGlobs disabledPaths synthesisFrequency blanksPerExercise 'learner off'; do
  grep -qF "$s" "$RM" && ok "README documents $s" || ko "README documents $s"
done

grep -qF -- '--project' "$RM" \
  && ok "README documents the legacy cleanup flag" \
  || ko "README documents the legacy cleanup flag"

# Bracket expressions, not backslash escapes: `\|` is defined in an ERE but a
# backslash before an ordinary character like a backtick is undefined, and
# implementations disagree — ugrep matched it, GNU grep 3.11 did not.
grep -qE '^[|] [`]?[DJCSE][`]? ' "$RM" \
  && ok "README documents the letter levels" \
  || ko "README documents the letter levels"

# --- bootstrap --------------------------------------------------------------
BOOT="$ROOT/bootstrap.sh"

# A tarball of the working tree, not `git archive`: the change under test must be
# covered before it is committed. Exactly one top-level directory, because the
# bootstrap strips one component.
TARBALL="$WORK/payload.tgz"
tar -czf "$TARBALL" -C "$(dirname "$ROOT")" "$(basename "$ROOT")"

boot() { CLAUDE_CONFIG_DIR="$1" LEARNER_URL="file://$TARBALL" sh "$BOOT" "${@:2}"; }

B1="$WORK/boot1"; mkdir -p "$B1"
boot "$B1" --level S >/dev/null 2>&1
{ [ -f "$B1/hooks/learner-config.sh" ] \
  && [ -f "$B1/hooks/learner-quiz.sh" ] \
  && [ -f "$B1/skills/learner/SKILL.md" ] \
  && [ -f "$B1/skills/learner/references/data.md" ] \
  && [ -f "$B1/learner.json" ]; } \
  && ok "bootstrap installs the payload from the tarball" \
  || ko "bootstrap installs the payload from the tarball"

B2="$WORK/boot2"; mkdir -p "$B2"
boot "$B2" --level senior --synthesis often --blanks 3 >/dev/null 2>&1
jq -e '.level == "S" and .synthesisFrequency == "often" and .blanksPerExercise == 3' \
  "$B2/learner.json" >/dev/null 2>&1 \
  && ok "bootstrap passes every flag through to install.sh" \
  || ko "bootstrap passes every flag through to install.sh"

B3="$WORK/boot3"; mkdir -p "$B3"
boot "$B3" --level S --dry-run >/dev/null 2>&1
[ ! -e "$B3/learner.json" ] \
  && ok "bootstrap honours --dry-run (nothing written)" \
  || ko "bootstrap honours --dry-run (nothing written)"

# Temp dirs must not accumulate: count what the bootstrap leaves behind.
before=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
B4="$WORK/boot4"; mkdir -p "$B4"
TMPDIR="$WORK/tmp" boot "$B4" --level S >/dev/null 2>&1
after=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$before" = "$after" ] \
  && ok "bootstrap removes its temp dir on success" \
  || ko "bootstrap removes its temp dir on success (before=$before after=$after)"

before=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
CLAUDE_CONFIG_DIR="$WORK/boot5" LEARNER_URL="file://$WORK/nope.tgz" \
  TMPDIR="$WORK/tmp" sh "$BOOT" --level S >/dev/null 2>&1
after=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$before" = "$after" ] \
  && ok "bootstrap removes its temp dir on a failed fetch" \
  || ko "bootstrap removes its temp dir on a failed fetch (before=$before after=$after)"

out=$(CLAUDE_CONFIG_DIR="$WORK/boot6" LEARNER_URL="file://$WORK/nope.tgz" \
  sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap fails on an unreachable URL" \
  || ok "bootstrap fails on an unreachable URL"
printf '%s' "$out" | grep -qi 'error' \
  && ok "the unreachable-URL message is an error line" \
  || ko "the unreachable-URL message is an error line"

# An archive without install.sh must be named as such, not fail deep inside bash.
BADTAR="$WORK/bad.tgz"; mkdir -p "$WORK/badsrc/inner"; echo x > "$WORK/badsrc/inner/f"
tar -czf "$BADTAR" -C "$WORK" badsrc
out=$(CLAUDE_CONFIG_DIR="$WORK/boot7" LEARNER_URL="file://$BADTAR" \
  sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap rejects an archive with no install.sh" \
  || ok "bootstrap rejects an archive with no install.sh"
printf '%s' "$out" | grep -q 'install.sh' \
  && ok "the bad-archive message names install.sh" \
  || ko "the bad-archive message names install.sh"

# Claude Code absent: must abort BEFORE fetching. A fake curl proves no fetch ran.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\ntouch "%s/curl-ran"\nexit 1\n' "$WORK" > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"
rm -f "$WORK/curl-ran"
out=$(PATH="$FAKEBIN:/usr/bin:/bin" HOME="$WORK/nohome" \
  CLAUDE_CONFIG_DIR="$WORK/no-such-cfg" sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap aborts when Claude Code is absent" \
  || ok "bootstrap aborts when Claude Code is absent"
printf '%s' "$out" | grep -qi 'claude' \
  && ok "the abort message names Claude Code" \
  || ko "the abort message names Claude Code"
[ ! -e "$WORK/curl-ran" ] \
  && ok "the Claude Code check runs before any fetch" \
  || ko "the Claude Code check runs before any fetch"

# LEARNER_REF must reach the URL. A fake curl records the URL it was handed.
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in http*|file*) echo "$a" > "%s/curl-url" ;; esac; done\nexit 1\n' \
  "$WORK" > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"
rm -f "$WORK/curl-url"
PATH="$FAKEBIN:/usr/bin:/bin" LEARNER_REF=v9.9.9 \
  CLAUDE_CONFIG_DIR="$B1" sh "$BOOT" --level S >/dev/null 2>&1
{ [ -f "$WORK/curl-url" ] && grep -q 'v9.9.9' "$WORK/curl-url"; } \
  && ok "LEARNER_REF reaches the fetch URL" \
  || ko "LEARNER_REF reaches the fetch URL"
grep -q 'Tykok/learning-with-claude' "$WORK/curl-url" 2>/dev/null \
  && ok "the fetch URL names the repo" \
  || ko "the fetch URL names the repo"

# No terminal and no --level: install.sh could neither prompt nor proceed, so the
# bootstrap must say so itself — the user typed a URL, not a script with flags.
# Only assertable where /dev/tty is unreadable (CI); skipped in an interactive shell.
if [ -r /dev/tty ]; then
  skip "no-tty guidance (a terminal is available here)"
else
  out=$(CLAUDE_CONFIG_DIR="$B1" LEARNER_URL="file://$TARBALL" sh "$BOOT" 2>&1) \
    && ko "bootstrap refuses with no terminal and no --level" \
    || ok "bootstrap refuses with no terminal and no --level"
  printf '%s' "$out" | grep -q -- '--level' \
    && ok "the no-tty message shows the --level re-run" \
    || ko "the no-tty message shows the --level re-run"
fi

# --- summary ----------------------------------------------------------------
echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
