#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash tests/static_test.sh --include-untracked
bash tests/install_test.sh
bash tests/restore_test.sh
bash tests/live_validation_test.sh
bash -n install.sh scripts/restore.sh scripts/check.sh scripts/validate-live.sh tests/install_test.sh tests/restore_test.sh tests/static_test.sh tests/live_validation_test.sh
shellcheck -x -P "$ROOT" install.sh scripts/restore.sh scripts/check.sh scripts/validate-live.sh tests/install_test.sh tests/restore_test.sh tests/static_test.sh tests/live_validation_test.sh
git diff --check

printf '\nAll checks passed\n'
