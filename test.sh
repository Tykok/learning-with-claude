#!/usr/bin/env bash
# Tests for the learning-mode hooks + installer.
# Plain sh/bash, no framework. Requires: jq, git. Run: ./test.sh
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
REC="$ROOT/hooks/learner-record-edit.sh"
QUIZ="$ROOT/hooks/learner-quiz.sh"
ONB="$ROOT/hooks/learner-onboard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
ko()  { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

command -v jq  >/dev/null 2>&1 || { echo "jq required"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

# Isolated project dir + tmp so session state can't collide with a real session.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.claude" "$WORK/tmp"
export CLAUDE_PROJECT_DIR="$WORK"
export TMPDIR="$WORK/tmp"
CFG="$WORK/.claude/learner.local.json"
edits() { echo "$TMPDIR/claude-learner-$1.edits"; }

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
SID=rec1
printf '{"session_id":"%s","tool_input":{"file_path":"%s/src/Foo.kt"}}' "$SID" "$WORK" | sh "$REC"
grep -q 'Foo.kt' "$(edits "$SID")" 2>/dev/null \
  && ok "records a tracked source file (.kt)" \
  || ko "records a tracked source file (.kt)"

printf '{"session_id":"%s","tool_input":{"file_path":"%s/build/Gen.kt"}}' "$SID" "$WORK" | sh "$REC"
grep -q 'build/Gen.kt' "$(edits "$SID")" 2>/dev/null \
  && ko "ignores files under build/" \
  || ok "ignores files under build/"

printf '{"session_id":"%s","tool_input":{"file_path":"%s/notes.txt"}}' "$SID" "$WORK" | sh "$REC"
grep -q 'notes.txt' "$(edits "$SID")" 2>/dev/null \
  && ko "ignores untracked extension (.txt)" \
  || ok "ignores untracked extension (.txt)"

# opt-out: no config file => record-edit is a no-op
mv "$CFG" "$CFG.bak"
SID2=rec2
printf '{"session_id":"%s","tool_input":{"file_path":"%s/src/Bar.kt"}}' "$SID2" "$WORK" | sh "$REC"
[ -s "$(edits "$SID2")" ] \
  && ko "no-op when learning mode is not configured" \
  || ok "no-op when learning mode is not configured"
mv "$CFG.bak" "$CFG"

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
{ [ "$n1" = 3 ] && [ "$n2" = 3 ]; } \
  && ok "install merge is idempotent (3 learner hooks)" \
  || ko "install merge is idempotent (got $n1 then $n2, want 3/3)"
rm -rf "$R"

# --- summary ----------------------------------------------------------------
echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
