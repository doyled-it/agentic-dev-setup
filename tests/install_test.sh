#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

write_failing_claude_mock() {
  local mode=$1
  local path="$TEST_BIN/claude"
  cat >"$path" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
mode='$mode'
printf 'claude %s\n' "\$*" >>"\$MOCK_LOG"
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
  env HOME="$TEST_HOME" PATH="$TEST_BIN:/usr/bin:/bin" MOCK_LOG="$MOCK_LOG" \
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
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
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
  assert_file_contains "$claude_file" "@$canonical_file"
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
  run_install --full >"$TEST_SANDBOX/install.out"
  assert_log_contains 'claude plugin marketplace add anthropics/claude-plugins-official'
  assert_log_contains 'codex plugin marketplace add anthropics/claude-plugins-official --ref main'
  for plugin in code-review code-simplifier claude-md-management claude-security frontend-design context7 playwright plugin-dev skill-creator mcp-server-dev pyright-lsp typescript-lsp; do
    assert_log_contains "claude plugin install $plugin@claude-plugins-official"
    assert_log_contains "codex plugin add $plugin@claude-plugins-official"
  done
  pass 'full mode installs the selected official-marketplace plugin set'
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
scenario_agent_targeting_and_explicit_missing_tool
scenario_opt_outs_skip_requested_components
scenario_dry_run_makes_no_changes
scenario_explicit_index_initializes_then_syncs_path_with_spaces
scenario_help_is_available
scenario_marketplace_and_plugin_failures_are_not_masked

printf '\nAll installer tests passed\n'
