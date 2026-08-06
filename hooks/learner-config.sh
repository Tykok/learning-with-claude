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
