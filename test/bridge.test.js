import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

for (const operation of ['create_event', 'append_note', 'move_note']) test(`cancelled queued writes never start; active ${operation} finishes journaling`, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'apple-helper-cancel-'));
  const binary = join(dir, 'bridge'); const started = join(dir, 'started'); const gate = join(dir, 'release'); const log = join(dir, 'log');
  try {
    await writeFile(binary, `#!${process.execPath}\nconst fs=require('node:fs');let s='';process.stdin.on('data',x=>s+=x);process.stdin.on('end',()=>{const r=JSON.parse(s);fs.appendFileSync(${JSON.stringify(log)},r.operation+'\\n');fs.writeFileSync(${JSON.stringify(started)},'');const timer=setInterval(()=>{if(fs.existsSync(${JSON.stringify(gate)})){clearInterval(timer);process.stdout.write(JSON.stringify({ok:true,data:{finished:true}}))}},5)});\n`, { mode: 0o700 });
    process.env.APPLE_HELPER_BRIDGE_PATH = binary;
    const { invokeBridge } = await import(`../src/bridge.js?test=${Date.now()}`);
    const activeController = new AbortController();
    const active = invokeBridge(operation, { request_id: 'active' }, { signal: activeController.signal });
    for (let i = 0; ; i++) {
      try { await access(started); break; } catch { if (i > 300) throw new Error('Fake bridge did not start'); await new Promise(r => setTimeout(r, 10)); }
    }
    const queuedController = new AbortController();
    const queued = invokeBridge('create_reminder', { request_id: 'queued' }, { signal: queuedController.signal });
    const cancelled = assert.rejects(queued, { code: 'CANCELLED' });
    queuedController.abort(); activeController.abort();
    await writeFile(gate, '');
    assert.equal((await active).finished, true); await cancelled;
    assert.equal(await readFile(log, 'utf8'), `${operation}\n`);
  } finally { delete process.env.APPLE_HELPER_BRIDGE_PATH; await rm(dir, { recursive: true, force: true }); }
});

test('active batch cancellation signals a checkpoint and lets the current write finish', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'apple-helper-batch-cancel-'));
  const binary = join(dir, 'bridge'), started = join(dir, 'started');
  try {
    await writeFile(binary, `#!${process.execPath}\nconst fs=require('node:fs');process.stdin.resume();process.stdin.on('end',()=>{const file=process.env.APPLE_HELPER_CANCEL_FILE;fs.writeFileSync(${JSON.stringify(started)},file);const timer=setInterval(()=>{if(fs.existsSync(file)){clearInterval(timer);process.stdout.write(JSON.stringify({ok:true,data:{cancelled:true,current_write_finished:true,cancel_file:file}}))}},5)});\n`, { mode: 0o700 });
    process.env.APPLE_HELPER_BRIDGE_PATH = binary;
    const { invokeBridge } = await import(`../src/bridge.js?batch=${Date.now()}`);
    const controller = new AbortController();
    const pending = invokeBridge('batch_update', { request_id: 'batch' }, { signal: controller.signal });
    for (let i = 0; ; i++) {
      try { await access(started); break; } catch { if (i > 300) throw new Error('Fake batch did not start'); await new Promise(r => setTimeout(r, 10)); }
    }
    controller.abort();
    const result = await pending;
    assert.equal(result.cancelled, true); assert.equal(result.current_write_finished, true);
    await assert.rejects(access(result.cancel_file), { code: 'ENOENT' });
  } finally { delete process.env.APPLE_HELPER_BRIDGE_PATH; await rm(dir, { recursive: true, force: true }); }
});
