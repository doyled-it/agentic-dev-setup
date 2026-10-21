#!/usr/bin/env bash

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit

failures=0
include_untracked=false

case "${1-}" in
  '')
    ;;
  --include-untracked)
    include_untracked=true
    ;;
  *)
    printf 'Usage: %s [--include-untracked]\n' "$0" >&2
    exit 2
    ;;
esac

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

require_ignored_path() {
  local ignored_path=$1
  local status

  if git -c core.excludesFile=/dev/null check-ignore -q --no-index -- "$ignored_path"; then
    pass "$ignored_path is ignored"
  else
    status=$?
    if ((status == 1)); then
      fail "$ignored_path must be ignored"
    else
      fail "could not verify ignore rules for $ignored_path"
    fi
  fi
}

require_no_match() {
  local failure_message=$1
  local pass_message=$2
  local status
  shift 2

  if "$@" >/dev/null 2>&1; then
    fail "$failure_message"
  else
    status=$?
    if ((status == 1)); then
      pass "$pass_message"
    else
      fail "$failure_message because the scan exited with status $status"
    fi
  fi
}

git_remote_host() {
  local remote=$1
  local host

  if [[ $remote =~ ^(ssh|git)://([^/@[:space:]]+@)?([^/:[:space:]]+) ]]; then
    host=${BASH_REMATCH[3]}
  elif [[ $remote =~ ^https?://([^/@[:space:]]+@)?([^/:[:space:]]+) ]]; then
    host=${BASH_REMATCH[2]}
  elif [[ $remote =~ ^[[:alnum:]_.-]+@([^:[:space:]]+): ]]; then
    host=${BASH_REMATCH[1]}
  else
    return 1
  fi

  printf '%s' "$host" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

is_public_git_host() {
  case "$1" in
    github.com|gist.github.com|gitlab.com|bitbucket.org|codeberg.org|git.sr.ht|code.claude.com|developers.openai.com|docs.github.com)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_public_git_hosts() {
  local git_remote_pattern
  local matches
  local public_file
  local remote
  local host
  local status

  git_remote_pattern="(ssh|git)://([^/@[:space:]]+@)?[[:alnum:].-]+(:[[:digit:]]+)?/[^[:space:]<>\"']+|https?://([^/@[:space:]]+@)?[[:alnum:].-]+(:[[:digit:]]+)?/[^[:space:]<>\"']+|[[:alnum:]_.-]+@[[:alnum:].-]+:[^[:space:]<>\"']+"

  for public_file in "${public_files[@]}"; do
    if matches=$(LC_ALL=C grep -IEo "$git_remote_pattern" -- "$public_file"); then
      while IFS= read -r remote; do
        if ! host=$(git_remote_host "$remote"); then
          fail "could not parse a Git remote in $public_file"
          return
        fi
        if ! is_public_git_host "$host"; then
          fail "public files contain a non-public Git host"
          return
        fi
      done <<< "$matches"
    else
      status=$?
      if ((status != 1)); then
        fail "could not scan $public_file for Git remotes"
        return
      fi
    fi
  done

  pass "public files contain only allowlisted public hosts"
}

required_files=(
  .gitignore
  .github/workflows/ci.yml
  LICENSE
  README.md
  SECURITY.md
  dependencies.env
  AGENTS.md
  CLAUDE.md
  docs/multi-repo.md
  docs/removal.md
  docs/tools.md
  docs/workflow.md
  prompts/README.md
  prompts/discovery.md
  prompts/finish.md
  prompts/implementation.md
  prompts/multi-repo.md
  prompts/review.md
  scripts/check.sh
  tests/restore_test.sh
  tests/static_test.sh
)

for required_file in "${required_files[@]}"; do
  require_file "$required_file"
done

required_executables=(
  install.sh
  scripts/check.sh
  scripts/restore.sh
  tests/install_test.sh
  tests/restore_test.sh
  tests/static_test.sh
)

for required_executable in "${required_executables[@]}"; do
  if [[ -x $required_executable ]]; then
    pass "$required_executable is executable"
  else
    fail "$required_executable is not executable"
  fi
done

if [[ -f CLAUDE.md ]] && grep -Fqx '@AGENTS.md' CLAUDE.md; then
  pass "CLAUDE.md imports AGENTS.md"
else
  fail "CLAUDE.md must contain an @AGENTS.md import"
fi

required_readme_text=(
  './install.sh'
  './install.sh --full'
  './install.sh --dry-run'
  './scripts/restore.sh latest'
  'https://github.com/doyled-it/claude-skills'
  'https://github.com/obra/superpowers'
  'https://github.com/colbymchenry/codegraph'
  'docs/workflow.md'
  'docs/multi-repo.md'
  'prompts/README.md'
)

for required_text in "${required_readme_text[@]}"; do
  if [[ -f README.md ]] && grep -Fq -- "$required_text" README.md; then
    pass "README.md contains $required_text"
  else
    fail "README.md is missing $required_text"
  fi
done

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

required_ignored_paths=(
  .env
  nested/.env.production
  nested/signing.key
  nested/private.pem
  nested/service-account.json
  nested/.claude/state.json
  nested/.codex/state.json
  nested/.agents/state.json
  nested/.aws/credentials
)

for required_ignored_path in "${required_ignored_paths[@]}"; do
  require_ignored_path "$required_ignored_path"
done

public_files=()
file_list=$(mktemp "${TMPDIR:-/tmp}/agentic-dev-static.XXXXXX") || {
  fail "could not create the temporary file list"
  file_list=''
}

if [[ -n $file_list ]]; then
  trap 'rm -f -- "$file_list"' EXIT

  if $include_untracked; then
    if ! git ls-files -z --cached --others --exclude-standard -- >"$file_list"; then
      fail "could not enumerate tracked and untracked files"
    fi
  elif ! git ls-files -z --cached -- >"$file_list"; then
    fail "could not enumerate tracked files"
  fi

  while IFS= read -r -d '' public_file; do
    public_files+=("$public_file")
  done <"$file_list"
fi

for public_file in "${public_files[@]}"; do
  public_basename=${public_file##*/}
  case "$public_basename" in
    design.md|*-design.md|plan.md|*-plan.md)
      fail "$public_file is not safe to publish"
      ;;
  esac
  case "/$public_file" in
    *transcript*|*.jsonl|*/.claude/*|*/.codex/*|*/.agents/*|*/.aws/*)
      fail "$public_file is not safe to publish"
      ;;
  esac
done

if ((${#public_files[@]} > 0)); then
  em_dash=$(printf '\342\200\224')
  absolute_home_pattern='/'"Users/"'|/'"home/"'[[:alnum:]_.-]+/'
  credential_pattern='g'"h[pousr]_[[:alnum:]]{20,}"'|github_pat_[[:alnum:]_]{20,}|glp'"at-[[:alnum:]_-]{20,}"'|sk-'"[[:alnum:]_-]{20,}"'|api[_-]?key[[:space:]]*=[[:space:]]*[^[:space:]]+|A(KIA|SIA)[A-Z0-9]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'

  require_no_match \
    "public files contain an em dash" \
    "public files contain no em dash" \
    env LC_ALL=C grep -IFn "$em_dash" -- "${public_files[@]}"

  require_no_match \
    "public files contain an absolute home path" \
    "public files contain no absolute home paths" \
    env LC_ALL=C grep -IEn "$absolute_home_pattern" -- "${public_files[@]}"

  require_no_match \
    "public files contain a credential-like value" \
    "public files contain no credential-like values" \
    env LC_ALL=C grep -IEn "$credential_pattern" -- "${public_files[@]}"

  require_public_git_hosts
else
  fail "no files were available for public-safety scanning"
fi

if ((failures > 0)); then
  printf '\n%d static check(s) failed\n' "$failures"
  exit 1
fi

printf '\nAll static checks passed\n'
