'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const { test } = require('node:test');

const helper = path.resolve(__dirname, '../scripts/verify-runtimes.cjs');
const load = () => require(helper);

// Independent wire peers reject missing lifecycle steps and fetch the real page.
const peer = String.raw`
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const { spawn } = require('node:child_process');
const [kind, mode, log] = process.argv.slice(2);
fs.appendFileSync(log, JSON.stringify({ pid: process.pid, cwd: process.cwd() }) + '\n');
setInterval(() => {}, 1000);
if (mode === 'stubborn') process.on('SIGTERM', () => {});
if (mode === 'descendant') {
  const child = spawn(process.execPath, ['-e', 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  fs.appendFileSync(log, JSON.stringify({ descendant: child.pid }) + '\n');
}
let initialized = false;
let notified = false;
let stopped = false;
let input = Buffer.alloc(0);
let chain = Promise.resolve();
const record = value => fs.appendFileSync(log, JSON.stringify(value) + '\n');
async function send(message) {
  const body = JSON.stringify({ jsonrpc: '2.0', ...message });
  const wire = kind === 'lsp'
    ? Buffer.from('Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncOnTeNt-LeNgTh: ' + Buffer.byteLength(body) + '\r\n\r\n' + body)
    : Buffer.from(body + '\n');
  if (mode === 'partial') {
    for (let i = 0; i < wire.length; i += 7) {
      process.stdout.write(wire.subarray(i, i + 7));
      await new Promise(resolve => setTimeout(resolve, 1));
    }
  } else process.stdout.write(wire);
}
async function handle(message) {
  record({ method: message.method });
  if (mode === 'silent' || mode === 'stubborn' || mode === 'descendant') return;
  if (mode === 'crash') {
    process.stderr.write('fixture cannot load runtime\n');
    process.exit(7);
  }
  if (mode === 'flood') { process.stdout.write('x'.repeat(100000)); return; }
  if (mode === 'stderr-flood') { process.stderr.write('x'.repeat(100000)); return; }
  if (mode === 'bad-frame') { process.stdout.write('Content-Length: nope\r\n\r\n{}'); return; }
  if (mode === 'bad-json') { process.stdout.write(kind === 'lsp' ? 'Content-Length: 1\r\n\r\n{' : '{\n'); return; }
  if (message.method === 'initialize') {
    assert.equal(message.jsonrpc, '2.0');
    assert.equal(typeof message.id, 'number');
    assert.ok(message.params.capabilities);
    if (kind === 'lsp') assert.ok('rootUri' in message.params);
    else assert.ok(message.params.protocolVersion && message.params.clientInfo.name);
    if (mode === 'rpc-error') return send({ id: message.id, error: { code: -32000, message: 'runtime initialization failed' } });
    initialized = true;
    await send({ method: 'notifications/message', params: { message: 'λ peer ready' } });
    await send({ id: 999, result: { capabilities: {} } });
    return send({ id: message.id, result: mode === 'no-capabilities' ? {} : { capabilities: { hoverProvider: true, note: 'λ' }, protocolVersion: '2024-11-05', serverInfo: { name: 'fixture', version: '1' } } });
  }
  if (message.method === 'initialized' || message.method === 'notifications/initialized') {
    assert.ok(initialized);
    notified = true;
    return;
  }
  assert.ok(initialized && notified, 'must finish initialization before using runtime');
  if (message.method === 'shutdown') {
    stopped = true;
    return send({ id: message.id, result: null });
  }
  if (message.method === 'exit') {
    assert.ok(stopped, 'shutdown must precede exit');
    process.exit(0);
  }
  assert.equal(message.method, 'tools/call');
  if (message.params.name === 'browser_close') {
    record({ closed: true });
    return send({ id: message.id, result: { isError: mode === 'close-error', content: [{ type: 'text', text: 'Browser closed' }] } });
  }
  assert.equal(message.params.name, 'browser_navigate');
  const url = new URL(message.params.arguments.url);
  assert.equal(url.hostname, '127.0.0.1');
  assert.equal(url.protocol, 'http:');
  record({ url: url.href });
  const body = await new Promise((resolve, reject) => {
    http.get(url, response => {
      assert.equal(response.statusCode, 200);
      let text = '';
      response.on('data', chunk => { text += chunk; });
      response.on('end', () => resolve(text));
    }).on('error', reject);
  });
  if (mode === 'navigate-silent') return;
  const text = mode === 'tool-error' ? 'Missing browser library fixture' : mode === 'wrong-text' ? 'An unrelated page' : body;
  return send({ id: message.id, result: { isError: mode === 'tool-error', content: [{ type: 'text', text }] } });
}
process.stdin.on('data', chunk => {
  input = Buffer.concat([input, chunk]);
  for (;;) {
    let body;
    if (kind === 'lsp') {
      const end = input.indexOf('\r\n\r\n');
      if (end < 0) return;
      const length = Number(/^Content-Length: (\d+)$/mi.exec(input.subarray(0, end).toString())[1]);
      if (input.length < end + 4 + length) return;
      body = input.subarray(end + 4, end + 4 + length);
      input = input.subarray(end + 4 + length);
    } else {
      const end = input.indexOf('\n');
      if (end < 0) return;
      body = input.subarray(0, end);
      input = input.subarray(end + 1);
    }
    const message = JSON.parse(body);
    chain = chain.then(() => handle(message)).catch(error => { console.error(error); process.exit(8); });
  }
});
`;

async function fixture(t, kind, mode = 'ok') {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'runtime protocol '));
  const script = path.join(dir, 'peer.cjs');
  const log = path.join(dir, 'events.jsonl');
  await fs.writeFile(script, peer);
  t.after(async () => {
    for (const event of await events(log)) {
      for (const pid of [event.pid, event.descendant].filter(Boolean)) {
        try { process.kill(pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
      }
    }
    await fs.rm(dir, { recursive: true, force: true });
  });
  return { command: process.execPath, args: [script, kind, mode, log], log, dir };
}

async function events(log) {
  try { return (await fs.readFile(log, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse); }
  catch (error) { if (error.code === 'ENOENT') return []; throw error; }
}

async function assertClean(spec) {
  const recorded = await events(spec.log);
  assert.ok(recorded.some(event => event.pid), 'peer must have started');
  for (const event of recorded) {
    if (event.pid) assert.throws(() => process.kill(event.pid, 0), { code: 'ESRCH' }, 'runtime child must be reaped');
    if (event.descendant) {
      for (let i = 0; i < 30; i++) {
        try { process.kill(event.descendant, 0); } catch (error) { if (error.code === 'ESRCH') break; throw error; }
        await delay(20);
      }
      assert.throws(() => process.kill(event.descendant, 0), { code: 'ESRCH' }, 'runtime descendants must be stopped');
    }
    if (event.url) await assert.rejects(new Promise((resolve, reject) => {
      http.get(event.url, response => { response.resume(); resolve(); }).on('error', reject);
    }), { code: 'ECONNREFUSED' }, 'localhost page must be closed');
  }
  return recorded;
}

test('LSP accepts partial headers, fragmented UTF-8 and unrelated messages, then shuts down', async t => {
  const spec = await fixture(t, 'lsp', 'partial');
  await load().verifyLsp('pyright', spec, { timeoutMs: 2500 });
  const log = await assertClean(spec);
  assert.deepEqual(log.filter(event => event.method).map(event => event.method), ['initialize', 'initialized', 'shutdown', 'exit']);
});

for (const [mode, expected] of [
  ['no-capabilities', /capabilities/i], ['rpc-error', /runtime initialization failed/],
  ['crash', /fixture cannot load runtime/], ['bad-frame', /Content-Length/i],
  ['bad-json', /JSON/i], ['flood', /output.*limit/i], ['stderr-flood', /output.*limit/i],
  ['silent', /timed out.*initialize/i], ['stubborn', /timed out/i], ['descendant', /timed out/i],
]) {
  test('LSP rejects ' + mode + ' and cleans its processes', { timeout: 5000 }, async t => {
    const spec = await fixture(t, 'lsp', mode);
    await assert.rejects(load().verifyLsp('typescript', spec, { timeoutMs: 700, maxBytes: 8192 }), error => {
      assert.match(error.message, /typescript/);
      assert.match(error.message, expected);
      return true;
    });
    await assertClean(spec);
  });
}

test('MCP navigates to a live localhost page, verifies returned text and closes browser', async t => {
  const spec = await fixture(t, 'mcp', 'partial');
  await load().verifyPlaywright(spec, { timeoutMs: 3000 });
  const log = await assertClean(spec);
  assert.notEqual(log[0].cwd, process.cwd(), 'browser probe must not write into the caller workspace');
  await assert.rejects(fs.stat(log[0].cwd), { code: 'ENOENT' });
  assert.deepEqual(log.filter(event => event.method).map(event => event.method), ['initialize', 'notifications/initialized', 'tools/call', 'tools/call']);
});

for (const [mode, expected] of [
  ['wrong-text', /synthetic|page text/i], ['tool-error', /browser_navigate.*isError.*Missing browser library fixture/i],
  ['close-error', /browser_close.*isError/i],
  ['navigate-silent', /timed out.*browser_navigate/i], ['bad-json', /JSON/i],
]) {
  test('MCP rejects ' + mode + ' and releases browser process and page', { timeout: 5000 }, async t => {
    const spec = await fixture(t, 'mcp', mode);
    await assert.rejects(load().verifyPlaywright(spec, { timeoutMs: 700 }), expected);
    const log = await assertClean(spec);
    if (['wrong-text', 'tool-error', 'close-error'].includes(mode)) {
      assert.ok(log.some(event => event.closed), 'browser_close must be attempted after navigation replies');
    }
  });
}

test('spawn failures identify the runtime and executable', async () => {
  await assert.rejects(load().verifyLsp('pyright', { command: '/nonexistent/runtime', args: ['--stdio'] }), /pyright.*nonexistent\/runtime.*ENOENT/);
});

async function runCli(args) {
  const child = spawn(process.execPath, [helper, ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  const timer = setTimeout(() => child.kill('SIGKILL'), 10000);
  const code = await new Promise(resolve => child.on('close', resolve));
  clearTimeout(timer);
  return { code, stdout, stderr };
}

test('CLI reads a manifest with spaced paths and prints one PASS per verified runtime', async t => {
  const pyright = await fixture(t, 'lsp');
  const typescript = await fixture(t, 'lsp');
  const playwright = await fixture(t, 'mcp');
  const manifest = path.join(pyright.dir, 'manifest.json');
  await fs.writeFile(manifest, JSON.stringify({ pyright, typescript, playwright }));
  const result = await runCli([manifest]);
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout, 'PASS pyright\nPASS typescript\nPASS playwright\n');
  assert.equal(result.stderr, '');
  await Promise.all([pyright, typescript, playwright].map(assertClean));
});

test('CLI fails clearly on missing, malformed or incomplete manifests', async t => {
  const spec = await fixture(t, 'lsp');
  const manifest = path.join(spec.dir, 'manifest.json');
  for (const [args, contents, expected] of [
    [[], '', /Usage:/], [[manifest], '{', /JSON|manifest/i],
    [[manifest], '{}', /pyright.*absolute.*command/i],
    [[manifest], JSON.stringify({ pyright: { command: 'node', args: [] } }), /pyright.*absolute/i],
  ]) {
    await fs.writeFile(manifest, contents);
    const result = await runCli(args);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, expected);
    assert.equal(result.stdout, '');
  }
});

test('CLI runtime failure exits nonzero with diagnostics and no false PASS', async t => {
  const spec = await fixture(t, 'lsp', 'rpc-error');
  const manifest = path.join(spec.dir, 'manifest.json');
  await fs.writeFile(manifest, JSON.stringify({ pyright: spec, typescript: spec, playwright: spec }));
  const result = await runCli([manifest]);
  assert.notEqual(result.code, 0);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /pyright.*runtime initialization failed/);
  await assertClean(spec);
});
