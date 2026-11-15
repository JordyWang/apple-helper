import test from 'node:test';
import assert from 'node:assert/strict';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createServer } from '../src/server.js';
import { tools } from '../src/tools.js';

async function connection(t, invoke) {
  const server = createServer(invoke);
  const client = new Client({ name: 'apple-helper-test', version: '1' });
  const [serverTransport, clientTransport] = InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);
  await client.connect(clientTransport);
  t.after(async () => { await client.close(); await server.close(); });
  return client;
}

test('MCP exposes all tools with read and destructive annotations', async t => {
  const client = await connection(t, async () => ({}));
  const { tools: listed } = await client.listTools();
  assert.equal(listed.length, 40);
  assert.equal(listed.find(x => x.name === 'list_events').annotations.readOnlyHint, true);
  assert.equal(listed.find(x => x.name === 'delete_reminder').annotations.destructiveHint, true);
  assert.ok(listed.find(x => x.name === 'create_event').inputSchema.required.includes('request_id'));
  assert.equal(listed.find(x => x.name === 'create_event').inputSchema.required.includes('calendar_id'), false);
});

test('validation rejects malformed dates, zones, empty patches, and unknown fields', () => {
  const schema = name => tools.find(x => x.name === name).schema;
  const base = { request_id: 'validation', expected_version: 'a'.repeat(64) };
  assert.equal(schema('update_reminder').safeParse({ ...base, id: 'r', due_at: '2026-02-28T09:00:00+08:00' }).success, true);
  for (const args of [{ id: 'r' }, { id: 'r', due_at: '2026-02-30T09:00:00+08:00' }, { id: 'r', due_at: '2026-11-15T09:00:00' }, { id: 'r', due_at: null, due_date: null }, { id: 'r', title: 'x', time_zone: 'Mars/Olympus' }, { id: 'r', title: 'x', arbitrary_script: 'evil' }]) {
    const result = schema('update_reminder').safeParse({ ...base, ...args });
    assert.equal(result.success, false);
    assert.ok(result.error.issues.every(i => !['request_id', 'expected_version'].includes(i.path[0])));
  }
  assert.equal(schema('create_event').safeParse({ request_id: 'validation', calendar_id: 'c', title: 'x', start: '2026-11-15T10:00:00+08:00', end: '2026-11-15T09:00:00+08:00' }).success, false);
  assert.equal(schema('list_events').safeParse({ start: '2025-01-01T00:00:00Z', end: '2027-01-01T00:00:00Z' }).success, false);
});

test('advanced schemas validate recurrence combinations and complete planning inputs', () => {
  const schema = name => tools.find(x => x.name === name).schema;
  const base = { request_id: 'recurrence', title: 'weekly', start: '2099-06-15T10:00:00+08:00', end: '2099-06-15T11:00:00+08:00' };
  assert.equal(schema('create_event').safeParse({ ...base, recurrence: { frequency: 'weekly', days_of_week: [{ day: 1 }, { day: 5 }], count: 10 } }).success, true);
  for (const recurrence of [{ frequency: 'daily', days_of_week: [{ day: 1 }] }, { frequency: 'weekly', days_of_month: [5] }, { frequency: 'daily', count: 3, until: base.end }, { frequency: 'monthly', days_of_week: [{ day: 1, week: 6 }] }]) {
    assert.equal(schema('create_event').safeParse({ ...base, recurrence }).success, false);
  }
  assert.equal(schema('find_free_slots').safeParse({ start: base.start, end: base.end, duration_minutes: 30, work_hours: { days: [1, 2, 3, 4, 5], start: '09:00', end: '18:00' } }).success, true);
});

test('extension schemas reject ambiguous batch items and incomplete destructive scope', () => {
  const schema = name => tools.find(x => x.name === name).schema;
  const version = 'a'.repeat(64), request_id = 'extensions';
  const item = { key: 'one', kind: 'reminder', id: 'r', expected_version: version, changes: { completed: true } };
  assert.equal(schema('batch_update').safeParse({ request_id, items: [item] }).success, true);
  for (const items of [[item, item], [item, { ...item, key: 'two' }], [{ ...item, changes: {} }], [{ ...item, changes: { due_at: null, due_date: null } }], [{ ...item, expected_version: undefined }]]) {
    assert.equal(schema('batch_update').safeParse({ request_id, items }).success, false);
  }
  const deletion = { request_id, id: 'calendar', expected_version: version };
  assert.equal(schema('delete_calendar').safeParse(deletion).success, false);
  assert.equal(schema('delete_calendar').safeParse({ ...deletion, delete_contents: true }).success, true);
  assert.equal(schema('undo_operation').parse({ request_id, target_request_id: 'original', expected_operation_version: version }).allow_recreate, false);
  const range = { start: '2028-08-01T09:00:00+08:00', end: '2028-08-01T18:00:00+08:00' };
  assert.equal(schema('plan_tasks').safeParse({ ...range, tasks: [{ reminder_id: 'r' }, { reminder_id: 'r' }] }).success, false);
  assert.equal(schema('get_changes').safeParse({ page_token: 'frozen:10' }).success, true);
  assert.equal(schema('get_changes').safeParse({ ...range, page_token: 'frozen:10' }).success, false);
  assert.equal(schema('get_changes').safeParse({ ...range, offset: 10 }).success, false);
});

test('MCP cancellation reaches the tool handler AbortSignal', async t => {
  let entered, received;
  const started = new Promise(r => entered = r);
  const client = await connection(t, async (_name, _args, { signal }) => {
    received = signal; entered();
    await new Promise(resolve => signal.addEventListener('abort', resolve, { once: true }));
    return {};
  });
  const controller = new AbortController();
  const request = client.callTool({ name: 'get_status', arguments: {} }, undefined, { signal: controller.signal });
  const rejected = assert.rejects(request);
  await started; controller.abort(); await rejected;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(received.aborted, true);
});

test('invalid MCP input never reaches native bridge', async t => {
  let called = false;
  const client = await connection(t, async () => { called = true; return {}; });
  const result = await client.callTool({ name: 'create_reminder', arguments: { title: 'x' } });
  assert.equal(result.isError, true);
  assert.equal(called, false);
});

test('quoted and multiline content is preserved as data', async t => {
  const notes = '中文\n"quotes" \\ backslash $(touch /tmp/never) `command`';
  let received;
  const client = await connection(t, async (name, args) => { received = { name, args }; return { id: 'new', ...args }; });
  const result = await client.callTool({ name: 'create_reminder', arguments: { request_id: 'quoted-content', list_id: 'list-1', title: '测试 😀', notes } });
  assert.equal(result.structuredContent.notes, notes);
  assert.equal(received.args.notes, notes);
});

test('native errors propagate as actionable MCP errors', async t => {
  const client = await connection(t, async () => { throw new Error('PERMISSION_REQUIRED: Enable full access.'); });
  const result = await client.callTool({ name: 'list_calendars', arguments: {} });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /PERMISSION_REQUIRED/);
});

test('recurring-event mutations default to one occurrence', () => {
  const schema = tools.find(x => x.name === 'delete_event').schema;
  assert.equal(schema.parse({ id: 'event', request_id: 'delete', expected_version: 'a'.repeat(64) }).scope, 'this');
});

test('new write contracts validate versions, preferences and notification choices', () => {
  const schema = name => tools.find(x => x.name === name).schema;
  assert.equal(schema('update_event').safeParse({ id: 'e', request_id: 'r', title: 'x' }).success, false);
  assert.equal(schema('update_reminder').safeParse({ id: 'r', request_id: 'r', expected_version: 'a'.repeat(64) }).success, false);
  assert.equal(schema('create_event').safeParse({ request_id: 'r', title: 'x', start: '2099-06-15T10:00:00+08:00', alarms: [{ type: 'relative', offset_minutes: -10 }] }).success, true);
  assert.equal(schema('create_reminder').safeParse({ request_id: 'r', title: 'x', alarm_at: null, alarms: [] }).success, false);
  const base = { request_id: 'r', expected_version: 'a'.repeat(64) };
  assert.equal(schema('update_preferences').safeParse({ ...base, work_hours: { days: [1, 1], start: '09:00', end: '18:00' } }).success, false);
  assert.equal(schema('update_preferences').safeParse({ ...base, work_hours: { days: [1], start: '19:00', end: '18:00' } }).success, false);
  assert.equal(schema('update_preferences').safeParse({ ...base, event_duration_minutes: 0 }).success, false);
  assert.equal(schema('update_preferences').safeParse({ ...base, default_calendar_id: null }).success, true);
});
