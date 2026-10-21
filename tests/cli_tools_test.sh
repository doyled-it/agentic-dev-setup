#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cli-tools-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
NODE=$(command -v node)
TAR=$(command -v tar)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$1 lacks $2"; }
new_case() {
  CASE_DIR="$WORK/$1"; export CASE_DIR
  BIN_DIR="$CASE_DIR/managed bin"; export BIN_DIR
  mkdir -p "$CASE_DIR/repo/scripts" "$CASE_DIR/tools" "$BIN_DIR" "$CASE_DIR/home" "$CASE_DIR/assets"
  if [[ -f $ROOT/scripts/ensure-cli-tools.sh ]]; then
    cp "$ROOT/scripts/ensure-cli-tools.sh" "$CASE_DIR/repo/scripts/"
  else
    printf '#!/bin/bash\nexit 0\n' > "$CASE_DIR/repo/scripts/ensure-cli-tools.sh"
  fi
  printf 'GH_VERSION=2.102.0\nUV_VERSION=0.12.18\nPYTHON_VERSION=3.12\n' > "$CASE_DIR/repo/dependencies.env"
  local tool
  for tool in bash dirname mkdir mktemp rm cp chmod gzip; do ln -s "$(command -v "$tool")" "$CASE_DIR/tools/$tool"; done
  ln -s "$NODE" "$CASE_DIR/tools/node"
  cat > "$CASE_DIR/tools/uname" <<'MOCK'
#!/bin/bash
case "$1" in -s) echo "${MOCK_OS:-Linux}";; -m) echo "${MOCK_ARCH:-x86_64}";; *) exit 9;; esac
MOCK
  cat > "$CASE_DIR/tools/curl" <<'MOCK'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$CASE_DIR/downloads"
[[ ${DOWNLOAD_FAIL:-0} == 0 ]] || exit 22
while [[ $# -gt 0 ]]; do
  case "$1" in -o|--output) out=$2; shift 2;; https://*) url=$1; shift;; *) shift;; esac
done
cp "$CASE_DIR/assets/${url##*/}" "$out"
MOCK
  cat > "$CASE_DIR/tools/tar" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE_DIR/extractions"
[[ ${EXTRACT_FAIL:-0} == 0 ]] || exit 2
exec "$REAL_TAR" "$@"
MOCK
  cat > "$CASE_DIR/gh" <<'MOCK'
#!/bin/bash
[[ $* == --version && ${BAD_GH:-0} == 0 ]] || exit 9
echo 'gh version 2.102.0'
MOCK
  cat > "$CASE_DIR/python3" <<'MOCK'
#!/bin/bash
[[ $* == --version ]] || exit 9
echo "Python ${MOCK_PYTHON:-3.12.0}"
MOCK
  cat > "$CASE_DIR/uv" <<'MOCK'
#!/bin/bash
set -eu
[[ $* != --version ]] || { echo 'uv 0.12.18'; exit 0; }
[[ $* == 'python install 3.12 --default' && $UV_PYTHON_BIN_DIR == "$BIN_DIR" && ${UV_SYSTEM_CERTS:-} == true ]] || exit 9
printf '%s\n' "$*" >> "$CASE_DIR/python-installs"
[[ ${UV_FAIL:-0} == 0 ]] || exit 8
[[ ${NO_PYTHON:-0} == 0 ]] || exit 0
cp "$CASE_DIR/python3" "$UV_PYTHON_BIN_DIR/python3"
MOCK
  chmod +x "$CASE_DIR/tools/uname" "$CASE_DIR/tools/curl" "$CASE_DIR/tools/tar" \
    "$CASE_DIR/gh" "$CASE_DIR/python3" "$CASE_DIR/uv"
}
run() {
  env HOME="$CASE_DIR/home" PATH="$BIN_DIR:$CASE_DIR/tools" REAL_TAR="$TAR" \
    UV_OFFLINE=1 UV_SYSTEM_CERTS= UV_PYTHON_INSTALL_DIR="$CASE_DIR/uv-python" \
    UV_CACHE_DIR="$CASE_DIR/uv-cache" TMPDIR="$CASE_DIR" \
    /bin/bash "$CASE_DIR/repo/scripts/ensure-cli-tools.sh" --bin-dir "$BIN_DIR" > "$CASE_DIR/output" 2>&1
}
ok() { run || { cat "$CASE_DIR/output" >&2; fail "$1"; }; printf 'PASS: %s\n' "$1"; }
bad() { if run; then fail "$1 unexpectedly succeeded"; fi; contains "$CASE_DIR/output" "$2"; printf 'PASS: %s\n' "$1"; }
existing() { cp "$CASE_DIR/$1" "$CASE_DIR/tools/$1"; }
archive() {
  local name=$1 directory=$2
  "$TAR" -czf "$CASE_DIR/assets/$name" -C "$CASE_DIR/stage" "$directory"
  "$NODE" - "$CASE_DIR/assets/$name" "$name" <<'JS' > "$CASE_DIR/assets/$name.sha256"
const fs = require('fs'), crypto = require('crypto');
console.log(crypto.createHash('sha256').update(fs.readFileSync(process.argv[2])).digest('hex') + '  ' + process.argv[3]);
JS
}
gh_asset() {
  local name=$1 directory=${1%.*}
  directory=${directory%.tar}
  mkdir -p "$CASE_DIR/stage/$directory/bin"
  cp "$CASE_DIR/gh" "$CASE_DIR/stage/$directory/bin/gh"
  archive "$name" "$directory"
  cp "$CASE_DIR/assets/$name.sha256" "$CASE_DIR/assets/gh_2.102.0_checksums.txt"
}
uv_asset() {
  local directory=$1
  mkdir -p "$CASE_DIR/stage/$directory"
  cp "$CASE_DIR/uv" "$CASE_DIR/stage/$directory/uv"
  cp "$CASE_DIR/uv" "$CASE_DIR/stage/$directory/uvx"
  archive "$directory.tar.gz" "$directory"
}
new_case present
existing gh; existing python3
ok 'preserve usable commands without downloads'
[[ ! -e $CASE_DIR/downloads && ! -e $BIN_DIR/gh && ! -e $BIN_DIR/python3 ]] || fail 'changed existing setup'

# Wrong platform URLs must fail against literal release asset fixtures.
while read -r os arch gh_name uv_name; do
  new_case "$os-$arch"
  gh_asset "$gh_name"; uv_asset "$uv_name"
  export MOCK_OS=$os MOCK_ARCH=$arch
  ok "bootstrap $os $arch"
  [[ -x $BIN_DIR/gh && -x $BIN_DIR/uv && -x $BIN_DIR/uvx && -x $BIN_DIR/python3 ]] || fail 'missing installed commands'
  contains "$CASE_DIR/downloads" 'https://github.com/cli/cli/releases/download/v2.102.0/'
  contains "$CASE_DIR/downloads" 'https://github.com/astral-sh/uv/releases/download/0.12.18/'
done <<'CASES'
Linux x86_64 gh_2.102.0_linux_amd64.tar.gz uv-x86_64-unknown-linux-musl
Linux aarch64 gh_2.102.0_linux_arm64.tar.gz uv-aarch64-unknown-linux-musl
Darwin x86_64 gh_2.102.0_macOS_amd64.zip uv-x86_64-apple-darwin
Darwin arm64 gh_2.102.0_macOS_arm64.zip uv-aarch64-apple-darwin
CASES
unset MOCK_OS MOCK_ARCH
new_case existing_uv
existing gh; existing uv
ok 'reuse existing uv'
[[ ! -e $CASE_DIR/downloads ]] || fail 'downloaded despite working uv'
new_case empty_python; existing gh; existing uv
printf '#!/bin/bash\nexit 0\n' > "$CASE_DIR/tools/python3"
chmod +x "$CASE_DIR/tools/python3"
ok 'empty Python version uses mock uv without network'
[[ ! -e $CASE_DIR/downloads && -x $BIN_DIR/python3 ]] || fail 'empty version bypassed isolated uv'
new_case upgrade_old_python
existing gh; existing uv
printf '#!/bin/bash\necho "Python 3.8.20"\n' > "$CASE_DIR/tools/python3"
chmod +x "$CASE_DIR/tools/python3"
ok 'shadow old external Python without changing it'
contains "$CASE_DIR/tools/python3" '3.8.20'
[[ -x $BIN_DIR/python3 ]] || fail 'new Python not installed'
new_case old_python
existing gh; existing uv; existing python3
MOCK_PYTHON=3.8.20 bad 'reject old python after installation' 'python3'
new_case foreign
existing gh; existing uv
printf 'manual file\n' > "$BIN_DIR/python"
bad 'preserve foreign Python path' 'python'
contains "$BIN_DIR/python" 'manual file'
[[ ! -e $CASE_DIR/python-installs ]] || fail 'invoked uv despite conflict'
new_case foreign_link
existing gh; existing uv
ln -s "$CASE_DIR/missing" "$BIN_DIR/python3"
bad 'preserve dangling Python link' 'python3'
[[ -L $BIN_DIR/python3 ]] || fail 'removed foreign link'
for conflict in gh uv uvx python3.12; do
  new_case "foreign-$conflict"
  if [[ $conflict != gh ]]; then existing gh; fi
  printf 'manual file\n' > "$BIN_DIR/$conflict"
  bad "preserve foreign $conflict" "$conflict"
  contains "$BIN_DIR/$conflict" 'manual file'
  [[ ! -e $CASE_DIR/downloads ]] || fail 'downloaded despite destination conflict'
done
new_case checksum
existing python3; gh_asset gh_2.102.0_linux_amd64.tar.gz
printf 'tampered\n' >> "$CASE_DIR/assets/gh_2.102.0_linux_amd64.tar.gz"
bad 'reject gh checksum mismatch before extraction' 'checksum'
[[ ! -e $CASE_DIR/extractions && ! -e $BIN_DIR/gh ]] || fail 'extracted unverified archive'
new_case checksum_missing
existing python3; gh_asset gh_2.102.0_linux_amd64.tar.gz
printf 'unrelated checksum\n' > "$CASE_DIR/assets/gh_2.102.0_checksums.txt"
bad 'reject missing checksum entry' 'checksum'
[[ ! -e $CASE_DIR/extractions ]] || fail 'extracted without matching checksum'
new_case uv_checksum
existing gh; uv_asset uv-x86_64-unknown-linux-musl
printf 'tampered\n' >> "$CASE_DIR/assets/uv-x86_64-unknown-linux-musl.tar.gz"
bad 'reject uv checksum mismatch before extraction' 'checksum'
[[ ! -e $CASE_DIR/extractions ]] || fail 'extracted unverified uv'
new_case download
existing python3
DOWNLOAD_FAIL=1 bad 'report download errors' 'download'
new_case extract
existing python3; gh_asset gh_2.102.0_linux_amd64.tar.gz
EXTRACT_FAIL=1 bad 'report extraction errors' 'extract'
new_case unusable
existing python3; gh_asset gh_2.102.0_linux_amd64.tar.gz
BAD_GH=1 bad 'reject unusable downloaded gh' 'gh'
new_case python_failure
existing gh; existing uv
UV_FAIL=1 bad 'report Python installation failure' 'Python'
new_case python_missing
existing gh; existing uv
NO_PYTHON=1 bad 'require working python3 after uv succeeds' 'python3'
for missing in curl tar; do
  new_case "missing-$missing"; existing python3
  rm "$CASE_DIR/tools/$missing"
  bad "report missing $missing" "$missing"
done
new_case platform
existing python3
MOCK_OS=FreeBSD bad 'reject unsupported platform' 'Unsupported'
new_case architecture
existing python3
MOCK_ARCH=ppc64 bad 'reject unsupported architecture' 'Unsupported'
new_case relative_bin
BIN_DIR=relative bad 'require absolute bin directory' 'ABSOLUTE_DIR'
printf 'All CLI tool tests passed\n'
