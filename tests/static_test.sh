#!/usr/bin/env bash

set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.."

failures=0

fail() {
  printf 'FAIL: %s\n' "$1"
  failures=$((failures + 1))
}

pass() {
  printf 'PASS: %s\n' "$1"
}

require_file() {
  if [[ -f "$1" ]]; then
    pass "$1 exists"
  else
    fail "$1 is missing"
  fi
}

require_heading() {
  local heading=$1

  if grep -Fqx "$heading" AGENTS.md 2>/dev/null; then
    pass "AGENTS.md contains $heading"
  else
    fail "AGENTS.md is missing $heading"
  fi
}

required_files=(
  .gitignore
  LICENSE
  dependencies.env
  AGENTS.md
  CLAUDE.md
  tests/static_test.sh
)

for required_file in "${required_files[@]}"; do
  require_file "$required_file"
done

if [[ -x tests/static_test.sh ]]; then
  pass "tests/static_test.sh is executable"
else
  fail "tests/static_test.sh is not executable"
fi

if [[ -f CLAUDE.md ]] && grep -Fqx '@AGENTS.md' CLAUDE.md; then
  pass "CLAUDE.md imports AGENTS.md"
else
  fail "CLAUDE.md must contain an @AGENTS.md import"
fi

required_headings=(
  '## Repository state'
  '## CodeGraph'
  '## Development workflow'
  '## Test-driven development'
  '## Cross-repository changes'
  '## Git workflow'
  '## Verification'
  '## Instruction maintenance'
  '## Human decisions'
  '## Writing'
)

for required_heading in "${required_headings[@]}"; do
  require_heading "$required_heading"
done

public_files=()
while IFS= read -r public_file; do
  public_files+=("$public_file")
done < <(git ls-files --cached --others --exclude-standard)

for public_file in "${public_files[@]}"; do
  case "$public_file" in
    design.md|*-design.md|plan.md|*-plan.md|implementation-plan.md|*transcript*|*.jsonl|.claude/*|.codex/*|.aws/*)
      fail "$public_file is not safe to publish"
      ;;
  esac
done

if ((${#public_files[@]} > 0)); then
  em_dash=$(printf '\342\200\224')
  absolute_home_pattern='/'"Users/"'|/'"home/"'[[:alnum:]_.-]+/'
  credential_pattern='g'"hp_[[:alnum:]]{20,}"'|glp'"at-[[:alnum:]_-]{20,}"'|sk-'"[[:alnum:]_-]{20,}"'|api[_-]?key[[:space:]]*=[[:space:]]*[^[:space:]]+'

  if LC_ALL=C grep -IlZ . "${public_files[@]}" | xargs -0 grep -nF "$em_dash" >/dev/null 2>&1; then
    fail "public files contain an em dash"
  else
    pass "public files contain no em dash"
  fi

  if grep -EIn "$absolute_home_pattern" "${public_files[@]}" >/dev/null 2>&1; then
    fail "public files contain an absolute home path"
  else
    pass "public files contain no absolute home paths"
  fi

  if grep -EIn "$credential_pattern" "${public_files[@]}" >/dev/null 2>&1; then
    fail "public files contain a credential-like value"
  else
    pass "public files contain no credential-like values"
  fi
fi

if ((failures > 0)); then
  printf '\n%d static check(s) failed\n' "$failures"
  exit 1
fi

printf '\nAll static checks passed\n'
