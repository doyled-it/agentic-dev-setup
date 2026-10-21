#!/usr/bin/env bash

set -euo pipefail
umask 077

FULL=false
KEEP=false
DRY_RUN=false
MODE=core
WORK_DIR=''

usage() {
  while IFS= read -r line; do
    printf '%s\n' "$line"
  done <<'EOF'
Usage: ./scripts/validate-live.sh [--full] [--keep] [--dry-run]

Validate a real installation using installed CLIs and public downloads, with
no model requests or authentication commands. Requires claude, codex,
codegraph, jq, npm, node, and git on PATH, plus standard Unix utilities.

  --full      Validate the extended plugin set as well as the core plugins
  --keep      Retain the disposable configuration and logs, even on failure
  --dry-run   Check dependencies and describe the run without executing tools
  --help      Show this help without checking dependencies

The run uses a fresh HOME, CODEX_HOME, CLAUDE_CONFIG_DIR, and npm prefix.
No credentials are copied. Telemetry is disabled. By default all generated
files are removed. Retained logs describe synthetic data and public plugins.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --full) FULL=true; MODE=full ;;
    --keep) KEEP=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 (use --help)" ;;
  esac
  shift
done

# Resolve executables before replacing HOME or changing directory. In
# particular, the native Claude executable may live below the caller's HOME.
CALLER_DIR=$PWD
CALLER_PATH=${PATH:-}
BASH_BIN=$BASH
TOOLS=(claude codex codegraph jq npm node git)
TOOL_PATHS=()
MISSING=false
for tool in "${TOOLS[@]}"; do
  found=$(type -P "$tool" || true)
  if [[ -z $found || ! -x $found ]]; then
    printf 'error: missing required tool: %s\n' "$tool" >&2
    MISSING=true
    continue
  fi
  [[ $found == /* ]] || found="$CALLER_DIR/$found"
  TOOL_PATHS[${#TOOL_PATHS[@]}]=$found
done
if [[ $MISSING == true ]]; then
  die 'Install Claude Code, Codex CLI, CodeGraph, jq, Node.js/npm, and git; put their executables on PATH and rerun --dry-run.'
fi

if [[ $DRY_RUN == true ]]; then
  printf 'Preflight passed: %s live installation, isolated config, no model requests.\n' "$MODE"
  printf 'Would verify plugins, MCP registration, multi_agent, instructions, repeat installation, indexing, and restore.\n'
  exit 0
fi

ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd -P)
[[ -f $ROOT/install.sh && -f $ROOT/scripts/restore.sh && -f $ROOT/dependencies.env ]] || die 'Run this script from a complete checkout of agentic-dev-setup.'
# shellcheck source=dependencies.env
source "$ROOT/dependencies.env"

CLAUDE_BIN=${TOOL_PATHS[0]}
CODEX_BIN=${TOOL_PATHS[1]}
CODEGRAPH_BIN=${TOOL_PATHS[2]}
JQ_BIN=${TOOL_PATHS[3]}
GIT_BIN=${TOOL_PATHS[6]}

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agentic-live.XXXXXX")
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)
cleanup() {
  local status=$?
  trap - EXIT
  if [[ $KEEP == true ]]; then
    printf 'Retained synthetic configuration and logs: %s\n' "$WORK_DIR"
  else
    rm -rf -- "$WORK_DIR"
    if ((status != 0)); then
      printf 'Disposable files removed; rerun with --keep to inspect logs.\n' >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

LIVE_HOME="$WORK_DIR/home with spaces"
LOG_DIR="$WORK_DIR/logs"
FIXTURE="$WORK_DIR/python-repository"
mkdir -p "$LIVE_HOME/.claude" "$LIVE_HOME/.codex" \
  "$LIVE_HOME/.config/agentic-dev-setup" "$WORK_DIR/bin" "$WORK_DIR/tmp" \
  "$WORK_DIR/npm" "$LOG_DIR" "$FIXTURE" "$WORK_DIR/originals" "$WORK_DIR/installed"

# The installer resolves CLI names through PATH. These links retain the
# caller's actual executables, rather than installing substitute CLIs.
for ((i = 0; i < ${#TOOLS[@]}; i++)); do
  ln -s "${TOOL_PATHS[$i]}" "$WORK_DIR/bin/${TOOLS[$i]}"
done

# Preserve auxiliary tool lookup even if the caller used relative PATH entries.
RUN_PATH="$WORK_DIR/bin:$WORK_DIR/npm/bin"
IFS=: read -r -a path_entries <<<"$CALLER_PATH"
for entry in "${path_entries[@]}"; do
  case "$entry" in
    /*) RUN_PATH="$RUN_PATH:$entry" ;;
    '') RUN_PATH="$RUN_PATH:$CALLER_DIR" ;;
    *) RUN_PATH="$RUN_PATH:$CALLER_DIR/$entry" ;;
  esac
done
RUN_PATH="$RUN_PATH:/usr/bin:/bin"
: >"$WORK_DIR/gitconfig"
: >"$WORK_DIR/npmrc"
: >"$WORK_DIR/npm-globalrc"

# Every external integration starts from an allowlisted environment. Inherited
# API keys, agent settings, credential helpers, and SSH agents are not passed.
isolated() {
  env -i HOME="$LIVE_HOME" CODEX_HOME="$LIVE_HOME/.codex" \
    PATH="$RUN_PATH" \
    TMPDIR="$WORK_DIR/tmp" XDG_CONFIG_HOME="$LIVE_HOME/.config" \
    XDG_CACHE_HOME="$LIVE_HOME/.cache" XDG_DATA_HOME="$LIVE_HOME/.local/share" \
    XDG_STATE_HOME="$LIVE_HOME/.local/state" \
    npm_config_prefix="$WORK_DIR/npm" npm_config_cache="$WORK_DIR/npm-cache" \
    npm_config_userconfig="$WORK_DIR/npmrc" npm_config_globalconfig="$WORK_DIR/npm-globalrc" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK_DIR/gitconfig" \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
    DO_NOT_TRACK=1 CODEGRAPH_TELEMETRY=0 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 \
    CI=1 NO_COLOR=1 TERM=dumb LC_ALL=C "$@"
}

capture() {
  local label=$1
  shift
  isolated "$@" >"$LOG_DIR/$label.log" 2>&1 || die "$label failed; inspect $label.log with --keep."
}

capture_json() {
  local label=$1
  shift
  isolated "$@" >"$LOG_DIR/$label.json" 2>"$LOG_DIR/$label.stderr.log" || die "$label failed; inspect its log with --keep."
  "$JQ_BIN" -e . "$LOG_DIR/$label.json" >/dev/null || die "$label returned invalid JSON."
}

assert_equal() {
  cmp -s -- "$1" "$2" || die "$3"
}

assert_original_prefix() {
  local original=$1
  local installed=$2
  local length
  length=$(wc -c <"$original")
  head -c "$length" "$installed" >"$WORK_DIR/prefix"
  assert_equal "$original" "$WORK_DIR/prefix" 'Installation changed preseeded instruction content.'
}

backup_inventory() {
  local transaction
  for transaction in "$LIVE_HOME/.config/agentic-dev-setup/backups"/* \
    "$LIVE_HOME/.config/agentic-dev-setup/backups"/.[!.]*; do
    [[ -e $transaction || -L $transaction ]] || continue
    printf '%s\n' "${transaction##*/}"
  done
}

assert_plugin() {
  local id=$1
  # jq expands $id from --arg, rather than from the shell.
  # shellcheck disable=SC2016
  "$JQ_BIN" -e --arg id "$id" 'any(.[]; .id == $id and .enabled == true)' \
    "$LOG_DIR/claude-plugins.json" >/dev/null || die "Claude plugin is not enabled: $id"
  # shellcheck disable=SC2016
  "$JQ_BIN" -e --arg id "$id" 'any(.installed[]; .pluginId == $id and .installed == true and .enabled == true)' \
    "$LOG_DIR/codex-plugins.json" >/dev/null || die "Codex plugin is not enabled: $id"
}

verify_native_state() {
  local plugin
  capture_json claude-plugins "$CLAUDE_BIN" plugin list --json
  capture_json codex-plugins "$CODEX_BIN" plugin list --json
  for plugin in $CORE_UPSTREAM_PLUGINS; do
    assert_plugin "$plugin@$SUPERPOWERS_MARKETPLACE_NAME"
  done
  for plugin in $CORE_WORKFLOW_PLUGINS; do
    assert_plugin "$plugin@$WORKFLOW_MARKETPLACE_NAME"
  done
  if [[ $FULL == true ]]; then
    for plugin in $EXTENDED_MARKETPLACE_PLUGINS; do
      if [[ $plugin == claude-security ]]; then
        # jq expands its own $id variable.
        # shellcheck disable=SC2016
        "$JQ_BIN" -e --arg id "$plugin@$OFFICIAL_MARKETPLACE_NAME" 'any(.[]; .id == $id and .enabled == true)' "$LOG_DIR/claude-plugins.json" >/dev/null || die 'Claude Security is missing from Claude'
      else
        assert_plugin "$plugin@$OFFICIAL_MARKETPLACE_NAME"
      fi
    done
    "$JQ_BIN" -e 'all(.[]; (.id | startswith("context7@")) == false and (.id | startswith("playwright@")) == false)' "$LOG_DIR/claude-plugins.json" >/dev/null || die 'Retired Claude plugins were installed'
    "$JQ_BIN" -e 'all(.installed[]; (.pluginId | test("^(context7|playwright|claude-security)@")) == false)' "$LOG_DIR/codex-plugins.json" >/dev/null || die 'Retired or unsupported Codex plugins were installed'
    capture runtime-protocols "${TOOL_PATHS[5]}" "$ROOT/scripts/verify-runtimes.cjs" "$LIVE_HOME/.config/agentic-dev-setup/runtimes.json"
  fi

  capture codex-features "$CODEX_BIN" features list
  awk '$1 == "multi_agent" && $NF == "true" { found=1 } END { exit !found }' \
    "$LOG_DIR/codex-features.log" || die 'Codex multi_agent is not enabled.'
  awk '
    /^\[/ { features=($0 == "[features]") }
    features && /^[[:space:]]*multi_agent[[:space:]]*=[[:space:]]*true([[:space:]]|$)/ { found=1 }
    END { exit !found }
  ' "$LIVE_HOME/.codex/config.toml" || die 'Codex multi_agent was not persisted in configuration.'

  capture_json codex-mcp "$CODEX_BIN" mcp list --json
  "$JQ_BIN" -e 'any(.[]; .name == "codegraph" and .transport.type == "stdio" and
    .transport.command == "codegraph" and .transport.args == ["serve", "--mcp"])' \
    "$LOG_DIR/codex-mcp.json" >/dev/null || die 'CodeGraph MCP registration is missing from Codex.'
  "$JQ_BIN" -e '.mcpServers.codegraph | .command == "codegraph" and .args == ["serve", "--mcp"]' \
    "$LIVE_HOME/.claude.json" >/dev/null || die 'CodeGraph MCP registration is missing from Claude configuration.'
  if [[ $FULL == true ]]; then
    "$JQ_BIN" -e 'any(.[]; .name == "agentic-playwright" and .transport.type == "stdio")' "$LOG_DIR/codex-mcp.json" >/dev/null || die 'Playwright is missing from Codex MCP configuration'
    "$JQ_BIN" -e '.mcpServers["agentic-playwright"].args | index("--config") != null' "$LIVE_HOME/.claude.json" >/dev/null || die 'Playwright is missing from Claude MCP configuration'
  fi
}

printf '# Existing canonical preferences\n\nKeep this original in the backup.\n' >"$WORK_DIR/originals/canonical"
printf '# Existing Claude preferences\n\nPreserve this instruction verbatim.\n' >"$WORK_DIR/originals/claude"
printf '# Existing Codex preferences\n\nPreserve this instruction verbatim.\n' >"$WORK_DIR/originals/codex"
CANONICAL="$LIVE_HOME/.config/agentic-dev-setup/AGENTS.md"
CLAUDE_INSTRUCTIONS="$LIVE_HOME/.claude/CLAUDE.md"
CODEX_INSTRUCTIONS="$LIVE_HOME/.codex/AGENTS.md"
cp "$WORK_DIR/originals/canonical" "$CANONICAL"
cp "$WORK_DIR/originals/claude" "$CLAUDE_INSTRUCTIONS"
cp "$WORK_DIR/originals/codex" "$CODEX_INSTRUCTIONS"

cd "$FIXTURE"
capture git-init "$GIT_BIN" -c init.defaultBranch=main init --quiet
cat >validation_fixture.py <<'EOF'
def live_validation_symbol(value: int) -> int:
    return value + 1
EOF
capture claude-version "$CLAUDE_BIN" --version
capture codex-version "$CODEX_BIN" --version
capture codegraph-version "$CODEGRAPH_BIN" --version

printf 'Running real %s installation in disposable configuration (no model requests).\n' "$MODE"
if [[ $FULL == true ]]; then
  capture install-first "$BASH_BIN" "$ROOT/install.sh" --full
else
  capture install-first "$BASH_BIN" "$ROOT/install.sh"
fi
verify_native_state
assert_equal "$ROOT/AGENTS.md" "$CANONICAL" 'Generated canonical instructions differ from this checkout.'
assert_original_prefix "$WORK_DIR/originals/claude" "$CLAUDE_INSTRUCTIONS"
assert_original_prefix "$WORK_DIR/originals/codex" "$CODEX_INSTRUCTIONS"
claude_import_path=${CANONICAL// /\\ }
grep -Fxq -- "@$claude_import_path" "$CLAUDE_INSTRUCTIONS" || die 'Claude instructions do not import the canonical instructions with escaped spaces.'
awk '
  $0 == "<!-- BEGIN agentic-dev-setup -->" { inside=1; next }
  $0 == "<!-- END agentic-dev-setup -->" { inside=0; next }
  inside { print }
' "$CODEX_INSTRUCTIONS" >"$WORK_DIR/codex-managed"
assert_equal "$CANONICAL" "$WORK_DIR/codex-managed" 'Codex managed instructions differ from the canonical instructions.'
backup_inventory >"$WORK_DIR/backups-before"
[[ $(wc -l <"$WORK_DIR/backups-before") -eq 1 ]] || die 'Expected exactly one complete instruction backup.'
transaction=$(cat "$WORK_DIR/backups-before")
[[ -f $LIVE_HOME/.config/agentic-dev-setup/backups/$transaction/COMPLETE ]] || die 'Instruction backup is incomplete.'
assert_equal "$WORK_DIR/originals/canonical" \
  "$LIVE_HOME/.config/agentic-dev-setup/backups/$transaction/canonical.AGENTS.md" \
  'The canonical backup does not preserve the original.'
cp "$CANONICAL" "$WORK_DIR/installed/canonical"
cp "$CLAUDE_INSTRUCTIONS" "$WORK_DIR/installed/claude"
cp "$CODEX_INSTRUCTIONS" "$WORK_DIR/installed/codex"
cp -R "$LIVE_HOME/.config/agentic-dev-setup/backups" "$WORK_DIR/installed/backups"
printf 'PASS: native plugins, multi_agent, MCP registration, and preserved instructions.\n'

if [[ $FULL == true ]]; then
  capture install-second "$BASH_BIN" "$ROOT/install.sh" --full
else
  capture install-second "$BASH_BIN" "$ROOT/install.sh"
fi
verify_native_state
backup_inventory >"$WORK_DIR/backups-after"
assert_equal "$WORK_DIR/backups-before" "$WORK_DIR/backups-after" 'Repeat installation created another instruction backup.'
diff -r -- "$WORK_DIR/installed/backups" "$LIVE_HOME/.config/agentic-dev-setup/backups" \
  >"$LOG_DIR/backup-diff.log" || die 'Repeat installation changed existing instruction backups.'
assert_equal "$WORK_DIR/installed/canonical" "$CANONICAL" 'Repeat installation changed canonical instructions.'
assert_equal "$WORK_DIR/installed/claude" "$CLAUDE_INSTRUCTIONS" 'Repeat installation changed Claude instructions.'
assert_equal "$WORK_DIR/installed/codex" "$CODEX_INSTRUCTIONS" 'Repeat installation changed Codex instructions.'
printf 'PASS: repeat installation leaves instructions and backup inventory unchanged.\n'

capture codegraph-init "$CODEGRAPH_BIN" init "$FIXTURE" --yes
capture_json codegraph-query "$CODEGRAPH_BIN" query live_validation_symbol --path "$FIXTURE" --json
"$JQ_BIN" -e 'any(.[]; .node.name == "live_validation_symbol" and .node.kind == "function")' \
  "$LOG_DIR/codegraph-query.json" >/dev/null || die 'CodeGraph did not index the disposable Python function.'
printf 'PASS: real CodeGraph init and symbol query.\n'

capture restore "$BASH_BIN" "$ROOT/scripts/restore.sh" latest
assert_equal "$WORK_DIR/originals/canonical" "$CANONICAL" 'Restore changed the original canonical instructions.'
assert_equal "$WORK_DIR/originals/claude" "$CLAUDE_INSTRUCTIONS" 'Restore changed the original Claude instructions.'
assert_equal "$WORK_DIR/originals/codex" "$CODEX_INSTRUCTIONS" 'Restore changed the original Codex instructions.'
printf 'PASS: restored all three pre-install instruction files byte for byte.\n'
printf 'Live %s installation validation passed.\n' "$MODE"
