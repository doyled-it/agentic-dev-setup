#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash tests/static_test.sh --include-untracked
bash tests/install_test.sh
bash tests/restore_test.sh
bash tests/live_validation_test.sh
bash tests/cli_tools_test.sh
node --test tests/runtime_protocol.test.cjs
node --check scripts/verify-runtimes.cjs
bash -n install.sh scripts/restore.sh scripts/check.sh scripts/validate-live.sh scripts/install-full-runtime.sh scripts/ensure-cli-tools.sh tests/install_test.sh tests/restore_test.sh tests/static_test.sh tests/live_validation_test.sh tests/cli_tools_test.sh
shellcheck -x -P "$ROOT" install.sh scripts/restore.sh scripts/check.sh scripts/validate-live.sh scripts/install-full-runtime.sh scripts/ensure-cli-tools.sh tests/install_test.sh tests/restore_test.sh tests/static_test.sh tests/live_validation_test.sh tests/cli_tools_test.sh
git diff --check

printf '\nAll checks passed\n'
