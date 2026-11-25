import { spawn } from 'node:child_process';
import readline from 'node:readline';

const codexPath = process.argv.find((arg) => arg.startsWith('--codex='))?.slice('--codex='.length) ?? 'codex.cmd';
const command = `& '${codexPath.replaceAll("'", "''")}' app-server`;
const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command], {
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
});
let stderr = '';
child.stderr.on('data', (chunk) => { stderr += chunk.toString().slice(0, 2000); });
const shutdown = () => {
  child.stdin.end();
  setTimeout(() => child.kill(), 3000).unref();
};
const timeout = setTimeout(() => {
  process.stderr.write('Timed out waiting for Codex account/read.\n');
  if (stderr) process.stderr.write(stderr + '\n');
  child.kill();
  process.exitCode = 1;
}, 15000);
let finished = false;
let accountInfo = null;
const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);
const lines = readline.createInterface({ input: child.stdout });
lines.on('line', (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (message.id === 0) {
    if (message.error) {
      process.stderr.write(`Codex initialize failed: ${message.error.message}\n`);
      process.exitCode = 1;
      shutdown();
      return;
    }
    send({ method: 'initialized', params: {} });
    send({ method: 'account/read', id: 1, params: { refreshToken: process.argv.includes('--refresh') } });
  } else if (message.id === 1) {
    if (message.error) {
      process.stderr.write(`Codex account/read failed: ${message.error.message}\n`);
      process.exitCode = 1;
      finished = true;
      clearTimeout(timeout);
      shutdown();
      return;
    }
    const account = message.result?.account;
    accountInfo = { type: account?.type ?? null, email: account?.email ?? null };
    if (process.argv.includes('--limits')) {
      send({ method: 'account/rateLimits/read', id: 2 });
      return;
    }
    finished = true;
    clearTimeout(timeout);
    process.stdout.write(JSON.stringify(accountInfo) + '\n');
    shutdown();
  } else if (message.id === 2) {
    finished = true;
    clearTimeout(timeout);
    const rate = message.result?.rateLimits;
    process.stdout.write(JSON.stringify({ ...accountInfo, rateLimits: rate ? {
      limitId: rate.limitId,
      primary: rate.primary,
      secondary: rate.secondary,
    } : null, error: message.error?.message ?? null }) + '\n');
    shutdown();
  }
});
child.on('error', (error) => {
  if (!finished) {
    clearTimeout(timeout);
    process.stderr.write(`Could not launch Codex: ${error.message}\n`);
    process.exitCode = 1;
  }
});
child.on('exit', (code) => {
  if (!finished && code !== null) {
    clearTimeout(timeout);
    process.stderr.write(`Codex app-server exited before account/read (${code}). ${stderr}\n`);
    process.exitCode = 1;
  }
});
send({ method: 'initialize', id: 0, params: { clientInfo: { name: 'codex_auth_probe', title: 'codex-auth local probe', version: '1.0.0' } } });
