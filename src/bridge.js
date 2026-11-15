import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const binary = process.env.APPLE_HELPER_BRIDGE_PATH || fileURLToPath(new URL('../bin/eventkit-bridge', import.meta.url));
const children = new Set();
let queue = Promise.resolve();
let queued = 0;
let closed = false;
const cancelled = () => Object.assign(new Error('Request cancelled before execution.'), { code: 'CANCELLED' });

export function closeBridge() { closed = true; for (const child of children) child.kill('SIGTERM'); }

// Serialize writes and reads to avoid overlapping EventKit store snapshots.
export function invokeBridge(operation, args, { signal } = {}) {
  if (closed || signal?.aborted) return Promise.reject(cancelled());
  if (queued >= 64) return Promise.reject(Object.assign(new Error('Bridge queue is full; retry later.'), { code: 'BUSY' }));
  queued++;
  const enqueuedAt = Date.now();
  const run = queue.then(() => {
    queued--;
    if (closed || signal?.aborted) throw cancelled();
    if (Date.now() - enqueuedAt > 120000) throw Object.assign(new Error('Request expired in queue; no write was started.'), { code: 'QUEUE_TIMEOUT' });
    return execute(operation, args, signal);
  });
  queue = run.catch(() => {});
  return run;
}

function execute(operation, args, signal) {
  return new Promise((resolve, reject) => {
    const composite = ['batch_update', 'apply_plan'].includes(operation);
    const isWrite = composite || /^(create|update|delete|reschedule|reconcile|prune|undo|append|move)_/.test(operation);
    const failure = message => Object.assign(new Error(message), {
      code: isWrite ? 'RESULT_UNKNOWN' : 'BRIDGE_ERROR',
      ...(isWrite ? { details: { request_id: args.request_id, next_step: 'Inspect get_operation and current item state. Do not retry under a new request ID.' } } : {}),
    });
    if (process.platform !== 'darwin') return reject(new Error('This MCP requires macOS 14 or later.'));
    const cancelDir = composite ? mkdtempSync(join(tmpdir(), 'apple-helper-cancel-')) : undefined;
    const cancelFile = cancelDir && join(cancelDir, 'cancelled');
    const child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'pipe'], ...(cancelFile ? { env: { ...process.env, APPLE_HELPER_CANCEL_FILE: cancelFile } } : {}) });
    children.add(child);
    // Once a write starts, let its durable journal finish. Cancellation is not rollback.
    const abort = () => { if (cancelFile) writeFileSync(cancelFile, ''); else if (!isWrite) child.kill('SIGTERM'); };
    signal?.addEventListener('abort', abort, { once: true });
    let stdout = '', stderr = '', failed = false;
    const timeout = setTimeout(() => {
      failed = true; child.kill('SIGKILL');
      reject(failure('macOS request timed out. Check system permission dialogs. If this was a write, query current state before retrying; it may already have succeeded.'));
    }, operation === 'request_access' || composite ? 120000 : 45000);
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', data => {
      stdout += data;
      if (stdout.length > 8 * 1024 * 1024) { failed = true; child.kill('SIGKILL'); reject(failure('Response too large; use a narrower query.')); }
    });
    child.stderr.on('data', data => { stderr = (stderr + data).slice(-4000); });
    child.stdin.on('error', () => {});
    child.on('error', error => { clearTimeout(timeout); signal?.removeEventListener('abort', abort); children.delete(child); failed = true; reject(new Error(`Cannot start native bridge; run npm run build. ${error.message}`)); });
    child.on('close', code => {
      clearTimeout(timeout); children.delete(child);
      signal?.removeEventListener('abort', abort);
      if (cancelDir) rmSync(cancelDir, { recursive: true, force: true });
      if (failed) return;
      if (code !== 0) return reject(failure(`Native bridge exited (${code}). ${stderr}`));
      try {
        const result = JSON.parse(stdout);
        if (!result.ok) return reject(Object.assign(new Error(`${result.error.code}: ${result.error.message}`), result.error));
        resolve(result.data);
      } catch (error) { reject(failure(`Invalid bridge response: ${error.message}`)); }
    });
    // User data is JSON on stdin, never executable source or shell arguments.
    child.stdin.end(JSON.stringify({ operation, arguments: args }));
  });
}
