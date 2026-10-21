#!/usr/bin/env bash

set -euo pipefail
umask 077

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
INSTALL_CLAUDE=true
INSTALL_CODEX=true
CLAUDE_EXPLICIT=false
CODEX_EXPLICIT=false
FULL_INSTALL=false
SKIP_CODEGRAPH=false
SKIP_INSTRUCTIONS=false
ENABLE_MULTI_AGENT=true
DRY_RUN=false
FULL_FAILURES=0
INDEX_PATHS=('')
INDEX_COUNT=0
PENDING_TRANSACTION=''
INSTRUCTION_SNAPSHOT_READY=false

restore_instruction_snapshot() {
  local key
  local target
  [[ $INSTRUCTION_SNAPSHOT_READY == true ]] || return 0
  for key in claude codex; do
    [[ -f $WORK_DIR/$key.original-state ]] || continue
    if [[ $key == claude ]]; then target=$CLAUDE_FILE; else target=$CODEX_FILE; fi
    [[ ! -L $target ]] || die "instruction target became a symlink: $target"
    if [[ $(cat "$WORK_DIR/$key.original-state") == present ]]; then
      mkdir -p -- "$(dirname "$target")"
      cp -p -- "$WORK_DIR/$key.original" "$target"
    else
      [[ ! -e $target || -f $target ]] || die "instruction target must be a regular file: $target"
      rm -f -- "$target"
    fi
  done
  INSTRUCTION_SNAPSHOT_READY=false
}

cleanup() {
  restore_instruction_snapshot
  rm -rf -- "$WORK_DIR"
  if [[ -n $PENDING_TRANSACTION ]]; then
    rm -rf -- "$PENDING_TRANSACTION"
  fi
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

usage() {
  cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Install the shared agent instructions, core workflow plugins, and CodeGraph.

Options:
  --full               Also install the selected official-marketplace plugins
  --claude-only        Configure Claude Code only
  --codex-only         Configure Codex only
  --skip-codegraph     Do not install or configure CodeGraph
  --skip-instructions  Do not update global instruction files
  --no-multi-agent     Do not enable Codex multi-agent support
  --dry-run            Report intended actions without making changes
  --index PATH         Initialize or sync a repository after setup; repeatable
  -h, --help           Show this help
EOF
}

parse_args() {
  local target_mode='both'

  while (($# > 0)); do
    case "$1" in
      --full)
        FULL_INSTALL=true
        ;;
      --claude-only)
        [[ $target_mode != codex ]] || die '--claude-only and --codex-only cannot be combined'
        target_mode=claude
        INSTALL_CLAUDE=true
        INSTALL_CODEX=false
        CLAUDE_EXPLICIT=true
        ;;
      --codex-only)
        [[ $target_mode != claude ]] || die '--claude-only and --codex-only cannot be combined'
        target_mode=codex
        INSTALL_CLAUDE=false
        INSTALL_CODEX=true
        CODEX_EXPLICIT=true
        ;;
      --skip-codegraph)
        SKIP_CODEGRAPH=true
        ;;
      --skip-instructions)
        SKIP_INSTRUCTIONS=true
        ;;
      --no-multi-agent)
        ENABLE_MULTI_AGENT=false
        ;;
      --dry-run)
        DRY_RUN=true
        ;;
      --index)
        shift
        (($# > 0)) || die '--index requires a path'
        INDEX_PATHS[INDEX_COUNT]=$1
        INDEX_COUNT=$((INDEX_COUNT + 1))
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
    shift
  done

  if [[ $SKIP_CODEGRAPH == true && $INDEX_COUNT -gt 0 ]]; then
    die '--skip-codegraph cannot be combined with --index'
  fi
}

validate_explicit_targets() {
  if [[ $CLAUDE_EXPLICIT == true ]] && ! command -v claude >/dev/null 2>&1; then
    die 'Claude Code CLI is required by --claude-only'
  fi
  if [[ $CODEX_EXPLICIT == true ]] && ! command -v codex >/dev/null 2>&1; then
    die 'Codex CLI is required by --codex-only'
  fi
}

describe_dry_run() {
  local index_number
  local index_path
  local targets='Claude Code and Codex'
  if [[ $INSTALL_CODEX == false ]]; then
    targets='Claude Code'
  elif [[ $INSTALL_CLAUDE == false ]]; then
    targets='Codex'
  fi

  say "Would install core plugins for $targets"
  if [[ $FULL_INSTALL == true ]]; then
    say "Would install the extended official-marketplace plugin set for $targets"
  fi
  if [[ $SKIP_CODEGRAPH == false ]]; then
    say 'Would install and configure CodeGraph'
  fi
  if [[ $SKIP_INSTRUCTIONS == false ]]; then
    say "Would update managed global instructions for $targets"
  fi
  if [[ $INSTALL_CODEX == true && $ENABLE_MULTI_AGENT == true ]]; then
    say 'Would enable Codex multi-agent support'
  fi
  for ((index_number = 0; index_number < INDEX_COUNT; index_number++)); do
    index_path=${INDEX_PATHS[$index_number]}
    say "Would initialize or sync the CodeGraph index at $index_path"
  done
}

managed_block_count() {
  local file=$1
  local begin_marker=${2:-$BEGIN_MARKER}
  local end_marker=${3:-$END_MARKER}
  local count_output

  if [[ ! -e $file ]]; then
    printf '0\n'
    return
  fi
  [[ -f $file && ! -L $file ]] || die "$file must be a regular file"
  if ! count_output=$(awk -v begin="$begin_marker" -v end="$end_marker" '
    BEGIN { state=0; count=0; invalid=0 }
    $0 == begin {
      if (state != 0 || count != 0) invalid=1
      state=1
      count++
      next
    }
    $0 == end {
      if (state != 1) invalid=1
      state=2
      next
    }
    END {
      if (state == 1 || invalid) exit 2
      print count
    }
  ' "$file"); then
    return 1
  fi
  printf '%s\n' "$count_output"
}

snapshot_instructions() {
  local key
  local target
  for key in claude codex; do
    if [[ $key == claude ]]; then
      [[ $INSTALL_CLAUDE == true ]] || continue
      target=$CLAUDE_FILE
    else
      [[ $INSTALL_CODEX == true ]] || continue
      target=$CODEX_FILE
    fi
    if [[ -e $target || -L $target ]]; then
      [[ -f $target && ! -L $target ]] || die "$target must be a regular file"
      cp -p -- "$target" "$WORK_DIR/$key.original"
      printf 'present\n' >"$WORK_DIR/$key.original-state"
    else
      printf 'absent\n' >"$WORK_DIR/$key.original-state"
    fi
  done
  INSTRUCTION_SNAPSHOT_READY=true
}

without_codegraph_guidance() {
  local target=$1
  local output=$2
  local count
  if ! count=$(managed_block_count "$target" '<!-- CODEGRAPH_START -->' '<!-- CODEGRAPH_END -->'); then
    die "$target contains malformed CodeGraph instruction markers"
  fi
  if [[ ! -e $target ]]; then
    : >"$output"
  elif [[ $count == 0 ]]; then
    cp -- "$target" "$output"
  else
    awk '
      $0 == "<!-- CODEGRAPH_START -->" { skipping=1; next }
      $0 == "<!-- CODEGRAPH_END -->" { skipping=0; next }
      !skipping { print }
    ' "$target" >"$output"
  fi
}

render_managed_file() {
  local target=$1
  local block_file=$2
  local output=$3
  local block_count

  if ! block_count=$(managed_block_count "$target"); then
    die "$target contains malformed or duplicate agentic-dev-setup markers"
  fi

  if [[ $block_count == 0 ]]; then
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
  local claude_import_path
  claude_import_path=${CANONICAL_FILE// /\\ }

  {
    printf '%s\n' "$BEGIN_MARKER"
    printf '@%s\n' "$claude_import_path"
    printf '%s\n' "$END_MARKER"
  } >"$claude_block"

  {
    printf '%s\n' "$BEGIN_MARKER"
    cat -- "$ROOT/AGENTS.md"
    printf '%s\n' "$END_MARKER"
  } >"$codex_block"

  cp -- "$ROOT/AGENTS.md" "$WORK_DIR/canonical.desired"
  if [[ $INSTALL_CLAUDE == true ]]; then
    without_codegraph_guidance "$CLAUDE_FILE" "$WORK_DIR/claude.base"
    render_managed_file "$WORK_DIR/claude.base" "$claude_block" "$WORK_DIR/claude.desired"
  fi
  if [[ $INSTALL_CODEX == true ]]; then
    without_codegraph_guidance "$CODEX_FILE" "$WORK_DIR/codex.base"
    render_managed_file "$WORK_DIR/codex.base" "$codex_block" "$WORK_DIR/codex.desired"
  fi

  if files_differ "$WORK_DIR/canonical.desired" "$CANONICAL_FILE"; then
    INSTRUCTIONS_CHANGED=true
  fi
  if [[ $INSTALL_CLAUDE == true ]] && files_differ "$WORK_DIR/claude.desired" "$CLAUDE_FILE"; then
    INSTRUCTIONS_CHANGED=true
  fi
  if [[ $INSTALL_CODEX == true ]] && files_differ "$WORK_DIR/codex.desired" "$CODEX_FILE"; then
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
    chmod 0600 "$transaction/$backup_name"
    printf '%s|present|%s|%s\n' "$key" "$target" "$backup_name" >>"$transaction/manifest"
  else
    printf '%s|absent|%s|%s\n' "$key" "$target" "$backup_name" >>"$transaction/manifest"
  fi
}

apply_instructions() {
  local transaction
  local transaction_pending
  local stamp

  if [[ $INSTRUCTIONS_CHANGED != true ]]; then
    say 'Global instructions already current'
    return
  fi

  stamp=$(date -u '+%Y%m%dT%H%M%SZ')
  transaction="$BACKUP_ROOT/$stamp-$$"
  transaction_pending="$BACKUP_ROOT/.pending-$stamp-$$"
  if [[ -e $BACKUP_ROOT || -L $BACKUP_ROOT ]]; then
    [[ -d $BACKUP_ROOT && ! -L $BACKUP_ROOT ]] || die "$BACKUP_ROOT must be a directory, not a symlink"
  fi
  mkdir -p -- "$BACKUP_ROOT"
  chmod 0700 "$BACKUP_ROOT"
  mkdir -m 0700 -- "$transaction_pending"
  PENDING_TRANSACTION=$transaction_pending
  : >"$transaction_pending/manifest"
  chmod 0600 "$transaction_pending/manifest"
  backup_target "$transaction_pending" canonical "$CANONICAL_FILE" canonical.AGENTS.md
  if [[ $INSTALL_CLAUDE == true ]]; then
    backup_target "$transaction_pending" claude "$CLAUDE_FILE" claude.CLAUDE.md
  fi
  if [[ $INSTALL_CODEX == true ]]; then
    backup_target "$transaction_pending" codex "$CODEX_FILE" codex.AGENTS.md
  fi
  : >"$transaction_pending/COMPLETE"
  chmod 0600 "$transaction_pending/COMPLETE"
  mv -- "$transaction_pending" "$transaction"
  PENDING_TRANSACTION=''

  mkdir -p -- "$(dirname "$CANONICAL_FILE")"
  cp -- "$WORK_DIR/canonical.desired" "$CANONICAL_FILE"
  chmod 0600 "$CANONICAL_FILE"
  if [[ $INSTALL_CLAUDE == true ]]; then
    mkdir -p -- "$(dirname "$CLAUDE_FILE")"
    cp -- "$WORK_DIR/claude.desired" "$CLAUDE_FILE"
    chmod 0600 "$CLAUDE_FILE"
  fi
  if [[ $INSTALL_CODEX == true ]]; then
    mkdir -p -- "$(dirname "$CODEX_FILE")"
    cp -- "$WORK_DIR/codex.desired" "$CODEX_FILE"
    chmod 0600 "$CODEX_FILE"
  fi
  say "Updated global instructions (backup: $transaction)"
}

marketplace_status() {
  local file=$1
  local name=$2
  local source=$3
  tr '{' '\n' <"$file" | awk -v wanted_name="$name" -v wanted_source="$source" '
    BEGIN {
      in_target=0
      found=0
      matched=0
      source_url="https://github.com/" wanted_source ".git"
    }
    {
      if (index($0, "\"name\"") > 0) {
        if (index($0, "\"" wanted_name "\"") > 0) {
          in_target=1
          found=1
        } else if (in_target) {
          in_target=0
        }
      }
      if (in_target && (index($0, "\"" wanted_source "\"") > 0 || index($0, "\"" source_url "\"") > 0)) {
        matched=1
      }
    }
    END {
      if (!found) print "missing"
      else if (matched) print "match"
      else print "mismatch"
    }
  '
}

claude_marketplace() {
  local source=$1
  local name=$2
  local list_file="$WORK_DIR/claude-marketplaces.json"
  local status

  claude plugin marketplace list --json >"$list_file"
  status=$(marketplace_status "$list_file" "$name" "$source")
  case "$status" in
    missing)
      claude plugin marketplace add "$source" >/dev/null
      ;;
    match)
      claude plugin marketplace update "$name" >/dev/null
      ;;
    mismatch)
      warn "Claude marketplace $name does not match expected source $source"
      return 1
      ;;
  esac
}

codex_marketplace() {
  local source=$1
  local name=$2
  local list_file="$WORK_DIR/codex-marketplaces.json"
  local status

  codex plugin marketplace list --json >"$list_file"
  status=$(marketplace_status "$list_file" "$name" "$source")
  case "$status" in
    missing)
      codex plugin marketplace add "$source" --ref main >/dev/null
      ;;
    match)
      codex plugin marketplace upgrade "$name" >/dev/null
      ;;
    mismatch)
      warn "Codex marketplace $name does not match expected source $source"
      return 1
      ;;
  esac
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

install_claude_full() {
  local plugin
  say 'Installing full Claude Code plugin set'
  if ! claude_marketplace "$OFFICIAL_MARKETPLACE" "$OFFICIAL_MARKETPLACE_NAME"; then
    warn "could not configure $OFFICIAL_MARKETPLACE_NAME for Claude Code"
    FULL_FAILURES=$((FULL_FAILURES + 1))
    return
  fi
  for plugin in $EXTENDED_MARKETPLACE_PLUGINS; do
    if ! claude plugin install "$plugin@$OFFICIAL_MARKETPLACE_NAME" -y >/dev/null; then
      warn "could not install $plugin for Claude Code"
      FULL_FAILURES=$((FULL_FAILURES + 1))
    fi
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
  if [[ $ENABLE_MULTI_AGENT == true ]]; then
    codex features enable multi_agent >/dev/null
  fi
}

install_codex_full() {
  local plugin
  say 'Installing full Codex plugin set'
  if ! codex_marketplace "$OFFICIAL_MARKETPLACE" "$OFFICIAL_MARKETPLACE_NAME"; then
    warn "could not configure $OFFICIAL_MARKETPLACE_NAME for Codex"
    FULL_FAILURES=$((FULL_FAILURES + 1))
    return
  fi
  for plugin in $EXTENDED_MARKETPLACE_PLUGINS; do
    if ! codex plugin add "$plugin@$OFFICIAL_MARKETPLACE_NAME" >/dev/null; then
      warn "could not install $plugin for Codex"
      FULL_FAILURES=$((FULL_FAILURES + 1))
    fi
  done
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
  command -v npm >/dev/null 2>&1 || die 'npm is required to install the pinned CodeGraph package'
  npm install -g "$CODEGRAPH_PACKAGE@$CODEGRAPH_VERSION" >/dev/null
}

configure_codegraph() {
  local codegraph_cmd
  local target
  codegraph_cmd=$(find_codegraph)
  if [[ -z $codegraph_cmd ]]; then
    say "Installing CodeGraph $CODEGRAPH_VERSION"
    install_codegraph_binary
    codegraph_cmd=$(find_codegraph)
  fi
  [[ -n $codegraph_cmd ]] || die 'CodeGraph installation completed but the command was not found'
  if [[ $INSTALL_CLAUDE == true && $INSTALL_CODEX == true ]]; then
    target='claude,codex'
  elif [[ $INSTALL_CLAUDE == true ]]; then
    target='claude'
  else
    target='codex'
  fi
  "$codegraph_cmd" telemetry off >/dev/null
  "$codegraph_cmd" install --yes --target "$target" >/dev/null
  say 'CodeGraph installed and registered; no repositories were indexed'
}

index_repositories() {
  local codegraph_cmd
  local index_number
  local index_path
  codegraph_cmd=$(find_codegraph)
  [[ -n $codegraph_cmd ]] || die 'CodeGraph is required to index repositories'
  for ((index_number = 0; index_number < INDEX_COUNT; index_number++)); do
    index_path=${INDEX_PATHS[$index_number]}
    [[ -d $index_path ]] || die "index path is not a directory: $index_path"
    index_path=$(cd "$index_path" && pwd -P)
    if [[ -d $index_path/.codegraph ]]; then
      "$codegraph_cmd" sync "$index_path"
    else
      "$codegraph_cmd" init "$index_path" --yes
    fi
  done
}

parse_args "$@"
if [[ $DRY_RUN == true ]]; then
  describe_dry_run
  exit 0
fi
validate_explicit_targets
if [[ $SKIP_CODEGRAPH == false ]]; then
  snapshot_instructions
fi
if [[ $SKIP_INSTRUCTIONS == false ]]; then
  prepare_instructions
fi
if [[ $INSTALL_CLAUDE == true ]]; then
  install_claude_core
  if [[ $FULL_INSTALL == true ]] && command -v claude >/dev/null 2>&1; then
    install_claude_full
  fi
fi
if [[ $INSTALL_CODEX == true ]]; then
  install_codex_core
  if [[ $FULL_INSTALL == true ]] && command -v codex >/dev/null 2>&1; then
    install_codex_full
  fi
fi
if [[ $SKIP_CODEGRAPH == false ]]; then
  configure_codegraph
  index_repositories
fi
restore_instruction_snapshot
if [[ $SKIP_INSTRUCTIONS == false ]]; then
  apply_instructions
fi
if ((FULL_FAILURES > 0)); then
  die "$FULL_FAILURES optional full-plugin installation(s) failed"
fi
say 'Setup complete. Restart active agent sessions to load new plugins and instructions.'
