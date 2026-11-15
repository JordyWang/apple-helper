import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, existsSync, unlinkSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const root = fileURLToPath(new URL('../', import.meta.url));
const journal = join(root, '.extensions-test-state.json');
if (existsSync(journal)) throw new Error('Clean the exact prior extension fixtures before retrying.');
const directory = mkdtempSync(join(tmpdir(), 'apple-helper-extensions-'));
const marker = `Apple Helper Extensions ${randomUUID()}`;
writeFileSync(journal, JSON.stringify({ marker, directory }, null, 2), { mode: 0o600 });
const clients = [];
async function connect(env = {}) {
  const c = new Client({ name: 'extensions-test', version: '1' });
  await c.connect(new StdioClientTransport({ command: process.execPath, args: [join(root, 'src/server.js')], env: { ...process.env, APPLE_HELPER_DATA_DIR: directory, ...env }, stderr: 'inherit' }));
  clients.push(c); return c;
}
async function call(c, name, args = {}) {
  const result = await c.callTool({ name, arguments: args }, undefined, { timeout: 140000 });
  if (result.isError) { const error = result.structuredContent?.error ?? JSON.parse(result.content[0].text); throw Object.assign(new Error(error.message), error); }
  return result.structuredContent;
}
const request = () => ({ request_id: randomUUID() });
const edit = x => ({ ...request(), id: x.id, expected_version: x.version, ...(x.occurrence_start ? { occurrence_start: x.occurrence_start } : {}) });
const native = (operation, args, env = {}) => JSON.parse(execFileSync(join(root, 'bin/eventkit-test-bridge'), [], { input: JSON.stringify({ operation, arguments: args }), encoding: 'utf8', env: { ...process.env, APPLE_HELPER_DATA_DIR: directory, ...env } }));
let client;
try {
  client = await connect();
  assert.equal((await client.listTools()).tools.length, 40);
  assert.ok((await call(client, 'list_sources')).items.length);
  let calendar = await call(client, 'create_calendar', { ...request(), name: `${marker} calendar`, color: '#336699' });
  let list = await call(client, 'create_reminder_list', { ...request(), name: `${marker} reminders`, color: '#669933' });
  assert.equal(calendar.color, '#336699'); assert.equal(list.color, '#669933');
  assert.ok(calendar.source_id && calendar.version && list.version);
  await assert.rejects(call(client, 'create_calendar', { ...request(), name: calendar.name, source_id: calendar.source_id }), { code: 'DUPLICATE_FOUND' });
  const oldCalendar = calendar;
  calendar = await call(client, 'update_calendar', { ...edit(calendar), name: `${marker} renamed calendar`, color: '#993366' });
  await assert.rejects(call(client, 'update_calendar', { ...edit(oldCalendar), name: 'Must not rename' }), { code: 'VERSION_CONFLICT' });
  list = await call(client, 'update_reminder_list', { ...edit(list), name: `${marker} renamed reminders` });
  console.log('Calendar/list create, rename, color, duplicate protection and stale versions: PASS');

  const range = { start: '2028-08-01T09:00:00+08:00', end: '2028-08-01T18:00:00+08:00', time_zone: 'Asia/Shanghai', calendar_ids: [calendar.id] };
  const scope = { ...range, reminder_list_ids: [list.id] };
  const hours = { days: [1, 2, 3, 4, 5, 6, 7], start: '09:00', end: '18:00' };
  const createEvent = (label, start, end, extra = {}) => call(client, 'create_event', { ...request(), calendar_id: calendar.id, title: `${marker} ${label}`, start, end, time_zone: 'Asia/Shanghai', ...extra });
  const createReminder = (label, extra = {}) => call(client, 'create_reminder', { ...request(), list_id: list.id, title: `${marker} ${label}`, ...extra });
  await createEvent('busy', '2028-08-01T10:00:00+08:00', '2028-08-01T11:00:00+08:00');
  const taskA = await createReminder('A', { due_at: '2028-08-01T12:00:00+08:00', priority: 1 });
  const taskB = await createReminder('B', { due_date: '2028-08-01', priority: 5 });
  const large = await createReminder('too large', { due_date: '2028-08-01' });
  const completed = await createReminder('already complete', { completed: true });
  const planArgs = { ...range, destination_calendar_id: calendar.id, work_hours: hours, tasks: [{ reminder_id: taskB.id, duration_minutes: 60 }, { reminder_id: large.id, duration_minutes: 1000 }, { reminder_id: taskA.id, duration_minutes: 60 }, { reminder_id: completed.id, duration_minutes: 30 }] };
  const plan = await call(client, 'plan_tasks', planArgs);
  assert.equal(plan.assignments.length, 2); assert.equal(plan.unscheduled.length, 2);
  assert.equal(plan.assignments[0].reminder_id, taskA.id);
  assert.equal(plan.assignments[0].start, '2028-08-01T01:00:00Z');
  assert.equal(plan.assignments[1].start, '2028-08-01T03:00:00Z');
  assert.ok(plan.unscheduled.some(x => x.reason === 'already_completed'));
  assert.ok(plan.unscheduled.some(x => x.reason === 'no_contiguous_slot_before_deadline'));
  const applyArgs = { ...request(), plan_id: plan.plan_id, expected_plan_version: plan.version };
  const applied = await call(client, 'apply_plan', applyArgs);
  assert.equal(applied.status, 'succeeded'); assert.equal(applied.succeeded_count, 2);
  assert.equal((await call(client, 'apply_plan', applyArgs)).operation.replayed, true);
  assert.equal((await call(client, 'apply_plan', { ...applyArgs, ...request() })).succeeded_count, 2);
  assert.equal((await call(client, 'get_plan', { plan_id: plan.plan_id })).links.length, 2);
  assert.equal((await call(client, 'get_reminder', { id: taskA.id })).completed, false);
  const again = await call(client, 'plan_tasks', { ...planArgs, tasks: [{ reminder_id: taskA.id, duration_minutes: 60 }] });
  assert.equal(again.unscheduled[0].reason, 'already_scheduled');
  assert.equal((await call(client, 'check_conflicts', range)).total, 0);
  console.log('Task scheduling, unscheduled reasons, plan apply/replay/linking and no auto-completion: PASS');

  const extra = await createReminder('new task', { due_date: '2028-08-01' });
  const stalePlan = await call(client, 'plan_tasks', { ...planArgs, tasks: [{ reminder_id: extra.id, duration_minutes: 30 }] });
  const assignment = stalePlan.assignments[0];
  const obstruction = await createEvent('new obstruction', assignment.start, assignment.end);
  const staleApply = { ...request(), plan_id: stalePlan.plan_id, expected_plan_version: stalePlan.version };
  const blocked = await call(client, 'apply_plan', staleApply);
  assert.equal(blocked.status, 'partial'); assert.equal(blocked.items[0].error.code, 'SCHEDULE_CONFLICT');
  await call(client, 'delete_event', edit(obstruction));
  const resumed = await call(client, 'apply_plan', staleApply);
  assert.equal(resumed.status, 'succeeded'); assert.equal(resumed.items[0].attempt, 1);
  const changed = await createReminder('changed source', { due_date: '2028-08-01' });
  const changedPlan = await call(client, 'plan_tasks', { ...planArgs, tasks: [{ reminder_id: changed.id, duration_minutes: 30 }] });
  await call(client, 'update_reminder', { ...edit(changed), completed: true });
  const refused = await call(client, 'apply_plan', { ...request(), plan_id: changedPlan.plan_id, expected_plan_version: changedPlan.version });
  assert.equal(refused.items[0].error.code, 'VERSION_CONFLICT');
  console.log('Apply-time conflicts/source changes and safe resumption after known failure: PASS');

  const r1 = await createReminder('batch one'), r2 = await createReminder('batch two');
  const onceFile = join(directory, 'fail-once'); writeFileSync(onceFile, '');
  const changedTitle = `${marker} resumed title`;
  const faultClient = await connect({ APPLE_HELPER_BRIDGE_PATH: join(root, 'bin/eventkit-test-bridge'), APPLE_HELPER_TEST_FAIL_ONCE_TITLE: changedTitle, APPLE_HELPER_TEST_FAIL_ONCE_FILE: onceFile });
  const batch = { ...request(), items: [{ key: 'one', kind: 'reminder', id: r1.id, expected_version: r1.version, changes: { title: changedTitle } }, { key: 'two', kind: 'reminder', id: r2.id, expected_version: r2.version, changes: { completed: true } }] };
  const partial = await call(faultClient, 'batch_update', batch);
  assert.equal(partial.failed_count, 1); assert.equal(partial.not_started_count, 1); assert.equal(partial.items[0].error.code, 'TEST_TRANSIENT');
  const full = await call(faultClient, 'batch_update', batch);
  assert.equal(full.status, 'succeeded'); assert.equal(full.succeeded_count, 2); assert.equal(full.items[0].attempt, 1);
  assert.equal((await call(client, 'batch_update', batch)).operation.replayed, true);
  await assert.rejects(call(client, 'batch_update', { ...batch, on_error: 'continue' }), { code: 'REQUEST_ID_REUSED' });
  const cancelFile = join(directory, 'cancel'); writeFileSync(cancelFile, '');
  const r3 = await createReminder('cancel batch');
  const cancelledBatch = { ...request(), on_error: 'stop', items: [{ key: 'r3', kind: 'reminder', id: r3.id, expected_version: r3.version, allow_recurring: false, changes: { completed: true, alarm_policy: 'shift' } }] };
  const cancelled = native('batch_update', cancelledBatch, { APPLE_HELPER_CANCEL_FILE: cancelFile });
  assert.equal(cancelled.data.cancelled, true); assert.equal(cancelled.data.succeeded_count, 0); unlinkSync(cancelFile);
  assert.equal(native('batch_update', cancelledBatch).data.status, 'succeeded');
  const moving = await createEvent('batch event', '2028-08-06T10:00:00+08:00', '2028-08-06T11:00:00+08:00');
  const continued = await call(client, 'batch_update', { ...request(), on_error: 'continue', items: [
    { key: 'stale', kind: 'reminder', id: r1.id, expected_version: r1.version, changes: { notes: 'must not overwrite' } },
    { key: 'event', kind: 'event', id: moving.id, expected_version: moving.version, changes: { start: '2028-08-06T12:00:00+08:00' } },
  ] });
  assert.equal(continued.failed_count, 1); assert.equal(continued.succeeded_count, 1);
  assert.equal(continued.items[1].result.end, '2028-08-06T05:00:00Z');
  console.log('Batch stop/resume, per-item results, replay and cancellation before remaining steps: PASS');

  const undo = async (target, extra = {}, via = client) => { const op = await call(client, 'get_operation', { request_id: target }); return call(via, 'undo_operation', { ...request(), target_request_id: target, expected_operation_version: op.version, ...extra }); };
  let restoredReminder = await createReminder('undo reminder', { notes: 'original', due_at: '2028-08-03T09:00:00+08:00' });
  const update = { ...edit(restoredReminder), notes: 'changed', due_at: '2028-08-03T10:00:00+08:00' };
  await call(client, 'update_reminder', update);
  restoredReminder = await undo(update.request_id);
  assert.equal(restoredReminder.notes, 'original'); assert.equal(restoredReminder.due_at, '2028-08-03T01:00:00Z');
  await assert.rejects(undo(update.request_id), { code: 'UNDO_ALREADY_STARTED' });
  const staleUpdate = { ...edit(restoredReminder), notes: 'intermediate' };
  const intermediate = await call(client, 'update_reminder', staleUpdate);
  const later = await call(client, 'update_reminder', { ...edit(intermediate), notes: 'newer user edit' });
  await assert.rejects(undo(staleUpdate.request_id), { code: 'VERSION_CONFLICT' });
  assert.equal((await call(client, 'get_reminder', { id: later.id })).notes, 'newer user edit');
  const deletion = edit(later); await call(client, 'delete_reminder', deletion);
  await assert.rejects(undo(deletion.request_id), { code: 'RECREATE_REQUIRED' });
  const recreated = await undo(deletion.request_id, { allow_recreate: true });
  assert.equal(recreated.restored_as_new, true); assert.notEqual(recreated.id, later.id); assert.equal(recreated.notes, later.notes);
  let undoEvent = await createEvent('undo event', '2028-08-03T10:00:00+08:00', '2028-08-03T11:00:00+08:00', { alarms: [{ type: 'relative', offset_minutes: -10 }] });
  const originalAlarms = undoEvent.alarms;
  const moveArgs = { ...edit(undoEvent), start: '2028-08-03T12:00:00+08:00' };
  await call(client, 'update_event', moveArgs); undoEvent = await undo(moveArgs.request_id);
  assert.equal(undoEvent.start, '2028-08-03T02:00:00Z');
  assert.deepEqual(undoEvent.alarms, originalAlarms);
  const eventDelete = edit(undoEvent); await call(client, 'delete_event', eventDelete);
  const recoveredEvent = await undo(eventDelete.request_id, { allow_recreate: true });
  assert.notEqual(recoveredEvent.id, undoEvent.id); assert.equal(recoveredEvent.start, undoEvent.start);
  assert.deepEqual(recoveredEvent.alarms, originalAlarms);
  const temporary = await createEvent('undo creation', '2028-08-04T10:00:00+08:00', '2028-08-04T11:00:00+08:00');
  await undo(temporary.operation.request_id);
  await assert.rejects(call(client, 'get_event', { id: temporary.id }), { code: 'NOT_FOUND' });
  const prefs = await call(client, 'get_preferences');
  const preferenceWrite = { ...request(), expected_version: prefs.version, event_duration_minutes: 35 };
  await call(client, 'update_preferences', preferenceWrite);
  assert.deepEqual((await undo(preferenceWrite.request_id)).preferences, prefs.preferences);
  console.log('Undo create/update/delete/preferences, new IDs on restore and later-edit protection: PASS');

  const changeArgs = { ...scope, limit: 1 };
  let page = await call(client, 'get_changes', changeArgs); assert.equal(page.baseline, true);
  const baseline = [...page.items];
  const addedAfterSnapshot = await createReminder('snapshot addition');
  while (page.next_page_token) { page = await call(client, 'get_changes', { page_token: page.next_page_token }); baseline.push(...page.items); }
  const cursor = page.cursor; assert.ok(cursor); assert.ok(!baseline.some(x => x.after?.id === addedAfterSnapshot.id));
  const freshA = await call(client, 'get_reminder', { id: taskA.id });
  await call(client, 'update_reminder', { ...edit(freshA), notes: 'snapshot update' });
  const freshB = await call(client, 'get_reminder', { id: taskB.id }); await call(client, 'delete_reminder', edit(freshB));
  let delta = await call(client, 'get_changes', { ...changeArgs, cursor, limit: 200 });
  assert.equal(delta.baseline, false);
  assert.ok(delta.items.some(x => x.change === 'added' && x.after.id === addedAfterSnapshot.id));
  assert.ok(delta.items.some(x => x.change === 'updated' && x.after.id === taskA.id));
  assert.ok(delta.items.some(x => x.change === 'removed' && x.before.id === taskB.id && x.meaning === 'absent_from_scope_not_proof_of_deletion'));
  assert.equal((await call(client, 'get_changes', { ...changeArgs, cursor: delta.cursor })).total, 0);
  await assert.rejects(call(client, 'get_changes', { ...changeArgs, cursor, end: '2028-08-01T19:00:00+08:00' }), { code: 'CURSOR_SCOPE_MISMATCH' });
  assert.match(cursor, /^[A-Fa-f0-9-]+$/);
  execFileSync('/usr/bin/sqlite3', [join(directory, 'state.sqlite3'), `UPDATE records SET value=json_set(value,'$.expires_at','2000-01-01T00:00:00Z') WHERE key='snapshot:${cursor}'`]);
  await assert.rejects(call(client, 'get_changes', { ...changeArgs, cursor }), { code: 'CURSOR_EXPIRED' });
  console.log('Snapshot baseline, frozen pagination, added/updated/removed and cursor scope: PASS');

  await createEvent('overlap one', '2028-08-02T13:00:00+08:00', '2028-08-02T14:00:00+08:00');
  await createEvent('overlap two', '2028-08-02T13:30:00+08:00', '2028-08-02T14:30:00+08:00');
  const statsScope = { ...scope, start: '2028-08-02T13:00:00+08:00', end: '2028-08-02T15:00:00+08:00', as_of: '2028-08-02T15:00:00+08:00' };
  const stats = await call(client, 'get_statistics', statsScope);
  assert.equal(stats.events.scheduled_minutes_sum, 120); assert.equal(stats.events.timed_busy_minutes_union, 90);
  assert.equal(stats.daily[0].scheduled_minutes_sum, 120); assert.ok(stats.reminders.overdue_as_of > 0);
  const conflicts = await call(client, 'check_conflicts', { ...range, start: statsScope.start, end: statsScope.end, limit: 1 });
  assert.equal(conflicts.total, 1); assert.equal(conflicts.items[0].overlap_minutes, 30);
  const now = Date.now();
  const completionStats = await call(client, 'get_statistics', { ...scope, start: new Date(now - 3600000).toISOString(), end: new Date(now + 3600000).toISOString() });
  assert.ok(completionStats.reminders.completed_in_range >= 3);
  const recurring = await createEvent('recurring conflict', '2028-08-07T09:00:00+08:00', '2028-08-07T10:00:00+08:00', { recurrence: { frequency: 'daily', count: 3 } });
  await createEvent('third occurrence overlap', '2028-08-09T09:30:00+08:00', '2028-08-09T10:30:00+08:00');
  const recurrenceRange = { ...range, start: '2028-08-09T00:00:00+08:00', end: '2028-08-10T00:00:00+08:00' };
  const recurringConflicts = await call(client, 'check_conflicts', recurrenceRange);
  assert.equal(recurringConflicts.total, 1); assert.equal(recurringConflicts.items[0].overlap_minutes, 30);
  await assert.rejects(undo(recurring.operation.request_id), { code: 'UNDO_UNSUPPORTED' });
  const linked = (await call(client, 'get_plan', { plan_id: plan.plan_id })).links[0];
  await call(client, 'delete_event', edit(linked.current_event));
  const missingLink = (await call(client, 'get_plan', { plan_id: plan.plan_id })).links.find(x => x.event_id === linked.event_id);
  assert.equal(missingLink.state, 'missing');
  console.log('Conflict pairs, planned sum versus busy union, daily buckets and completion statistics: PASS');

  const crashTask = await createReminder('crash plan', { due_date: '2028-08-05' });
  const crashPlan = await call(client, 'plan_tasks', { ...planArgs, start: '2028-08-05T09:00:00+08:00', end: '2028-08-05T18:00:00+08:00', tasks: [{ reminder_id: crashTask.id, duration_minutes: 30 }] });
  const crashClient = await connect({ APPLE_HELPER_BRIDGE_PATH: join(root, 'bin/eventkit-test-bridge'), APPLE_HELPER_TEST_CRASH_AFTER_WRITE: '1' });
  const crashApply = { ...request(), plan_id: crashPlan.plan_id, expected_plan_version: crashPlan.version };
  await assert.rejects(call(crashClient, 'apply_plan', crashApply), { code: 'RESULT_UNKNOWN' });
  const uncertain = await call(client, 'apply_plan', crashApply);
  assert.equal(uncertain.uncertain_count, 1);
  const crashEvents = await call(client, 'list_events', { start: '2028-08-05T00:00:00+08:00', end: '2028-08-06T00:00:00+08:00', calendar_id: calendar.id, query: crashTask.title });
  assert.equal(crashEvents.total, 1);
  const victim = await createReminder('undo crash');
  const victimDelete = edit(victim); await call(client, 'delete_reminder', victimDelete);
  await assert.rejects(undo(victimDelete.request_id, { allow_recreate: true }, crashClient), { code: 'RESULT_UNKNOWN' });
  await assert.rejects(undo(victimDelete.request_id, { allow_recreate: true }), { code: 'UNDO_ALREADY_STARTED' });
  assert.equal((await call(client, 'list_reminders', { list_id: list.id, query: victim.title })).total, 1);
  console.log('Crash during plan/undo: pending records prevent duplicate writes or restoration: PASS');
} finally {
  let clean = !!client;
  if (client) {
    for (const kind of ['calendar', 'reminder_list']) {
      try {
        const name = kind === 'calendar' ? 'list_calendars' : 'list_reminder_lists';
        const containers = (await call(client, name)).items.filter(x => x.name.startsWith(marker));
        for (const container of containers) await call(client, `delete_${kind}`, { ...edit(container), delete_contents: true });
        assert.equal((await call(client, name)).items.filter(x => x.name.startsWith(marker)).length, 0);
      } catch (error) { clean = false; console.error('Fixture container cleanup failed:', error); }
    }
  }
  for (const c of clients) await c.close();
  if (clean) { unlinkSync(journal); rmSync(directory, { recursive: true }); console.log('Dedicated test calendars/lists and all contained fixtures removed.'); }
  else throw new Error(`Cleanup incomplete; inspect ${journal}`);
}
