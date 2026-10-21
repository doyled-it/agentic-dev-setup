#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REAL_NODE=$(command -v node)
export REAL_NODE
SANDBOXES=()

cleanup() {
  local sandbox
  for sandbox in "${SANDBOXES[@]}"; do
    rm -rf -- "$sandbox"
  done
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

assert_file_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_log_contains() {
  assert_file_contains "$MOCK_LOG" "$1"
}

assert_path_absent() {
  [[ ! -e $1 && ! -L $1 ]] || fail "$1 should be absent"
}

new_sandbox() {
  TEST_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/agentic-dev-install.XXXXXX")
  SANDBOXES+=("$TEST_SANDBOX")
  TEST_HOME="$TEST_SANDBOX/home with spaces"
  TEST_BIN="$TEST_SANDBOX/bin"
  MOCK_LOG="$TEST_SANDBOX/commands.log"
  export TEST_SANDBOX TEST_HOME TEST_BIN MOCK_LOG
  mkdir -p "$TEST_HOME" "$TEST_BIN"
  : >"$MOCK_LOG"
}

write_recording_mock() {
  local name=$1
  local path="$TEST_BIN/$name"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$MOCK_LOG"
printf '%s argc=%s' "$(basename "$0")" "$#" >>"$MOCK_LOG"
arg_number=1
for arg in "$@"; do
  printf ' arg%s=<%s>' "$arg_number" "$arg" >>"$MOCK_LOG"
  arg_number=$((arg_number + 1))
done
printf '\n' >>"$MOCK_LOG"
if [[ ${1-} == plugin && ${2-} == list ]]; then
  if [[ ${MOCK_RETIRED_PLUGINS:-false} == true ]]; then
    if [[ $(basename "$0") == claude ]]; then
      printf '[{"id":"context7@claude-plugins-official"},{"id":"playwright@claude-plugins-official"}]\n'
    else
      printf '{"installed":[{"pluginId":"context7@claude-plugins-official","installed":true},{"pluginId":"playwright@claude-plugins-official","installed":true},{"pluginId":"claude-security@claude-plugins-official","installed":true}]}\n'
    fi
    exit 0
  fi
  if [[ $(basename "$0") == claude ]]; then printf '[]\n'; else printf '{"installed":[]}\n'; fi
fi
if [[ ${1-} == mcp && ${2-} == get ]]; then
  if [[ $(basename "$0") == claude && -f $HOME/claude-existing.txt ]]; then cat "$HOME/claude-existing.txt"; exit 0; fi
  exit 1
fi
exit 0
MOCK
  chmod +x "$path"
}

write_npm_mock() {
  local path="$TEST_BIN/npm"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm %s\n' "$*" >>"$MOCK_LOG"
mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/codegraph" <<'CODEGRAPH'
#!/usr/bin/env bash
printf 'codegraph %s\n' "$*" >>"$MOCK_LOG"
CODEGRAPH
chmod +x "$HOME/.local/bin/codegraph"
MOCK
  chmod +x "$path"
}

write_instruction_mutating_codegraph_mock() {
  cat >"$TEST_BIN/codegraph" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'codegraph %s\n' "$*" >>"$MOCK_LOG"
if [[ ${1:-} == install ]]; then
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  for target in "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md"; do
    printf '%s\n' '<!-- CODEGRAPH_START -->' 'Skip it when there is no index; indexing is the operator choice.' '<!-- CODEGRAPH_END -->' >>"$target"
  done
  if [[ ${FAIL_REGISTRATION:-false} == true ]]; then exit 8; fi
fi
MOCK
  chmod +x "$TEST_BIN/codegraph"
}

write_full_runtime_mocks() {
  write_recording_mock gh
  cat >"$TEST_BIN/python3" <<'MOCK'
#!/usr/bin/env bash
printf 'Python 3.12.0\n'
MOCK
  cat >"$TEST_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'unexpected network download in installer unit test\n' >&2
exit 91
MOCK
  chmod +x "$TEST_BIN/python3" "$TEST_BIN/curl"
  cat >"$TEST_BIN/node" <<'MOCK'
#!/usr/bin/env bash
if [[ ${1-} == --version ]]; then printf '%s\n' "${MOCK_NODE_VERSION:-v24.15.0}"; exit 0; fi
if [[ ${1-} == */verify-runtimes.cjs ]]; then
  printf 'runtime protocol verification\n' >>"$MOCK_LOG"
  exit 0
fi
exec "$REAL_NODE" "$@"
MOCK
  cat >"$TEST_BIN/npm" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm %s\n' "$*" >>"$MOCK_LOG"
runtime="$HOME/npm-runtime"
case "$*" in
  'prefix -g') printf '%s\n' "$runtime"; exit 0 ;;
  'root -g') printf '%s/node_modules\n' "$runtime"; exit 0 ;;
  'list -g --depth=0 --json')
    if [[ -f $runtime/versions.json ]]; then cat "$runtime/versions.json"; else printf '{}\n'; fi
    exit 0 ;;
esac
[[ ${FAIL_RUNTIME_DOWNLOAD:-false} != true ]] || exit 19
mkdir -p "$runtime/bin" "$runtime/node_modules/@playwright/mcp"
for binary in pyright-langserver typescript-language-server; do
  printf '#!/bin/sh\nexit 0\n' >"$runtime/bin/$binary"
  chmod +x "$runtime/bin/$binary"
done
cat >"$runtime/node_modules/@playwright/mcp/package.json" <<'JSON'
{"name":"@playwright/mcp","main":"index.js"}
JSON
cat >"$runtime/node_modules/@playwright/mcp/index.js" <<'JS'
module.exports.chromium = { executablePath: () => require('node:path').join(process.env.HOME, 'chromium binary') };
JS
mkdir -p "$runtime/node_modules/@playwright/mcp/node_modules/playwright"
cp "$runtime/node_modules/@playwright/mcp/index.js" "$runtime/node_modules/@playwright/mcp/node_modules/playwright/index.js"
cat >"$runtime/node_modules/@playwright/mcp/cli.js" <<'JS'
require('node:fs').writeFileSync(require('node:path').join(process.env.HOME, 'chromium binary'), '', {mode: 0o755});
JS
printf '{"dependencies":{"pyright":{"version":"1.1.414"},"typescript-language-server":{"version":"6.0.2"},"typescript":{"version":"6.0.3"},"@playwright/mcp":{"version":"0.0.83"}}}\n' >"$runtime/versions.json"
MOCK
  chmod +x "$TEST_BIN/node" "$TEST_BIN/npm"
}

write_failing_claude_mock() {
  local mode=$1
  local path="$TEST_BIN/claude"
  cat >"$path" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
mode='$mode'
printf 'claude %s\n' "\$*" >>"\$MOCK_LOG"
if [[ \$* == 'plugin list --json' ]]; then printf '[]\n'; exit 0; fi
if [[ \$* == 'plugin marketplace list --json' ]]; then
  case "\$mode" in
    update-fail)
      printf '%s\n' '[{"name":"superpowers-marketplace","repo":"obra/superpowers-marketplace"}]'
      ;;
    mismatch)
      printf '%s\n' '[{"name":"superpowers-marketplace","repo":"example/wrong-source"},{"name":"other","repo":"obra/superpowers-marketplace"}]'
      ;;
    *)
      printf '%s\n' '[]'
      ;;
  esac
  exit 0
fi
if [[ \$mode == add-fail && \$* == 'plugin marketplace add obra/superpowers-marketplace' ]]; then
  exit 7
fi
if [[ \$mode == update-fail && \$* == 'plugin marketplace update superpowers-marketplace' ]]; then
  exit 8
fi
if [[ \$mode == core-fail && \$* == 'plugin install superpowers@superpowers-marketplace -y' ]]; then
  exit 9
fi
if [[ \$mode == optional-fail && \$* == 'plugin install frontend-design@claude-plugins-official -y' ]]; then
  exit 10
fi
exit 0
MOCK
  chmod +x "$path"
}

run_install() {
  env HOME="$TEST_HOME" PATH="$TEST_BIN:$TEST_HOME/npm-runtime/bin:/usr/bin:/bin" MOCK_LOG="$MOCK_LOG" \
    bash "$ROOT/install.sh" "$@"
}

backup_count() {
  local backup_root="$TEST_HOME/.config/agentic-dev-setup/backups"
  if [[ ! -d $backup_root ]]; then
    printf '0\n'
    return
  fi
  find "$backup_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

file_mode() {
  case "$(uname -s)" in
    Darwin|FreeBSD)
      stat -f '%Lp' "$1"
      ;;
    *)
      stat -c '%a' "$1"
      ;;
  esac
}

latest_backup() {
  find "$TEST_HOME/.config/agentic-dev-setup/backups" -mindepth 1 -maxdepth 1 -type d ! -name '.pending-*' | sort | tail -1
}

scenario_core_install_is_native_reversible_and_idempotent() {
  local before_count
  local after_count
  local claude_file
  local codex_file
  local canonical_file

  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_npm_mock

  claude_file="$TEST_HOME/.claude/CLAUDE.md"
  codex_file="$TEST_HOME/.codex/AGENTS.md"
  canonical_file="$TEST_HOME/.config/agentic-dev-setup/AGENTS.md"
  mkdir -p "$(dirname "$claude_file")" "$(dirname "$codex_file")"
  printf 'keep claude\n' >"$claude_file"
  printf 'keep codex\n' >"$codex_file"
  chmod 0600 "$claude_file" "$codex_file"

  run_install >"$TEST_SANDBOX/install.out"

  assert_log_contains 'claude plugin marketplace add obra/superpowers-marketplace'
  assert_log_contains 'claude plugin marketplace add doyled-it/claude-skills'
  assert_log_contains 'claude plugin install superpowers@superpowers-marketplace'
  assert_log_contains 'claude plugin install development-loop@doyled-it-skills'
  assert_log_contains 'claude plugin install codegraph@doyled-it-skills'
  assert_log_contains 'claude plugin install cross-repo-completeness@doyled-it-skills'
  assert_log_contains 'codex plugin marketplace add obra/superpowers-marketplace'
  assert_log_contains 'codex plugin marketplace add doyled-it/claude-skills'
  assert_log_contains 'codex plugin add superpowers@superpowers-marketplace'
  assert_log_contains 'codex plugin add development-loop@doyled-it-skills'
  assert_log_contains 'codex features enable multi_agent'
  assert_log_contains 'codegraph telemetry off'
  assert_log_contains 'codegraph install --yes --target claude,codex'
  if grep -Eq '^codegraph (init|sync)( |$)' "$MOCK_LOG"; then
    fail 'default install must not index or sync a repository'
  fi

  cmp -s "$ROOT/AGENTS.md" "$canonical_file" || fail 'canonical AGENTS.md copy differs'
  assert_file_contains "$claude_file" 'keep claude'
  assert_file_contains "$claude_file" '<!-- BEGIN agentic-dev-setup -->'
  assert_file_contains "$claude_file" "@$TEST_SANDBOX/home\\ with\\ spaces/.config/agentic-dev-setup/AGENTS.md"
  assert_file_contains "$codex_file" 'keep codex'
  assert_file_contains "$codex_file" '<!-- BEGIN agentic-dev-setup -->'
  assert_file_contains "$codex_file" '# Agent Instructions'
  [[ $(backup_count) == 1 ]] || fail 'first changed install must create one backup transaction'
  [[ -f $(latest_backup)/COMPLETE ]] || fail 'backup transaction is missing its completion marker'
  [[ $(file_mode "$(latest_backup)") == 700 ]] || fail 'backup transaction permissions are too broad'
  [[ $(file_mode "$(latest_backup)/manifest") == 600 ]] || fail 'backup manifest permissions are too broad'
  [[ $(file_mode "$claude_file") == 600 ]] || fail 'Claude instruction permissions were broadened'
  [[ $(file_mode "$codex_file") == 600 ]] || fail 'Codex instruction permissions were broadened'
  [[ $(file_mode "$canonical_file") == 600 ]] || fail 'canonical instruction permissions are too broad'

  before_count=$(backup_count)
  cp "$claude_file" "$TEST_SANDBOX/claude.first"
  cp "$codex_file" "$TEST_SANDBOX/codex.first"
  cp "$canonical_file" "$TEST_SANDBOX/canonical.first"
  run_install >"$TEST_SANDBOX/install.second.out"
  after_count=$(backup_count)
  [[ $before_count == "$after_count" ]] || fail 'idempotent install created another backup'
  cmp -s "$claude_file" "$TEST_SANDBOX/claude.first" || fail 'Claude instructions changed on second install'
  cmp -s "$codex_file" "$TEST_SANDBOX/codex.first" || fail 'Codex instructions changed on second install'
  cmp -s "$canonical_file" "$TEST_SANDBOX/canonical.first" || fail 'canonical instructions changed on second install'

  env HOME="$TEST_HOME" bash "$ROOT/scripts/restore.sh" latest >"$TEST_SANDBOX/restore.out"
  [[ $(<"$claude_file") == 'keep claude' ]] || fail 'restore did not recover Claude content'
  [[ $(<"$codex_file") == 'keep codex' ]] || fail 'restore did not recover Codex content'
  assert_path_absent "$canonical_file"
  pass 'core install is native, reversible, and idempotent'
}

scenario_missing_codex_warns_and_continues() {
  new_sandbox
  write_recording_mock claude
  write_recording_mock codegraph
  write_npm_mock
  run_install >"$TEST_SANDBOX/install.out" 2>&1
  assert_file_contains "$TEST_SANDBOX/install.out" 'Codex CLI not found'
  if grep -Fq 'codex ' "$MOCK_LOG"; then
    fail 'missing Codex CLI was invoked'
  fi
  pass 'missing auto-detected Codex warns and continues'
}

scenario_missing_codegraph_installs_known_good_package() {
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_npm_mock
  run_install >"$TEST_SANDBOX/install.out"
  assert_log_contains 'npm install -g @colbymchenry/codegraph@1.6.0'
  assert_log_contains 'codegraph telemetry off'
  assert_log_contains 'codegraph install --yes'
  pass 'missing CodeGraph installs the known-good package'
}

scenario_missing_codegraph_requires_npm() {
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  if run_install >"$TEST_SANDBOX/install.out" 2>&1; then
    fail 'missing CodeGraph and npm should fail'
  fi
  assert_file_contains "$TEST_SANDBOX/install.out" 'npm is required to install the pinned CodeGraph package'
  pass 'missing CodeGraph fails instead of executing an unpinned installer'
}

scenario_malformed_markers_fail_without_changes() {
  local claude_file
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_npm_mock
  claude_file="$TEST_HOME/.claude/CLAUDE.md"
  mkdir -p "$(dirname "$claude_file")"
  printf '%s\n' '<!-- BEGIN agentic-dev-setup -->' 'broken' '<!-- BEGIN agentic-dev-setup -->' >"$claude_file"
  cp "$claude_file" "$TEST_SANDBOX/before"
  if run_install >"$TEST_SANDBOX/install.out" 2>&1; then
    fail 'malformed managed markers should fail'
  fi
  cmp -s "$claude_file" "$TEST_SANDBOX/before" || fail 'malformed marker failure changed the file'
  [[ $(backup_count) == 0 ]] || fail 'malformed marker failure created a backup transaction'

  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_npm_mock
  claude_file="$TEST_HOME/.claude/CLAUDE.md"
  mkdir -p "$(dirname "$claude_file")"
  printf '%s\n' '<!-- END agentic-dev-setup -->' 'content' '<!-- BEGIN agentic-dev-setup -->' >"$claude_file"
  cp "$claude_file" "$TEST_SANDBOX/before"
  if run_install >"$TEST_SANDBOX/install.out" 2>&1; then
    fail 'reversed managed markers should fail'
  fi
  cmp -s "$claude_file" "$TEST_SANDBOX/before" || fail 'reversed marker failure changed the file'
  [[ $(backup_count) == 0 ]] || fail 'reversed marker failure created a backup transaction'
  pass 'malformed markers fail without changes'
}

scenario_restore_removes_files_that_were_absent() {
  local canonical_file
  local claude_file
  local codex_file
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_npm_mock
  canonical_file="$TEST_HOME/.config/agentic-dev-setup/AGENTS.md"
  claude_file="$TEST_HOME/.claude/CLAUDE.md"
  codex_file="$TEST_HOME/.codex/AGENTS.md"
  run_install >"$TEST_SANDBOX/install.out"
  env HOME="$TEST_HOME" bash "$ROOT/scripts/restore.sh" latest >"$TEST_SANDBOX/restore.out"
  assert_path_absent "$canonical_file"
  assert_path_absent "$claude_file"
  assert_path_absent "$codex_file"
  pass 'restore removes files that were originally absent'
}

scenario_full_installs_exact_official_set_for_both_agents() {
  local plugin
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_npm_mock
  write_full_runtime_mocks
  run_install --full >"$TEST_SANDBOX/install.out"
  if grep -Fq 'plugin install context7@' "$MOCK_LOG" || grep -Fq 'plugin add context7@' "$MOCK_LOG"; then
    fail 'full installation must not install Context7'
  fi
  assert_log_contains 'claude plugin marketplace add anthropics/claude-plugins-official'
  assert_log_contains 'codex plugin marketplace add anthropics/claude-plugins-official --ref main'
  for plugin in code-review code-simplifier claude-md-management frontend-design plugin-dev skill-creator mcp-server-dev pyright-lsp typescript-lsp; do
    assert_log_contains "claude plugin install $plugin@claude-plugins-official"
    assert_log_contains "codex plugin add $plugin@claude-plugins-official"
  done
  assert_log_contains 'claude plugin install claude-security@claude-plugins-official'
  if grep -Fq 'codex plugin add claude-security@' "$MOCK_LOG"; then fail 'Claude Security requires the Claude Workflow tool'; fi
  assert_log_contains 'npm install -g pyright@1.1.414 typescript-language-server@6.0.2 typescript@6.0.3 @playwright/mcp@0.0.83'
  assert_log_contains 'runtime protocol verification'
  assert_log_contains 'claude mcp add --scope user agentic-playwright'
  assert_log_contains 'codex mcp add agentic-playwright'
  run_install --full >"$TEST_SANDBOX/second-full.out"
  [[ $(grep -c '^npm install -g pyright@' "$MOCK_LOG") -eq 1 ]] || fail 'repeat full installation reinstalled matching npm runtimes'
  pass 'full mode installs the selected official-marketplace plugin set'
}

scenario_full_runtime_failures_are_fatal() {
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_full_runtime_mocks
  mkdir -p "$TEST_HOME/.claude"
  printf 'Preserve original instructions\n' >"$TEST_HOME/.claude/CLAUDE.md"
  cp "$TEST_HOME/.claude/CLAUDE.md" "$TEST_SANDBOX/original"
  if MOCK_NODE_VERSION=v20.18.0 run_install --full >"$TEST_SANDBOX/node.out" 2>&1; then fail 'old Node should fail full preflight'; fi
  [[ ! -s $MOCK_LOG ]] || fail 'Node preflight failure mutated agent state'
  if FAIL_RUNTIME_DOWNLOAD=true run_install --full >"$TEST_SANDBOX/download.out" 2>&1; then fail 'runtime download failure must fail full installation'; fi
  cmp -s "$TEST_HOME/.claude/CLAUDE.md" "$TEST_SANDBOX/original" || fail 'runtime failure changed original instructions'
  [[ $(backup_count) == 0 ]] || fail 'failed runtime setup created an instruction backup'
  if grep -Fq 'Setup complete' "$TEST_SANDBOX/download.out"; then fail 'runtime failure reported success'; fi
  pass 'runtime download and Node preflight failures fail without changing instructions'
}

scenario_full_runtime_rejects_shadowed_tools_and_foreign_mcp() {
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_full_runtime_mocks
  write_recording_mock typescript-language-server
  if run_install --full >"$TEST_SANDBOX/shadow.out" 2>&1; then fail 'PATH-shadowed language server must not pass readiness'; fi
  rm "$TEST_BIN/typescript-language-server"
  run_install --full >"$TEST_SANDBOX/initial.out"
  local mcp="$TEST_HOME/npm-runtime/node_modules/@playwright/mcp/cli.js"
  local config="$TEST_HOME/.config/agentic-dev-setup/playwright.json"
  printf 'Command: /removed/node\nArgs: %s --config %s --browser firefox\n' "$mcp" "$config" >"$TEST_HOME/claude-existing.txt"
  "$REAL_NODE" - "$TEST_HOME/.claude.json" "$mcp" "$config" <<'JS'
const fs = require('node:fs');
fs.writeFileSync(process.argv[2], JSON.stringify({mcpServers: {'agentic-playwright': {
  type: 'stdio', command: '/removed/node', args: [process.argv[3], '--config', process.argv[4], '--browser', 'firefox']
}}}));
JS
  cp "$TEST_HOME/.claude.json" "$TEST_SANDBOX/foreign.before"
  if run_install --full >"$TEST_SANDBOX/foreign.out" 2>&1; then fail 'conflicting Claude MCP definition must not pass readiness'; fi
  cmp -s "$TEST_HOME/.claude.json" "$TEST_SANDBOX/foreign.before" || fail 'foreign Claude MCP definition was changed'
  pass 'shadowed tools and conflicting Claude MCP definitions are rejected'
}

scenario_full_retires_only_selected_agent_plugins() {
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_full_runtime_mocks
  MOCK_RETIRED_PLUGINS=true run_install --full --claude-only >"$TEST_SANDBOX/claude.out"
  assert_log_contains 'claude plugin uninstall context7@claude-plugins-official'
  assert_log_contains 'claude plugin uninstall playwright@claude-plugins-official'
  if grep -Fq 'codex ' "$MOCK_LOG"; then fail 'Claude-only migration changed Codex'; fi
  : >"$MOCK_LOG"
  MOCK_RETIRED_PLUGINS=true run_install --full --codex-only >"$TEST_SANDBOX/codex.out"
  for plugin in context7 playwright claude-security; do assert_log_contains "codex plugin remove $plugin@claude-plugins-official"; done
  if grep -Fq 'claude ' "$MOCK_LOG"; then fail 'Codex-only migration changed Claude'; fi
  pass 'full migration retires exact plugin IDs only in selected agents'
}

scenario_agent_targeting_and_explicit_missing_tool() {
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_npm_mock
  run_install --claude-only >"$TEST_SANDBOX/install.out"
  if grep -Fq 'codex ' "$MOCK_LOG"; then
    fail 'Claude-only mode invoked Codex'
  fi
  assert_path_absent "$TEST_HOME/.codex/AGENTS.md"
  assert_log_contains 'codegraph install --yes --target claude'

  new_sandbox
  write_recording_mock claude
  write_recording_mock codegraph
  write_npm_mock
  if run_install --codex-only >"$TEST_SANDBOX/install.out" 2>&1; then
    fail 'explicit Codex target should fail when Codex is missing'
  fi
  assert_file_contains "$TEST_SANDBOX/install.out" 'Codex CLI is required by --codex-only'
  assert_path_absent "$TEST_HOME/.config/agentic-dev-setup/AGENTS.md"
  pass 'agent targeting is selective and explicit missing tools are fatal'
}

scenario_opt_outs_skip_requested_components() {
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_npm_mock
  run_install --skip-codegraph --skip-instructions --no-multi-agent >"$TEST_SANDBOX/install.out"
  if grep -Fq 'codegraph ' "$MOCK_LOG"; then
    fail 'skip-codegraph invoked CodeGraph'
  fi
  if grep -Fq 'codex features enable multi_agent' "$MOCK_LOG"; then
    fail 'no-multi-agent enabled Codex multi-agent support'
  fi
  assert_path_absent "$TEST_HOME/.config/agentic-dev-setup/AGENTS.md"
  assert_path_absent "$TEST_HOME/.claude/CLAUDE.md"
  assert_path_absent "$TEST_HOME/.codex/AGENTS.md"

  mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.codex"
  printf 'Dotfile-managed instructions\n' >"$TEST_SANDBOX/shared-instructions"
  ln -s "$TEST_SANDBOX/shared-instructions" "$TEST_HOME/.claude/CLAUDE.md"
  ln -s "$TEST_SANDBOX/shared-instructions" "$TEST_HOME/.codex/AGENTS.md"
  : >"$MOCK_LOG"
  run_install --skip-codegraph --skip-instructions --no-multi-agent >"$TEST_SANDBOX/symlink-opt-out.out"
  [[ -L $TEST_HOME/.claude/CLAUDE.md && -L $TEST_HOME/.codex/AGENTS.md ]] || fail 'plugin-only install replaced instruction symlinks'
  [[ $(cat "$TEST_SANDBOX/shared-instructions") == 'Dotfile-managed instructions' ]] || fail 'plugin-only install changed symlink targets'
  assert_log_contains 'claude plugin install development-loop@doyled-it-skills -y'
  assert_log_contains 'codex plugin add development-loop@doyled-it-skills'
  pass 'opt-out flags skip their components'
}

scenario_dry_run_makes_no_changes() {
  new_sandbox
  run_install --full --dry-run >"$TEST_SANDBOX/install.out"
  [[ ! -s $MOCK_LOG ]] || fail 'dry-run invoked an external command'
  assert_path_absent "$TEST_HOME/.config/agentic-dev-setup"
  assert_path_absent "$TEST_HOME/.claude/CLAUDE.md"
  assert_path_absent "$TEST_HOME/.codex/AGENTS.md"
  assert_file_contains "$TEST_SANDBOX/install.out" 'Would install core plugins'
  assert_file_contains "$TEST_SANDBOX/install.out" 'Would install the extended official-marketplace plugin set'
  pass 'dry-run reports work without changing the system'
}

scenario_explicit_index_initializes_then_syncs_path_with_spaces() {
  local project
  local project_real
  new_sandbox
  project="$TEST_SANDBOX/project with spaces"
  write_recording_mock claude
  write_recording_mock codex
  write_recording_mock codegraph
  write_npm_mock
  mkdir -p "$project"
  project_real=$(cd "$project" && pwd -P)
  run_install --index "$project" >"$TEST_SANDBOX/install.out"
  assert_log_contains "codegraph init $project_real --yes"
  assert_log_contains "codegraph argc=3 arg1=<init> arg2=<$project_real> arg3=<--yes>"
  mkdir -p "$project/.codegraph"
  : >"$MOCK_LOG"
  run_install --index "$project" >"$TEST_SANDBOX/install.second.out"
  assert_log_contains "codegraph sync $project_real"
  pass 'explicit indexing initializes and syncs paths with spaces'
}

scenario_help_is_available() {
  new_sandbox
  run_install --help >"$TEST_SANDBOX/help.out"
  assert_file_contains "$TEST_SANDBOX/help.out" 'Usage:'
  assert_file_contains "$TEST_SANDBOX/help.out" '--index PATH'
  pass 'help documents installer modes'
}

scenario_codegraph_instruction_side_effects_are_reversible() {
  local target
  new_sandbox
  write_recording_mock claude
  write_recording_mock codex
  write_instruction_mutating_codegraph_mock
  mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.codex"
  printf 'Original Claude instructions\n' >"$TEST_HOME/.claude/CLAUDE.md"
  printf 'Original Codex instructions\n' >"$TEST_HOME/.codex/AGENTS.md"
  cp "$TEST_HOME/.claude/CLAUDE.md" "$TEST_SANDBOX/claude.before"
  cp "$TEST_HOME/.codex/AGENTS.md" "$TEST_SANDBOX/codex.before"

  run_install >"$TEST_SANDBOX/install.out"
  env HOME="$TEST_HOME" bash "$ROOT/scripts/restore.sh" latest >"$TEST_SANDBOX/restore.out"
  cmp -s "$TEST_HOME/.claude/CLAUDE.md" "$TEST_SANDBOX/claude.before" || fail 'restore captured CodeGraph output instead of original Claude instructions'
  cmp -s "$TEST_HOME/.codex/AGENTS.md" "$TEST_SANDBOX/codex.before" || fail 'restore captured CodeGraph output instead of original Codex instructions'

  run_install --skip-instructions >"$TEST_SANDBOX/skip.out"
  cmp -s "$TEST_HOME/.claude/CLAUDE.md" "$TEST_SANDBOX/claude.before" || fail 'CodeGraph violated --skip-instructions for Claude'
  cmp -s "$TEST_HOME/.codex/AGENTS.md" "$TEST_SANDBOX/codex.before" || fail 'CodeGraph violated --skip-instructions for Codex'

  if FAIL_REGISTRATION=true run_install >"$TEST_SANDBOX/failure.out" 2>&1; then
    fail 'failed CodeGraph registration should fail setup'
  fi
  cmp -s "$TEST_HOME/.claude/CLAUDE.md" "$TEST_SANDBOX/claude.before" || fail 'failed CodeGraph registration changed original Claude instructions'
  cmp -s "$TEST_HOME/.codex/AGENTS.md" "$TEST_SANDBOX/codex.before" || fail 'failed CodeGraph registration changed original Codex instructions'

  for target in "$TEST_HOME/.claude/CLAUDE.md" "$TEST_HOME/.codex/AGENTS.md"; do
    printf '%s\n' '<!-- CODEGRAPH_START -->' 'Skip it when there is no index; indexing is the operator choice.' '<!-- CODEGRAPH_END -->' >>"$target"
  done
  run_install >"$TEST_SANDBOX/legacy.out"
  if grep -Fq 'Skip it when there is no index' "$TEST_HOME/.claude/CLAUDE.md" "$TEST_HOME/.codex/AGENTS.md"; then
    fail 'legacy CodeGraph marker block contradicts the canonical indexing policy'
  fi
  assert_file_contains "$TEST_HOME/.claude/CLAUDE.md" 'Original Claude instructions'
  assert_file_contains "$TEST_HOME/.codex/AGENTS.md" 'Original Codex instructions'
  pass 'CodeGraph instruction side effects preserve restore, opt-outs, and coherent policy'
}

scenario_marketplace_and_plugin_failures_are_not_masked() {
  local mode

  for mode in add-fail update-fail mismatch core-fail; do
    new_sandbox
    write_failing_claude_mock "$mode"
    if run_install --claude-only --skip-codegraph --skip-instructions >"$TEST_SANDBOX/install.out" 2>&1; then
      fail "$mode should fail the core installation"
    fi
    case "$mode" in
      add-fail)
        if grep -Fq 'plugin marketplace update superpowers-marketplace' "$MOCK_LOG"; then
          fail 'marketplace add failure was masked by an update attempt'
        fi
        ;;
      update-fail)
        if grep -Fq 'plugin marketplace add obra/superpowers-marketplace' "$MOCK_LOG"; then
          fail 'known marketplace update failure fell back to add'
        fi
        ;;
      mismatch)
        assert_file_contains "$TEST_SANDBOX/install.out" 'does not match expected source'
        ;;
    esac
  done

  new_sandbox
  write_failing_claude_mock optional-fail
  write_full_runtime_mocks
  if run_install --claude-only --skip-codegraph --skip-instructions --full >"$TEST_SANDBOX/install.out" 2>&1; then
    fail 'optional plugin failure should produce a final nonzero exit'
  fi
  assert_log_contains 'claude plugin install typescript-lsp@claude-plugins-official -y'
  assert_file_contains "$TEST_SANDBOX/install.out" 'optional full-plugin installation(s) failed'
  pass 'marketplace and plugin failures preserve their real failure semantics'
}

scenario_core_install_is_native_reversible_and_idempotent
scenario_missing_codex_warns_and_continues
scenario_missing_codegraph_installs_known_good_package
scenario_missing_codegraph_requires_npm
scenario_malformed_markers_fail_without_changes
scenario_restore_removes_files_that_were_absent
scenario_full_installs_exact_official_set_for_both_agents
scenario_full_runtime_failures_are_fatal
scenario_full_runtime_rejects_shadowed_tools_and_foreign_mcp
scenario_full_retires_only_selected_agent_plugins
scenario_agent_targeting_and_explicit_missing_tool
scenario_opt_outs_skip_requested_components
scenario_dry_run_makes_no_changes
scenario_explicit_index_initializes_then_syncs_path_with_spaces
scenario_help_is_available
scenario_codegraph_instruction_side_effects_are_reversible
scenario_marketplace_and_plugin_failures_are_not_masked

printf '\nAll installer tests passed\n'
