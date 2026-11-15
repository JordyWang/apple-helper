import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, existsSync, unlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const root = fileURLToPath(new URL('../', import.meta.url));
const journal = join(root, '.advanced-test-state.json');
if (existsSync(journal)) throw new Error('Review and clean up the previous advanced-test journal first.');
const directory = mkdtempSync(join(tmpdir(), 'apple-helper-advanced-'));
const marker = `Apple Helper Advanced ${randomUUID()}`;
const range = { start: '2028-07-01T00:00:00+08:00', end: '2030-07-01T00:00:00+08:00' };
const queryRange = { start: range.start, end: '2029-07-01T00:00:00+08:00' };
writeFileSync(journal, JSON.stringify({ marker, directory, range }, null, 2), { mode: 0o600 });
const clients = [];
async function connect(extra = {}) {
  const client = new Client({ name: 'advanced-test', version: '1' });
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [join(root, 'src/server.js')], stderr: 'inherit', env: { ...process.env, APPLE_HELPER_DATA_DIR: directory, ...extra } }));
  clients.push(client); return client;
}
async function call(client, name, args = {}) {
  const result = await client.callTool({ name, arguments: args });
  if (result.isError) { const e = result.structuredContent?.error ?? JSON.parse(result.content[0].text); throw Object.assign(new Error(e.message), e); }
  return result.structuredContent;
}
const request = () => ({ request_id: randomUUID() });
const edit = item => ({ ...request(), id: item.id, expected_version: item.version, ...(item.occurrence_start ? { occurrence_start: item.occurrence_start } : {}) });
let client;
try {
  client = await connect();
  const calendar = (await call(client, 'list_calendars')).items.find(c => c.writable && !c.subscribed);
  const list = (await call(client, 'list_reminder_lists')).items.find(c => c.writable);
  const event = (label, start, end, extra = {}) => call(client, 'create_event', { ...request(), calendar_id: calendar.id, title: `${marker} ${label}`, start, end, time_zone: 'Asia/Shanghai', ...extra });
  const reminder = (label, extra = {}) => call(client, 'create_reminder', { ...request(), list_id: list.id, title: `${marker} ${label}`, ...extra });
  const series = await event('daily', '2028-07-01T10:00:00+08:00', '2028-07-01T11:00:00+08:00', { recurrence: { frequency: 'daily', count: 4 } });
  const seriesEvents = () => call(client, 'list_events', { ...queryRange, query: `${marker} daily`, calendar_id: calendar.id });
  let instances = (await seriesEvents()).items;
  assert.equal(instances.length, 4); assert.equal(series.recurrence_rules[0].count, 4);
  const detached = await call(client, 'update_event', { ...edit(instances[1]), title: `${marker} daily exception`, scope: 'this' });
  assert.equal(detached.title, `${marker} daily exception`);
  instances = (await seriesEvents()).items;
  assert.equal(instances.filter(x => x.title.endsWith('exception')).length, 1);
  assert.equal(instances.length, 4);
  const parent = await call(client, 'get_event_series', { id: instances[2].id });
  assert.equal(parent.start, '2028-07-01T02:00:00Z');
  await call(client, 'update_event', { ...edit(parent), notes: 'series-wide note', scope: 'all' });
  instances = (await seriesEvents()).items;
  assert.ok(instances.every(x => x.notes === 'series-wide note'));
  const third = instances[2];
  await call(client, 'update_event', { ...edit(third), title: `${marker} future segment`, scope: 'future' });
  const all = (await call(client, 'list_events', { ...queryRange, query: marker, calendar_id: calendar.id })).items;
  assert.equal(all.filter(x => x.title === `${marker} future segment`).length, 2);
  assert.ok(all.some(x => x.start === instances[0].start && x.title === instances[0].title));
  const tail = (await call(client, 'list_events', { ...queryRange, query: `${marker} future segment` })).items;
  assert.equal(tail.length, 2);
  await call(client, 'delete_event', { ...edit(tail[1]), scope: 'future' });
  assert.equal((await call(client, 'list_events', { ...queryRange, query: `${marker} future segment` })).total, 1);
  const oldRoot = await call(client, 'get_event_series', { id: all.find(x => x.title === `${marker} daily`).id });
  await call(client, 'delete_event', { ...edit(oldRoot), scope: 'all' });
  assert.equal((await seriesEvents()).total, 0, 'Whole-series deletion must remove detached exceptions as well');
  console.log('Recurring creation, single exception, whole-series and future-segment updates: PASS');

  const weekly = await event('weekly', '2028-07-06T09:00:00+08:00', '2028-07-06T09:30:00+08:00', { recurrence: { frequency: 'weekly', days_of_week: [{ day: 1 }, { day: 3 }], count: 4 } });
  assert.equal((await call(client, 'list_events', { ...queryRange, query: weekly.title })).total, 4);
  const weeklyRoot = await call(client, 'get_event_series', { id: weekly.id });
  await call(client, 'update_event', { ...edit(weeklyRoot), scope: 'all', recurrence: { frequency: 'daily', count: 2 } });
  assert.equal((await call(client, 'list_events', { ...queryRange, query: weekly.title })).total, 2);
  const monthly = await event('monthly', '2028-07-31T09:00:00+08:00', '2028-07-31T09:30:00+08:00', { recurrence: { frequency: 'monthly', days_of_month: [-1], count: 2 } });
  assert.equal((await call(client, 'list_events', { ...queryRange, query: monthly.title })).total, 2);
  const yearly = await event('yearly', '2028-07-01T09:00:00+08:00', '2028-07-01T09:30:00+08:00', { recurrence: { frequency: 'yearly', months_of_year: [7], count: 2 } });
  assert.equal(yearly.recurrence_rules[0].frequency, 'yearly');
  const ordinal = await event('ordinal', '2028-07-11T11:00:00+08:00', '2028-07-11T11:30:00+08:00', { recurrence: { frequency: 'monthly', days_of_week: [{ day: 2, week: 2 }], until: '2028-08-31T23:59:59+08:00' } });
  assert.equal((await call(client, 'list_events', { ...queryRange, query: ordinal.title })).total, 2);
  const infinite = await event('infinite', '2028-07-10T13:00:00+08:00', '2028-07-10T13:30:00+08:00', { recurrence: { frequency: 'daily' } });
  assert.ok((await call(client, 'list_events', { ...queryRange, query: infinite.title })).total > 300);
  const infiniteRoot = await call(client, 'get_event_series', { id: infinite.id });
  await call(client, 'update_event', { ...edit(infiniteRoot), scope: 'all', recurrence: null });
  assert.equal((await call(client, 'list_events', { ...queryRange, query: infinite.title })).total, 1);
  const rr = await reminder('recurring task', { due_at: '2028-07-01T15:00:00+08:00', recurrence: { frequency: 'weekly', count: 3 } });
  assert.equal(rr.recurring, true);
  const completed = await call(client, 'update_reminder', { ...edit(rr), allow_recurring: true, completed: true });
  assert.equal(completed.completed, true);
  assert.ok(completed.next_occurrence); assert.notEqual(completed.id, completed.next_occurrence.id);
  const generated = (await call(client, 'list_reminders', { query: rr.title, completed: false })).items;
  assert.ok(generated.some(x => Date.parse(x.due_at) > Date.parse(rr.due_at)), 'Completing a recurring reminder must generate the next occurrence');
  const noRule = await call(client, 'update_reminder', { ...edit(generated[0]), allow_recurring: true, recurrence: null });
  assert.equal(noRule.recurring, false);
  console.log('Weekly/monthly/yearly rules, recurring reminder creation and rule removal: PASS');

  await reminder('overdue', { due_date: '2028-06-30' });
  await reminder('due', { due_date: '2028-07-01' });
  await reminder('undated');
  const planning = { start: '2028-07-01T00:00:00+08:00', end: '2028-07-02T00:00:00+08:00', calendar_ids: [calendar.id], time_zone: 'Asia/Shanghai' };
  const agenda = await call(client, 'get_agenda', { ...planning, reminder_list_ids: [list.id], include_undated: true, limit: 200 });
  for (const category of ['scheduled', 'overdue', 'due', 'undated']) assert.ok(agenda.items.some(x => x.item.title.startsWith(marker) && x.category === category));
  const one = await call(client, 'get_agenda', { ...planning, reminder_list_ids: [list.id], limit: 1 });
  assert.equal(one.items.length, 1); assert.equal(one.next_offset, 1);
  const slots = await call(client, 'find_free_slots', { ...planning, duration_minutes: 30, work_hours: { days: [1, 2, 3, 4, 5, 6, 7], start: '09:00', end: '18:00' }, buffer_minutes: 10 });
  for (const window of slots.items) {
    assert.ok(Date.parse(window.end) - Date.parse(window.start) >= 30 * 60000);
    for (const busy of slots.busy_intervals) assert.ok(Date.parse(window.end) <= Date.parse(busy.start) || Date.parse(window.start) >= Date.parse(busy.end));
  }
  assert.ok(slots.busy_intervals.some(x => Date.parse(x.start) <= Date.parse('2028-07-01T08:50:00+08:00') && Date.parse(x.end) >= Date.parse('2028-07-01T09:40:00+08:00')));
  const free = await event('transparent', '2028-07-01T12:00:00+08:00', '2028-07-01T17:00:00+08:00', { availability: 'free' });
  assert.equal(free.availability, 'free');
  const slotArgs = { ...planning, duration_minutes: 30, work_hours: { days: [1, 2, 3, 4, 5, 6, 7], start: '09:00', end: '18:00' }, buffer_minutes: 10 };
  assert.deepEqual((await call(client, 'find_free_slots', slotArgs)).items, slots.items);
  const allDay = await event('all day', '2028-07-01T00:00:00+08:00', '2028-07-02T00:00:00+08:00', { all_day: true });
  assert.equal((await call(client, 'find_free_slots', slotArgs)).total, 0);
  assert.ok((await call(client, 'find_free_slots', { ...slotArgs, all_day_policy: 'ignore' })).total > 0);
  await call(client, 'delete_event', edit(allDay));
  await assert.rejects(call(client, 'find_free_slots', planning), { code: 'PLANNING_PREFERENCES_REQUIRED' });
  const farFuture = { ...planning, start: '2099-07-01T00:00:00+08:00', end: '2099-07-02T00:00:00+08:00' };
  await assert.rejects(call(client, 'find_free_slots', { ...slotArgs, ...farFuture }), { code: 'RECURRENCE_HORIZON' });
  assert.ok((await call(client, 'list_events', { start: farFuture.start, end: farFuture.end })).warnings.length);
  const prefs = await call(client, 'get_preferences');
  await call(client, 'update_preferences', { ...request(), expected_version: prefs.version, event_duration_minutes: 30, work_hours: slotArgs.work_hours, time_zone: 'Asia/Shanghai' });
  assert.deepEqual((await call(client, 'find_free_slots', { ...planning, buffer_minutes: 10 })).items, slots.items);
  console.log('Merged agenda categories/pagination and free slots with duration, busy merge and buffers: PASS');

  let moving = await event('moving', '2028-07-01T16:00:00+08:00', '2028-07-01T16:30:00+08:00', { alarms: [{ type: 'relative', offset_minutes: -10 }] });
  await event('blocker', '2028-07-01T10:00:00+08:00', '2028-07-01T11:00:00+08:00');
  await assert.rejects(call(client, 'reschedule_event', { ...edit(moving), start: '2028-07-01T10:15:00+08:00', calendar_ids: [calendar.id] }), { code: 'SCHEDULE_CONFLICT' });
  assert.equal((await call(client, 'get_event', { id: moving.id })).start, moving.start);
  moving = await call(client, 'reschedule_event', { ...edit(moving), start: '2028-07-01T10:15:00+08:00', calendar_ids: [calendar.id], conflict_policy: 'allow' });
  assert.equal(moving.end, '2028-07-01T02:45:00Z'); assert.equal(moving.alarms[0].offset_minutes, -10);
  assert.ok(moving.conflicts.length); assert.equal(moving.conflict_checked_scope, 'selected_occurrence');
  console.log('Conflict rejection without mutation, explicit overlap, preserved duration/alerts: PASS');

  const crashing = await connect({ APPLE_HELPER_BRIDGE_PATH: join(root, 'bin/eventkit-test-bridge'), APPLE_HELPER_TEST_CRASH_AFTER_WRITE: '1' });
  const crashedArgs = { ...request(), title: `${marker} crash`, calendar_id: calendar.id, start: '2028-07-01T20:00:00+08:00', end: '2028-07-01T21:00:00+08:00' };
  await assert.rejects(call(crashing, 'create_event', crashedArgs), { code: 'RESULT_UNKNOWN' });
  const operation = await call(client, 'get_operation', { request_id: crashedArgs.request_id });
  const actual = (await call(client, 'list_events', { ...queryRange, query: crashedArgs.title })).items[0];
  const resolutionArgs = { ...request(), target_request_id: crashedArgs.request_id, expected_operation_version: operation.version, conclusion: 'observed_applied', note: 'Test verified current fixture matches requested fields.', evidence: { kind: 'event', id: actual.id, expected_version: actual.version } };
  const resolved = await call(client, 'reconcile_operation', resolutionArgs);
  const pendingArgs = { ...crashedArgs, ...request(), title: `${marker} unresolved crash` };
  await assert.rejects(call(crashing, 'create_event', pendingArgs), { code: 'RESULT_UNKNOWN' });
  assert.equal(resolved.status, 'resolved'); assert.equal(resolved.resolution.historical_execution_proven, false);
  await assert.rejects(call(client, 'create_event', crashedArgs), { code: 'OPERATION_RESOLVED' });
  assert.equal((await call(client, 'reconcile_operation', resolutionArgs)).operation.replayed, true);
  // The isolated state directory contains only test records. Keep permanent ID fingerprints.
  await new Promise(resolve => setTimeout(resolve, 1100));
  const before = new Date().toISOString();
  const preview = await call(client, 'preview_operation_prune', { before }); assert.ok(preview.eligible_count > 0);
  const compacted = await call(client, 'prune_operations', { ...request(), before }); assert.equal(compacted.compacted_count, preview.eligible_count);
  const tombstone = await call(client, 'get_operation', { request_id: crashedArgs.request_id });
  const pending = await call(client, 'get_operation', { request_id: pendingArgs.request_id });
  assert.equal(pending.status, 'pending'); assert.equal(pending.compacted_at, undefined); assert.ok(pending.arguments);
  await assert.rejects(call(client, 'create_event', pendingArgs), { code: 'RESULT_UNKNOWN' });
  const abandonArgs = { ...request(), target_request_id: pendingArgs.request_id, expected_operation_version: pending.version, conclusion: 'abandoned', note: 'Test closes investigation without claiming original execution result.' };
  await assert.rejects(call(client, 'reconcile_operation', { ...abandonArgs, ...request(), expected_operation_version: '0'.repeat(64) }), { code: 'VERSION_CONFLICT' });
  await call(client, 'reconcile_operation', abandonArgs);
  await assert.rejects(call(client, 'create_event', pendingArgs), { code: 'OPERATION_RESOLVED' });
  assert.equal(tombstone.arguments, undefined); assert.ok(tombstone.fingerprint); assert.ok(tombstone.compacted_at);
  await assert.rejects(call(client, 'create_event', crashedArgs), { code: 'RESULT_PRUNED' });
  assert.equal((await call(client, 'list_events', { ...queryRange, query: crashedArgs.title })).total, 1);
  console.log('Crash reconciliation, replay protection, payload compaction and durable tombstones: PASS');
} finally {
  let cleanupOK = !!client;
  if (client) {
    try {
      for (const cleanupRange of [queryRange, { start: queryRange.end, end: range.end }]) {
        for (let pass = 0; pass < 100; pass++) {
          const items = (await call(client, 'list_events', { ...cleanupRange, query: marker, limit: 200 })).items;
          if (!items.length) break;
          const item = items[0];
          if (item.recurring && !item.detached) {
            const parent = await call(client, 'get_event_series', { id: item.id });
            assert.ok(parent.title.startsWith(marker));
            await call(client, 'delete_event', { ...edit(parent), scope: 'all' });
          } else await call(client, 'delete_event', edit(item));
        }
        assert.equal((await call(client, 'list_events', { ...cleanupRange, query: marker })).total, 0);
      }
      const reminders = (await call(client, 'list_reminders', { query: marker, limit: 200 })).items;
      for (const item of reminders) await call(client, 'delete_reminder', { ...edit(item), allow_recurring: true });
      assert.equal((await call(client, 'list_reminders', { query: marker })).total, 0);
    } catch (error) { cleanupOK = false; console.error('Cleanup needs attention:', error); }
  }
  for (const c of clients) await c.close();
  if (cleanupOK) { unlinkSync(journal); rmSync(directory, { recursive: true }); console.log('All advanced fixtures removed.'); }
  else throw new Error(`Cleanup incomplete; inspect ${journal}`);
}
