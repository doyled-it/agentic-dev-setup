#!/usr/bin/env bash
# Install missing plugin CLI runtimes into an operator-selected directory.
set -euo pipefail

fail() { printf 'ensure-cli-tools: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 && $1 == --bin-dir && $2 == /* ]] || fail 'Usage: bash scripts/ensure-cli-tools.sh --bin-dir ABSOLUTE_DIR'
BIN_DIR=$2
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=dependencies.env
source "$ROOT/dependencies.env"
mkdir -p "$BIN_DIR" || fail "Cannot create bin directory: $BIN_DIR"
export PATH="$BIN_DIR:$PATH"
WORK=''
cleanup() { if [[ -n $WORK ]]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

require_command() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required to download and extract CLI tools; make it available on PATH and retry."; }
vacant() {
  [[ ! -e $1 && ! -L $1 ]] || fail "Refusing to overwrite existing path: $1. Move it yourself or choose a different --bin-dir."
}
python_usable() {
  local version regex='^Python[[:space:]]+([0-9]+)\.([0-9]+)(\.|[[:space:]]|$)'
  version=$(python3 --version 2>&1) || return 1
  [[ $version =~ $regex ]] || return 1
  (( 10#${BASH_REMATCH[1]} > 3 || (10#${BASH_REMATCH[1]} == 3 && 10#${BASH_REMATCH[2]} >= 9) ))
}
platform() {
  local os machine
  os=$(uname -s); machine=$(uname -m)
  case "$os" in
    Darwin) GH_OS=macOS; GH_EXTENSION=zip; UV_PLATFORM=apple-darwin ;;
    Linux) GH_OS=linux; GH_EXTENSION=tar.gz; UV_PLATFORM=unknown-linux-musl ;;
    *) fail "Unsupported platform: $os. Install gh and Python 3.9+ manually and retry." ;;
  esac
  case "$machine" in
    x86_64|amd64) GH_ARCH=amd64; UV_ARCH=x86_64 ;;
    arm64|aarch64) GH_ARCH=arm64; UV_ARCH=aarch64 ;;
    *) fail "Unsupported architecture: $machine. Install gh and Python 3.9+ manually and retry." ;;
  esac
}
download_extract() {
  local name=$1 base=$2 asset=$3 checksum=$4
  require_command curl
  require_command tar
  require_command node
  if [[ -z $WORK ]]; then WORK=$(mktemp -d "${TMPDIR:-/tmp}/ensure-cli-tools.XXXXXX") || fail 'Cannot create download directory'; fi
  EXTRACTED_DIR="$WORK/$name"
  mkdir -p "$EXTRACTED_DIR"
  curl -fsSL --retry 3 --output "$WORK/$asset" "$base/$asset" || fail "Failed to download $asset from $base"
  curl -fsSL --retry 3 --output "$WORK/$checksum" "$base/$checksum" || fail "Failed to download checksum file $checksum"
  node - "$WORK/$asset" "$WORK/$checksum" "$asset" <<'JS' || fail "SHA256 checksum verification failed for $asset; no archive was extracted."
const fs = require('fs'), crypto = require('crypto');
const [archive, checksumFile, asset] = process.argv.slice(2);
const matches = fs.readFileSync(checksumFile, 'utf8').split(/\r?\n/).map(line =>
  /^([a-fA-F0-9]{64})\s+\*?(.+?)\s*$/.exec(line)
).filter(match => match && match[2] === asset);
const actual = crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
if (matches.length !== 1 || matches[0][1].toLowerCase() !== actual) {
  console.error(`Missing, ambiguous, or mismatched checksum for ${asset}`);
  process.exit(1);
}
JS
  # macOS ships libarchive tar, which also extracts the official macOS ZIP.
  tar -xf "$WORK/$asset" -C "$EXTRACTED_DIR" || fail "Failed to extract $asset"
}
copy_tool() {
  local candidate=$1 name=$2
  vacant "$BIN_DIR/$name"
  chmod +x "$candidate" || fail "Downloaded $name executable is missing"
  "$candidate" --version >/dev/null 2>&1 || fail "Downloaded $name is unusable on this platform"
  cp -n "$candidate" "$BIN_DIR/$name" || fail "Cannot install $name into $BIN_DIR"
  hash -r
}

if ! gh --version >/dev/null 2>&1; then
  : "${GH_VERSION:?Set GH_VERSION in dependencies.env}"
  vacant "$BIN_DIR/gh"
  platform
  gh_stem="gh_${GH_VERSION}_${GH_OS}_${GH_ARCH}"
  download_extract gh "https://github.com/cli/cli/releases/download/v${GH_VERSION}" \
    "$gh_stem.$GH_EXTENSION" "gh_${GH_VERSION}_checksums.txt"
  copy_tool "$EXTRACTED_DIR/$gh_stem/bin/gh" gh
fi
gh --version >/dev/null 2>&1 || fail 'gh is still unusable; check --bin-dir permissions and PATH.'

if ! python_usable; then
  : "${PYTHON_VERSION:?Set PYTHON_VERSION in dependencies.env}"
  for python_name in python python3 "python$PYTHON_VERSION"; do vacant "$BIN_DIR/$python_name"; done
  if ! uv --version >/dev/null 2>&1; then
    : "${UV_VERSION:?Set UV_VERSION in dependencies.env}"
    vacant "$BIN_DIR/uv"
    vacant "$BIN_DIR/uvx"
    platform
    uv_stem="uv_${UV_VERSION}"
    uv_archive="uv-${UV_ARCH}-${UV_PLATFORM}.tar.gz"
    download_extract "$uv_stem" "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}" \
      "$uv_archive" "$uv_archive.sha256"
    for uv_name in uv uvx; do copy_tool "$EXTRACTED_DIR/${uv_archive%.tar.gz}/$uv_name" "$uv_name"; done
  fi
  uv --version >/dev/null 2>&1 || fail 'uv is unusable; check --bin-dir permissions and PATH.'
  UV_SYSTEM_CERTS="${UV_SYSTEM_CERTS:-true}" UV_PYTHON_BIN_DIR="$BIN_DIR" \
    uv python install "$PYTHON_VERSION" --default \
    || fail "Python installation failed. Check network access and write permissions for $BIN_DIR and the uv data directory."
  hash -r
fi
python_usable || fail "python3 >=3.9 is still unavailable. Ensure $BIN_DIR is first on PATH and resolve any conflicting Python links without using --force."
printf 'gh and python3 >=3.9 are available\n'
