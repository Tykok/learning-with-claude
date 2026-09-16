#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# learner sync — carry the learning record between machines through a private gist.
#
# Mechanical half of the feature (see design/superpowers/specs/2026-09-16-sync-design.md):
# every `gh` call, the snapshot, the backup, the memory.md three-way merge and the
# Session history union live here. The theme merge lives in the skill, because it
# needs judgement this script must not fake.
#
# Prints exactly one compact JSON object on stdout. skills/learner/references/sync.md
# turns it into a sentence in the dev's language; nothing here is user-facing prose.
#
#   sh learner-sync.sh push [--create-ok]
#   sh learner-sync.sh pull [<gist-id-or-url>]
#   sh learner-sync.sh pull-finish <work-dir>
#   sh learner-sync.sh status
#   sh learner-sync.sh use <gist-id-or-url>
#   sh learner-sync.sh merge-memory  <base> <local> <remote>
#   sh learner-sync.sh merge-history <local> <remote>

# shellcheck source=hooks/learner-config.sh
. "$(dirname "$0")/learner-config.sh"

# shellcheck disable=SC2034
SYNC_SCHEMA=1
# shellcheck disable=SC2034
SYNC_DESC="claude-learner-state"

DATA_DIR="$LEARNER_CFG_DIR/learner"
# shellcheck disable=SC2034
MEM_FILE="$DATA_DIR/memory.md"
# shellcheck disable=SC2034
REC_FILE="$DATA_DIR/recap.md"
# shellcheck disable=SC2034
CFG_FILE="$LEARNER_CFG_DIR/learner.json"
# shellcheck disable=SC2034
SYNC_JSON="$DATA_DIR/sync.json"
# shellcheck disable=SC2034
BASE_DIR="$DATA_DIR/sync-base"
# shellcheck disable=SC2034
BACKUP_DIR="$DATA_DIR/backups"

# Every failure leaves stdout with one machine-readable object and nothing else.
fail() { printf '{"ok":false,"error":"%s"}\n' "$1"; exit 1; }

usage() { printf '{"ok":false,"error":"usage"}\n'; exit 2; }

need_jq() { command -v jq >/dev/null 2>&1 || fail jq-missing; }

need_gh() {
  command -v gh >/dev/null 2>&1 || fail gh-missing
  gh auth status >/dev/null 2>&1 || fail gh-unauthenticated
}

# True when the file exists and holds something other than whitespace. An empty
# memory.md is a real state (a dev who has mastered everything open), so "exists"
# alone would push a snapshot of nothing over a good remote one.
has_content() { [ -f "$1" ] && grep -q '[^[:space:]]' "$1"; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cmd=${1:-}
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  push|pull|pull-finish|status|use|merge-memory|merge-history) ;;
  *) usage ;;
esac

need_jq

case "$cmd" in
  merge-memory|merge-history) ;;   # pure text, no network
  *) need_gh ;;
esac

# Subcommand bodies are added by later tasks.
fail not-implemented
