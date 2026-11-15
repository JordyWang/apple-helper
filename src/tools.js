import { z } from 'zod';

const id = z.string().min(1).max(2048).describe('Use a returned ID, never a guessed name.');
const title = z.string().min(1).max(1000).refine(s => s.trim().length > 0, 'Title cannot be blank.');
const text = z.string().max(16000);
const timestamp = z.iso.datetime({ offset: true }).describe('ISO 8601 with Z or offset, e.g. 2026-11-16T09:00:00+08:00.');
const timeZone = z.string().refine(s => {
  try { new Intl.DateTimeFormat('en', { timeZone: s }); return true; } catch { return false; }
}, 'Use an IANA timezone, e.g. Asia/Shanghai.');
const requestId = z.string().min(1).max(200).describe('Unique ID for this logical write. Retry with the SAME ID and SAME arguments; use a new ID for a new action.');
const version = z.string().regex(/^[a-f0-9]{64}$/).describe('Exact version from the most recent get/list response. Stale writes are rejected.');
const write = { request_id: requestId };
const edit = { ...write, expected_version: version };
const create = { ...write, allow_duplicate: z.boolean().default(false).describe('Only true when an additional copy is intentionally requested.') };
const paging = { limit: z.number().int().min(1).max(200).default(50), offset: z.number().int().min(0).default(0) };
const alarm = z.discriminatedUnion('type', [
  z.strictObject({ type: z.literal('absolute'), at: timestamp }),
  z.strictObject({ type: z.literal('relative'), offset_minutes: z.number().int().min(-525600).max(525600).describe('Negative means before start / timed reminder due date. E.g. -10 is ten minutes before.') }),
]);
const notificationFields = {
  alarms: z.array(alarm).max(10).optional().describe('Replace time-based alerts. [] clears alerts. Omit to preserve existing alerts. Reminder relative alerts are normalized to absolute due-date offsets.'),
  alarm_policy: z.enum(['shift', 'preserve']).default('shift').describe('On rescheduling, shift moves absolute alerts by the same delta; preserve keeps absolute times. Relative alerts continue following the event.'),
};
const integers = (min, max) => z.array(z.number().int().min(min).max(max).refine(n => n !== 0)).min(1).max(366).refine(a => new Set(a).size === a.length);
const recurrence = z.strictObject({
  frequency: z.enum(['daily', 'weekly', 'monthly', 'yearly']),
  interval: z.number().int().min(1).max(999).default(1),
  days_of_week: z.array(z.strictObject({ day: z.number().int().min(1).max(7).describe('ISO Monday=1, Sunday=7.'), week: z.number().int().min(-53).max(53).default(0) })).min(1).max(7).optional(),
  days_of_month: integers(-31, 31).optional(), months_of_year: integers(1, 12).optional(),
  set_positions: integers(-366, 366).optional(),
  count: z.number().int().min(1).max(10000).optional(), until: timestamp.optional(),
}).superRefine((r, ctx) => {
  const issue = message => ctx.addIssue({ code: 'custom', message });
  if (r.count && r.until) issue('Choose count or until.');
  if (r.days_of_week && r.frequency === 'daily') issue('Daily recurrence cannot filter weekdays.');
  if (r.days_of_week?.some(d => d.week !== 0) && !['monthly', 'yearly'].includes(r.frequency)) issue('Ordinal weekdays require monthly/yearly recurrence.');
  if (r.frequency === 'monthly' && r.days_of_week?.some(d => Math.abs(d.week) > 5)) issue('Monthly ordinal weekdays must be -5 through 5.');
  if (r.days_of_month && r.frequency !== 'monthly') issue('Month days require monthly recurrence.');
  if (r.months_of_year && r.frequency !== 'yearly') issue('Months require yearly recurrence.');
  if (r.set_positions && !(r.days_of_week || r.days_of_month || r.months_of_year)) issue('Set positions require a day/month filter.');
});
const reminderFields = {
  title: title.optional(), notes: text.optional(), completed: z.boolean().optional(),
  priority: z.number().int().min(0).max(9).optional().describe('0=none; 1–4=high; 5=medium; 6–9=low.'),
  due_at: timestamp.nullable().optional().describe('Timed deadline; null clears. Does not itself enable a notification.'),
  due_date: z.iso.date().nullable().optional().describe('All-day YYYY-MM-DD. Mutually exclusive with due_at.'),
  alarm_at: timestamp.nullable().optional().describe('Legacy single absolute alert; null clears alerts. Mutually exclusive with alarms.'),
  time_zone: timeZone.optional(), recurrence: recurrence.nullable().optional(), ...notificationFields,
};
const eventFields = {
  title: title.optional(), notes: text.optional(), location: z.string().max(2000).optional(),
  start: timestamp.optional(), end: timestamp.optional(), all_day: z.boolean().optional(), time_zone: timeZone.optional(),
  availability: z.enum(['busy', 'free', 'tentative', 'unavailable']).optional().describe('Whether this event blocks scheduling; provider must support the selected value.'),
  url: z.union([z.literal(''), z.url({ protocol: /^https?$/ })]).optional(), recurrence: recurrence.nullable().optional(), ...notificationFields,
};
const eventRef = { id, occurrence_start: timestamp.optional().describe('For repeated events, use occurrence_start from list_events.') };
const scope = z.enum(['this', 'future', 'all']).default('this').describe('this=selected occurrence, future=this and following, all=series from its first occurrence. all requires expected_version from get_event_series.');
const reminderRules = s => s.refine(a => !(Object.hasOwn(a, 'due_at') && Object.hasOwn(a, 'due_date')), 'Use only one due field.')
  .refine(a => !(Object.hasOwn(a, 'alarm_at') && Object.hasOwn(a, 'alarms')), 'Use only one alarm field.');
const eventRange = s => s.refine(a => !a.start || !a.end || Date.parse(a.end) > Date.parse(a.start), 'end must be after start.');
const patch = (s, fields) => s.refine(a => fields.some(k => Object.hasOwn(a, k)), 'Supply at least one field to update.');
const preferenceFields = {
  default_calendar_id: id.nullable().optional().describe('User-selected calendar; null returns to the macOS default.'),
  default_reminder_list_id: id.nullable().optional().describe('User-selected reminder list; null returns to the macOS default.'),
  time_zone: timeZone.nullable().optional(),
  event_duration_minutes: z.number().int().min(1).max(1440).nullable().optional().describe('Explicit user preference, used when a new timed event omits end.'),
  work_hours: z.strictObject({
    days: z.array(z.number().int().min(1).max(7)).min(1).max(7).refine(a => new Set(a).size === a.length).describe('ISO weekday: Monday=1, Sunday=7.'),
    start: z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d$/),
    end: z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d$/),
  }).refine(a => a.end > a.start, 'Work hours must end after start.').nullable().optional(),
};
const planningRange = { start: timestamp, end: timestamp, time_zone: timeZone.optional(), calendar_ids: z.array(id).min(1).max(100).optional() };
const planRange = s => eventRange(s).refine(a => Date.parse(a.end) - Date.parse(a.start) <= 366 * 86400000, 'Maximum range is 366 days.');
const evidence = z.strictObject({ kind: z.enum(['event', 'reminder']), id, occurrence_start: timestamp.optional(), expected_version: version });

export const tools = [
  { name: 'get_status', description: 'Check macOS permissions and timezone.', schema: z.strictObject({}), readOnly: true },
  { name: 'request_access', description: 'Request macOS full access; may display a system permission dialog.', schema: z.strictObject({ target: z.enum(['calendar', 'reminders', 'both']).default('both') }) },
  { name: 'get_preferences', description: 'Read saved user preferences, effective defaults, system default calendar/list, and preference version. Does not invent preferences.', schema: z.strictObject({}), readOnly: true },
  { name: 'update_preferences', description: 'Persist only preferences explicitly chosen by the user. Null resets a field. Requires current preference version and a request ID.', schema: patch(z.strictObject({ ...preferenceFields, ...edit }), Object.keys(preferenceFields)), destructive: true, mutation: true },
  { name: 'get_operation', description: 'Look up a durable write record by request_id, including result or failure. Pending/uncertain means inspect current item state before a new write; never blindly retry under a new ID.', schema: z.strictObject({ request_id: requestId }), readOnly: true },
  { name: 'reconcile_operation', description: 'Record an operator conclusion for a pending/uncertain write after inspecting actual data. Never repeats the original action or claims historical atomic proof. observed_applied requires a fresh item as evidence, or verified absence for a deletion. abandoned closes investigation without asserting success/failure.', schema: z.strictObject({ ...write, target_request_id: requestId, expected_operation_version: version, conclusion: z.enum(['observed_applied', 'abandoned']), note: z.string().min(1).max(2000), evidence: evidence.optional() }), mutation: true },
  { name: 'preview_operation_prune', description: 'Count terminal operation payloads eligible for compaction before a timestamp. Request IDs and fingerprints will always remain; unresolved operations are excluded.', schema: z.strictObject({ before: timestamp }), readOnly: true },
  { name: 'prune_operations', description: 'Compact old terminal operation payloads, preserving permanent request-ID tombstones. Replays of compacted requests return RESULT_PRUNED and never execute again. Does not alter Calendar/Reminders.', schema: z.strictObject({ ...write, before: timestamp }), mutation: true, destructive: true },
  { name: 'list_operations', description: 'List recent operation metadata without item content.', schema: z.strictObject({ limit: z.number().int().min(1).max(100).default(20) }), readOnly: true },
  { name: 'list_reminder_lists', description: 'List reminder lists, IDs, account sources, writability, and system-default flags.', schema: z.strictObject({}), readOnly: true },
  { name: 'list_reminders', description: 'Query reminders by list, title/notes, completion, due range [after,before), with pagination and versions.', schema: z.strictObject({ list_id: id.optional(), query: z.string().max(1000).optional(), completed: z.boolean().optional(), due_after: timestamp.optional(), due_before: timestamp.optional(), ...paging }).refine(a => !a.due_after || !a.due_before || Date.parse(a.due_before) > Date.parse(a.due_after), 'Invalid due range.'), readOnly: true },
  { name: 'get_reminder', description: 'Get a reminder, its full time-alert list, and version for subsequent edits.', schema: z.strictObject({ id }), readOnly: true },
  { name: 'create_reminder', description: 'Create a reminder. Omitted list_id uses the saved preference, then macOS default. Request ID prevents replay; duplicate title/deadline is detected.', schema: reminderRules(z.strictObject({ ...reminderFields, ...create, list_id: id.optional(), title })), mutation: true },
  { name: 'update_reminder', description: 'Update supplied fields using expected_version. Due-date changes shift absolute alerts by default; use alarm_policy=preserve to retain times. Omitted alarms retain all alerts. Recurring items need allow_recurring.', schema: reminderRules(patch(z.strictObject({ ...reminderFields, ...edit, id, list_id: id.optional(), allow_recurring: z.boolean().default(false) }), [...Object.keys(reminderFields).filter(k => !['time_zone', 'alarm_policy'].includes(k)), 'list_id'])), destructive: true, mutation: true },
  { name: 'delete_reminder', description: 'Delete a reminder using its current version. Only when requested; recurring deletion needs allow_recurring.', schema: z.strictObject({ ...edit, id, allow_recurring: z.boolean().default(false) }), destructive: true, mutation: true },
  { name: 'list_calendars', description: 'List calendars, IDs, account sources, writability, and system-default flags.', schema: z.strictObject({}), readOnly: true },
  { name: 'get_agenda', description: 'Combined, chronologically paginated events and unfinished reminders for a range, optionally including overdue and undated tasks. One native snapshot; returns categories and totals.', schema: planRange(z.strictObject({ ...planningRange, reminder_list_ids: z.array(id).min(1).max(100).optional(), include_overdue: z.boolean().default(true), include_undated: z.boolean().default(false), ...paging })), readOnly: true },
  { name: 'find_free_slots', description: 'Compute free windows using all selected calendars, merged busy intervals, buffers and work hours in an IANA timezone. Uses explicit duration/work hours, then saved preferences; missing values are errors. Free/cancelled events do not block. Each returned window includes one suggested slot.', schema: planRange(z.strictObject({ ...planningRange, duration_minutes: z.number().int().min(1).max(1440).optional(), work_hours: preferenceFields.work_hours.unwrap().unwrap().optional(), buffer_minutes: z.number().int().min(0).max(240).default(0), all_day_policy: z.enum(['block', 'ignore']).default('block'), ...paging })), readOnly: true },
  { name: 'get_event_series', description: 'Read the series first occurrence and version for scope=all mutations. Also accepts an occurrence ID; detached exceptions without an unambiguous parent are rejected.', schema: z.strictObject({ id }), readOnly: true },
  { name: 'list_events', description: 'Query events overlapping [start,end), including recurring occurrences and versions. Max 366 days; chronological, paginated.', schema: eventRange(z.strictObject({ start: timestamp, end: timestamp, calendar_id: id.optional(), query: z.string().max(1000).optional(), ...paging })).refine(a => Date.parse(a.end) - Date.parse(a.start) <= 366 * 86400000, 'Maximum range is 366 days.'), readOnly: true },
  { name: 'get_event', description: 'Get an event, alerts, and version. Repeated events require occurrence_start.', schema: z.strictObject(eventRef), readOnly: true },
  { name: 'create_event', description: 'Create an event with multiple absolute/relative alerts. Omit calendar_id to use preference/system default. Omit end only if a duration preference exists. All-day boundaries are Mac-local midnights, end exclusive.', schema: eventRange(z.strictObject({ ...eventFields, ...create, calendar_id: id.optional(), title, start: timestamp })), mutation: true },
  { name: 'update_event', description: 'Edit using expected_version. New start without end preserves duration. Absolute alerts shift with start by default; relative alerts retain offsets. Omit alarms to retain them. Attendee meetings cannot be modified.', schema: eventRange(patch(z.strictObject({ ...eventFields, ...eventRef, ...edit, calendar_id: id.optional(), scope }), [...Object.keys(eventFields).filter(k => k !== 'alarm_policy'), 'calendar_id'])), destructive: true, mutation: true },
  { name: 'delete_event', description: 'Delete using current version. Repeated events need occurrence_start; defaults to this occurrence. Meetings with attendees cannot be deleted.', schema: z.strictObject({ ...eventRef, ...edit, scope }), destructive: true, mutation: true },
  { name: 'reschedule_event', description: 'Move an event preserving duration and alerts, checking conflicts before saving. Default rejects conflicts across all calendars; allow only when overlapping is intended. For recurring scopes, conflict check covers the selected moved occurrence only and reports that boundary.', schema: eventRange(z.strictObject({ ...eventRef, ...edit, start: timestamp, end: timestamp.optional(), time_zone: timeZone.optional(), scope, alarm_policy: notificationFields.alarm_policy, conflict_policy: z.enum(['reject', 'allow']).default('reject'), calendar_ids: z.array(id).min(1).max(100).optional() })), mutation: true, destructive: true },
];
