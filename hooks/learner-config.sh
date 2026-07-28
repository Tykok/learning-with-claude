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
      # shellcheck disable=SC2088 # matching a literal "~/" prefix in a case pattern, not tilde expansion
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
