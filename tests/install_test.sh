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
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # shellcheck disable=SC2016 # This line is source for the generated mock.
    printf '%s\n' 'printf '\''%s %s\\n'\'' "$(basename "$0")" "$*" >>"$MOCK_LOG"'
    printf '%s\n' 'exit 0'
  } >"$path"
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

run_install() {
  env HOME="$TEST_HOME" PATH="$TEST_BIN:/usr/bin:/bin" MOCK_LOG="$MOCK_LOG" \
    bash "$ROOT/install.sh"
}

backup_count() {
  local backup_root="$TEST_HOME/.config/agentic-dev-setup/backups"
  if [[ ! -d $backup_root ]]; then
    printf '0\n'
    return
  fi
  find "$backup_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
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
  assert_log_contains 'codegraph install --yes'
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

scenario_core_install_is_native_reversible_and_idempotent
scenario_missing_codex_warns_and_continues
scenario_missing_codegraph_installs_known_good_package
scenario_malformed_markers_fail_without_changes
scenario_restore_removes_files_that_were_absent

printf '\nAll installer tests passed\n'
