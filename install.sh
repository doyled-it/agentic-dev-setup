#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=dependencies.env
source "$ROOT/dependencies.env"

BEGIN_MARKER='<!-- BEGIN agentic-dev-setup -->'
END_MARKER='<!-- END agentic-dev-setup -->'
CONFIG_ROOT="$HOME/.config/agentic-dev-setup"
BACKUP_ROOT="$CONFIG_ROOT/backups"
CANONICAL_FILE="$CONFIG_ROOT/AGENTS.md"
CLAUDE_FILE="$HOME/.claude/CLAUDE.md"
CODEX_FILE="$HOME/.codex/AGENTS.md"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agentic-dev-setup.XXXXXX")
INSTRUCTIONS_CHANGED=false

cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

say() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

count_marker() {
  local marker=$1
  local file=$2
  local count

  if [[ ! -e $file ]]; then
    printf '0\n'
    return
  fi
  [[ -f $file && ! -L $file ]] || die "$file must be a regular file"
  count=$(grep -Fxc -- "$marker" "$file" || true)
  printf '%s\n' "$count"
}

render_managed_file() {
  local target=$1
  local block_file=$2
  local output=$3
  local begin_count
  local end_count

  begin_count=$(count_marker "$BEGIN_MARKER" "$target")
  end_count=$(count_marker "$END_MARKER" "$target")
  if [[ $begin_count != "$end_count" || $begin_count -gt 1 ]]; then
    die "$target contains malformed or duplicate agentic-dev-setup markers"
  fi

  if [[ $begin_count == 0 ]]; then
    if [[ -f $target ]]; then
      cat -- "$target" >"$output"
      if [[ -s $target ]]; then
        printf '\n' >>"$output"
      fi
    else
      : >"$output"
    fi
    cat -- "$block_file" >>"$output"
    return
  fi

  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v block="$block_file" '
    function emit_block(   line) {
      while ((getline line < block) > 0) print line
      close(block)
    }
    $0 == begin { emit_block(); skipping=1; next }
    $0 == end { skipping=0; next }
    !skipping { print }
  ' "$target" >"$output"
}

files_differ() {
  local source=$1
  local target=$2
  [[ ! -f $target ]] || ! cmp -s -- "$source" "$target"
}

prepare_instructions() {
  local claude_block="$WORK_DIR/claude.block"
  local codex_block="$WORK_DIR/codex.block"

  {
    printf '%s\n' "$BEGIN_MARKER"
    printf '@%s\n' "$CANONICAL_FILE"
    printf '%s\n' "$END_MARKER"
  } >"$claude_block"

  {
    printf '%s\n' "$BEGIN_MARKER"
    cat -- "$ROOT/AGENTS.md"
    printf '%s\n' "$END_MARKER"
  } >"$codex_block"

  cp -- "$ROOT/AGENTS.md" "$WORK_DIR/canonical.desired"
  render_managed_file "$CLAUDE_FILE" "$claude_block" "$WORK_DIR/claude.desired"
  render_managed_file "$CODEX_FILE" "$codex_block" "$WORK_DIR/codex.desired"

  if files_differ "$WORK_DIR/canonical.desired" "$CANONICAL_FILE" ||
    files_differ "$WORK_DIR/claude.desired" "$CLAUDE_FILE" ||
    files_differ "$WORK_DIR/codex.desired" "$CODEX_FILE"; then
    INSTRUCTIONS_CHANGED=true
  fi
}

backup_target() {
  local transaction=$1
  local key=$2
  local target=$3
  local backup_name=$4

  if [[ -e $target || -L $target ]]; then
    [[ -f $target && ! -L $target ]] || die "$target must be a regular file"
    cp -p -- "$target" "$transaction/$backup_name"
    printf '%s|present|%s|%s\n' "$key" "$target" "$backup_name" >>"$transaction/manifest"
  else
    printf '%s|absent|%s|%s\n' "$key" "$target" "$backup_name" >>"$transaction/manifest"
  fi
}

apply_instructions() {
  local transaction
  local stamp

  if [[ $INSTRUCTIONS_CHANGED != true ]]; then
    say 'Global instructions already current'
    return
  fi

  stamp=$(date -u '+%Y%m%dT%H%M%SZ')
  transaction="$BACKUP_ROOT/$stamp-$$"
  mkdir -p -- "$transaction"
  : >"$transaction/manifest"
  backup_target "$transaction" canonical "$CANONICAL_FILE" canonical.AGENTS.md
  backup_target "$transaction" claude "$CLAUDE_FILE" claude.CLAUDE.md
  backup_target "$transaction" codex "$CODEX_FILE" codex.AGENTS.md

  mkdir -p -- "$(dirname "$CANONICAL_FILE")" "$(dirname "$CLAUDE_FILE")" "$(dirname "$CODEX_FILE")"
  cp -- "$WORK_DIR/canonical.desired" "$CANONICAL_FILE"
  cp -- "$WORK_DIR/claude.desired" "$CLAUDE_FILE"
  cp -- "$WORK_DIR/codex.desired" "$CODEX_FILE"
  chmod 0644 "$CANONICAL_FILE" "$CLAUDE_FILE" "$CODEX_FILE"
  say "Updated global instructions (backup: $transaction)"
}

claude_marketplace() {
  local source=$1
  local name=$2
  claude plugin marketplace add "$source" >/dev/null 2>&1 ||
    claude plugin marketplace update "$name" >/dev/null
}

codex_marketplace() {
  local source=$1
  local name=$2
  codex plugin marketplace add "$source" --ref main >/dev/null 2>&1 ||
    codex plugin marketplace upgrade "$name" >/dev/null
}

install_claude_core() {
  local plugin
  if ! command -v claude >/dev/null 2>&1; then
    warn 'Claude Code CLI not found; skipped Claude plugin installation'
    return
  fi

  say 'Installing core Claude Code plugins'
  claude_marketplace "$SUPERPOWERS_MARKETPLACE" "$SUPERPOWERS_MARKETPLACE_NAME"
  claude_marketplace "$WORKFLOW_MARKETPLACE" "$WORKFLOW_MARKETPLACE_NAME"
  for plugin in $CORE_UPSTREAM_PLUGINS; do
    claude plugin install "$plugin@$SUPERPOWERS_MARKETPLACE_NAME" -y >/dev/null
  done
  for plugin in $CORE_WORKFLOW_PLUGINS; do
    claude plugin install "$plugin@$WORKFLOW_MARKETPLACE_NAME" -y >/dev/null
  done
}

install_codex_core() {
  local plugin
  if ! command -v codex >/dev/null 2>&1; then
    warn 'Codex CLI not found; skipped Codex plugin installation'
    return
  fi

  say 'Installing core Codex plugins'
  codex_marketplace "$SUPERPOWERS_MARKETPLACE" "$SUPERPOWERS_MARKETPLACE_NAME"
  codex_marketplace "$WORKFLOW_MARKETPLACE" "$WORKFLOW_MARKETPLACE_NAME"
  for plugin in $CORE_UPSTREAM_PLUGINS; do
    codex plugin add "$plugin@$SUPERPOWERS_MARKETPLACE_NAME" >/dev/null
  done
  for plugin in $CORE_WORKFLOW_PLUGINS; do
    codex plugin add "$plugin@$WORKFLOW_MARKETPLACE_NAME" >/dev/null
  done
  codex features enable multi_agent >/dev/null
}

find_codegraph() {
  local found
  found=$(command -v codegraph 2>/dev/null || true)
  if [[ -n $found ]]; then
    printf '%s\n' "$found"
  elif [[ -x $HOME/.local/bin/codegraph ]]; then
    printf '%s\n' "$HOME/.local/bin/codegraph"
  fi
}

install_codegraph_binary() {
  local installer
  if command -v npm >/dev/null 2>&1; then
    npm install -g "$CODEGRAPH_PACKAGE@$CODEGRAPH_VERSION" >/dev/null
    return
  fi
  command -v curl >/dev/null 2>&1 || die 'CodeGraph is missing and neither npm nor curl is available'
  installer="$WORK_DIR/codegraph-install.sh"
  curl -fsSL -o "$installer" https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh
  sh "$installer"
}

configure_codegraph() {
  local codegraph_cmd
  codegraph_cmd=$(find_codegraph)
  if [[ -z $codegraph_cmd ]]; then
    say "Installing CodeGraph $CODEGRAPH_VERSION"
    install_codegraph_binary
    codegraph_cmd=$(find_codegraph)
  fi
  [[ -n $codegraph_cmd ]] || die 'CodeGraph installation completed but the command was not found'
  "$codegraph_cmd" telemetry off >/dev/null
  "$codegraph_cmd" install --yes >/dev/null
  say 'CodeGraph installed and registered; no repositories were indexed'
}

prepare_instructions
install_claude_core
install_codex_core
configure_codegraph
apply_instructions
say 'Setup complete. Restart active agent sessions to load new plugins and instructions.'
