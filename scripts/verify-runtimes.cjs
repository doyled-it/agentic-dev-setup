'use strict';

const { spawn } = require('node:child_process');
const { randomBytes } = require('node:crypto');
const fs = require('node:fs/promises');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');

function validate(name, spec) {
  if (!spec || typeof spec.command !== 'string' || !path.isAbsolute(spec.command)
      || !Array.isArray(spec.args) || !spec.args.every(arg => typeof arg === 'string')) {
    throw new Error(`${name}: provide an absolute command and an array of string args in the manifest`);
  }
}

class Rpc {
  constructor(spec, framing, { timeoutMs = 20000, maxBytes = 2 * 1024 * 1024, cwd, env } = {}) {
    this.framing = framing;
    this.maxBytes = maxBytes;
    this.buffer = Buffer.alloc(0);
    this.bytes = 0;
    this.stderr = '';
    this.pending = new Map();
    this.nextId = 0;
    this.child = spawn(spec.command, spec.args, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'], detached: process.platform !== 'win32' });
    this.exited = new Promise(resolve => {
      this.child.once('exit', resolve);
      this.child.once('error', resolve);
    });
    this.child.on('error', error => this.fail(error));
    this.child.on('close', (code, signal) => {
      if (!this.closing) this.fail(new Error(`runtime exited (${signal || code}) before completing the protocol`));
    });
    this.child.stdin.on('error', error => this.fail(error));
    this.child.stdout.on('data', chunk => this.receive(chunk));
    this.child.stderr.on('data', chunk => {
      this.stderr = (this.stderr + chunk.toString()).slice(-1000);
      this.account(chunk.length);
    });
    this.timer = setTimeout(() => {
      const step = [...this.pending.values()].map(entry => entry.method).join(', ');
      this.fail(new Error(`timed out after ${timeoutMs}ms waiting for ${step || 'runtime'}; check the installed runtime and executable paths`));
    }, timeoutMs);
  }

  fail(error) {
    this.error ||= error;
    for (const entry of this.pending.values()) entry.reject(this.error);
    this.pending.clear();
  }

  account(length) {
    this.bytes += length;
    if (this.bytes > this.maxBytes) this.fail(new Error(`runtime output exceeded limit of ${this.maxBytes} bytes`));
    return !this.error;
  }

  receive(chunk) {
    if (!this.account(chunk.length)) return;
    this.buffer = Buffer.concat([this.buffer, chunk]);
    try {
      for (;;) {
        let body;
        if (this.framing === 'lsp') {
          const end = this.buffer.indexOf('\r\n\r\n');
          if (end < 0) return;
          const header = this.buffer.subarray(0, end).toString('ascii');
          const lengths = [...header.matchAll(/^Content-Length:\s*(\d+)\s*$/gmi)];
          if (lengths.length !== 1) throw new Error('invalid LSP Content-Length header');
          const length = Number(lengths[0][1]);
          if (!Number.isSafeInteger(length) || length > this.maxBytes) throw new Error('LSP Content-Length exceeds output limit');
          if (this.buffer.length < end + 4 + length) return;
          body = this.buffer.subarray(end + 4, end + 4 + length);
          this.buffer = this.buffer.subarray(end + 4 + length);
        } else {
          const end = this.buffer.indexOf('\n');
          if (end < 0) return;
          body = this.buffer.subarray(0, end);
          this.buffer = this.buffer.subarray(end + 1);
        }
        const message = JSON.parse(body.toString('utf8'));
        if (!message || message.jsonrpc !== '2.0') throw new Error('invalid JSON-RPC message');
        const entry = this.pending.get(message.id);
        if (!entry) continue;
        this.pending.delete(message.id);
        if (message.error) entry.reject(new Error(`${entry.method}: JSON-RPC error ${message.error.code}: ${String(message.error.message).slice(0, 500)}`));
        else if ('result' in message) entry.resolve(message.result);
        else entry.reject(new Error(`${entry.method}: JSON-RPC response is missing result`));
      }
    } catch (error) {
      this.fail(new Error(`invalid runtime JSON-RPC output: ${error.message}`));
    }
  }

  send(message) {
    if (this.error) throw this.error;
    const body = JSON.stringify({ jsonrpc: '2.0', ...message });
    this.child.stdin.write(this.framing === 'lsp'
      ? `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}` : `${body}\n`);
  }

  request(method, params) {
    return new Promise((resolve, reject) => {
      const id = ++this.nextId;
      this.pending.set(id, { resolve, reject, method: `${method}${params?.name ? ` ${params.name}` : ''}` });
      try { this.send({ id, method, params }); } catch (error) { this.fail(error); }
    });
  }

  notify(method) { this.send({ method, params: {} }); }

  async close() {
    this.closing = true;
    clearTimeout(this.timer);
    this.child.stdin.end();
    await Promise.race([this.exited, delay(150)]);
    const kill = signal => {
      if (!this.child.pid) return;
      try {
        if (process.platform === 'win32') this.child.kill(signal);
        else process.kill(-this.child.pid, signal);
      } catch (error) { if (error.code !== 'ESRCH') throw error; }
    };
    kill('SIGTERM');
    await delay(100);
    kill('SIGKILL');
    await Promise.race([this.exited, delay(150)]);
    this.child.stdin.destroy();
    this.child.stdout.destroy();
    this.child.stderr.destroy();
  }
}

async function withRuntime(name, spec, framing, options, probe) {
  validate(name, spec);
  const rpc = new Rpc(spec, framing, options);
  try {
    await probe(rpc);
    if (rpc.error) throw rpc.error;
  } catch (error) {
    const detail = rpc.stderr.trim().replace(/\s+/g, ' ');
    throw new Error(`${name} (${spec.command}): ${error.message}${detail ? `; stderr: ${detail}` : ''}`);
  } finally {
    await rpc.close();
  }
}

function capabilities(result) {
  if (!result || !result.capabilities || typeof result.capabilities !== 'object' || Array.isArray(result.capabilities)) {
    throw new Error('initialize did not return result.capabilities; check the runtime installation');
  }
}

async function verifyLsp(name, spec, options) {
  await withRuntime(name, spec, 'lsp', options, async rpc => {
    capabilities(await rpc.request('initialize', { processId: process.pid, rootUri: null, capabilities: {} }));
    rpc.notify('initialized');
    await rpc.request('shutdown', null);
    rpc.notify('exit');
  });
}

async function verifyPlaywright(spec, options) {
  validate('playwright', spec);
  const cwd = await fs.mkdtemp(path.join(process.platform === 'darwin' ? '/tmp' : os.tmpdir(), 'ad-browser-'));
  const marker = `runtime-verification-${randomBytes(16).toString('hex')}`;
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    response.end(`<!doctype html><html><head><title>${marker}</title><link rel="icon" href="data:,"></head><body><p>${marker}</p></body></html>`);
  });
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    await withRuntime('playwright', spec, 'mcp', { ...options, cwd,
      env: { ...process.env, PWTEST_SOCKETS_DIR: cwd } }, async rpc => {
      capabilities(await rpc.request('initialize', {
        protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'runtime-verifier', version: '1.0.0' },
      }));
      rpc.notify('notifications/initialized');
      const call = async (name, args) => {
        const result = await rpc.request('tools/call', { name, arguments: args });
        if (!result || result.isError) {
          const detail = result?.content?.filter(item => item?.type === 'text').map(item => item.text).join(' ').slice(-1800) || '';
          throw new Error(`${name} returned ${result?.isError ? 'isError' : 'no result'}: ${detail}; check Chromium and the MCP installation`);
        }
        return result;
      };
      let failure;
      try {
        const result = await call('browser_navigate', { url: `http://127.0.0.1:${server.address().port}/` });
        if (!Array.isArray(result.content) || !result.content.some(item => item?.type === 'text' && typeof item.text === 'string' && item.text.includes(marker))) {
          throw new Error('browser_navigate did not return the synthetic page text: ' + JSON.stringify(result).slice(-1800));
        }
      } catch (error) { failure = error; }
      try { if (!rpc.error) await call('browser_close', {}); } catch (error) { failure ||= error; }
      if (failure) throw failure;
    });
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    await fs.rm(cwd, { recursive: true, force: true });
  }
}

async function verifyRuntimes(manifest, options, report = line => console.log(line)) {
  for (const name of ['pyright', 'typescript', 'playwright']) validate(name, manifest?.[name]);
  for (const name of ['pyright', 'typescript']) {
    await verifyLsp(name, manifest[name], options);
    report(`PASS ${name}`);
  }
  await verifyPlaywright(manifest.playwright, options);
  report('PASS playwright');
}

module.exports = { verifyLsp, verifyPlaywright, verifyRuntimes };

if (require.main === module) {
  (async () => {
    if (process.argv.length !== 3) throw new Error('Usage: node scripts/verify-runtimes.cjs <manifest.json>');
    const manifest = JSON.parse(await fs.readFile(process.argv[2], 'utf8'));
    await verifyRuntimes(manifest);
  })().catch(error => {
    console.error(`FAIL ${error.message.slice(0, 2500)}`);
    process.exitCode = 1;
  });
}
