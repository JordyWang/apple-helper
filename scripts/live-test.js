import assert from 'node:assert/strict';
import { writeFileSync, unlinkSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

// Opt-in integration test: creates temporary items and only deletes IDs it created.
const root = fileURLToPath(new URL('../', import.meta.url));
const journal = `${root}.test-state.json`;
if (existsSync(journal)) throw new Error('A prior test journal exists. Review and clean up those exact test items before running again.');
const client = new Client({ name: 'apple-helper-live-test', version: '1' });
const transport = new StdioClientTransport({ command: process.execPath, args: [`${root}src/server.js`], stderr: 'inherit' });
const created = [];
const marker = `Apple Helper MCP 测试 ${randomUUID()}`;
const save = () => writeFileSync(journal, JSON.stringify({ marker, created }, null, 2), { mode: 0o600 });
async function call(name, args = {}) {
  args = { ...args };
  if (/^(create|update|delete)_/.test(name)) args.request_id ??= randomUUID();
  if (/^(update|delete)_/.test(name) && !args.expected_version) {
    const item = await call(name.endsWith('reminder') ? 'get_reminder' : 'get_event', { id: args.id });
    args.expected_version = item.version;
  }
  const result = await client.callTool({ name, arguments: args });
  if (result.isError) throw new Error(result.content[0].text);
  return result.structuredContent ?? JSON.parse(result.content[0].text);
}
async function remove(item) {
  await call(item.type === 'reminder' ? 'delete_reminder' : 'delete_event', { id: item.id });
  created.splice(created.indexOf(item), 1); save();
}
try {
  await client.connect(transport);
  assert.equal((await client.listTools()).tools.length, 25);
  const status = await call('get_status');
  assert.equal(status.calendar, 'full_access'); assert.equal(status.reminders, 'full_access');
  const list = (await call('list_reminder_lists')).items.find(c => c.writable);
  const calendar = (await call('list_calendars')).items.find(c => c.writable && !c.subscribed);
  assert.ok(list && calendar, 'Need a writable reminder list and calendar.');
  const notes = '临时测试数据\n"引号" 😀 $(literal)';
  const r = await call('create_reminder', { list_id: list.id, title: marker, notes, due_at: '2099-06-15T09:30:00+08:00', time_zone: 'Asia/Shanghai', priority: 1 });
  const rr = { type: 'reminder', id: r.id }; created.push(rr); save();
  assert.equal(r.notes, notes); assert.equal(r.due_at, '2099-06-15T01:30:00Z');
  assert.equal((await call('get_reminder', { id: r.id })).title, marker);
  const found = await call('list_reminders', { list_id: list.id, query: marker, completed: false, limit: 1 });
  assert.equal(found.items[0].id, r.id);
  assert.equal((await call('list_reminders', { list_id: list.id, query: marker, offset: 1 })).items.length, 0);
  const updated = await call('update_reminder', { id: r.id, title: `${marker} 已改`, completed: true, due_date: '2099-06-16', priority: 5 });
  assert.equal(updated.completed, true); assert.equal(updated.due_date, '2099-06-16'); assert.equal(updated.due_at, null);
  const cleared = await call('update_reminder', { id: r.id, due_date: null, completed: false, notes: '' });
  assert.equal(cleared.due_date, null); assert.equal(cleared.notes, '');
  console.log('Reminders create/read/query/update/complete/clear: PASS');

  const e = await call('create_event', { calendar_id: calendar.id, title: marker, notes, start: '2099-06-15T10:00:00+08:00', end: '2099-06-15T11:00:00+08:00', time_zone: 'Asia/Shanghai', location: '临时测试' });
  const er = { type: 'event', id: e.id }; created.push(er); save();
  assert.equal(e.notes, notes); assert.equal(e.start, '2099-06-15T02:00:00Z');
  assert.equal((await call('get_event', { id: e.id })).title, marker);
  const events = await call('list_events', { calendar_id: calendar.id, query: marker, start: '2099-06-15T00:00:00+08:00', end: '2099-06-16T00:00:00+08:00' });
  assert.ok(events.items.some(x => x.id === e.id));
  const moved = await call('update_event', { id: e.id, start: '2099-06-15T12:00:00+08:00', end: '2099-06-15T13:00:00+08:00', title: `${marker} 已改`, location: '' });
  er.id = moved.id; save();
  assert.equal(moved.start, '2099-06-15T04:00:00Z'); assert.equal(moved.location, '');
  await assert.rejects(call('update_event', { id: er.id, end: '2099-06-15T09:00:00+08:00', title: 'must not persist' }), /INVALID_RANGE/);
  assert.equal((await call('get_event', { id: er.id })).title, `${marker} 已改`);
  const allDay = await call('update_event', { id: er.id, all_day: true, start: '2099-06-16T00:00:00+08:00', end: '2099-06-17T00:00:00+08:00', time_zone: 'Asia/Shanghai' });
  er.id = allDay.id; save();
  assert.equal(allDay.all_day, true); assert.equal(allDay.start, '2099-06-15T16:00:00Z');
  assert.equal(allDay.end, '2099-06-16T16:00:00Z');
  const savedAllDay = await call('get_event', { id: er.id });
  assert.equal(savedAllDay.all_day, true); assert.equal(savedAllDay.end, allDay.end);
  console.log('Calendar create/read/query/update/all-day and rejected-write atomicity: PASS');
  await remove(er); await remove(rr);
  await assert.rejects(call('get_reminder', { id: r.id }), /NOT_FOUND/);
  await assert.rejects(call('get_event', { id: er.id }), /NOT_FOUND/);
  console.log('Both deletions verified; temporary test data removed: PASS');
} finally {
  for (const item of [...created]) {
    try { await remove(item); } catch (e) { console.error(`Cleanup failed for ${item.type} ${item.id}: ${e.message}`); }
  }
  if (created.length === 0 && existsSync(journal)) unlinkSync(journal);
  await client.close();
}
