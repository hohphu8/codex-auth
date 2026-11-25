import { spawn } from 'node:child_process';
import readline from 'node:readline';

const option = (name) => process.argv.find((arg) => arg.startsWith(`${name}=`))?.slice(name.length + 1);
const codex = option('--codex') ?? 'codex.cmd';
const home = option('--home');
const cwd = option('--cwd');
if (!home) {
  process.stderr.write('Missing --home.\n');
  process.exit(2);
}

const command = `& '${codex.replaceAll("'", "''")}' app-server`;
const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command], {
  env: { ...process.env, CODEX_HOME: home },
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
});
let stderr = '';
child.stderr.on('data', (chunk) => { stderr += chunk.toString().slice(0, 1000); });
const threads = [];
const cursors = new Set();
let requestId = 1;
let finished = false;
const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);
const close = () => {
  child.stdin.end();
  setTimeout(() => child.kill(), 3000).unref();
};
const fail = (message) => {
  if (finished) return;
  finished = true;
  clearTimeout(timeout);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
  close();
};
const timeout = setTimeout(() => fail(`Timed out listing sessions. ${stderr}`), 45000);
const normalize = (value) => value?.replace(/^\\\\\?\\/, '').replaceAll('/', '\\').replace(/[\\]+$/, '').toLowerCase();
const list = (cursor = null) => send({
  method: 'thread/list',
  id: requestId++,
  params: {
    currentAccountOnly: false,
    modelProviders: [],
    sourceKinds: ['cli', 'vscode'],
    sortKey: 'updated_at',
    limit: 100,
    cursor,
  },
});

readline.createInterface({ input: child.stdout }).on('line', (line) => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.id === 0) {
    if (message.error) return fail(`Codex initialization failed: ${message.error.message}`);
    send({ method: 'initialized', params: {} });
    list();
    return;
  }
  if (typeof message.id !== 'number' || message.id < 1 || finished) return;
  if (message.error) return fail(`Codex thread/list failed: ${message.error.message}`);
  threads.push(...(message.result?.data ?? []));
  const cursor = message.result?.nextCursor;
  if (cursor) {
    if (cursors.has(cursor) || cursors.size >= 100) return fail('Codex session pagination repeated a cursor.');
    cursors.add(cursor);
    list(cursor);
    return;
  }
  finished = true;
  clearTimeout(timeout);
  const selected = cwd ? threads.filter((thread) => normalize(thread.cwd) === normalize(cwd)) : threads;
  const json = JSON.stringify(selected.map((thread) => ({
    id: thread.id,
    cwd: thread.cwd,
    title: thread.name || thread.preview || '(untitled)',
    updatedAt: thread.updatedAt,
  })));
  // Windows PowerShell 5.1 may decode native stdout with a legacy code page.
  // Keep the transport ASCII; ConvertFrom-Json restores the Unicode titles.
  process.stdout.write(json.replace(/[\u007F-\uFFFF]/g, (char) =>
    `\\u${char.charCodeAt(0).toString(16).padStart(4, '0')}`) + '\n');
  close();
});
child.on('error', (error) => fail(`Could not launch Codex: ${error.message}`));
child.on('exit', (code) => {
  if (!finished) fail(`Codex app-server exited before listing sessions (${code}). ${stderr}`);
});
send({ method: 'initialize', id: 0, params: { clientInfo: { name: 'codex_auth_sessions', title: 'codex-auth shared sessions', version: '1.0.0' } } });
