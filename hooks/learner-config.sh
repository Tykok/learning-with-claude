#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared config resolution for the learner hooks. SOURCED, never executed.
#
# Exposes:
#   LEARNER_CFG_DIR                 resolved Claude config dir
#   learner_config                  merged config as one-line JSON
#   learner_level RAW               canonical level letter, empty when invalid
#   learner_level_name LETTER       human name for a level letter
#   learner_synthesis_n WORD        questions between synthesis questions (0 = off)
#   learner_excluded PATH CFG       true when PATH is never quiz/coach material
#   learner_version_valid V         true if V is "X.Y.Z" with X/Y/Z decimal integers
#   learner_version_gt A B          true if A > B (both must satisfy learner_version_valid)
#   learner_repo_root               git toplevel of the project dir, empty if none
#   learner_path_disabled ROOT CFG  true when ROOT sits under a disabledPaths entry
#   learner_active CFG ROOT         true when the automatic quiz should run here
#   learner_coach_active CFG ROOT   true when the coach regime is on here
#   learner_coach_work_minutes N CFG  length in minutes of work block N (1-based)

LEARNER_CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

LEARNER_DEFAULTS='{"enabled":true,"questionStyles":"auto","synthesisFrequency":"normal","blanksPerExercise":2,"untrackGlobs":[],"disabledPaths":[],"coach":false,"coachCadence":"pomodoro","coachWorkMinutes":25,"coachWorkGrowthMinutes":5,"coachWorkMaxMinutes":45,"coachChallengeMinutes":8,"coachIdleCycles":2,"coachPollSeconds":45,"coachLines":40,"coachFiles":3,"coachEveryMinutes":0,"coachCooldownMinutes":5}'

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
  command -v jq >/dev/null 2>&1 || return 1
  _lg=$(_learner_read_json "$LEARNER_CFG_DIR/learner.json")
  _lp=$(_learner_read_json "${CLAUDE_PROJECT_DIR:-.}/.claude/learner.local.json")
  jq -nc --argjson d "$LEARNER_DEFAULTS" --argjson g "$_lg" --argjson p "$_lp" \
    '$d * $g * $p' 2>/dev/null
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

# learner_excluded PATH CFG — true (0) when PATH must never become quiz or coach
# material. Two layers:
#
#   1. A built-in floor, deliberately NOT overridable through config: without it
#      every package-lock.json and generated file would become quiz material.
#   2. The user's `untrackGlobs` on top of that floor.
#
# PATH is absolute. Globs are whitespace-separated, so a glob containing a space
# is not supported (documented in README).
learner_excluded() {
  _lxp="$1"
  _lxcfg="$2"

  case "$_lxp" in
    */node_modules/*|*/build/*|*/dist/*|*/out/*|*/target/*|*/vendor/*) return 0 ;;
    */.git/*|*/.gradle/*|*/__pycache__/*|*/.venv/*|*/coverage/*|*/__snapshots__/*) return 0 ;;
  esac
  case "$_lxp" in
    *.lock|*-lock.*|*.min.*|*.generated.*|*.snap) return 0 ;;
  esac

  # `set -f` is a shell-wide option and this is a sourced function, so the
  # caller's globbing state has to be restored on every exit path — including
  # the match. A hook that silently disabled globbing for the rest of its own
  # run would be a very hard bug to find.
  case "$-" in *f*) _lxf=1 ;; *) _lxf=0 ;; esac
  _lxhit=1
  set -f
  # shellcheck disable=SC2046,SC2086  # intentional word splitting on the glob list
  for _lxo in $(printf '%s' "$_lxcfg" | jq -r '(.untrackGlobs // [])[]' 2>/dev/null); do
    [ -n "$_lxo" ] || continue
    # shellcheck disable=SC2254  # $_lxo is a glob pattern on purpose
    case "$_lxp" in $_lxo) _lxhit=0; break ;; esac
  done
  [ "$_lxf" = 1 ] || set +f
  return "$_lxhit"
}

# learner_version_valid V — true if V is "X.Y.Z" with X/Y/Z decimal integers.
learner_version_valid() {
  _lv0="${1:-}"
  case "$_lv0" in *.*.*) ;; *) return 1 ;; esac
  _lv1=${_lv0%%.*}; _lv_rest=${_lv0#*.}; _lv2=${_lv_rest%%.*}; _lv3=${_lv_rest#*.}
  case "$_lv1" in ''|*[!0-9]*) return 1 ;; esac
  case "$_lv2" in ''|*[!0-9]*) return 1 ;; esac
  case "$_lv3" in ''|*[!0-9]*) return 1 ;; esac
}

# learner_version_gt A B — true if A > B. Both must already satisfy
# learner_version_valid; callers validate first (hooks/learner-update-check.sh does).
learner_version_gt() {
  _la0="${1:-}"; _lb0="${2:-}"
  _la1=${_la0%%.*}; _la_rest=${_la0#*.}; _la2=${_la_rest%%.*}; _la3=${_la_rest#*.}
  _lb1=${_lb0%%.*}; _lb_rest=${_lb0#*.}; _lb2=${_lb_rest%%.*}; _lb3=${_lb_rest#*.}
  [ "$_la1" -gt "$_lb1" ] && return 0; [ "$_la1" -lt "$_lb1" ] && return 1
  [ "$_la2" -gt "$_lb2" ] && return 0; [ "$_la2" -lt "$_lb2" ] && return 1
  [ "$_la3" -gt "$_lb3" ]
}

learner_repo_root() {
  git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || printf ''
}

# Prefix match on path components, so /a/b disables /a/b/c but not /a/bee.
# ROOT is always a physical path (git rev-parse --show-toplevel), so entries are
# canonicalised before comparing: otherwise an entry reaching the repo through a
# symlink — /tmp and /var on macOS, a symlinked ~/work — silently fails to match,
# and silently failing to disable is the one outcome this switch must not have.
learner_path_disabled() {
  _lroot="$1"
  _lcfg="$2"
  printf '%s' "$_lcfg" | jq -r '(.disabledPaths // [])[]' 2>/dev/null | (
    while IFS= read -r _lp; do
      [ -n "$_lp" ] || continue
      # shellcheck disable=SC2088 # matching a literal "~/" prefix in a case pattern, not tilde expansion
      case "$_lp" in "~/"*) _lp="$HOME/${_lp#\~/}" ;; esac
      # Only a path that exists can be resolved; keep the raw string otherwise, so
      # an entry for a repo that is not checked out here still matches as a prefix.
      if [ -d "$_lp" ]; then
        _lppwd=$(cd "$_lp" 2>/dev/null && pwd -P) && [ -n "$_lppwd" ] && _lp="$_lppwd"
      fi
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

# learner_int RAW FALLBACK FLOOR — a positive integer from config, or FALLBACK
# when RAW is absent, empty, non-numeric or below FLOOR. Every cadence value goes
# through this: a malformed config must never yield an empty or zero sleep
# interval, which would spin the watcher at 100% CPU instead of waiting.
learner_int() {
  _lir="${1:-}"; _lif="$2"; _lil="${3:-1}"
  case "$_lir" in ''|null|*[!0-9]*) printf '%s' "$_lif"; return 0 ;; esac
  # Strip leading zeros: a value like "008" is digit-only and passes the guard
  # above, but /bin/sh's POSIX-mode arithmetic treats a leading-zero literal as
  # octal and aborts on an invalid digit, which would otherwise crash the
  # caller's arithmetic instead of just returning an integer. "0" and "00" stay
  # "0" rather than becoming empty.
  while [ ${#_lir} -gt 1 ] && [ "${_lir#0}" != "$_lir" ]; do _lir=${_lir#0}; done
  [ "$_lir" -lt "$_lil" ] && { printf '%s' "$_lif"; return 0; }
  printf '%s' "$_lir"
}

# The coach regime is the learner regime plus one switch: everything that
# silences the quiz (no level, enabled:false, disabledPaths) silences the coach
# too, so a dev who switched learner off in a repo does not get coached in it.
learner_coach_active() {
  _lcacfg="$1"
  _lcaroot="$2"
  learner_active "$_lcacfg" "$_lcaroot" || return 1
  [ "$(printf '%s' "$_lcacfg" | jq -r '.coach')" = "true" ] || return 1
  return 0
}

# learner_coach_work_minutes N CFG — the work block grows by
# coachWorkGrowthMinutes per completed cycle, capped at coachWorkMaxMinutes.
# A cap below the base is unambiguous in intent, so it clamps to the base rather
# than being rejected.
learner_coach_work_minutes() {
  _lcwn="${1:-1}"
  _lcwcfg="$2"
  case "$_lcwn" in ''|*[!0-9]*) _lcwn=1 ;; esac
  [ "$_lcwn" -lt 1 ] && _lcwn=1
  _lcwbase=$(learner_int "$(printf '%s' "$_lcwcfg" | jq -r '.coachWorkMinutes // empty')" 25 1)
  _lcwgrow=$(learner_int "$(printf '%s' "$_lcwcfg" | jq -r '.coachWorkGrowthMinutes // empty')" 5 0)
  _lcwmax=$(learner_int "$(printf '%s' "$_lcwcfg" | jq -r '.coachWorkMaxMinutes // empty')" 45 1)
  _lcwv=$((_lcwbase + _lcwgrow * (_lcwn - 1)))
  [ "$_lcwv" -gt "$_lcwmax" ] && _lcwv=$_lcwmax
  [ "$_lcwv" -lt "$_lcwbase" ] && _lcwv=$_lcwbase
  printf '%s' "$_lcwv"
}
