#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Tests for the learning-mode hooks + installer.
# Plain sh/bash, no framework. Requires: jq, git. Run: ./test.sh
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
REC="$ROOT/hooks/learner-record-edit.sh"
QUIZ="$ROOT/hooks/learner-quiz.sh"
ONB="$ROOT/hooks/learner-onboard.sh"
CLEAN="$ROOT/hooks/learner-cleanup.sh"
UCHK="$ROOT/hooks/learner-update-check.sh"

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

for pair in "1.2.3:yes" "0.1.0:yes" "1.0:no" "1.x.0:no" "1.2.3.4:no" "1.2.:no" "1..3:no"; do
  raw="${pair%%:*}"; want="${pair##*:}"
  if cfgsh "learner_version_valid $raw"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] \
    && ok "learner_version_valid '$raw' -> $want" \
    || ko "learner_version_valid '$raw' -> $want (got $got)"
done

for t in "1.2.3:1.2.3:no" "1.2.4:1.2.3:yes" "1.2.3:1.2.4:no" \
         "1.3.0:1.2.9:yes" "2.0.0:1.9.9:yes" "1.9.9:2.0.0:no" "1.2.9:1.3.0:no"; do
  a=$(printf '%s' "$t" | cut -d: -f1)
  b=$(printf '%s' "$t" | cut -d: -f2)
  want=$(printf '%s' "$t" | cut -d: -f3)
  if cfgsh "learner_version_gt $a $b"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] \
    && ok "learner_version_gt $a vs $b -> $want" \
    || ko "learner_version_gt $a vs $b -> $want (got $got)"
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

# --- learner_excluded -------------------------------------------------------
echo '{"level":"C","untrackGlobs":["*.md","*.json"]}' > "$GCFG"
rm -f "$PCFG"
XCFG=$(cfgsh 'learner_config')

excl() { cfgsh "learner_excluded '$1' '$XCFG'"; }

excl "$WORK/proj/src/Main.kt"            && ko "plain source is material"            || ok "plain source is material"
excl "$WORK/proj/node_modules/x/i.js"    && ok "node_modules is excluded"             || ko "node_modules is excluded"
excl "$WORK/proj/build/gen/A.kt"         && ok "build/ is excluded"                   || ko "build/ is excluded"
excl "$WORK/proj/target/out.jar"         && ok "target/ is excluded"                  || ko "target/ is excluded"
excl "$WORK/proj/.git/COMMIT_EDITMSG"    && ok ".git/ is excluded"                    || ko ".git/ is excluded"
excl "$WORK/proj/pnpm-lock.yaml"         && ok "*-lock.* is excluded"                 || ko "*-lock.* is excluded"
excl "$WORK/proj/yarn.lock"              && ok "*.lock is excluded"                   || ko "*.lock is excluded"
excl "$WORK/proj/app.min.js"             && ok "*.min.* is excluded"                  || ko "*.min.* is excluded"
excl "$WORK/proj/api.generated.ts"       && ok "*.generated.* is excluded"            || ko "*.generated.* is excluded"
excl "$WORK/proj/README.md"              && ok "untrackGlobs *.md is excluded"        || ko "untrackGlobs *.md is excluded"
excl "$WORK/proj/pkg.json"               && ok "untrackGlobs *.json is excluded"      || ko "untrackGlobs *.json is excluded"

# An empty untrackGlobs must not accidentally exclude everything.
echo '{"level":"C"}' > "$GCFG"
XCFG=$(cfgsh 'learner_config')
excl "$WORK/proj/src/Main.kt" && ko "no globs: source still material" || ok "no globs: source still material"

# The helper must not leave `set -f` on in the caller's shell, or every later
# glob expansion in that shell silently stops working.
out=$(cfgsh "learner_excluded '$WORK/proj/src/Main.kt' '$XCFG'; case \"\$-\" in *f*) echo LEAKED ;; *) echo CLEAN ;; esac")
[ "$out" = "CLEAN" ] && ok "learner_excluded restores globbing" || ko "learner_excluded restores globbing"

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

[ -f "$I/skills/learner/VERSION" ] && [ "$(cat "$I/skills/learner/VERSION")" = "$(cat "$ROOT/VERSION")" ] \
  && ok "install stamps the installed VERSION" \
  || ko "install stamps the installed VERSION"

echo '9.9.9' > "$I/skills/learner/VERSION"
inst "$I" --level S >/dev/null 2>&1
[ "$(cat "$I/skills/learner/VERSION")" = "$(cat "$ROOT/VERSION")" ] \
  && ok "a re-install always refreshes VERSION, unlike learner.json" \
  || ko "a re-install always refreshes VERSION, unlike learner.json"

[ -f "$I/skills/learner/INSTALL_ORIGIN" ] && [ "$(cat "$I/skills/learner/INSTALL_ORIGIN")" = "curl" ] \
  && ok "install defaults --origin to curl" \
  || ko "install defaults --origin to curl"

IB="$WORK/inst-brew"; mkdir -p "$IB"
inst "$IB" --level S --origin brew >/dev/null 2>&1
[ "$(cat "$IB/skills/learner/INSTALL_ORIGIN" 2>/dev/null)" = "brew" ] \
  && ok "install stamps --origin brew" \
  || ko "install stamps --origin brew"

IA="$WORK/inst-apt"; mkdir -p "$IA"
inst "$IA" --level S --origin apt >/dev/null 2>&1
[ "$(cat "$IA/skills/learner/INSTALL_ORIGIN" 2>/dev/null)" = "apt" ] \
  && ok "install stamps --origin apt" \
  || ko "install stamps --origin apt"

out=$(inst "$WORK/inst-bad-origin" --level S --origin homebrew 2>&1) \
  && ko "install rejects an unknown --origin value" \
  || ok "install rejects an unknown --origin value"
printf '%s' "$out" | grep -qF -- '--origin' \
  && ok "the --origin error message names the flag" \
  || ko "the --origin error message names the flag (got '$out')"

echo 'brew' > "$I/skills/learner/INSTALL_ORIGIN"
inst "$I" --level S --origin curl >/dev/null 2>&1
[ "$(cat "$I/skills/learner/INSTALL_ORIGIN")" = "curl" ] \
  && ok "a re-install always refreshes INSTALL_ORIGIN, unlike learner.json" \
  || ko "a re-install always refreshes INSTALL_ORIGIN, unlike learner.json"

jq -e '.level == "S" and .synthesisFrequency == "often" and .blanksPerExercise == 3' \
  "$I/learner.json" >/dev/null 2>&1 \
  && ok "install writes the global config from flags" \
  || ko "install writes the global config from flags"

n=$(find "$I/hooks" -name 'learner-*.sh' | wc -l | tr -d ' ')
[ "$n" = 6 ] \
  && ok "install lays down 6 hook files" \
  || ko "install lays down 6 hook files (got $n)"

# Only 5 are wired: learner-config.sh is sourced, never invoked by Claude Code.
n1=$(hookcount "$I")
inst "$I" --level S >/dev/null 2>&1
n2=$(hookcount "$I")
{ [ "$n1" = 5 ] && [ "$n2" = 5 ]; } \
  && ok "hook merge is idempotent (5 wired hooks)" \
  || ko "hook merge is idempotent (got $n1 then $n2, want 5/5)"

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
  && [ ! -e "$U/hooks/learner-update-check.sh" ] \
  && [ ! -e "$U/skills/learner/INSTALL_ORIGIN" ] \
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
  && [ "$(hookcount "$UE")" = 5 ]; } \
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

for f in hook-quiz.md quiz.md improve.md data.md export.md update.md; do
  [ -f "$REFS/$f" ] && ok "references/$f exists" || ko "references/$f exists"
done

UPD="$ROOT/skills/learner/references/update.md"

grep -qF 'INSTALL_ORIGIN' "$UPD" \
  && ok "update.md reads the install-origin marker" \
  || ko "update.md reads the install-origin marker"

grep -qF 'brew upgrade learner' "$UPD" \
  && ok "update.md tells a brew install to use brew upgrade" \
  || ko "update.md tells a brew install to use brew upgrade"

grep -qF 'apt install' "$UPD" \
  && ok "update.md tells an apt install to grab a new .deb" \
  || ko "update.md tells an apt install to grab a new .deb"

grep -qF 'learner-install' "$UPD" \
  && ok "update.md points package-managed installs at learner-install" \
  || ko "update.md points package-managed installs at learner-install"

grep -qF '/plugins/' "$UPD" \
  && ok "update.md detects a plugin install by its own load path" \
  || ko "update.md detects a plugin install by its own load path"

grep -qF '/plugin update learner' "$UPD" \
  && ok "update.md points a plugin install at /plugin update" \
  || ko "update.md points a plugin install at /plugin update"

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

# Same guard for the export Dispatch row: repointed at prose elsewhere, export.md would
# become dead weight and every assertion below would still pass.
grep -q 'references/export.md' "$SK" \
  && ok "SKILL.md routes the export subcommand to references/export.md" \
  || ko "SKILL.md routes the export subcommand to references/export.md"

grep -q 'references/update.md' "$SK" \
  && ok "SKILL.md routes the update subcommand to references/update.md" \
  || ko "SKILL.md routes the update subcommand to references/update.md"

grep -qi 'skills/learner/VERSION' "$SK" \
  && ok "SKILL.md's Status section reads the installed VERSION file" \
  || ko "SKILL.md's Status section reads the installed VERSION file"

grep -qF '/plugin' "$SK" \
  && ok "SKILL.md's Status section is plugin-aware" \
  || ko "SKILL.md's Status section is plugin-aware"

grep -q 'references/data.md' "$REFS/hook-quiz.md" \
  && grep -q 'references/data.md' "$REFS/quiz.md" \
  && grep -q 'references/data.md' "$REFS/improve.md" \
  && ok "the three quiz modes all defer to references/data.md" \
  || ko "the three quiz modes all defer to references/data.md"

grep -q 'CLAUDE_CONFIG_DIR' "$REFS/data.md" \
  && ok "data.md resolves the config dir from CLAUDE_CONFIG_DIR" \
  || ko "data.md resolves the config dir from CLAUDE_CONFIG_DIR"

# The Learning level in the Notion export is computed per theme from these rows, so a row
# that does not name its theme is uncountable. `Theme` going last is the decision, not an
# accident: an old six-cell row then reads unambiguously as untagged, where an inserted
# column would make cell 4 mean `Style` on old rows and `Theme` on new ones — and the
# reader here is a model, not a parser holding a schema.
grep -qF '| Date | Repo | Domain | Style | Verdict | Note | Theme |' "$REFS/data.md" \
  && ok "data.md's Session history table ends with the Theme column" \
  || ko "data.md's Session history table ends with the Theme column"

# The five-value scale is the export's whole contribution beyond a copy of recap.md, and
# rule 1 is what keeps recap.md authoritative over the tally. A value renamed or a rule
# dropped in a later edit would silently regrade every row, with no other symptom.
# Narrowed to the `Learning level` row: every value also appears in §5's rule table, and
# `Mastered` in the prose besides, so a file-wide grep stayed green with the Select row
# and rule 1 both gone.
for v in Discovered Shaky Progressing Solid Mastered; do
  grep -F 'Learning level' "$REFS/export.md" | grep -qF "\`$v\`" \
    && ok "export.md documents the '$v' learning level" \
    || ko "export.md documents the '$v' learning level"
done

# Bracket expressions, not `\|`: the rule rows are the only lines in the file that open
# with a pipe, a single digit and a pipe. Scoped to §5 so an unrelated `| N |` row added
# elsewhere cannot inflate the count and turn this red with a misleading message.
nrules=$(awk '/^## 5[.]/{f=1} /^## 6[.]/{f=0} f && /^[|] [1-6] [|]/{c++} END{print c+0}' "$REFS/export.md")
[ "$nrules" -eq 6 ] \
  && ok "export.md keeps all six level-derivation rules" \
  || ko "export.md keeps all six level-derivation rules (got $nrules)"

grep -qF 'CLAUDE_CONFIG_DIR' "$REFS/export.md" \
  && grep -qF 'export.json' "$REFS/export.md" \
  && ok "export.md resolves export.json under CLAUDE_CONFIG_DIR" \
  || ko "export.md resolves export.json under CLAUDE_CONFIG_DIR"

# Locked decision 2: no connector, no export. A file-shaped consolation prize would
# reopen the export surface this design defers, so the two words are banned outright —
# the protocol cannot drift into offering one without turning this red.
grep -qiE 'csv|markdown' "$REFS/export.md" \
  && ko "export.md offers no file-format fallback" \
  || ok "export.md offers no file-format fallback"

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

# A question that quotes both sides of a hunk and then asks what the change does has
# already been answered. The rule that forbids it has to live in both protocols: the
# Stop hook reads one, `learner quiz` reads the other, and neither reads the other one.
for f in quiz.md hook-quiz.md; do
  leak=$(awk '/^## Never hand the answer over/{f=1;next} /^## /{f=0} f' "$REFS/$f")
  { printf '%s' "$leak" | grep -qi 'both sides' \
    && printf '%s' "$leak" | grep -qi 'feedback'; } \
    && ok "$f forbids a question that carries its own answer" \
    || ko "$f forbids a question that carries its own answer"
done

# --- docs -------------------------------------------------------------------
RM="$ROOT/README.md"
SITE="$ROOT/docs/index.html"
STYLE="$ROOT/docs/assets/style.css"

SITE_INSTALL="$ROOT/docs/install.html"
SITE_USAGE="$ROOT/docs/usage.html"
SITE_CONFIG="$ROOT/docs/config.html"
SITE_SAFETY="$ROOT/docs/safety.html"

# Every published page, by basename. Per-page loops iterate this list, so a page
# added to the site cannot quietly skip the structural checks below.
PAGES="index install usage config safety"

page_path() { printf '%s/docs/%s.html' "$ROOT" "$1"; }

# Boundary-aware on trackGlobs (untrackGlobs must not self-trip this). Only
# `intermediaire` is banned: `junior` and `senior` are supported level aliases, so
# a legitimate "aliases accepted" line must not trip this.
grep -qE 'recapEvery|trouBlanks|(^|[^A-Za-z])trackGlobs|"language"|intermediaire' "$RM" \
  && ko "README mentions no removed key or old level" \
  || ok "README mentions no removed key or old level"

grep -qF 'bootstrap.sh' "$RM" \
  && ok "README documents the one-line install" \
  || ko "README documents the one-line install"

grep -qF 'LEARNER_REF' "$RM" \
  && ok "README documents pinning a ref" \
  || ko "README documents pinning a ref"

grep -qF 'sh -s --' "$RM" \
  && ok "README documents the non-interactive one-liner form" \
  || ko "README documents the non-interactive one-liner form"

# Named and pinned to the bullet it was kept for, not to the bare word: the README no
# longer mentions Windows/WSL/Git Bash at all (that moved to the site), but a bare
# `grep -qiF 'posix'` still passed after a reviewer deleted every prose mention of it —
# the shields.io badge on line 6 (`shell-POSIX%20sh`) kept it green for the wrong reason.
grep -qE '^- [*][*]A POSIX-compliant shell to run the hooks[*][*]' "$RM" \
  && ok "README's Requirements list keeps the POSIX-shell bullet" \
  || ko "README's Requirements list keeps the POSIX-shell bullet"

# bootstrap.sh preflights `bash`, so it is a hard install-time dependency on both
# paths (install.sh is a bash script) and Requirements has to say so. A bare
# `grep -qF 'bash'` would be worthless here: every fenced code block in this
# README opens with ```bash, and "Git Bash" appears on the site's platform
# table, so it would pass against a README that never mentions the dependency.
# Pinned to the bullet's shape instead, including "to install" — the claim that
# distinguishes it from the POSIX-shell bullet, which is about running the
# hooks. Bracket expressions, not backslashes, before the ordinary backtick
# character.
grep -qE '^- [*][*][`]bash[`][*][*] on [`]PATH[`] to install' "$RM" \
  && ok "README requires bash to install, separately from the hooks' shell" \
  || ko "README requires bash to install, separately from the hooks' shell"

# The Development section's shellcheck line must match what CI actually runs. A fixed
# substring here only ever proved the README mentions bootstrap.sh, never that it matches
# .github/workflows/ci.yml — so read the real command out of the workflow file and compare
# against it, rather than trusting a copy of a copy.
CI_YML="$ROOT/.github/workflows/ci.yml"
CI_SHELLCHECK=$(awk '/name: shellcheck/{getline; sub(/^[[:space:]]*run:[[:space:]]*/, ""); print; exit}' "$CI_YML")
[ -n "$CI_SHELLCHECK" ] \
  && grep -qF "$CI_SHELLCHECK" "$RM" \
  && ok "README's Development shellcheck line matches .github/workflows/ci.yml" \
  || ko "README's Development shellcheck line matches .github/workflows/ci.yml"

grep -qE "tags:[[:space:]]*\['?v\*'?\]" "$CI_YML" \
  && ok "CI triggers on version tags, for the VERSION-vs-tag guard" \
  || ko "CI triggers on version tags, for the VERSION-vs-tag guard"

grep -qF 'startsWith(github.ref' "$CI_YML" \
  && grep -qF 'TAG="${GITHUB_REF_NAME#v}"' "$CI_YML" \
  && grep -qF 'FILE="$(cat VERSION)"' "$CI_YML" \
  && grep -qF '[ "$TAG" != "$FILE" ]' "$CI_YML" \
  && grep -qF 'exit 1' "$CI_YML" \
  && ok "CI guards a tag push against the VERSION file" \
  || ko "CI guards a tag push against the VERSION file"

grep -qF 'contents: write' "$CI_YML" \
  && ok "CI grants contents:write, needed to publish a release asset" \
  || ko "CI grants contents:write, needed to publish a release asset"

grep -qF 'run: bash packaging/deb/build.sh' "$CI_YML" \
  && ok "CI builds the .deb on a tag push" \
  || ko "CI builds the .deb on a tag push"

grep -qF 'softprops/action-gh-release' "$CI_YML" \
  && grep -qF 'learner_*_all.deb' "$CI_YML" \
  && ok "CI publishes the .deb as a release asset" \
  || ko "CI publishes the .deb as a release asset"

grep -qF 'deploy-pages:' "$CI_YML" \
  && ok "CI defines a deploy-pages job" \
  || ko "CI defines a deploy-pages job"

grep -qF 'run: bash packaging/apt-repo/assemble-site.sh' "$CI_YML" \
  && ok "deploy-pages runs the site assembler" \
  || ko "deploy-pages runs the site assembler"

grep -qF 'actions/upload-pages-artifact' "$CI_YML" \
  && grep -qF 'actions/deploy-pages' "$CI_YML" \
  && ok "deploy-pages uploads and deploys the Pages artifact" \
  || ko "deploy-pages uploads and deploys the Pages artifact"

grep -qF 'pages: write' "$CI_YML" \
  && grep -qF 'id-token: write' "$CI_YML" \
  && ok "deploy-pages grants pages:write and id-token:write" \
  || ko "deploy-pages grants pages:write and id-token:write"

grep -qF 'needs: [ci, release]' "$CI_YML" \
  && ok "deploy-pages runs after both ci and release" \
  || ko "deploy-pages runs after both ci and release"

grep -qF 'plugin.json version matches VERSION' "$CI_YML" \
  && ok "CI guards plugin.json's version against the VERSION file" \
  || ko "CI guards plugin.json's version against the VERSION file"

grep -qF "jq -r '.version' .claude-plugin/plugin.json" "$CI_YML" \
  && ok "the plugin.json version guard reads the real field" \
  || ko "the plugin.json version guard reads the real field"

grep -qF 'update-check hook' "$RM" \
  && ok "README notes curl as a soft run-time dependency for the update-check hook" \
  || ko "README notes curl as a soft run-time dependency for the update-check hook"

# The install one-liner appears in two files by design. Pin them to each other so
# they cannot drift: this is the whole reason the split is acceptable.
ONELINER='curl -fsSL https://raw.githubusercontent.com/Tykok/learning-with-claude/main/bootstrap.sh | sh'
{ grep -qF "$ONELINER" "$RM" && grep -qF "$ONELINER" "$SITE_INSTALL"; } \
  && ok "the install one-liner is identical in the README and on install.html" \
  || ko "the install one-liner is identical in the README and on install.html"

apt_h2=$(grep -n '<h2 id="apt">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
homebrew_h2=$(grep -n '<h2 id="homebrew">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
clone_h2=$(grep -n '<h2 id="clone">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
alt_h2=$(grep -n '<h2 id="alternative">' "$SITE_INSTALL" | head -1 | cut -d: -f1)

{ [ -n "$apt_h2" ] && [ -n "$homebrew_h2" ] && [ -n "$clone_h2" ] && [ -n "$alt_h2" ] \
  && [ "$apt_h2" -lt "$homebrew_h2" ] \
  && [ "$homebrew_h2" -lt "$clone_h2" ] \
  && [ "$clone_h2" -lt "$alt_h2" ]; } \
  && ok "install.html orders sections as apt, Homebrew, clone, then the curl alternative" \
  || ko "install.html orders sections as apt, Homebrew, clone, then the curl alternative"

plugin_h2=$(grep -n '<h2 id="plugin">' "$SITE_INSTALL" | head -1 | cut -d: -f1)
apt_h2=$(grep -n '<h2 id="apt">' "$SITE_INSTALL" | head -1 | cut -d: -f1)

{ [ -n "$plugin_h2" ] && [ -n "$apt_h2" ] && [ "$plugin_h2" -lt "$apt_h2" ]; } \
  && ok "install.html lists the plugin section before apt" \
  || ko "install.html lists the plugin section before apt"

grep -qF 'claude plugin install learner' "$SITE_INSTALL" \
  && ok "install.html documents installing the plugin by name" \
  || ko "install.html documents installing the plugin by name"

grep -qF 'sudo apt install learner' "$SITE_INSTALL" \
  && ok "install.html documents installing directly from the apt repository" \
  || ko "install.html documents installing directly from the apt repository"

grep -qF '<h2 id="packages">' "$SITE_INSTALL" \
  && ko "install.html no longer has the old combined packages section" \
  || ok "install.html no longer has the old combined packages section"

{ grep -qF 'docs/index.html' "$RM" || grep -qiF 'github.io' "$RM"; } \
  && ok "the README links to the site" \
  || ko "the README links to the site"

grep -qF 'brew install learner' "$RM" \
  && ok "README documents the Homebrew install path" \
  || ko "README documents the Homebrew install path"

grep -qF 'sudo apt install ./learner_' "$RM" \
  && ok "README documents the apt/.deb install path" \
  || ko "README documents the apt/.deb install path"

grep -qF 'learner-install --level' "$RM" \
  && ok "README documents the learner-install activation command" \
  || ko "README documents the learner-install activation command"

apt_line=$(grep -n '^### apt (Debian/Ubuntu)$' "$RM" | head -1 | cut -d: -f1)
brew_line=$(grep -n '^### Homebrew' "$RM" | head -1 | cut -d: -f1)
clone_line=$(grep -n '^### Clone and run$' "$RM" | head -1 | cut -d: -f1)
alt_line=$(grep -n '^### Alternative: the curl one-liner$' "$RM" | head -1 | cut -d: -f1)

{ [ -n "$apt_line" ] && [ -n "$brew_line" ] && [ -n "$clone_line" ] && [ -n "$alt_line" ] \
  && [ "$apt_line" -lt "$brew_line" ] \
  && [ "$brew_line" -lt "$clone_line" ] \
  && [ "$clone_line" -lt "$alt_line" ]; } \
  && ok "README orders Install as apt, Homebrew, clone, then the curl alternative" \
  || ko "README orders Install as apt, Homebrew, clone, then the curl alternative"

grep -qF 'sudo apt install learner' "$RM" \
  && ok "README documents installing directly from the apt repository" \
  || ko "README documents installing directly from the apt repository"

grep -qF 'learner.gpg' "$RM" \
  && ok "README documents the apt repo's signing key setup" \
  || ko "README documents the apt repo's signing key setup"

plugin_line=$(grep -n '^### Claude Code plugin$' "$RM" | head -1 | cut -d: -f1)
apt_line=$(grep -n '^### apt (Debian/Ubuntu)$' "$RM" | head -1 | cut -d: -f1)

{ [ -n "$plugin_line" ] && [ -n "$apt_line" ] && [ "$plugin_line" -lt "$apt_line" ]; } \
  && ok "README lists the Claude Code plugin before apt" \
  || ko "README lists the Claude Code plugin before apt"

grep -qF 'claude plugin install learner' "$RM" \
  && ok "README documents installing the plugin by name" \
  || ko "README documents installing the plugin by name"

grep -qF 'claude plugin marketplace add Tykok/learning-with-claude' "$RM" \
  && ok "README documents adding the self-hosted marketplace" \
  || ko "README documents adding the self-hosted marketplace"

grep -qF 'wires every hook twice' "$RM" \
  && ok "README warns against installing both the plugin and a traditional install" \
  || ko "README warns against installing both the plugin and a traditional install"

grep -qF 'wires every hook twice' "$SITE_INSTALL" \
  && ok "install.html warns against installing both the plugin and a traditional install" \
  || ko "install.html warns against installing both the plugin and a traditional install"

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
mkdir -p "$WORK/boot5"
CLAUDE_CONFIG_DIR="$WORK/boot5" LEARNER_URL="file://$WORK/nope.tgz" \
  TMPDIR="$WORK/tmp" sh "$BOOT" --level S >/dev/null 2>&1
after=$(find "$WORK/tmp" -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$before" = "$after" ] \
  && ok "bootstrap removes its temp dir on a failed fetch" \
  || ko "bootstrap removes its temp dir on a failed fetch (before=$before after=$after)"

mkdir -p "$WORK/boot6"
out=$(CLAUDE_CONFIG_DIR="$WORK/boot6" LEARNER_URL="file://$WORK/nope.tgz" \
  sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap fails on an unreachable URL" \
  || ok "bootstrap fails on an unreachable URL"

# Every die() message is prefixed "error: ", so a bare 'error' grep would pass
# against ANY failure path, not specifically this one — the wording unique to a
# fetch that delivered nothing is "could not fetch". This assertion belongs on
# the *missing* URL and nowhere else, and it is assertable only because the
# bootstrap downloads to a file and reads curl's own exit status (37 here, on
# both curl builds). Under the earlier `curl | tar` pipeline it was unreachable
# on macOS: POSIX sh has no pipefail, so the pipeline's status was tar's, and
# bsdtar accepts curl's zero bytes as a valid empty archive and exits 0 (GNU
# tar exits 2) — every 404, DNS or proxy failure was reported there as
# "has no install.sh (bad ref?)", naming a branch problem for a network one.
printf '%s' "$out" | grep -qF 'could not fetch' \
  && ok "the failed-fetch message names the failed fetch" \
  || ko "the failed-fetch message names the failed fetch"

# A fetch that *succeeds* and hands back bytes that are not a gzip stream is a
# different fault with a different cause, and must not be reported as a failed
# fetch. An existing non-gzip file, not a missing one: curl returns 0 for it
# everywhere, and both bsdtar and GNU tar then reject the bytes identically
# (confirmed by running both directly), so this fixture is deterministic where
# a missing file would exercise the branch above instead.
GARBAGE="$WORK/garbage.tgz"
printf 'not a gzip archive at all, just plain bytes\n' > "$GARBAGE"
mkdir -p "$WORK/boot6b"
out=$(CLAUDE_CONFIG_DIR="$WORK/boot6b" LEARNER_URL="file://$GARBAGE" \
  sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap fails when the fetch yields no usable archive" \
  || ok "bootstrap fails when the fetch yields no usable archive"
printf '%s' "$out" | grep -qF 'not a readable tar.gz' \
  && ok "the unusable-archive message blames the archive, not the fetch" \
  || ko "the unusable-archive message blames the archive, not the fetch"

# An archive without install.sh must be named as such, not fail deep inside bash.
BADTAR="$WORK/bad.tgz"; mkdir -p "$WORK/badsrc/inner"; echo x > "$WORK/badsrc/inner/f"
tar -czf "$BADTAR" -C "$WORK" badsrc
mkdir -p "$WORK/boot7"
out=$(CLAUDE_CONFIG_DIR="$WORK/boot7" LEARNER_URL="file://$BADTAR" \
  sh "$BOOT" --level S 2>&1) \
  && ko "bootstrap rejects an archive with no install.sh" \
  || ok "bootstrap rejects an archive with no install.sh"
# -F on the whole phrase, not a bare 'install.sh': the path bash prints when it
# cannot find the file ("No such file or directory: …/install.sh") also contains
# that substring, so a bare pattern stayed green with the guard deleted.
printf '%s' "$out" | grep -qF 'has no install.sh' \
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
# `-r /dev/tty` only checks permissions, and a redirection failure on the `:`
# special built-in kills a POSIX shell (dash) outright, so this guard opens the
# terminal in a subshell to agree with bootstrap.sh. Only assertable where that
# open fails; skipped where it succeeds.
if (exec 3< /dev/tty) 2>/dev/null; then
  skip "no-tty guidance and its existing-config exemption (a terminal is available here)"
else
  # A config directory that exists but holds no learner.json. It has to exist,
  # or the Claude Code preflight fires first where no `claude` binary is on PATH
  # (CI); and it must have no learner.json, or the guard's exemption applies and
  # this exercises the pass-through below instead of the refusal it names — the
  # reason $B1 cannot be reused here now that the exemption exists.
  B8="$WORK/boot8"; mkdir -p "$B8"
  out=$(CLAUDE_CONFIG_DIR="$B8" LEARNER_URL="file://$TARBALL" sh "$BOOT" 2>&1) \
    && ko "bootstrap refuses with no terminal and no --level" \
    || ok "bootstrap refuses with no terminal and no --level"
  printf '%s' "$out" | grep -q -- '--level' \
    && ok "the no-tty message shows the --level re-run" \
    || ko "the no-tty message shows the --level re-run"

  # The other half of the guard: install.sh gates its whole prompt block on the
  # config NOT existing, so with a learner.json already there it needs no
  # answers and refusing would break a legitimate non-interactive re-install
  # (re-copying hooks after an update). $B1 has one, from the first bootstrap
  # test above. Deleting a hook first proves the run reached install.sh, rather
  # than merely getting past the guard and failing somewhere later.
  rm -f "$B1/hooks/learner-quiz.sh"
  { CLAUDE_CONFIG_DIR="$B1" LEARNER_URL="file://$TARBALL" sh "$BOOT" >/dev/null 2>&1 \
    && [ -f "$B1/hooks/learner-quiz.sh" ]; } \
    && ok "bootstrap proceeds with no terminal and no --level once a config exists" \
    || ko "bootstrap proceeds with no terminal and no --level once a config exists"
fi

# --- site -------------------------------------------------------------------
# SITE is set in the docs section above; the README and site checks share it so
# the one-liner and link assertions there can compare the two files.

[ -f "$SITE" ] && ok "the site exists at docs/index.html" \
               || ko "the site exists at docs/index.html"

[ -f "$ROOT/docs/.nojekyll" ] \
  && ok "docs/.nojekyll stops GitHub running the page through Jekyll" \
  || ko "docs/.nojekyll stops GitHub running the page through Jekyll"

# The published root must hold the site, and nothing else. The design records it
# once had to be kept apart from now live in the wiki, so there is no in-tree
# counterpart left to assert.
[ ! -d "$ROOT/docs/superpowers" ] \
  && ok "the published root carries no internal design records" \
  || ko "the published root carries no internal design records"

# No external request at load. <a href> navigation is fine; fetching tags/properties are
# not. The original three (script/link-href/@import) missed a whole class of fetch: an
# `@font-face { src: url(https://…) }` needs none of them, so a reviewer added one and the
# suite stayed green. img/iframe/embed/object/srcset cover the other tags that fetch;
# url(...) is scoped to an http(s) scheme so a local url(#fragment) or a data: URI (no
# request either) is not a false positive.
#
# The <link> branch is scoped to a scheme rather than banning href outright: the pages
# share one local stylesheet, which issues no external request. `//` is included because a
# protocol-relative URL fetches off-origin exactly like an absolute one.
EXTERNAL='<script|<link[^>]+href="(https?:|//)|@import|<img|<iframe|<embed|<object|srcset|url\([^)]*https?:'

for p in $PAGES; do
  f=$(page_path "$p")

  grep -qiE "$EXTERNAL" "$f" \
    && ko "$p.html issues no external request at load" \
    || ok "$p.html issues no external request at load"

  grep -qF '<link rel="stylesheet" href="assets/style.css">' "$f" \
    && ok "$p.html links the shared stylesheet" \
    || ko "$p.html links the shared stylesheet"

  # -o counts occurrences, not matching lines: two <h1> on one line must still fail.
  n=$(grep -oiE '<h1[ >]' "$f" | wc -l | tr -d ' ')
  [ "$n" = 1 ] && ok "$p.html has exactly one h1" \
               || ko "$p.html has exactly one h1 (found $n)"
done

# The stylesheet is scanned too, and it is the likelier place for a web font to appear.
grep -qiE "$EXTERNAL" "$STYLE" \
  && ko "the stylesheet issues no external request" \
  || ok "the stylesheet issues no external request"

grep -qiF 'prefers-color-scheme' "$STYLE" \
  && ok "the stylesheet styles both light and dark" \
  || ko "the stylesheet styles both light and dark"

# --- the shared chrome ------------------------------------------------------
# The menu is copied into every page by hand, so the thing to assert is not that
# copying happened but that the copies agree.

nav_links() {
  # The menu's ordered "href|label" list, one per line. aria-current sits between
  # the href and the '>' and is deliberately dropped: it differs by page on
  # purpose, so comparing raw bytes would report every page as divergent.
  awk '/<nav class="site"/,/<\/nav>/' "$1" \
    | grep -oE '<li><a href="[^"]+"[^>]*>[^<]+</a></li>' \
    | sed -e 's/^<li><a href="//' -e 's/"[^>]*>/|/' -e 's|</a></li>$||'
}

nav_ref=$(nav_links "$(page_path index)")

[ -n "$nav_ref" ] \
  && ok "index.html carries a menu" \
  || ko "index.html carries a menu"

for p in $PAGES; do
  [ "$(nav_links "$(page_path "$p")")" = "$nav_ref" ] \
    && ok "$p.html's menu matches index.html's" \
    || ko "$p.html's menu matches index.html's"
done

# The menu lists every page and nothing else. Without this, five pages could agree
# on a menu that omits one of them.
nav_n=$(printf '%s\n' "$nav_ref" | grep -c '|')
# shellcheck disable=SC2086  # word splitting is how the page list is iterated
page_n=$(printf '%s\n' $PAGES | wc -l | tr -d ' ')
[ "$nav_n" = "$page_n" ] \
  && ok "the menu lists every page ($page_n)" \
  || ko "the menu lists every page (menu $nav_n, pages $page_n)"

# Each page marks itself, and only itself. Two matches make $cur two lines and fail
# the comparison, so this covers "exactly one" without a separate count.
for p in $PAGES; do
  cur=$(awk '/<nav class="site"/,/<\/nav>/' "$(page_path "$p")" \
        | grep -oE 'href="[^"]+" aria-current="page"' \
        | sed -e 's/^href="//' -e 's/" aria-current="page"$//')
  [ "$cur" = "$p.html" ] \
    && ok "$p.html marks itself current in the menu" \
    || ko "$p.html marks itself current in the menu (got '$cur')"
done

# Every local href resolves: the file exists, and a fragment exists as an id in it.
# This is what guards the cross-page links the split creates, and the only check
# that catches an id deleted later. Hrefs on this site carry no spaces, so word
# splitting over the grep output is safe.
link_bad=0
for f in "$ROOT"/docs/*.html; do
  for h in $(grep -oE 'href="[^"]+"' "$f" | sed -e 's/^href="//' -e 's/"$//'); do
    case "$h" in http:*|https:*|//*|mailto:*) continue ;; esac
    target=${h%%#*}
    [ -n "$target" ] || target=$(basename "$f")
    if [ ! -f "$ROOT/docs/$target" ]; then
      link_bad=$((link_bad + 1))
      echo "    dangling file: $h  (in $(basename "$f"))"
      continue
    fi
    case "$h" in
      *[#]*)
        frag=${h#*#}
        grep -qF "id=\"$frag\"" "$ROOT/docs/$target" || {
          link_bad=$((link_bad + 1))
          echo "    dangling anchor: $h  (in $(basename "$f"))"
        } ;;
    esac
  done
done
[ "$link_bad" = 0 ] \
  && ok "every internal link resolves to a file and an id" \
  || ko "every internal link resolves to a file and an id ($link_bad dangling)"

# A page with four or more sections gets an "On this page" list; a shorter page does
# not, because a two-entry table of contents is decoration rather than navigation.
# Where the list exists, its entries must be the page's h2 ids in document order.
for p in $PAGES; do
  f=$(page_path "$p")
  h2_ids=$(grep -oE '<h2 id="[^"]+"' "$f" | sed -e 's/^<h2 id="//' -e 's/"$//')
  h2_n=$(printf '%s\n' "$h2_ids" | grep -c .)
  toc_ids=$(awk '/<nav class="toc"/,/<\/nav>/' "$f" \
            | grep -oE 'href="#[^"]+"' | sed -e 's/^href="#//' -e 's/"$//')
  if [ "$h2_n" -ge 4 ]; then
    [ "$toc_ids" = "$h2_ids" ] \
      && ok "$p.html's table of contents matches its $h2_n sections" \
      || ko "$p.html's table of contents matches its $h2_n sections"
  else
    [ -z "$toc_ids" ] \
      && ok "$p.html has $h2_n sections and needs no table of contents" \
      || ko "$p.html has $h2_n sections and needs no table of contents"
  fi
done

# Every page ends with a link onward, so no page is a dead end.
for p in $PAGES; do
  grep -qF '<p class="next">' "$(page_path "$p")" \
    && ok "$p.html links onward" \
    || ko "$p.html links onward"
done

# The reference content that moves off the README lives here now, pinned to the page
# that owns each fact rather than to anywhere on the site.
for s in untrackGlobs disabledPaths synthesisFrequency blanksPerExercise 'learner off'; do
  grep -qF "$s" "$SITE_CONFIG" \
    && ok "config.html documents $s" \
    || ko "config.html documents $s"
done

for s in CLAUDE_CONFIG_DIR 'learner-config.sh'; do
  grep -qF "$s" "$SITE_INSTALL" \
    && ok "install.html documents $s" \
    || ko "install.html documents $s"
done

# The check above only pins the config keys' *names*. The seven defaults are a
# hand-copy of LEARNER_DEFAULTS in hooks/learner-config.sh, and now a THIRD copy
# after skills/learner/SKILL.md and, until this task, the README — so
# blanksPerExercise could drift from 2 to 3 in the code and every copy would
# desync while this suite stayed green. Read the real defaults from the source
# of truth via jq instead of hard-coding them here, so a changed default with a
# stale page turns this red. (`level` is the one key with no default and is
# correctly absent from LEARNER_DEFAULTS, so it is skipped automatically.)
defaults_line=$(grep -m1 '^LEARNER_DEFAULTS=' "$ROOT/hooks/learner-config.sh")
defaults_json=${defaults_line#LEARNER_DEFAULTS=\'}
defaults_json=${defaults_json%\'}
for key in $(printf '%s' "$defaults_json" | jq -r 'keys[]'); do
  val=$(printf '%s' "$defaults_json" | jq -c --arg k "$key" '.[$k]')
  # A string default may appear quoted or bare in the page's prose (e.g.
  # "auto" vs normal), so accept either rendering.
  bare=${val#\"}; bare=${bare%\"}
  row=$(grep -F "<tr><td><code>$key</code></td>" "$SITE_CONFIG")
  # Scoped to the Default *column*, not the whole row: the table has four <td>
  # cells per row (Key, Values, Default, Effect) each closed with exactly one
  # "</td>", so splitting on that literal string isolates cell 3. A row-wide
  # search here previously passed with the wrong default documented, because the
  # correct value still existed somewhere else in the same row (the Values
  # cell) — this rescopes the read, not just the pattern.
  cell=$(printf '%s' "$row" | awk -F'</td>' '{print $3}')
  { printf '%s' "$cell" | grep -qF "<td><code>${val}</code>" \
    || printf '%s' "$cell" | grep -qF "<td><code>${bare}</code>"; } \
    && ok "config.html's default for $key matches LEARNER_DEFAULTS ($val)" \
    || ko "config.html's default for $key matches LEARNER_DEFAULTS ($val)"
done

# The site is both the pitch and the full reference (locked decision #3) — that covers
# more than the automatic quiz. Derive the subcommand list from the skill's own dispatch
# table instead of hard-coding it here, so a seventh subcommand added later is caught by
# this check automatically rather than silently shipping undocumented, the way
# `status`/`improve`/`help` and `quiz`'s syntax did the first time around.
DISPATCH=$(awk '/^## Dispatch/{f=1;next} /^## /{f=0} f' "$ROOT/skills/learner/SKILL.md")
SUBCOMMANDS=$(printf '%s\n' "$DISPATCH" | awk -F'|' '/^\|/{print $2}' \
  | grep -oE '`[^`]*`' | tr -d '`' | awk '{print $1}' | grep -vE '^-' | sort -u)
for sub in $SUBCOMMANDS; do
  # Bounded on the right: an unanchored `grep -F "learner $sub"` passes on any prose
  # that happens to contain the substring — "the learner once told me…" satisfies
  # "learner on" with no `on` subcommand in sight. Space or punctuation (a closing
  # `<`, in practice) after the word; end of line covers a subcommand as the last
  # word on its line.
  grep -qE "learner ${sub}([[:space:][:punct:]]|\$)" "$SITE_USAGE" \
    && ok "usage.html documents the 'learner $sub' subcommand" \
    || ko "usage.html documents the 'learner $sub' subcommand"
done

grep -qF -- '--project' "$SITE_SAFETY" \
  && ok "safety.html documents the legacy cleanup flag" \
  || ko "safety.html documents the legacy cleanup flag"

grep -qF -- '--purge' "$SITE_SAFETY" \
  && ok "safety.html documents --purge" \
  || ko "safety.html documents --purge"

grep -qF 'learner-uninstall' "$SITE_SAFETY" \
  && ok "safety.html's Uninstall section covers the brew/apt path" \
  || ko "safety.html's Uninstall section covers the brew/apt path"

grep -qF 'apt remove learner' "$SITE_SAFETY" \
  && ok "safety.html's Uninstall section names apt remove specifically" \
  || ko "safety.html's Uninstall section names apt remove specifically"

# Letter levels, as real table cells rather than prose. The markup shape is fixed by
# the plan (`<td><code>D</code></td>`) so this can be a fixed-string match — a bracket
# expression trying to allow several shapes is how the `\`` ERE bug got in last time.
for l in D J C S E; do
  grep -qF "<td><code>$l</code></td>" "$SITE_CONFIG" \
    && ok "config.html documents level $l as a table cell" \
    || ko "config.html documents level $l as a table cell"
done

for p in WSL 'Git Bash'; do
  grep -qF "$p" "$SITE_INSTALL" \
    && ok "install.html covers $p" \
    || ko "install.html covers $p"
done

grep -qiE 'native windows|windows, native' "$SITE_INSTALL" \
  && ok "install.html states native Windows is unsupported" \
  || ko "install.html states native Windows is unsupported"

grep -qiF 'posix' "$SITE_INSTALL" \
  && ok "install.html gives the reason native Windows cannot work" \
  || ko "install.html gives the reason native Windows cannot work"

# The three checks above are satisfied by prose alone (the Requirements list
# also says "POSIX", independent of the table), so deleting the platform table
# itself would not turn them red. Row-shaped patterns pin the table
# specifically — the same reasoning that used to pin the README's markdown
# table, now pinning the site's HTML one instead.
grep -qF '<tr><td>Windows via WSL</td><td>yes</td>' "$SITE_INSTALL" \
  && ok "the platform table has a WSL row" \
  || ko "the platform table has a WSL row"

grep -qF '<tr><td>Windows, native</td><td>no</td>' "$SITE_INSTALL" \
  && ok "the platform table has a native-Windows row" \
  || ko "the platform table has a native-Windows row"

grep -qiE '<tr><td>Windows, native</td><td>no</td><td>[^<]*posix' "$SITE_INSTALL" \
  && ok "the native-Windows row itself states the POSIX reason" \
  || ko "the native-Windows row itself states the POSIX reason"

grep -qF 'do not exist yet' "$SITE_INSTALL" \
  && ko "install.html no longer claims Homebrew/apt packages don't exist" \
  || ok "install.html no longer claims Homebrew/apt packages don't exist"

grep -qF 'brew install learner' "$SITE_INSTALL" \
  && ok "install.html documents the Homebrew install path" \
  || ko "install.html documents the Homebrew install path"

grep -qF 'sudo apt install ./learner_' "$SITE_INSTALL" \
  && ok "install.html documents the apt/.deb install path" \
  || ko "install.html documents the apt/.deb install path"

grep -qF 'INSTALL_ORIGIN' "$SITE_INSTALL" \
  && ok "install.html's file table documents INSTALL_ORIGIN" \
  || ko "install.html's file table documents INSTALL_ORIGIN"

grep -qF 'LEARNER-TODO' "$SITE_SAFETY" \
  && ok "safety.html shows the fill markers" \
  || ko "safety.html shows the fill markers"

# Case-SENSITIVE, and a phrase rather than the bare word: `grep -i HEAD` would match
# the page's own <head> tag and pass without the guardrail being explained at all.
grep -qF 'working tree' "$SITE_SAFETY" && grep -qF 'HEAD' "$SITE_SAFETY" \
  && ok "safety.html explains the guardrail counts leftovers only" \
  || ko "safety.html explains the guardrail counts leftovers only"

for p in $PAGES; do
  grep -qE 'recapEvery|trouBlanks|(^|[^A-Za-z])trackGlobs|"language"|intermediaire' "$(page_path "$p")" \
    && ko "$p.html mentions no removed key or old level" \
    || ok "$p.html mentions no removed key or old level"
done

# --- licence ----------------------------------------------------------------
# The licence name lives in four places — LICENSE, the README badge, the README
# footer and the site footer — so it is exactly the shape that drifts. Anchoring
# matters here: the README badge URL contains "GPLv3", so a bare `grep GPL`
# would pass on the badge alone even with the prose still saying MIT. That is
# how the old "README gives the reason native Windows cannot work" check went
# green off a shields.io URL.
LIC="$ROOT/LICENSE"

{ grep -qF 'GNU GENERAL PUBLIC LICENSE' "$LIC" \
  && grep -qF 'Version 3, 29 June 2007' "$LIC"; } \
  && ok "LICENSE carries the GPL-3.0 text" \
  || ko "LICENSE carries the GPL-3.0 text"

grep -qF 'Copyright (C) 2026 Tykok' "$LIC" \
  && ok "LICENSE carries the copyright line the GPL appendix asks for" \
  || ko "LICENSE carries the copyright line the GPL appendix asks for"

grep -qE '^[[]GPL-3[.]0-or-later[]][(][.]/LICENSE[)]' "$RM" \
  && ok "the README footer names the licence, not just the badge" \
  || ko "the README footer names the licence, not just the badge"

grep -qF 'License-GPLv3' "$RM" \
  && ok "the README badge shows GPLv3" \
  || ko "the README badge shows GPLv3"

# Footer text, so it holds on every page or on none.
for p in $PAGES; do
  f=$(page_path "$p")
  grep -qF '>GPL-3.0-or-later</a>' "$f" \
    && ok "$p.html's footer links the licence by name" \
    || ko "$p.html's footer links the licence by name"
  grep -qiF 'copyleft' "$f" \
    && ok "$p.html states the licence is copyleft" \
    || ko "$p.html states the licence is copyleft"
done

# Copyleft is the point of the change, so say so where a reader will look.
grep -qiF 'copyleft' "$RM" \
  && ok "README.md states the licence is copyleft" \
  || ko "README.md states the licence is copyleft"

# `[^A-Z]` guards the substring: LIMITED, SUBMIT and TRANSMIT all contain those
# three letters.
#
# The scanned set is what ships or is read by a user: the README, the site, and
# every script that ships or a user runs. test.sh is deliberately NOT
# in it — this file names the old licence in the pattern and in its own pass/fail
# messages, so scanning itself could never pass, and it is neither shipped nor
# documentation. design/ is excluded too: those plans record what was decided at
# the time, and rewriting them would falsify the record.
LIC_SCAN="README.md docs/ hooks/learner-config.sh hooks/learner-onboard.sh
hooks/learner-record-edit.sh hooks/learner-quiz.sh hooks/learner-cleanup.sh
hooks/learner-update-check.sh install.sh uninstall.sh bootstrap.sh
Formula/learner.rb scripts/bump-formula.sh packaging/deb/build.sh
packaging/apt-repo/assemble-site.sh"
# shellcheck disable=SC2086  # word splitting is how the path list is passed
if git -C "$ROOT" grep -qE '(^|[^A-Z])MIT([^A-Z]|$)' -- $LIC_SCAN; then
  ko "no shipped or user-facing file still claims MIT"
else
  ok "no shipped or user-facing file still claims MIT"
fi

# install.sh copies the hooks into the user's config directory, so they leave
# this repository and land somewhere with no LICENSE beside them. A one-line
# SPDX tag is what tells a reader over there what they are holding.
for f in hooks/learner-config.sh hooks/learner-onboard.sh hooks/learner-record-edit.sh \
         hooks/learner-quiz.sh hooks/learner-cleanup.sh hooks/learner-update-check.sh \
         install.sh uninstall.sh bootstrap.sh test.sh Formula/learner.rb \
         scripts/bump-formula.sh packaging/deb/build.sh packaging/apt-repo/assemble-site.sh; do
  grep -qF 'SPDX-License-Identifier: GPL-3.0-or-later' "$ROOT/$f" \
    && ok "$f carries an SPDX licence tag" \
    || ko "$f carries an SPDX licence tag"
done

# --- Homebrew formula --------------------------------------------------------
FORMULA="$ROOT/Formula/learner.rb"

[ -f "$FORMULA" ] && ok "Formula/learner.rb exists" || ko "Formula/learner.rb exists"

grep -qF 'depends_on "jq"' "$FORMULA" \
  && ok "the formula depends on jq" \
  || ko "the formula depends on jq"

grep -qF '"#{pkgshare}/install.sh" --origin brew' "$FORMULA" \
  && ok "the formula's learner-install wrapper passes --origin brew" \
  || ko "the formula's learner-install wrapper passes --origin brew"

grep -qE 'sha256 "[0-9a-f]{64}"' "$FORMULA" \
  && ok "the formula's sha256 is a real 64-hex-char digest, not a placeholder" \
  || ko "the formula's sha256 is a real 64-hex-char digest, not a placeholder"

[ -x "$ROOT/scripts/bump-formula.sh" ] \
  && ok "scripts/bump-formula.sh is executable" \
  || ko "scripts/bump-formula.sh is executable"

# --- Debian package -----------------------------------------------------------
DEBBUILD="$ROOT/packaging/deb/build.sh"

[ -f "$DEBBUILD" ] && ok "packaging/deb/build.sh exists" || ko "packaging/deb/build.sh exists"

if command -v dpkg-deb >/dev/null 2>&1; then
  DEBWORK="$(mktemp -d)"
  ( cd "$DEBWORK" && bash "$DEBBUILD" ) >/dev/null 2>&1
  DEBFILE="$DEBWORK/learner_$(cat "$ROOT/VERSION")_all.deb"
  [ -f "$DEBFILE" ] \
    && ok "build.sh produces learner_<VERSION>_all.deb" \
    || ko "build.sh produces learner_<VERSION>_all.deb"
  dpkg-deb -I "$DEBFILE" 2>/dev/null | grep -qF 'Depends: bash, jq' \
    && ok "the .deb declares bash and jq as Depends" \
    || ko "the .deb declares bash and jq as Depends"

  dpkg-deb -x "$DEBFILE" "$DEBWORK/extracted" 2>/dev/null

  for p in usr/share/learner/hooks usr/share/learner/skills \
           usr/share/learner/install.sh usr/share/learner/uninstall.sh \
           usr/share/learner/VERSION usr/share/learner/LICENSE \
           usr/bin/learner-install usr/bin/learner-uninstall; do
    [ -e "$DEBWORK/extracted/$p" ] \
      && ok "the .deb's payload contains $p" \
      || ko "the .deb's payload contains $p"
  done

  grep -qF -- '--origin apt' "$DEBWORK/extracted/usr/bin/learner-install" \
    && ok "learner-install passes --origin apt" \
    || ko "learner-install passes --origin apt"

  grep -qF 'exec /usr/share/learner/uninstall.sh' "$DEBWORK/extracted/usr/bin/learner-uninstall" \
    && ok "learner-uninstall execs uninstall.sh" \
    || ko "learner-uninstall execs uninstall.sh"

  rm -rf "$DEBWORK"
else
  skip "packaging/deb/build.sh smoke test (dpkg-deb not on PATH)"
fi

# --- apt repo assembler --------------------------------------------------------
ASSEMBLE="$ROOT/packaging/apt-repo/assemble-site.sh"

[ -f "$ASSEMBLE" ] && ok "packaging/apt-repo/assemble-site.sh exists" || ko "packaging/apt-repo/assemble-site.sh exists"

grep -qE "gh release download --pattern 'learner_\\*_all\\.deb' --dir \"\\\$TMPDL\"[[:space:]]*2>/dev/null" "$ASSEMBLE" \
  && ok "assemble-site.sh's gh release download has no trailing literal tag argument" \
  || ko "assemble-site.sh's gh release download has no trailing literal tag argument"

# A throwaway signing key, generated fresh for this test run only — never the
# real APT_SIGNING_KEY secret, which this file never has access to.
TESTGNUPGHOME="$(mktemp -d)"
chmod 700 "$TESTGNUPGHOME"
GNUPGHOME="$TESTGNUPGHOME" gpg --batch --gen-key <<'EOF' >/dev/null 2>&1
%no-protection
Key-Type: RSA
Key-Length: 2048
Key-Usage: sign
Name-Real: test key
Name-Email: test@example.invalid
Expire-Date: 0
EOF
TESTKEYID=$(GNUPGHOME="$TESTGNUPGHOME" gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5; exit}')
TESTSIGNINGKEY=$(GNUPGHOME="$TESTGNUPGHOME" gpg --armor --export-secret-keys "$TESTKEYID")

if command -v dpkg-scanpackages >/dev/null 2>&1 && command -v apt-ftparchive >/dev/null 2>&1; then
  ASMOUT="$(mktemp -d)"

  # No APT_DEB_SOURCE, and APT_SKIP_RELEASE_FETCH=1 tells the script to treat
  # this as "no release found" without ever invoking `gh` — keeps this test
  # fully off the network (the same offline-fixture pattern bootstrap.sh's
  # and the update-check hook's tests already use), rather than relying on a
  # `gh` call against a nonexistent repo that merely fails fast and harmlessly.
  # Must still assemble the hand-written site and must not fail the whole
  # build over a missing package.
  ( APT_SIGNING_KEY="$TESTSIGNINGKEY" APT_SKIP_RELEASE_FETCH=1 \
    bash "$ASSEMBLE" "$ASMOUT/no-release" )
  rc=$?
  { [ "$rc" = 0 ] && [ -f "$ASMOUT/no-release/index.html" ] && [ ! -d "$ASMOUT/no-release/apt" ]; } \
    && ok "assemble-site.sh ships the site with no apt/ tree when no release is available" \
    || ko "assemble-site.sh ships the site with no apt/ tree when no release is available (rc=$rc)"

  # A fixture .deb via APT_DEB_SOURCE, mirroring how test.sh keeps every other
  # network-touching script (bootstrap.sh, the update-check hook) offline.
  FIXDEB="$(mktemp -d)/learner_9.9.9_all.deb"
  FIXROOT="$(mktemp -d)"
  mkdir -p "$FIXROOT/DEBIAN"
  printf 'Package: learner\nVersion: 9.9.9\nArchitecture: all\nMaintainer: test\nDescription: test fixture\n' \
    > "$FIXROOT/DEBIAN/control"
  dpkg-deb --build --root-owner-group "$FIXROOT" "$FIXDEB" >/dev/null 2>&1

  APT_SIGNING_KEY="$TESTSIGNINGKEY" APT_DEB_SOURCE="$FIXDEB" bash "$ASSEMBLE" "$ASMOUT/with-release"
  rc=$?
  { [ "$rc" = 0 ] \
    && [ -f "$ASMOUT/with-release/index.html" ] \
    && [ -f "$ASMOUT/with-release/apt/pool/main/l/learner/learner_9.9.9_all.deb" ] \
    && [ -f "$ASMOUT/with-release/apt/dists/stable/main/binary-all/Packages" ] \
    && [ -f "$ASMOUT/with-release/apt/dists/stable/InRelease" ] \
    && [ -f "$ASMOUT/with-release/apt/learner.gpg" ]; } \
    && ok "assemble-site.sh builds the full apt tree from a fixture .deb" \
    || ko "assemble-site.sh builds the full apt tree from a fixture .deb (rc=$rc)"

  grep -qF 'learner_9.9.9_all.deb' "$ASMOUT/with-release/apt/dists/stable/main/binary-all/Packages" \
    && ok "the generated Packages file names the fixture package" \
    || ko "the generated Packages file names the fixture package"

  GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; chmod 700 "$GNUPGHOME"
  gpg --batch --import <(printf '%s' "$TESTSIGNINGKEY") >/dev/null 2>&1
  gpg --verify "$ASMOUT/with-release/apt/dists/stable/InRelease" >/dev/null 2>&1 \
    && ok "InRelease's signature verifies against the exported public key" \
    || ko "InRelease's signature verifies against the exported public key"
  unset GNUPGHOME

  # The private key text must never appear in what got written to disk.
  if grep -rqF "$TESTSIGNINGKEY" "$ASMOUT" 2>/dev/null; then
    ko "the private signing key never leaks into the assembled output"
  else
    ok "the private signing key never leaks into the assembled output"
  fi
else
  skip "packaging/apt-repo/assemble-site.sh tests (dpkg-scanpackages/apt-ftparchive not on PATH)"
fi
rm -rf "$TESTGNUPGHOME"

# --- Claude Code plugin ------------------------------------------------------
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$ROOT/.claude-plugin/marketplace.json"
PLUGIN_HOOKS="$ROOT/hooks/hooks.json"

[ -f "$PLUGIN_JSON" ] && ok ".claude-plugin/plugin.json exists" || ko ".claude-plugin/plugin.json exists"
[ -f "$MARKETPLACE_JSON" ] && ok ".claude-plugin/marketplace.json exists" || ko ".claude-plugin/marketplace.json exists"
[ -f "$PLUGIN_HOOKS" ] && ok "hooks/hooks.json exists" || ko "hooks/hooks.json exists"

jq -e . "$PLUGIN_JSON" >/dev/null 2>&1 \
  && ok "plugin.json is valid JSON" \
  || ko "plugin.json is valid JSON"

jq -e . "$MARKETPLACE_JSON" >/dev/null 2>&1 \
  && ok "marketplace.json is valid JSON" \
  || ko "marketplace.json is valid JSON"

jq -e . "$PLUGIN_HOOKS" >/dev/null 2>&1 \
  && ok "hooks/hooks.json is valid JSON" \
  || ko "hooks/hooks.json is valid JSON"

[ "$(jq -r '.name' "$PLUGIN_JSON")" = "learner" ] \
  && ok "plugin.json names the plugin learner" \
  || ko "plugin.json names the plugin learner"

[ "$(jq -r '.plugins[0].name' "$MARKETPLACE_JSON")" = "learner" ] \
  && [ "$(jq -r '.plugins[0].source' "$MARKETPLACE_JSON")" = "./" ] \
  && ok "marketplace.json lists learner with source ./" \
  || ko "marketplace.json lists learner with source ./"

for h in SessionStart PostToolUse Stop SessionEnd; do
  jq -e --arg h "$h" '.hooks[$h]' "$PLUGIN_HOOKS" >/dev/null 2>&1 \
    && ok "hooks/hooks.json wires $h" \
    || ko "hooks/hooks.json wires $h"
done

for script in learner-onboard.sh learner-record-edit.sh learner-quiz.sh learner-cleanup.sh; do
  grep -qF "$script" "$PLUGIN_HOOKS" \
    && ok "hooks/hooks.json references $script" \
    || ko "hooks/hooks.json references $script"
done

grep -qF 'CLAUDE_PLUGIN_ROOT' "$PLUGIN_HOOKS" \
  && ok "hooks/hooks.json commands use \${CLAUDE_PLUGIN_ROOT}" \
  || ko "hooks/hooks.json commands use \${CLAUDE_PLUGIN_ROOT}"

{ [ "$(jq '[.hooks[][].hooks[]] | length' "$PLUGIN_HOOKS")" = "4" ] \
  && [ "$(jq '[.hooks[][].hooks[].command | select(contains("CLAUDE_PLUGIN_ROOT"))] | length' "$PLUGIN_HOOKS")" = "4" ]; } \
  && ok "hooks/hooks.json wires exactly 4 commands, every one via \${CLAUDE_PLUGIN_ROOT}" \
  || ko "hooks/hooks.json wires exactly 4 commands, every one via \${CLAUDE_PLUGIN_ROOT}"

grep -qF 'learner-update-check.sh' "$PLUGIN_HOOKS" \
  && ko "hooks/hooks.json does not wire learner-update-check.sh" \
  || ok "hooks/hooks.json does not wire learner-update-check.sh"

[ "$(jq -r '.version' "$PLUGIN_JSON")" = "$(cat "$ROOT/VERSION")" ] \
  && ok "plugin.json's version matches the VERSION file" \
  || ko "plugin.json's version matches the VERSION file"

# --- summary ----------------------------------------------------------------
echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
