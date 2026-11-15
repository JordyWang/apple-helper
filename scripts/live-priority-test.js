import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, existsSync, unlinkSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const root = fileURLToPath(new URL('../', import.meta.url));
const journal = join(root, '.priority-test-state.json');
if (existsSync(journal)) throw new Error('Review and clean up the prior priority-test journal first.');
const directory = mkdtempSync(join(tmpdir(), 'apple-helper-priority-'));
const marker = `Apple Helper Priority ${randomUUID()}`;
writeFileSync(journal, JSON.stringify({ marker, directory }, null, 2), { mode: 0o600 });
const clients = [];
async function connect(extraEnv = {}) {
  const client = new Client({ name: 'priority-test', version: '1' });
  const transport = new StdioClientTransport({ command: process.execPath, args: [join(root, 'src/server.js')], stderr: 'inherit', env: { ...process.env, APPLE_HELPER_DATA_DIR: directory, ...extraEnv } });
  await client.connect(transport); clients.push(client); return client;
}
async function call(client, name, args = {}) {
  const result = await client.callTool({ name, arguments: args });
  if (result.isError) {
    const detail = result.structuredContent?.error ?? { code: 'TOOL_ERROR', message: result.content[0].text };
    throw Object.assign(new Error(detail.message), detail);
  }
  return result.structuredContent;
}
const request = () => ({ request_id: randomUUID() });
const edit = item => ({ ...request(), id: item.id, expected_version: item.version });
const eventRange = { start: '2099-06-14T00:00:00+08:00', end: '2099-06-20T00:00:00+08:00' };
const hasAlarm = (item, alarm) => item.alarms.some(a => Object.entries(alarm).every(([key, value]) => a[key] === value));
let client;
try {
  client = await connect(); const second = await connect();
  const status = await call(client, 'get_status');
  assert.equal(status.calendar, 'full_access'); assert.equal(status.reminders, 'full_access');
  const initial = await call(client, 'get_preferences');
  assert.deepEqual(initial.preferences, {});
  const calendars = (await call(client, 'list_calendars')).items;
  const lists = (await call(client, 'list_reminder_lists')).items;
  assert.equal(calendars.find(c => c.is_system_default)?.id, initial.system_defaults.calendar_id);
  assert.equal(lists.find(c => c.is_system_default)?.id, initial.system_defaults.reminder_list_id);
  const calendar = calendars.find(c => c.writable && !c.subscribed && c.id !== initial.system_defaults.calendar_id) ?? calendars.find(c => c.writable);
  const list = lists.find(c => c.writable && c.id !== initial.system_defaults.reminder_list_id) ?? lists.find(c => c.writable);
  const preferenceArgs = { ...request(), expected_version: initial.version, default_calendar_id: calendar.id, default_reminder_list_id: list.id, event_duration_minutes: 40, time_zone: 'America/New_York', work_hours: { days: [1, 2, 3, 4, 5], start: '09:00', end: '18:00' } };
  const prefs = await call(client, 'update_preferences', preferenceArgs);
  assert.equal(prefs.effective.default_calendar_id, calendar.id);
  assert.deepEqual((await call(second, 'get_preferences')).preferences, prefs.preferences);
  assert.equal((await call(second, 'update_preferences', preferenceArgs)).operation.replayed, true);
  await assert.rejects(call(second, 'update_preferences', { ...request(), expected_version: initial.version, event_duration_minutes: 60 }), { code: 'VERSION_CONFLICT' });
  await assert.rejects(call(client, 'update_preferences', { ...request(), expected_version: prefs.version, default_calendar_id: randomUUID() }), { code: 'NOT_FOUND' });
  assert.deepEqual((await call(client, 'get_preferences')).preferences, prefs.preferences);
  console.log('System defaults, explicit preferences, cross-client persistence and preference conflicts: PASS');

  const createArgs = { ...request(), title: `${marker} event`, start: '2099-06-15T10:00:00+08:00', alarms: [{ type: 'relative', offset_minutes: -10 }, { type: 'absolute', at: '2099-06-15T09:30:00+08:00' }] };
  let event = await call(client, 'create_event', createArgs);
  assert.equal(event.calendar_id, calendar.id); assert.equal(event.end, '2099-06-15T02:40:00Z');
  assert.equal(event.time_zone, 'America/New_York');
  assert.equal(event.operation.verified, true); assert.equal(event.alarms.length, 2);
  assert.ok(hasAlarm(event, { type: 'relative', offset_minutes: -10 }));
  const replay = await call(second, 'create_event', createArgs);
  assert.equal(replay.id, event.id); assert.equal(replay.operation.replayed, true);
  await assert.rejects(call(client, 'create_event', { ...createArgs, title: 'changed request' }), { code: 'REQUEST_ID_REUSED' });
  await assert.rejects(call(client, 'create_event', { ...createArgs, ...request() }), { code: 'DUPLICATE_FOUND' });
  const old = event;
  event = await call(second, 'update_event', { ...edit(event), notes: 'updated by another client' });
  await assert.rejects(call(client, 'update_event', { ...edit(old), title: 'stale overwrite' }), { code: 'VERSION_CONFLICT' });
  await assert.rejects(call(client, 'delete_event', edit(old)), { code: 'VERSION_CONFLICT' });
  assert.deepEqual(event.alarms, old.alarms);
  event = await call(client, 'update_event', { ...edit(event), start: '2099-06-15T11:00:00+08:00' });
  assert.equal(event.end, '2099-06-15T03:40:00Z');
  assert.ok(hasAlarm(event, { type: 'absolute', at: '2099-06-15T02:30:00Z' }));
  assert.ok(hasAlarm(event, { type: 'relative', offset_minutes: -10 }));
  event = await call(client, 'update_event', { ...edit(event), start: '2099-06-15T12:00:00+08:00', alarm_policy: 'preserve' });
  assert.ok(hasAlarm(event, { type: 'absolute', at: '2099-06-15T02:30:00Z' }));
  const concurrent = await Promise.allSettled([
    call(client, 'update_event', { ...edit(event), location: 'client A' }),
    call(second, 'update_event', { ...edit(event), location: 'client B' }),
  ]);
  assert.equal(concurrent.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(concurrent.find(r => r.status === 'rejected').reason.code, 'VERSION_CONFLICT');
  event = await call(client, 'get_event', { id: event.id });
  event = await call(client, 'update_event', { ...edit(event), alarms: [] }); assert.deepEqual(event.alarms, []);
  console.log('Multiple event alerts, default duration, rescheduling/retention, deduplication, replay and concurrent stale writes: PASS');

  const reminderArgs = { ...request(), title: `${marker} reminder`, due_at: '2099-06-15T10:00:00+08:00', alarms: [{ type: 'relative', offset_minutes: -15 }, { type: 'absolute', at: '2099-06-15T09:00:00+08:00' }] };
  let reminder = await call(client, 'create_reminder', reminderArgs);
  assert.equal(reminder.list_id, list.id); assert.equal(reminder.alarms.length, 2);
  assert.equal(reminder.time_zone, 'America/New_York');
  assert.ok(hasAlarm(reminder, { type: 'absolute', at: '2099-06-15T01:45:00Z' }));
  assert.equal((await call(second, 'create_reminder', reminderArgs)).id, reminder.id);
  await assert.rejects(call(client, 'create_reminder', { ...reminderArgs, ...request() }), { code: 'DUPLICATE_FOUND' });
  reminder = await call(client, 'update_reminder', { ...edit(reminder), due_at: '2099-06-15T11:00:00+08:00' });
  assert.ok(hasAlarm(reminder, { type: 'absolute', at: '2099-06-15T02:45:00Z' }));
  assert.ok(hasAlarm(reminder, { type: 'absolute', at: '2099-06-15T02:00:00Z' }));
  const before = reminder;
  reminder = await call(client, 'update_reminder', { ...edit(reminder), notes: 'keep alerts' });
  assert.deepEqual(reminder.alarms, before.alarms);
  await assert.rejects(call(second, 'update_reminder', { ...edit(before), completed: true }), { code: 'VERSION_CONFLICT' });
  reminder = await call(client, 'update_reminder', { ...edit(reminder), due_at: '2099-06-15T12:00:00+08:00', alarm_policy: 'preserve' });
  assert.deepEqual(reminder.alarms, before.alarms);
  reminder = await call(client, 'update_reminder', { ...edit(reminder), alarms: [] }); assert.deepEqual(reminder.alarms, []);
  console.log('Multiple reminder alerts, due-relative normalization, shifting, preserving and clearing: PASS');

  const simultaneousArgs = { ...request(), title: `${marker} simultaneous` };
  const simultaneous = await Promise.allSettled([call(client, 'create_reminder', simultaneousArgs), call(second, 'create_reminder', simultaneousArgs)]);
  assert.ok(simultaneous.some(r => r.status === 'fulfilled'));
  assert.equal((await call(client, 'list_reminders', { query: simultaneousArgs.title })).total, 1);
  assert.equal((await call(client, 'create_reminder', simultaneousArgs)).operation.replayed, true);

  const crashing = await connect({ APPLE_HELPER_BRIDGE_PATH: join(root, 'bin/eventkit-test-bridge'), APPLE_HELPER_TEST_CRASH_AFTER_WRITE: '1' });
  const crashArgs = { ...request(), title: `${marker} crash`, start: '2099-06-16T10:00:00+08:00', end: '2099-06-16T11:00:00+08:00' };
  await assert.rejects(call(crashing, 'create_event', crashArgs), { code: 'RESULT_UNKNOWN' });
  assert.equal((await call(client, 'get_operation', { request_id: crashArgs.request_id })).status, 'pending');
  await assert.rejects(call(client, 'create_event', crashArgs), { code: 'RESULT_UNKNOWN' });
  assert.equal((await call(client, 'list_events', { ...eventRange, query: crashArgs.title })).total, 1);
  const record = await call(client, 'get_operation', { request_id: createArgs.request_id });
  assert.equal(record.status, 'succeeded'); assert.equal(record.result.id, old.id);
  assert.ok((await call(client, 'list_operations')).items.length > 0);
  assert.equal(statSync(join(directory, 'state.sqlite3')).mode & 0o777, 0o600);
  console.log('Cross-process same-request replay, crash after save without duplicate retry, private durable journal: PASS');

  const current = await call(client, 'get_preferences');
  const reset = await call(client, 'update_preferences', { ...request(), expected_version: current.version, default_calendar_id: null, default_reminder_list_id: null, event_duration_minutes: null, time_zone: null, work_hours: null });
  assert.deepEqual(reset.preferences, {}); assert.equal(reset.effective.default_calendar_id, initial.system_defaults.calendar_id);
  const systemReminder = await call(client, 'create_reminder', { ...request(), title: `${marker} system default` });
  assert.equal(systemReminder.list_id, initial.system_defaults.reminder_list_id);
  const systemEvent = await call(client, 'create_event', { ...request(), title: `${marker} system default`, start: '2099-06-17T10:00:00+08:00', end: '2099-06-17T11:00:00+08:00' });
  assert.equal(systemEvent.calendar_id, initial.system_defaults.calendar_id);
  const deleteArgs = edit(systemReminder);
  assert.equal((await call(client, 'delete_reminder', deleteArgs)).operation.verified, true);
  assert.equal((await call(second, 'delete_reminder', deleteArgs)).operation.replayed, true);
  console.log('Reset-to-system defaults and verified delete replay: PASS');
} finally {
  let cleanupOK = !!client;
  if (client) {
    for (const entity of ['event', 'reminder']) {
      try {
        const result = await call(client, entity === 'event' ? 'list_events' : 'list_reminders', { ...(entity === 'event' ? eventRange : {}), query: marker, limit: 200 });
        for (const item of result.items) await call(client, `delete_${entity}`, edit(item));
        assert.equal((await call(client, entity === 'event' ? 'list_events' : 'list_reminders', { ...(entity === 'event' ? eventRange : {}), query: marker })).total, 0);
      } catch (error) { cleanupOK = false; console.error('Cleanup needs attention:', error); }
    }
  }
  for (const c of clients) await c.close();
  if (cleanupOK) { unlinkSync(journal); rmSync(directory, { recursive: true }); console.log('All priority-test calendar/reminder fixtures removed.'); }
  else throw new Error(`Cleanup incomplete; inspect ${journal}`);
}
