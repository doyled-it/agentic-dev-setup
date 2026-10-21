#!/usr/bin/env bash

set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=dependencies.env
source "$ROOT/dependencies.env"
CLAUDE=false
CODEX=false
PREFLIGHT=false
for option in "$@"; do
  case "$option" in
    --claude) CLAUDE=true ;;
    --codex) CODEX=true ;;
    --preflight) PREFLIGHT=true ;;
    *) printf 'error: unknown runtime option: %s\n' "$option" >&2; exit 2 ;;
  esac
done
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || die '--full requires Node.js 22.22.2 or newer on PATH'
command -v npm >/dev/null 2>&1 || die '--full requires npm on PATH'
version=$(node --version)
IFS=. read -r major minor patch <<<"${version#v}"
if ((major < 22 || (major == 22 && (minor < 22 || (minor == 22 && patch < 2))))); then
  die '--full requires Node.js 22.22.2 or newer for the TypeScript language server'
fi
[[ $PREFLIGHT == false ]] || exit 0
[[ $CLAUDE == true || $CODEX == true ]] || die 'select --claude, --codex, or both'
NODE=$(command -v node)
prefix=$(npm prefix -g)
[[ $prefix == /* ]] || die 'npm must report an absolute global prefix'
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) die "Add $prefix/bin to PATH before running --full so installed tools remain available to restarted agents" ;;
esac
bash "$ROOT/scripts/ensure-cli-tools.sh" --bin-dir "$prefix/bin"
gh --version >/dev/null 2>&1 || die "The active gh command is unusable; put $prefix/bin ahead of conflicting PATH entries"
active_python=$(python3 --version 2>&1)
if ! node - "$active_python" <<'JS'
const match = /^Python (\d+)\.(\d+)/.exec(process.argv[2]);
process.exit(match && (+match[1] > 3 || (+match[1] === 3 && +match[2] >= 9)) ? 0 : 1);
JS
then die "The active Python is too old; put $prefix/bin ahead of conflicting PATH entries"; fi
versions=$(npm list -g --depth=0 --json 2>/dev/null || true)
if ! node - "$versions" "$PYRIGHT_VERSION" "$TYPESCRIPT_LANGUAGE_SERVER_VERSION" "$TYPESCRIPT_VERSION" "$PLAYWRIGHT_MCP_VERSION" <<'JS'
const wanted = ['pyright', 'typescript-language-server', 'typescript', '@playwright/mcp'];
let installed;
try { installed = JSON.parse(process.argv[2]).dependencies || {}; } catch { process.exit(1); }
process.exit(wanted.every((name, i) => installed[name]?.version === process.argv[i + 3]) ? 0 : 1);
JS
then
  npm install -g "pyright@$PYRIGHT_VERSION" "typescript-language-server@$TYPESCRIPT_LANGUAGE_SERVER_VERSION" \
    "typescript@$TYPESCRIPT_VERSION" "@playwright/mcp@$PLAYWRIGHT_MCP_VERSION"
fi
modules=$(npm root -g)
MCP="$modules/@playwright/mcp/cli.js"
[[ -f $MCP ]] || die 'Playwright MCP did not install its executable'
printf '==> Downloading the matching Chromium browser\n'
node "$MCP" install-browser chromium
browser=$(node - "$modules/@playwright/mcp" <<'JS'
const {createRequire} = require('node:module');
const {join} = require('node:path');
const fromMcp = createRequire(join(process.argv[2], 'package.json'));
console.log(fromMcp('playwright').chromium.executablePath());
JS
)
[[ -x $browser ]] || die 'Chromium download did not produce an executable'
config="$HOME/.config/agentic-dev-setup/playwright.json"
manifest="$HOME/.config/agentic-dev-setup/runtimes.json"
mkdir -p "$(dirname "$config")"
[[ ! -L $config && ! -L $manifest ]] || die 'runtime configuration must not be a symlink'
for binary in pyright-langserver typescript-language-server; do
  active=$(command -v "$binary") || die "$binary is not on PATH after installation"
  if ! node - "$active" "$prefix/bin/$binary" <<'JS'
const fs = require('node:fs');
process.exit(fs.realpathSync(process.argv[2]) === fs.realpathSync(process.argv[3]) ? 0 : 1);
JS
  then die "$binary is shadowed on PATH; put $prefix/bin ahead of the conflicting executable"; fi
done
pyright="$prefix/bin/pyright-langserver"
typescript="$prefix/bin/typescript-language-server"
node - "$config" "$manifest" "$NODE" "$MCP" "$browser" "$pyright" "$typescript" <<'JS'
const fs = require('node:fs');
const [config, manifest, node, mcp, executablePath, pyright, typescript] = process.argv.slice(2);
fs.writeFileSync(config, JSON.stringify({browser: {browserName: 'chromium', isolated: true,
  launchOptions: {executablePath, headless: true}}}, null, 2) + '\n', {mode: 0o600});
fs.writeFileSync(manifest, JSON.stringify({
  pyright: {command: pyright, args: ['--stdio']},
  typescript: {command: typescript, args: ['--stdio']},
  playwright: {command: node, args: [mcp, '--config', config]}
}, null, 2) + '\n', {mode: 0o600});
JS
node "$ROOT/scripts/verify-runtimes.cjs" "$manifest"

# This reserved name belongs to this setup. Preserve a foreign definition.
if [[ $CLAUDE == true ]]; then
  existing=$(claude mcp get agentic-playwright 2>/dev/null || true)
  if [[ -n $existing ]]; then
    if ! node - "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" "$NODE" "$MCP" "$config" <<'JS'
const fs = require('node:fs');
const [file, command, mcp, config] = process.argv.slice(2);
const actual = JSON.parse(fs.readFileSync(file, 'utf8')).mcpServers?.['agentic-playwright'];
process.exit(actual?.type === 'stdio' && actual.command === command &&
  JSON.stringify(actual.args) === JSON.stringify([mcp, '--config', config]) &&
  Object.keys(actual.env || {}).length === 0 ? 0 : 1);
JS
    then die 'Claude agentic-playwright is already configured differently; preserved its definition'; fi
  else
    claude mcp add --scope user agentic-playwright -- "$NODE" "$MCP" --config "$config" >/dev/null
  fi
fi
if [[ $CODEX == true ]]; then
  existing=$(codex mcp get agentic-playwright --json 2>/dev/null || true)
  if [[ -n $existing ]]; then
    if ! node - "$existing" "$NODE" "$MCP" "$config" <<'JS'
const [data, command, mcp, config] = process.argv.slice(2);
const actual = JSON.parse(data).transport;
process.exit(actual?.command === command && JSON.stringify(actual.args) === JSON.stringify([mcp, '--config', config]) ? 0 : 1);
JS
    then die 'Codex agentic-playwright is already configured differently; preserved its definition'; fi
  else
    codex mcp add agentic-playwright -- "$NODE" "$MCP" --config "$config" >/dev/null
  fi
fi
printf '==> Full runtime dependencies downloaded and verified\n'
