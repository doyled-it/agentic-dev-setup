#!/usr/bin/env bash

set -euo pipefail

BACKUP_ROOT="$HOME/.config/agentic-dev-setup/backups"
SELECTION=${1:-latest}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

latest_transaction() {
  local candidate
  local latest=''
  [[ -d $BACKUP_ROOT ]] || return 1
  for candidate in "$BACKUP_ROOT"/*; do
    [[ -d $candidate ]] || continue
    if [[ -z $latest || $(basename "$candidate") > $(basename "$latest") ]]; then
      latest=$candidate
    fi
  done
  [[ -n $latest ]] || return 1
  printf '%s\n' "$latest"
}

if [[ $SELECTION == latest ]]; then
  TRANSACTION=$(latest_transaction) || die 'no backup transactions found'
elif [[ -d $SELECTION ]]; then
  TRANSACTION=$(cd "$SELECTION" && pwd)
elif [[ -d $BACKUP_ROOT/$SELECTION ]]; then
  TRANSACTION=$(cd "$BACKUP_ROOT/$SELECTION" && pwd)
else
  die "backup transaction not found: $SELECTION"
fi

MANIFEST="$TRANSACTION/manifest"
[[ -f $MANIFEST ]] || die "backup manifest not found: $MANIFEST"

while IFS='|' read -r key state target backup_name; do
  [[ -n $key && -n $state && -n $target && -n $backup_name ]] || die 'malformed backup manifest'
  case "$state" in
    present)
      [[ -f $TRANSACTION/$backup_name ]] || die "backup file missing for $key"
      mkdir -p -- "$(dirname "$target")"
      cp -p -- "$TRANSACTION/$backup_name" "$target"
      ;;
    absent)
      rm -f -- "$target"
      ;;
    *)
      die "unknown backup state for $key: $state"
      ;;
  esac
done <"$MANIFEST"

printf 'Restored instruction state from %s\n' "$TRANSACTION"
