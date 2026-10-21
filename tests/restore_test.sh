#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/agentic-dev-restore.XXXXXX")
trap 'rm -rf -- "$SANDBOX"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

TEST_HOME="$SANDBOX/home"
BACKUP_ROOT="$TEST_HOME/.config/agentic-dev-setup/backups"
EXTERNAL="$SANDBOX/external"
mkdir -p "$BACKUP_ROOT/valid" "$EXTERNAL"
touch "$BACKUP_ROOT/valid/COMPLETE"
printf 'canonical|absent|%s|canonical.AGENTS.md\n' \
  "$TEST_HOME/.config/agentic-dev-setup/AGENTS.md" >"$EXTERNAL/manifest"

if env HOME="$TEST_HOME" bash "$ROOT/scripts/restore.sh" "$EXTERNAL" >"$SANDBOX/external.out" 2>&1; then
  fail 'restore accepted a transaction outside its backup root'
fi

printf 'canonical|absent|%s|canonical.AGENTS.md\n' \
  "$TEST_HOME/unmanaged.txt" >"$BACKUP_ROOT/valid/manifest"
printf 'preserve\n' >"$TEST_HOME/unmanaged.txt"
if env HOME="$TEST_HOME" bash "$ROOT/scripts/restore.sh" valid >"$SANDBOX/tampered.out" 2>&1; then
  fail 'restore accepted a manifest target outside the managed file set'
fi
[[ $(<"$TEST_HOME/unmanaged.txt") == preserve ]] || fail 'tampered restore changed an unmanaged file'

mkdir -p "$BACKUP_ROOT/all-or-nothing"
touch "$BACKUP_ROOT/all-or-nothing/COMPLETE"
printf 'preserve canonical\n' >"$TEST_HOME/.config/agentic-dev-setup/AGENTS.md"
{
  printf 'canonical|absent|%s|canonical.AGENTS.md\n' "$TEST_HOME/.config/agentic-dev-setup/AGENTS.md"
  printf 'claude|absent|%s|wrong-name\n' "$TEST_HOME/.claude/CLAUDE.md"
} >"$BACKUP_ROOT/all-or-nothing/manifest"
if env HOME="$TEST_HOME" bash "$ROOT/scripts/restore.sh" all-or-nothing >"$SANDBOX/all-or-nothing.out" 2>&1; then
  fail 'restore accepted a manifest with a later invalid row'
fi
[[ $(<"$TEST_HOME/.config/agentic-dev-setup/AGENTS.md") == 'preserve canonical' ]] || \
  fail 'restore mutated a file before validating the complete manifest'

mkdir -p "$BACKUP_ROOT/incomplete"
printf 'canonical|absent|%s|canonical.AGENTS.md\n' \
  "$TEST_HOME/.config/agentic-dev-setup/AGENTS.md" >"$BACKUP_ROOT/incomplete/manifest"
if env HOME="$TEST_HOME" bash "$ROOT/scripts/restore.sh" incomplete >"$SANDBOX/incomplete.out" 2>&1; then
  fail 'restore accepted an incomplete transaction'
fi

printf 'PASS: restore rejects external and tampered transactions\n'
