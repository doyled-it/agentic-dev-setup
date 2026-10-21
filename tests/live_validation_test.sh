#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER="$ROOT/scripts/validate-live.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agentic-live-test.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "$3"
}

# These guards must work without starting a CLI, creating a workspace, or
# inheriting a user's configuration. Sentinel tools fail if invoked.
mkdir -p "$TEST_ROOT/empty" "$TEST_ROOT/tools with spaces"
for tool in claude codex codegraph jq npm node git; do
  cat >"$TEST_ROOT/tools with spaces/$tool" <<'EOF'
#!/bin/sh
printf 'unexpected tool invocation\n' >>"$SENTINEL_LOG"
exit 89
EOF
  chmod +x "$TEST_ROOT/tools with spaces/$tool"
done

run_guard() {
  local search_path=$1
  shift
  env -i PATH="$search_path" HOME="$TEST_ROOT/untouched-home" \
    TMPDIR="$TEST_ROOT/untouched-tmp" SENTINEL_LOG="$TEST_ROOT/invoked" \
    /bin/bash "$RUNNER" "$@" >"$TEST_ROOT/output" 2>&1
}

run_guard "$TEST_ROOT/empty" --help || fail 'help should work without dependencies'
assert_contains "$TEST_ROOT/output" '--dry-run' 'help must explain the safe preview'

if run_guard "$TEST_ROOT/empty" --unsupported; then
  fail 'an unknown option must fail before any installation'
fi
assert_contains "$TEST_ROOT/output" 'unknown option' 'invalid options need an actionable error'

if run_guard "$TEST_ROOT/empty"; then
  fail 'missing dependencies must fail before any installation'
fi
assert_contains "$TEST_ROOT/output" 'claude' 'preflight must name missing Claude Code'
assert_contains "$TEST_ROOT/output" 'jq' 'preflight must name missing jq'
assert_contains "$TEST_ROOT/output" 'PATH' 'preflight must explain how to expose installed tools'

run_guard "$TEST_ROOT/tools with spaces" --dry-run || fail 'core preview should pass preflight'
assert_contains "$TEST_ROOT/output" 'core' 'preview must identify the default installation mode'
assert_contains "$TEST_ROOT/output" 'no model requests' 'preview must state its validation boundary'

run_guard "$TEST_ROOT/tools with spaces" --full --keep --dry-run || fail 'extended preview should pass preflight'
assert_contains "$TEST_ROOT/output" 'full' 'preview must identify extended mode'

mv "$TEST_ROOT/tools with spaces/jq" "$TEST_ROOT/jq-sentinel"
if run_guard "$TEST_ROOT/tools with spaces" --dry-run; then
  fail 'preview must also check required tools'
fi
assert_contains "$TEST_ROOT/output" 'jq' 'missing jq must be identified before installation'

[[ ! -e $TEST_ROOT/invoked ]] || fail 'preflight or preview started a CLI'
[[ ! -e $TEST_ROOT/untouched-home ]] || fail 'preflight or preview changed HOME'
[[ ! -e $TEST_ROOT/untouched-tmp ]] || fail 'preflight or preview created a workspace'

# Stop at the first external command. This checks the real environment boundary
# without simulating an installation or reaching the network.
mv "$TEST_ROOT/jq-sentinel" "$TEST_ROOT/tools with spaces/jq"
cat >"$TEST_ROOT/tools with spaces/git" <<'EOF'
#!/bin/sh
case "$HOME" in
  */'home with spaces') ;;
  *) printf 'fixture HOME must contain spaces\n'; exit 78 ;;
esac
[ "$CODEX_HOME" = "$HOME/.codex" ] || exit 78
[ "$CLAUDE_CONFIG_DIR" = "$HOME/.claude" ] || exit 78
[ -n "$npm_config_prefix" ] || exit 78
[ "$DO_NOT_TRACK" = 1 ] && [ "$CODEGRAPH_TELEMETRY" = 0 ] || exit 78
[ -z "${OPENAI_API_KEY-}${ANTHROPIC_API_KEY-}${SSH_AUTH_SOCK-}${GITHUB_TOKEN-}" ] || exit 78
printf 'isolated environment verified\n'
exit 78
EOF
mkdir -p "$TEST_ROOT/runtime-tmp"
if env -i PATH="$TEST_ROOT/tools with spaces:/usr/bin:/bin" \
  HOME="$TEST_ROOT/untouched-home" TMPDIR="$TEST_ROOT/runtime-tmp" \
  OPENAI_API_KEY=must-not-propagate ANTHROPIC_API_KEY=must-not-propagate \
  SSH_AUTH_SOCK=must-not-propagate GITHUB_TOKEN=must-not-propagate \
  /bin/bash "$RUNNER" --keep >"$TEST_ROOT/runtime-output" 2>&1; then
  fail 'the boundary probe must stop before installation'
fi
boundary_logs=("$TEST_ROOT/runtime-tmp"/agentic-live.*/logs/git-init.log)
[[ ${#boundary_logs[@]} -eq 1 && -f ${boundary_logs[0]} ]] || fail 'boundary probe did not reach the isolated command'
assert_contains "${boundary_logs[0]}" 'isolated environment verified' 'runtime must use a spaced HOME and strip inherited credentials'
[[ ! -e $TEST_ROOT/untouched-home ]] || fail 'runtime touched the caller HOME'

printf 'Live validation guard tests passed\n'
