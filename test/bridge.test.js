import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('cancelled queued writes never start; already started writes finish journaling', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'apple-helper-cancel-'));
  const binary = join(dir, 'bridge'); const started = join(dir, 'started'); const gate = join(dir, 'release'); const log = join(dir, 'log');
  try {
    await writeFile(binary, `#!${process.execPath}\nconst fs=require('node:fs');let s='';process.stdin.on('data',x=>s+=x);process.stdin.on('end',()=>{const r=JSON.parse(s);fs.appendFileSync(${JSON.stringify(log)},r.operation+'\\n');fs.writeFileSync(${JSON.stringify(started)},'');const timer=setInterval(()=>{if(fs.existsSync(${JSON.stringify(gate)})){clearInterval(timer);process.stdout.write(JSON.stringify({ok:true,data:{finished:true}}))}},5)});\n`, { mode: 0o700 });
    process.env.APPLE_HELPER_BRIDGE_PATH = binary;
    const { invokeBridge } = await import(`../src/bridge.js?test=${Date.now()}`);
    const activeController = new AbortController();
    const active = invokeBridge('create_event', { request_id: 'active' }, { signal: activeController.signal });
    for (let i = 0; ; i++) {
      try { await access(started); break; } catch { if (i > 300) throw new Error('Fake bridge did not start'); await new Promise(r => setTimeout(r, 10)); }
    }
    const queuedController = new AbortController();
    const queued = invokeBridge('create_reminder', { request_id: 'queued' }, { signal: queuedController.signal });
    const cancelled = assert.rejects(queued, { code: 'CANCELLED' });
    queuedController.abort(); activeController.abort();
    await writeFile(gate, '');
    assert.equal((await active).finished, true); await cancelled;
    assert.equal(await readFile(log, 'utf8'), 'create_event\n');
  } finally { delete process.env.APPLE_HELPER_BRIDGE_PATH; await rm(dir, { recursive: true, force: true }); }
});
