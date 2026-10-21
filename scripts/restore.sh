#!/usr/bin/env bash

set -euo pipefail
umask 077

CONFIG_ROOT="$HOME/.config/agentic-dev-setup"
BACKUP_ROOT="$CONFIG_ROOT/backups"
SELECTION=${1:-latest}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agentic-dev-restore.XXXXXX")

cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

latest_transaction() {
  local candidate
  local latest=''
  [[ -d $BACKUP_ROOT && ! -L $BACKUP_ROOT ]] || return 1
  for candidate in "$BACKUP_ROOT"/*; do
    [[ -d $candidate && ! -L $candidate && -f $candidate/COMPLETE && ! -L $candidate/COMPLETE ]] || continue
    if [[ -z $latest || $(basename "$candidate") > $(basename "$latest") ]]; then
      latest=$candidate
    fi
  done
  [[ -n $latest ]] || return 1
  printf '%s\n' "$latest"
}

select_transaction() {
  local candidate
  if [[ $SELECTION == latest ]]; then
    latest_transaction || die 'no complete backup transactions found'
    return
  fi
  [[ $SELECTION =~ ^[[:alnum:]_-][[:alnum:]_.-]*$ ]] || die 'backup selection must be a transaction name'
  candidate="$BACKUP_ROOT/$SELECTION"
  [[ -d $candidate && ! -L $candidate ]] || die "backup transaction not found: $SELECTION"
  [[ -f $candidate/COMPLETE && ! -L $candidate/COMPLETE ]] || die "backup transaction is incomplete: $SELECTION"
  printf '%s\n' "$candidate"
}

validate_entry() {
  local key=$1
  local state=$2
  local target=$3
  local backup_name=$4
  local expected_target
  local expected_backup
  local seen

  case "$key" in
    canonical)
      expected_target="$CONFIG_ROOT/AGENTS.md"
      expected_backup='canonical.AGENTS.md'
      seen=$CANONICAL_SEEN
      CANONICAL_SEEN=true
      CANONICAL_STATE=$state
      CANONICAL_TARGET=$target
      ;;
    claude)
      expected_target="$HOME/.claude/CLAUDE.md"
      expected_backup='claude.CLAUDE.md'
      seen=$CLAUDE_SEEN
      CLAUDE_SEEN=true
      CLAUDE_STATE=$state
      CLAUDE_TARGET=$target
      ;;
    codex)
      expected_target="$HOME/.codex/AGENTS.md"
      expected_backup='codex.AGENTS.md'
      seen=$CODEX_SEEN
      CODEX_SEEN=true
      CODEX_STATE=$state
      CODEX_TARGET=$target
      ;;
    *)
      die "unknown backup key: $key"
      ;;
  esac

  [[ $seen == false ]] || die "duplicate backup key: $key"
  [[ $target == "$expected_target" ]] || die "unexpected restore target for $key"
  [[ $backup_name == "$expected_backup" ]] || die "unexpected backup filename for $key"
  [[ $state == present || $state == absent ]] || die "unknown backup state for $key: $state"
  [[ ! -L $target ]] || die "restore target must not be a symlink: $target"
  if [[ -e $target ]]; then
    [[ -f $target ]] || die "restore target must be a regular file: $target"
  fi
  if [[ $state == present ]]; then
    [[ -f $TRANSACTION/$backup_name && ! -L $TRANSACTION/$backup_name ]] || die "backup file missing for $key"
    cp -p -- "$TRANSACTION/$backup_name" "$WORK_DIR/$backup_name"
  fi
}

restore_entry() {
  local seen=$1
  local state=$2
  local target=$3
  local backup_name=$4
  local staged

  [[ $seen == true ]] || return
  [[ ! -L $target ]] || die "restore target became a symlink: $target"
  if [[ $state == present ]]; then
    mkdir -p -- "$(dirname "$target")"
    staged="$(dirname "$target")/.agentic-dev-restore.$$"
    cp -p -- "$WORK_DIR/$backup_name" "$staged"
    mv -f -- "$staged" "$target"
  else
    rm -f -- "$target"
  fi
}

TRANSACTION=$(select_transaction)
MANIFEST="$TRANSACTION/manifest"
[[ -f $MANIFEST && ! -L $MANIFEST ]] || die "backup manifest not found: $MANIFEST"

CANONICAL_SEEN=false
CLAUDE_SEEN=false
CODEX_SEEN=false
CANONICAL_STATE=''
CLAUDE_STATE=''
CODEX_STATE=''
CANONICAL_TARGET=''
CLAUDE_TARGET=''
CODEX_TARGET=''
ENTRY_COUNT=0

while IFS='|' read -r key state target backup_name extra; do
  [[ -n $key && -n $state && -n $target && -n $backup_name && -z $extra ]] || die 'malformed backup manifest'
  validate_entry "$key" "$state" "$target" "$backup_name"
  ENTRY_COUNT=$((ENTRY_COUNT + 1))
done <"$MANIFEST"

((ENTRY_COUNT > 0)) || die 'backup manifest is empty'

restore_entry "$CANONICAL_SEEN" "$CANONICAL_STATE" "$CANONICAL_TARGET" canonical.AGENTS.md
restore_entry "$CLAUDE_SEEN" "$CLAUDE_STATE" "$CLAUDE_TARGET" claude.CLAUDE.md
restore_entry "$CODEX_SEEN" "$CODEX_STATE" "$CODEX_TARGET" codex.AGENTS.md

printf 'Restored instruction state from %s\n' "$TRANSACTION"
