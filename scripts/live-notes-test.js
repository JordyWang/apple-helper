import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, unlinkSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const root = fileURLToPath(new URL('../', import.meta.url));
const journal = join(root, '.notes-test-state.json');
const cleanupOnly = process.argv.includes('--cleanup');
if (existsSync(journal) && !cleanupOnly) throw new Error('Inspect the prior Notes fixture journal; run this script with --cleanup to remove exactly those fixtures.');
const prior = cleanupOnly ? JSON.parse(readFileSync(journal, 'utf8')) : undefined;
const directory = prior?.directory ?? mkdtempSync(join(tmpdir(), 'apple-helper-notes-'));
const marker = prior?.marker ?? `Apple Helper Notes ${randomUUID()}`;
assert.match(marker, /^Apple Helper Notes [a-f0-9-]{36}$/);
assert.equal(dirname(directory), tmpdir()); assert.ok(directory.startsWith(join(tmpdir(), 'apple-helper-notes-')));
const owned = prior ?? { marker, directory, folders: [], notes: [] };
const save = () => writeFileSync(journal, JSON.stringify(owned, null, 2), { mode: 0o600 });
save();
const clients = [];
async function connect(env = {}) {
  const c = new Client({ name: 'notes-test', version: '1' });
  await c.connect(new StdioClientTransport({ command: process.execPath, args: [join(root, 'src/server.js')], env: { ...process.env, APPLE_HELPER_DATA_DIR: directory, ...env }, stderr: 'inherit' }));
  clients.push(c); return c;
}
async function call(c, name, args = {}) {
  const response = await c.callTool({ name, arguments: args }, undefined, { timeout: 140000 });
  if (response.isError) { const error = response.structuredContent?.error ?? JSON.parse(response.content[0].text); throw Object.assign(new Error(error.message), error); }
  return response.structuredContent;
}
const request = () => ({ request_id: randomUUID() });
const edit = x => ({ ...request(), id: x.id, expected_version: x.version });
let client;
try {
  client = await connect();
  if (!cleanupOnly) {
  assert.equal((await client.listTools()).tools.length, 52);
  const status = await call(client, 'request_access', { target: 'notes' });
  assert.equal(status.notes.automation, 'authorized');
  const accounts = (await call(client, 'list_note_accounts')).items;
  assert.ok(accounts.some(a => a.is_default && a.default_folder_id));
  const defaultFolder = accounts.find(a => a.is_default).default_folder_id;
  const createFolder = async (name, extra = {}) => {
    const item = await call(client, 'create_note_folder', { ...request(), name, ...extra });
    owned.folders.push(item.id); save(); return item;
  };
  const folder = await createFolder(marker);
  let nested = await createFolder(`${marker} nested`, { parent_folder_id: folder.id });
  assert.equal(nested.parent_id, folder.id); assert.equal(nested.parent_kind, 'folder');
  await assert.rejects(call(client, 'create_note_folder', { ...request(), name: marker }), { code: 'DUPLICATE_FOUND' });
  const oldNested = nested;
  nested = await call(client, 'update_note_folder', { ...edit(nested), name: `${marker} renamed` });
  await assert.rejects(call(client, 'update_note_folder', { ...edit(oldNested), name: 'must not apply' }), { code: 'VERSION_CONFLICT' });
  const currentFolder = async id => (await call(client, 'list_note_folders')).items.find(f => f.id === id);
  const fresh = async item => edit(await call(client, 'get_note', { id: item.id }));
  await assert.rejects(call(client, 'delete_note_folder', edit(await currentFolder(folder.id))), { code: 'CONTENTS_SCOPE_REQUIRED' });
  await assert.rejects(call(client, 'delete_note_folder', edit(await currentFolder(defaultFolder))), { code: 'PROTECTED_FOLDER' });
  console.log('Notes Automation, accounts/defaults, nested folders, versions and deletion scope: PASS');

  const create = async (title, body_text = '', extra = {}) => {
    const item = await call(client, 'create_note', { ...request(), folder_id: folder.id, title, body_text, ...extra });
    owned.notes.push(item.id); save(); return item;
  };
  const text = '中文 <literal> & "quotes" 😀 $(not-a-command) `literal`\n  两个空格\t制表符\n\n最后一行\n';
  let note = await create(`${marker} text`, text);
  assert.ok(note.text.includes(text.trimEnd()));
  assert.ok(note.html.includes('&lt')); assert.equal(note.attachments.length, 0);
  assert.equal((await call(client, 'list_notes', { folder_id: folder.id, query: '两个空格', search_in: 'text' })).total, 1);
  assert.equal((await call(client, 'list_notes', { folder_id: folder.id, query: '两个空格', search_in: 'title' })).total, 0);
  await assert.rejects(create(note.title), { code: 'DUPLICATE_FOUND' });
  const original = note;
  note = await call(client, 'update_note', { ...await fresh(note), title: `${marker} renamed note` });
  assert.equal(note.text, original.text); assert.equal(note.html, original.html);
  await assert.rejects(call(client, 'append_note', { ...edit(original), text: 'must not append' }), { code: 'VERSION_CONFLICT' });
  const append = { ...await fresh(note), text: '追加 <text> & \'quotes\'\n第二行' };
  note = await call(client, 'append_note', append);
  const replay = await call(client, 'append_note', append);
  assert.equal(replay.operation.replayed, true); assert.equal(note.text.split('追加 <text>').length, 2);
  note = await call(client, 'update_note', { ...await fresh(note), title: `${marker} replaced`, body_text: '替换的正文\n第二行' });
  assert.equal(note.text.trimEnd(), `${marker} replaced\n替换的正文\n第二行`);
  note = await call(client, 'move_note', { ...await fresh(note), folder_id: nested.id });
  assert.equal(note.folder_id, nested.id);
  assert.equal((await call(client, 'list_notes', { folder_id: folder.id, query: note.title })).total, 0);
  assert.equal((await call(client, 'list_notes', { folder_id: nested.id, query: note.title })).total, 1);
  const implicit = await call(client, 'create_note', { ...request(), title: `${marker} default`, body_text: 'default destination' });
  owned.notes.push(implicit.id); save(); assert.equal(implicit.folder_id, defaultFolder);
  await call(client, 'delete_note', await fresh(implicit));
  assert.equal((await call(client, 'list_notes', { folder_id: defaultFolder, query: implicit.title })).total, 0);
  try {
    const retained = await call(client, 'get_note', { id: implicit.id });
    assert.notEqual(retained.folder_id, defaultFolder); // Notes may retain the ID in Recently Deleted.
  } catch (e) { if (e.code !== 'NOT_FOUND') throw e; }
  const selectedAccount = accounts.find(a => a.is_default).id;
  const accountNote = await call(client, 'create_note', { ...request(), account_id: selectedAccount, title: `${marker} account destination`, body_text: 'selected account' });
  owned.notes.push(accountNote.id); save(); assert.equal(accountNote.folder_id, defaultFolder);
  assert.equal((await call(client, 'list_notes', { account_id: selectedAccount, query: accountNote.title })).total, 1);
  assert.ok((await call(client, 'list_note_folders', { account_id: selectedAccount })).items.some(f => f.id === nested.id));
  for (let i = 0; i < 3; i++) await create(`${marker} page ${i}`);
  const first = await call(client, 'list_notes', { folder_id: folder.id, query: `${marker} page`, limit: 1 });
  const second = await call(client, 'list_notes', { folder_id: folder.id, query: `${marker} page`, limit: 1, offset: first.next_offset });
  assert.equal(first.total, 3); assert.notEqual(first.items[0].id, second.items[0].id);
  console.log('Text escaping/search, title/body edits, append replay, movement, pagination and defaults: PASS');

  const mutateFixture = join(directory, 'fixture.applescript');
  writeFileSync(mutateFixture, 'on run argv\n tell application "Notes"\n  set body of note id (item 1 of argv) to item 2 of argv\n end tell\nend run\n');
  let rich = await create(`${marker} rich`);
  execFileSync('/usr/bin/osascript', [mutateFixture, rich.id, `<div>${marker} rich</div><div><b>bold</b></div>`]);
  rich = await call(client, 'get_note', { id: rich.id });
  assert.equal(rich.rich_formatting, true);
  await assert.rejects(call(client, 'update_note', { ...edit(rich), body_text: 'replace' }), { code: 'FORMAT_LOSS_CONFIRMATION_REQUIRED' });
  rich = await call(client, 'append_note', { ...await fresh(rich), text: 'append to bold' });
  assert.ok(/<b>|font-weight/i.test(rich.html));
  rich = await call(client, 'update_note', { ...await fresh(rich), body_text: 'replace', allow_format_loss: true });
  assert.equal(rich.rich_formatting, false);
  execFileSync('/usr/bin/osascript', [mutateFixture, rich.id, `<div>${marker} table</div><table><tr><td>cell</td></tr></table>`]);
  rich = await call(client, 'get_note', { id: rich.id });
  assert.equal(rich.complex_content, true);
  await assert.rejects(call(client, 'append_note', { ...edit(rich), text: 'must not append' }), error => ['COMPLEX_CONTENT', 'ATTACHMENTS_UNSUPPORTED'].includes(error.code));
  console.log('Rich formatting requires explicit replacement; append preserves simple formatting and rejects complex structures: PASS');

  const attachmentFile = join(directory, 'fixture.txt'), attachScript = join(directory, 'attach.applescript');
  writeFileSync(attachmentFile, 'Apple Helper temporary Notes attachment fixture.');
  writeFileSync(attachScript, 'on run argv\n tell application "Notes"\n  make new attachment at note id (item 1 of argv) with data (POSIX file (item 2 of argv))\n end tell\nend run\n');
  let attached = await create(`${marker} attachment`);
  execFileSync('/usr/bin/osascript', [attachScript, attached.id, attachmentFile]);
  attached = await call(client, 'get_note', { id: attached.id });
  assert.ok(attached.attachments.some(a => a.name === 'fixture.txt')); // Notes may expose additional internal/preview attachments.
  await assert.rejects(call(client, 'append_note', { ...await fresh(attached), text: 'must not rewrite attachment' }), { code: 'ATTACHMENTS_UNSUPPORTED' });
  await assert.rejects(call(client, 'update_note', { ...await fresh(attached), body_text: 'must not rewrite attachment', allow_format_loss: true }), { code: 'ATTACHMENTS_UNSUPPORTED' });
  attached = await call(client, 'get_note', { id: attached.id });
  const attachmentMetadata = attached.attachments;
  attached = await call(client, 'update_note', { ...await fresh(attached), title: `${marker} attachment renamed` });
  attached = await call(client, 'move_note', { ...await fresh(attached), folder_id: nested.id });
  assert.deepEqual(attached.attachments, attachmentMetadata);
  console.log('Attachment metadata, body-write rejection and attachment-preserving rename/move: PASS');

  const concurrent = await create(`${marker} concurrent`);
  const createdOperation = await call(client, 'get_operation', { request_id: concurrent.operation.request_id });
  assert.equal(createdOperation.undo.supported, false);
  await assert.rejects(call(client, 'undo_operation', { ...request(), target_request_id: concurrent.operation.request_id, expected_operation_version: createdOperation.version }), { code: 'UNDO_UNSUPPORTED' });
  const secondClient = await connect();
  const sharedRequest = { ...await fresh(concurrent), text: 'append once' };
  const results = await Promise.all([call(client, 'append_note', sharedRequest), call(secondClient, 'append_note', sharedRequest)]);
  assert.equal(results.filter(r => r.operation.replayed).length, 1);
  assert.equal((await call(client, 'get_note', { id: concurrent.id })).text.split('append once').length, 2);
  const crashClient = await connect({ APPLE_HELPER_BRIDGE_PATH: join(root, 'bin/eventkit-test-bridge'), APPLE_HELPER_TEST_CRASH_AFTER_WRITE: '1' });
  const victim = await create(`${marker} crash append`);
  const crashArgs = { ...await fresh(victim), text: 'saved before crash' };
  await assert.rejects(call(crashClient, 'append_note', crashArgs), { code: 'RESULT_UNKNOWN' });
  await assert.rejects(call(client, 'append_note', crashArgs), { code: 'RESULT_UNKNOWN' });
  assert.equal((await call(client, 'get_note', { id: victim.id })).text.split('saved before crash').length, 2);
  assert.equal((await call(client, 'get_operation', { request_id: crashArgs.request_id })).status, 'pending');
  const crashCreate = { ...request(), folder_id: folder.id, title: `${marker} crash creation`, body_text: 'created once' };
  await assert.rejects(call(crashClient, 'create_note', crashCreate), { code: 'RESULT_UNKNOWN' });
  await assert.rejects(call(client, 'create_note', crashCreate), { code: 'RESULT_UNKNOWN' });
  assert.equal((await call(client, 'list_notes', { folder_id: folder.id, query: crashCreate.title })).total, 1);
  const uncertain = await call(client, 'get_operation', { request_id: crashArgs.request_id });
  const resolved = await call(client, 'reconcile_operation', { ...request(), target_request_id: crashArgs.request_id, expected_operation_version: uncertain.version, conclusion: 'abandoned', note: 'Test inspected the note and observed one appended copy; closing investigation without repeating it.' });
  assert.equal(resolved.status, 'resolved');
  await assert.rejects(call(client, 'append_note', crashArgs), { code: 'OPERATION_RESOLVED' });
  console.log('Cross-client append replay and crash-after-save protection: PASS');
  }
} finally {
  let clean = !!client;
  if (client) {
    try {
      // Discover writes whose result was lost before their IDs reached this process.
      const notes = await call(client, 'list_notes', { query: marker, limit: 200 });
      assert.ok(notes.total <= 200);
      owned.notes = [...new Set([...owned.notes, ...notes.items.filter(n => n.title.startsWith(marker)).map(n => n.id)])];
      const folders = (await call(client, 'list_note_folders')).items.filter(f => f.name.startsWith(marker));
      owned.folders = [...new Set([...owned.folders, ...folders.map(f => f.id)])];
      save();
    } catch (e) { clean = false; console.error('Fixture discovery:', e); }
    for (const id of owned.notes) {
      try {
        const note = await call(client, 'get_note', { id });
        if (!note.title.startsWith(marker)) throw new Error('Fixture title no longer matches; refusing cleanup');
        await call(client, 'delete_note', edit(note));
      } catch (e) { if (e.code !== 'NOT_FOUND') { clean = false; console.error('Note cleanup:', e); } }
    }
    for (const id of [...owned.folders].reverse()) {
      try {
        const folder = (await call(client, 'list_note_folders')).items.find(f => f.id === id);
        if (!folder) continue;
        if (!folder.name.startsWith(marker)) throw new Error('Fixture folder name changed; refusing cleanup');
        await call(client, 'delete_note_folder', { ...edit(folder), delete_contents: true });
      } catch (e) { clean = false; console.error('Folder cleanup:', e); }
    }
  }
  for (const c of clients) await c.close();
  if (clean) { unlinkSync(journal); rmSync(directory, { recursive: true }); console.log('Test notes/folders deleted through Notes; Recently Deleted retention is controlled by Notes.'); }
  else throw new Error(`Cleanup incomplete; inspect ${journal}`);
}
