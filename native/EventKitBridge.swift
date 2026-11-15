import Foundation
import EventKit

struct BridgeError: Error {
    let code: String
    let message: String
    let details: [String: Any]
    init(_ code: String, _ message: String, _ details: [String: Any] = [:]) { self.code = code; self.message = message; self.details = details }
    var data: [String: Any] { ["code": code, "message": message, "details": details] }
}

@available(macOS 14.0, *)
final class Bridge {
    let store = EKEventStore()
    let iso = ISO8601DateFormatter()
    let null = NSNull()
    let state: StateStore
    var writeAttempted = false
    init() throws { state = try StateStore() }
    func versioned(_ data: [String: Any], modified: Date?) -> [String: Any] {
        var result = data
        result["version"] = try! fingerprint(["item": data, "modified": modified?.timeIntervalSince1970 as Any? ?? null])
        return result
    }
    func checkVersion(_ data: [String: Any], _ a: [String: Any]) throws {
        guard let expected = a["expected_version"] as? String else { throw BridgeError("VERSION_REQUIRED", "Read the item first and pass its version as expected_version.") }
        guard expected == data["version"] as? String else {
            throw BridgeError("VERSION_CONFLICT", "The item changed since it was read. Read it again and reapply the intended edit.", ["current": data])
        }
    }
    func operationKey(_ id: String) -> String { "operation:" + id }
    func execute(_ op: String, _ args: [String: Any]) async throws -> [String: Any] {
        if op == "batch_update" || op == "apply_plan" { return try await executeBatch(op, args) }
        let mutations = ["create_event", "update_event", "delete_event", "create_reminder", "update_reminder", "delete_reminder", "update_preferences", "reschedule_event", "reconcile_operation", "prune_operations", "create_calendar", "update_calendar", "delete_calendar", "create_reminder_list", "update_reminder_list", "delete_reminder_list", "create_task_event", "undo_operation"]
        guard mutations.contains(op) else { return try await run(op, args) }
        writeAttempted = false
        let id = try required(args, "request_id")
        let hash = try fingerprint(["tool": op, "arguments": args])
        try state.begin()
        do {
            if let previous = try state.get(operationKey(id)) {
                state.rollback()
                guard previous["fingerprint"] as? String == hash else { throw BridgeError("REQUEST_ID_REUSED", "This request_id belongs to different arguments. Use a new ID for a new action.") }
                if previous["compacted_at"] != nil { throw BridgeError("RESULT_PRUNED", "The stored result was compacted. This request will never execute again.", ["request_id": id, "status": previous["status"] ?? null]) }
                if previous["resolution"] != nil { throw BridgeError("OPERATION_RESOLVED", "Investigation was closed; inspect get_operation for the recorded conclusion. This request will never execute again.", ["request_id": id]) }
                if previous["status"] as? String == "succeeded", var result = previous["result"] as? [String: Any] {
                    result["operation"] = ["request_id": id, "replayed": true, "verified": true]
                    return result
                }
                if let error = previous["error"] as? [String: Any] {
                    throw BridgeError(error["code"] as? String ?? "OPERATION_FAILED", error["message"] as? String ?? "Previous operation failed.", error["details"] as? [String: Any] ?? [:])
                }
                throw BridgeError("RESULT_UNKNOWN", "This request was already started. It will not be executed again. Use get_operation and query the item before any new write.", ["request_id": id])
            }
            if op == "undo_operation" { try claimUndo(args) }
            store.reset()
            let undo: [String: Any]
            do { undo = try undoSnapshot(op, args) }
            catch { undo = ["supported": false, "reason": "Snapshot unavailable; the operation will still perform its normal validation."] }
            let record: [String: Any] = ["request_id": id, "tool": op, "fingerprint": hash, "status": "pending", "created_at": iso.string(from: Date()), "arguments": args, "owner_pid": ProcessInfo.processInfo.processIdentifier, "undo": undo]
            try state.set(operationKey(id), record)
            try state.commit() // durable BEFORE any EventKit side effect
        } catch { state.rollback(); throw error }
        try state.begin()
        do {
            store.reset()
            var result = try await run(op, args)
            result["operation"] = ["request_id": id, "replayed": false, "verified": true]
            var record = try state.get(operationKey(id))!
            record["status"] = "succeeded"; record["result"] = result; record["finished_at"] = iso.string(from: Date())
            try state.set(operationKey(id), record)
            try state.commit()
            return result
        } catch {
            state.rollback()
            let failure = error as? BridgeError ?? BridgeError("EVENTKIT_ERROR", error.localizedDescription)
            let reported = writeAttempted ? BridgeError("RESULT_UNKNOWN", "The write may have succeeded; inspect the item before retrying. \(failure.message)", ["request_id": id, "cause": failure.data]) : failure
            try state.begin()
            do {
                var record = try state.get(operationKey(id))!
                if op == "undo_operation" && !writeAttempted { try releaseUndoClaim(args) }
                record["status"] = writeAttempted ? "uncertain" : "failed"
                record["error"] = reported.data; record["finished_at"] = iso.string(from: Date())
                try state.set(operationKey(id), record); try state.commit()
            } catch { state.rollback(); throw BridgeError("RESULT_UNKNOWN", "Could not finalize the operation journal. Inspect get_operation and current item state before retrying.", ["request_id": id]) }
            throw reported
        }
    }
    func testCrashAfterWrite() {
        #if TESTING
        if ProcessInfo.processInfo.environment["APPLE_HELPER_TEST_CRASH_AFTER_WRITE"] == "1" { _exit(86) }
        #endif
    }
    func date(_ text: String) throws -> Date {
        if let d = iso.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = fractional.date(from: text) else { throw BridgeError("INVALID_DATE", "Use an ISO 8601 timestamp with a timezone.") }
        return d
    }
    func value(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? null as Any }
    func required(_ a: [String: Any], _ key: String) throws -> String {
        guard let s = a[key] as? String, !s.isEmpty else { throw BridgeError("INVALID_INPUT", "Missing \(key).") }
        return s
    }
    func status(_ entity: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "full_access"
        case .writeOnly: return "write_only"
        @unknown default: return "unknown"
        }
    }
    func requireAccess(_ entity: EKEntityType) throws {
        guard EKEventStore.authorizationStatus(for: entity) == .fullAccess else {
            throw BridgeError("PERMISSION_REQUIRED", "Full access is required. Run request_access, then allow this app in macOS System Settings > Privacy & Security > Calendars / Reminders.")
        }
    }
    func calendar(_ id: String, _ entity: EKEntityType, write: Bool = false) throws -> EKCalendar {
        guard let c = store.calendars(for: entity).first(where: { $0.calendarIdentifier == id }) else {
            throw BridgeError("NOT_FOUND", "Calendar or reminder list not found; list containers again for a current ID.")
        }
        if write && !c.allowsContentModifications { throw BridgeError("READ_ONLY", "This calendar or list is read-only.") }
        return c
    }
    func containerData(_ c: EKCalendar) -> [String: Any] {
        versioned(["id": c.calendarIdentifier, "name": c.title, "source": c.source.title, "source_id": c.source.sourceIdentifier, "color": colorHex(c.cgColor), "immutable": c.isImmutable,
         "writable": c.allowsContentModifications, "subscribed": c.isSubscribed,
         "is_system_default": c.calendarIdentifier == (c.allowedEntityTypes.contains(.event) ? store.defaultCalendarForNewEvents?.calendarIdentifier : store.defaultCalendarForNewReminders()?.calendarIdentifier)], modified: nil)
    }
    func preferences() throws -> [String: Any] {
        let saved = try state.get("preferences") ?? [:]
        let eventDefault = status(.event) == "full_access" ? store.defaultCalendarForNewEvents?.calendarIdentifier : nil
        let reminderDefault = status(.reminder) == "full_access" ? store.defaultCalendarForNewReminders()?.calendarIdentifier : nil
        return ["preferences": saved, "version": try fingerprint(saved), "effective": [
            "default_calendar_id": saved["default_calendar_id"] ?? eventDefault as Any? ?? null,
            "default_reminder_list_id": saved["default_reminder_list_id"] ?? reminderDefault as Any? ?? null,
            "time_zone": saved["time_zone"] ?? TimeZone.current.identifier,
            "event_duration_minutes": saved["event_duration_minutes"] ?? null,
            "work_hours": saved["work_hours"] ?? null,
        ], "system_defaults": ["calendar_id": eventDefault as Any? ?? null, "reminder_list_id": reminderDefault as Any? ?? null, "time_zone": TimeZone.current.identifier]]
    }
    func resolveCalendar(_ explicit: String?, _ entity: EKEntityType) throws -> EKCalendar {
        let saved = try state.get("preferences") ?? [:]
        let key = entity == .event ? "default_calendar_id" : "default_reminder_list_id"
        let system = entity == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let id = explicit ?? saved[key] as? String ?? system?.calendarIdentifier else {
            throw BridgeError("DESTINATION_REQUIRED", "No default destination is available. Specify a calendar/list ID.")
        }
        return try calendar(id, entity, write: true)
    }
    func alarmData(_ alarms: [EKAlarm]?) -> [[String: Any]] {
        (alarms ?? []).map { alarm in
            var data: [String: Any]
            if let at = alarm.absoluteDate { data = ["type": "absolute", "at": iso.string(from: at)] }
            else { data = ["type": "relative", "offset_minutes": alarm.relativeOffset / 60] }
            if alarm.structuredLocation != nil { data["has_location"] = true }
            return data
        }.sorted { (try! fingerprint($0)) < (try! fingerprint($1)) }
    }
    func makeAlarms(_ specs: [[String: Any]], anchor: Date?, reminder: Bool) throws -> [EKAlarm] {
        try specs.map { spec in
            if spec["type"] as? String == "absolute" { return EKAlarm(absoluteDate: try date(required(spec, "at"))) }
            guard spec["type"] as? String == "relative", let minutes = spec["offset_minutes"] as? Double else { throw BridgeError("INVALID_ALARM", "Use absolute at or relative offset_minutes.") }
            if reminder {
                guard let anchor else { throw BridgeError("ALARM_ANCHOR_REQUIRED", "A relative reminder alert needs a timed due_at.") }
                return EKAlarm(absoluteDate: anchor.addingTimeInterval(minutes * 60))
            }
            return EKAlarm(relativeOffset: minutes * 60)
        }
    }
    func replaceAlarms(_ item: EKCalendarItem, _ alarms: [EKAlarm]) {
        for existing in item.alarms ?? [] { item.removeAlarm(existing) }
        for alarm in alarms { item.addAlarm(alarm) }
    }
    func snapshotAlarms(_ item: EKCalendarItem) -> [EKAlarm] {
        (item.alarms ?? []).map { source in
            // A copied persisted Reminders alarm can retain its native identity; after
            // changing its date, removal can expose the original alarm again.
            // Recreate time alarms with fresh identities while retaining action/location.
            if source.type == .procedure { return source.copy() as! EKAlarm }
            let alarm = source.absoluteDate.map { EKAlarm(absoluteDate: $0) } ?? EKAlarm(relativeOffset: source.relativeOffset)
            alarm.structuredLocation = source.structuredLocation
            alarm.proximity = source.proximity
            if let email = source.emailAddress { alarm.emailAddress = email }
            if let sound = source.soundName { alarm.soundName = sound }
            return alarm
        }
    }
    func applyAlarms(_ item: EKCalendarItem, _ a: [String: Any], original: [EKAlarm], oldAnchor: Date?, newAnchor: Date?, reminder: Bool) throws {
        if let specs = a["alarms"] as? [[String: Any]] { replaceAlarms(item, try makeAlarms(specs, anchor: newAnchor, reminder: reminder)); return }
        if let at = a["alarm_at"] as? String { replaceAlarms(item, [EKAlarm(absoluteDate: try date(at))]); return }
        if a["alarm_at"] is NSNull { replaceAlarms(item, []); return }
        guard oldAnchor != newAnchor else { return }
        // Omitted alarms keep every existing alarm, including location/sound metadata.
        // Relative alarms naturally follow their anchor; only absolute alarms need shifting.
        if a["alarm_policy"] as? String != "preserve", let before = oldAnchor, let after = newAnchor, before != after {
            for alarm in original {
                if let at = alarm.absoluteDate { alarm.absoluteDate = at.addingTimeInterval(after.timeIntervalSince(before)) }
            }
        }
        // Reassign snapshots: Reminders otherwise applies its own due-date alarm adjustment
        // during save, even when absoluteDate looked unchanged in the in-memory object.
        replaceAlarms(item, original)
    }
    func reminderAnchor(_ r: EKReminder) -> Date? {
        guard let components = r.dueDateComponents else { return nil }
        return (components.calendar ?? Calendar.current).date(from: components)
    }
    func reminderData(_ r: EKReminder) -> [String: Any] {
        var dueAt: Any = null
        var dueDate: Any = null
        if let d = r.dueDateComponents {
            if d.hour == nil {
                dueDate = String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
            } else if let date = (d.calendar ?? Calendar.current).date(from: d) { dueAt = iso.string(from: date) }
        }
        return versioned(["id": r.calendarItemIdentifier, "list_id": r.calendar.calendarIdentifier,
                "title": r.title ?? "", "notes": r.notes ?? "", "completed": r.isCompleted,
                "priority": r.priority, "due_at": dueAt, "due_date": dueDate,
                "completed_at": value(r.completionDate), "modified_at": value(r.lastModifiedDate),
                "recurring": r.hasRecurrenceRules,
                "recurrence_rules": recurrenceData(r.recurrenceRules),
                "time_zone": r.dueDateComponents?.timeZone?.identifier ?? TimeZone.current.identifier,
                "alarms": alarmData(r.alarms),
                "alarm_at": (r.alarms ?? []).compactMap { $0.absoluteDate }.map { iso.string(from: $0) }.sorted()], modified: r.lastModifiedDate)
    }
    func eventEnd(_ e: EKEvent) -> Date? {
        guard let end = e.endDate, e.isAllDay else { return e.endDate }
        // macOS EventKit stores all-day ends inclusively at 23:59:59.
        let cal = Calendar.current
        if end == cal.startOfDay(for: end) { return end }
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end))
    }
    func eventData(_ e: EKEvent) -> [String: Any] {
        versioned(["id": e.eventIdentifier ?? e.calendarItemIdentifier, "calendar_id": e.calendar.calendarIdentifier,
         "title": e.title ?? "", "notes": e.notes ?? "", "location": e.location ?? "",
         "start": value(e.startDate), "end": value(eventEnd(e)), "all_day": e.isAllDay,
         "time_zone": e.timeZone?.identifier ?? TimeZone.current.identifier,
         "recurring": e.hasRecurrenceRules, "detached": e.isDetached,
         "series_id": e.calendarItemIdentifier, "recurrence_rules": recurrenceData(e.recurrenceRules),
         "availability": availability(e), "status": e.status.rawValue,
         "occurrence_start": value(e.startDate), "modified_at": value(e.lastModifiedDate),
         "alarms": alarmData(e.alarms), "has_attendees": e.hasAttendees, "url": e.url?.absoluteString ?? ""], modified: e.lastModifiedDate)
    }
    func page(_ items: [[String: Any]], _ a: [String: Any]) -> [String: Any] {
        let offset = max(0, a["offset"] as? Int ?? 0)
        let limit = max(1, min(200, a["limit"] as? Int ?? 50))
        let slice = Array(items.dropFirst(offset).prefix(limit))
        let next = offset + slice.count
        return ["items": slice, "total": items.count, "next_offset": next < items.count ? next as Any : null]
    }
    func matching(_ title: String?, _ notes: String?, _ query: String?) -> Bool {
        guard let query, !query.isEmpty else { return true }
        return ((title ?? "") + "\n" + (notes ?? "")).localizedCaseInsensitiveContains(query)
    }
    func reminder(_ a: [String: Any]) throws -> EKReminder {
        guard let r = store.calendarItem(withIdentifier: try required(a, "id")) as? EKReminder else { throw BridgeError("NOT_FOUND", "Reminder not found.") }
        return r
    }
    func event(_ a: [String: Any]) throws -> EKEvent {
        let id = try required(a, "id")
        guard let base = store.event(withIdentifier: id) else { throw BridgeError("NOT_FOUND", "Event not found; query events again for a current ID.") }
        if let s = a["occurrence_start"] as? String {
            let start = try date(s)
            let p = store.predicateForEvents(withStart: start.addingTimeInterval(-1), end: start.addingTimeInterval(1), calendars: [base.calendar])
            guard let e = store.events(matching: p).first(where: {
                ($0.eventIdentifier == id || $0.calendarItemIdentifier == base.calendarItemIdentifier) && abs($0.startDate.timeIntervalSince(start)) < 1
            }) else { throw BridgeError("NOT_FOUND", "That occurrence was not found at occurrence_start; query again.") }
            return e
        }
        if base.hasRecurrenceRules || base.isDetached { throw BridgeError("OCCURRENCE_REQUIRED", "Pass occurrence_start from list_events to identify the exact repeated event.") }
        return base
    }
    func checkEventWrite(_ e: EKEvent) throws {
        guard e.calendar.allowsContentModifications else { throw BridgeError("READ_ONLY", "This calendar is read-only.") }
        guard !e.hasAttendees else { throw BridgeError("INVITATION_UNSUPPORTED", "Editing or deleting meetings with attendees is not supported by this local helper.") }
    }
    func applyReminder(_ r: EKReminder, _ a: [String: Any]) throws {
        let oldDue = reminderAnchor(r)
        let oldAlarms = snapshotAlarms(r)
        if let id = a["list_id"] as? String { r.calendar = try calendar(id, .reminder, write: true) }
        if let title = a["title"] as? String { r.title = title }
        if let notes = a["notes"] as? String { r.notes = notes }
        if let p = a["priority"] as? Int { r.priority = p }
        if let completed = a["completed"] as? Bool { r.isCompleted = completed }
        let saved = try state.get("preferences") ?? [:]
        let tz = TimeZone(identifier: a["time_zone"] as? String ?? r.dueDateComponents?.timeZone?.identifier ?? saved["time_zone"] as? String ?? TimeZone.current.identifier)
        guard let tz else { throw BridgeError("INVALID_TIME_ZONE", "Unknown IANA time zone.") }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        if let d = a["due_date"] as? String {
            let pieces = d.split(separator: "-").compactMap { Int($0) }
            guard pieces.count == 3 else { throw BridgeError("INVALID_DATE", "due_date must be YYYY-MM-DD.") }
            var components = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
            components.calendar = cal; components.timeZone = tz
            r.dueDateComponents = components
        } else if let d = a["due_at"] as? String {
            var components = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try date(d))
            components.calendar = cal; components.timeZone = tz
            r.dueDateComponents = components
        } else if a["due_date"] is NSNull || a["due_at"] is NSNull { r.dueDateComponents = nil }
        let newDue = reminderAnchor(r)
        try applyRecurrence(r, a, anchor: newDue)
        if r.dueDateComponents?.hour == nil, let specs = a["alarms"] as? [[String: Any]], specs.contains(where: { $0["type"] as? String == "relative" }) {
            throw BridgeError("ALARM_ANCHOR_REQUIRED", "Relative reminder alerts need a timed due_at; use absolute alerts for all-day reminders.")
        }
        try applyAlarms(r, a, original: oldAlarms, oldAnchor: oldDue, newAnchor: newDue, reminder: true)
    }
    func applyEvent(_ e: EKEvent, _ a: [String: Any]) throws {
        let oldStart = e.startDate
        let oldAlarms = snapshotAlarms(e)
        let allDay = a["all_day"] as? Bool ?? e.isAllDay
        let start = try (a["start"] as? String).map(date) ?? e.startDate
        let saved = try state.get("preferences") ?? [:]
        var end = try (a["end"] as? String).map(date) ?? eventEnd(e)
        if a["end"] == nil, let start, let oldStart, let oldEnd = eventEnd(e), a["start"] != nil {
            end = shiftedEnd(oldStart: oldStart, oldEnd: oldEnd, newStart: start, allDay: allDay && e.isAllDay, calendar: Calendar.current)
        } else if end == nil, let start, let duration = saved["event_duration_minutes"] as? Int, !allDay {
            end = start.addingTimeInterval(Double(duration) * 60)
        }
        guard let start, let end, end > start else { throw BridgeError("INVALID_RANGE", "Event end must be after start.") }
        let inheritedZone = e.isNew ? saved["time_zone"] as? String : e.timeZone?.identifier
        let zoneName = a["time_zone"] as? String ?? inheritedZone ?? e.timeZone?.identifier ?? TimeZone.current.identifier
        guard let zone = TimeZone(identifier: zoneName) else { throw BridgeError("INVALID_TIME_ZONE", "Unknown IANA time zone.") }
        if allDay {
            // Floating all-day values are returned by EventKit in the Mac's timezone.
            let cal = Calendar.current
            guard zone.secondsFromGMT(for: start) == cal.timeZone.secondsFromGMT(for: start),
                  zone.secondsFromGMT(for: end) == cal.timeZone.secondsFromGMT(for: end),
                  cal.startOfDay(for: start) == start, cal.startOfDay(for: end) == end else {
                throw BridgeError("INVALID_ALL_DAY", "All-day events need midnight start/end in the Mac's timezone (\(TimeZone.current.identifier)); end is exclusive.")
            }
        }
        if let id = a["calendar_id"] as? String { e.calendar = try calendar(id, .event, write: true) }
        if let title = a["title"] as? String { e.title = title }
        if let notes = a["notes"] as? String { e.notes = notes }
        if let location = a["location"] as? String { e.location = location }
        if let availability = a["availability"] as? String {
            e.availability = ["busy": EKEventAvailability.busy, "free": .free, "tentative": .tentative, "unavailable": .unavailable][availability]!
        }
        if ["start", "end", "all_day", "time_zone"].contains(where: { a[$0] != nil }) {
            e.timeZone = zone
            e.isAllDay = allDay
            e.startDate = start
            e.endDate = allDay ? end.addingTimeInterval(-1) : end
        }
        if let s = a["url"] as? String { e.url = s.isEmpty ? nil : URL(string: s) }
        try applyRecurrence(e, a, anchor: start)
        try applyAlarms(e, a, original: oldAlarms, oldAnchor: oldStart, newAnchor: start, reminder: false)
    }
    func verify(_ expected: [String: Any], _ actual: [String: Any], keys: [String]) throws {
        let mismatches = try keys.filter { try fingerprint(expected[$0] ?? null) != fingerprint(actual[$0] ?? null) }
        guard mismatches.isEmpty else { throw BridgeError("VERIFICATION_FAILED", "Saved item differs from intended values.", ["fields": mismatches, "actual": actual]) }
    }
    func saveReminder(_ r: EKReminder) async throws -> [String: Any] {
        let expected = reminderData(r)
        let completingRecurring = r.hasRecurrenceRules && r.isCompleted
        let saveStarted = Date()
        writeAttempted = true
        try store.save(r, commit: true)
        let id = r.calendarItemIdentifier
        testCrashAfterWrite()
        store.reset()
        let actual = reminderData(try reminder(["id": id]))
        if completingRecurring && actual["completed"] as? Bool == false {
            // Reminders reuses the active reminder ID for the next recurrence and writes
            // the completed occurrence under a separate ID. Verify both observations.
            let list = try calendar(expected["list_id"] as! String, .reminder)
            let history = try await fetchReminders([list], completed: true)
            let keys = ["list_id", "title", "notes", "completed", "priority", "due_at", "due_date"]
            let matches = history.filter { item in
                guard let completedAt = item.completionDate, completedAt >= saveStarted.addingTimeInterval(-3) else { return false }
                let data = reminderData(item)
                return keys.allSatisfy { (try? fingerprint(expected[$0] ?? null)) == (try? fingerprint(data[$0] ?? null)) }
            }
            guard matches.count == 1 else { throw BridgeError("VERIFICATION_FAILED", "The recurring reminder advanced, but its completed occurrence could not be uniquely verified.", ["next_occurrence": actual, "completed_matches": matches.count]) }
            var completed = reminderData(matches[0]); completed["next_occurrence"] = actual
            completed["completion_behavior"] = "completed_occurrence_and_generated_next"
            return completed
        }
        try verify(expected, actual, keys: ["list_id", "title", "notes", "completed", "priority", "due_at", "due_date", "alarms", "recurrence_rules"])
        return actual
    }
    func saveEvent(_ e: EKEvent, span: EKSpan, recurrenceChanged: Bool = false) throws -> [String: Any] {
        var expected = eventData(e)
        let maySplitCount = !e.isNew && e.hasRecurrenceRules && span == .futureEvents && !recurrenceChanged
        // A this-occurrence edit intentionally becomes an exception without its own rule.
        if !e.isNew && e.hasRecurrenceRules && span == .thisEvent { expected["recurrence_rules"] = [] as [[String: Any]] }
        writeAttempted = true
        try store.save(e, span: span, commit: true)
        let ref: [String: Any] = ["id": e.eventIdentifier ?? e.calendarItemIdentifier, "occurrence_start": iso.string(from: e.startDate)]
        testCrashAfterWrite()
        store.reset()
        let actual = eventData(try event(ref))
        if maySplitCount, var before = expected["recurrence_rules"] as? [[String: Any]], let after = actual["recurrence_rules"] as? [[String: Any]], before.count == after.count {
            // EventKit reduces COUNT when splitting an existing series at a later instance.
            // Preserve verification of every other rule field and never accept an increase.
            for i in before.indices {
                if let oldCount = before[i]["count"] as? Int, let newCount = after[i]["count"] as? Int,
                   oldCount > 0 && newCount > 0 && newCount <= oldCount { before[i]["count"] = newCount }
            }
            expected["recurrence_rules"] = before
        }
        var keys = ["calendar_id", "title", "notes", "location", "start", "end", "all_day", "alarms", "url", "recurrence_rules", "availability"]
        if expected["all_day"] as? Bool == false { keys.append("time_zone") }
        try verify(expected, actual, keys: keys)
        return actual
    }
    func fetchReminders(_ containers: [EKCalendar]?, completed: Bool? = nil) async throws -> [EKReminder] {
        let predicate: NSPredicate
        if completed == true { predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: containers) }
        else if completed == false { predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: containers) }
        else { predicate = store.predicateForReminders(in: containers) }
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                guard let items else { continuation.resume(throwing: BridgeError("FETCH_FAILED", "EventKit could not read reminders. No empty snapshot was recorded.")); return }
                continuation.resume(returning: items)
            }
        }
    }
    func checkReminderDuplicate(_ r: EKReminder, _ a: [String: Any]) async throws {
        guard a["allow_duplicate"] as? Bool != true else { return }
        let intended = reminderData(r)
        let matches = try await fetchReminders([r.calendar]).filter { other in
            let data = reminderData(other)
            let sameTime = try fingerprint(data["due_at"]!) == fingerprint(intended["due_at"]!)
            let sameDay = try fingerprint(data["due_date"]!) == fingerprint(intended["due_date"]!)
            return other.title == r.title && other.isCompleted == r.isCompleted && sameTime && sameDay
        }
        if !matches.isEmpty { throw BridgeError("DUPLICATE_FOUND", "A reminder with this title and due date already exists. Use allow_duplicate=true only for an intentional additional copy.", ["ids": matches.map { $0.calendarItemIdentifier }]) }
    }
    func checkEventDuplicate(_ e: EKEvent, _ a: [String: Any]) throws {
        guard a["allow_duplicate"] as? Bool != true else { return }
        let p = store.predicateForEvents(withStart: e.startDate.addingTimeInterval(-1), end: e.startDate.addingTimeInterval(1), calendars: [e.calendar])
        let matches = store.events(matching: p).filter { $0.title == e.title && $0.startDate == e.startDate && eventEnd($0) == eventEnd(e) && $0.isAllDay == e.isAllDay }
        if !matches.isEmpty { throw BridgeError("DUPLICATE_FOUND", "An event with this title and time already exists. Use allow_duplicate=true only for an intentional additional copy.", ["ids": matches.compactMap { $0.eventIdentifier }]) }
    }
    func run(_ op: String, _ a: [String: Any]) async throws -> [String: Any] {
        #if TESTING
        if op == "update_reminder", let title = ProcessInfo.processInfo.environment["APPLE_HELPER_TEST_FAIL_ONCE_TITLE"], a["title"] as? String == title,
           let path = ProcessInfo.processInfo.environment["APPLE_HELPER_TEST_FAIL_ONCE_FILE"], FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
            throw BridgeError("TEST_TRANSIENT", "Injected failure before any write.")
        }
        #endif
        if op == "undo_operation" { return try await undoOperation(a) }
        if op == "plan_tasks" { return try planTasks(a) }
        if op == "get_plan" { return try getPlan(required(a, "plan_id")) }
        if op == "create_task_event" { return try await createTaskEvent(a) }
        if op == "check_conflicts" { return try checkConflicts(a) }
        if op == "get_statistics" { return try await statistics(a) }
        if op == "get_changes" { return try await changes(a) }
        if ["list_sources", "create_calendar", "update_calendar", "delete_calendar", "create_reminder_list", "update_reminder_list", "delete_reminder_list"].contains(op) { return try containerOperation(op, a) }
        if op == "get_agenda" { return try await agenda(a) }
        if op == "find_free_slots" { return try freeSlots(a) }
        if op == "reconcile_operation" { return try reconcile(a) }
        if op == "preview_operation_prune" || op == "prune_operations" { return try prune(a, dryRun: op == "preview_operation_prune") }
        if op == "get_status" { return ["calendar": status(.event), "reminders": status(.reminder), "time_zone": TimeZone.current.identifier] }
        if op == "get_preferences" { return try preferences() }
        if op == "get_operation" {
            guard let record = try state.get(operationKey(required(a, "request_id"))) else { throw BridgeError("NOT_FOUND", "Operation not found.") }
            var result = record; result["version"] = try fingerprint(record); return result
        }
        if op == "list_operations" {
            let records = try state.recent(a["limit"] as? Int ?? 20).map { record -> [String: Any] in
                record.filter { ["request_id", "tool", "status", "created_at", "finished_at"].contains($0.key) }
            }
            return ["items": records]
        }
        if op == "update_preferences" {
            let current = try preferences()
            try checkVersion(current, a)
            var saved = current["preferences"] as! [String: Any]
            for key in ["default_calendar_id", "default_reminder_list_id", "time_zone", "event_duration_minutes", "work_hours"] {
                guard let value = a[key] else { continue }
                if value is NSNull { saved.removeValue(forKey: key); continue }
                if key == "default_calendar_id" { try requireAccess(.event); _ = try calendar(value as! String, .event, write: true) }
                if key == "default_reminder_list_id" { try requireAccess(.reminder); _ = try calendar(value as! String, .reminder, write: true) }
                if key == "time_zone", TimeZone(identifier: value as! String) == nil { throw BridgeError("INVALID_TIME_ZONE", "Unknown IANA time zone.") }
                saved[key] = value
            }
            try state.set("preferences", saved)
            let result = try preferences()
            guard try fingerprint(result["preferences"]!) == fingerprint(saved) else { throw BridgeError("VERIFICATION_FAILED", "Preference readback mismatch.") }
            return result
        }
        if op == "request_access" {
            let target = a["target"] as? String ?? "both"
            if target == "both" || target == "calendar" { _ = try await store.requestFullAccessToEvents() }
            if target == "both" || target == "reminders" { _ = try await store.requestFullAccessToReminders() }
            return ["calendar": status(.event), "reminders": status(.reminder)]
        }
        let entity: EKEntityType = op.contains("reminder") ? .reminder : .event
        try requireAccess(entity)
        switch op {
        case "list_calendars", "list_reminder_lists":
            return ["items": store.calendars(for: entity).map(containerData)]
        case "list_reminders":
            let containers = try (a["list_id"] as? String).map { [try calendar($0, .reminder)] }
            let reminders = try await fetchReminders(containers, completed: a["completed"] as? Bool)
            let completed = a["completed"] as? Bool
            let after = try (a["due_after"] as? String).map(date)
            let before = try (a["due_before"] as? String).map(date)
            let filtered = reminders.filter { r in
                if let completed, r.isCompleted != completed { return false }
                if !matching(r.title, r.notes, a["query"] as? String) { return false }
                if after != nil || before != nil {
                    guard let components = r.dueDateComponents,
                          let due = (components.calendar ?? Calendar.current).date(from: components) else { return false }
                    if let after, due < after { return false }
                    if let before, due >= before { return false }
                }
                return true
            }.sorted { $0.calendarItemIdentifier < $1.calendarItemIdentifier }
            var result = page([], a); let offset = a["offset"] as? Int ?? 0; let limit = a["limit"] as? Int ?? 50
            let items = filtered.dropFirst(offset).prefix(limit).map(reminderData)
            result["items"] = items; result["total"] = filtered.count; result["next_offset"] = offset + items.count < filtered.count ? offset + items.count : null
            return result
        case "get_reminder": return reminderData(try reminder(a))
        case "create_reminder":
            let r = EKReminder(eventStore: store)
            r.calendar = try resolveCalendar(a["list_id"] as? String, .reminder)
            try applyReminder(r, a)
            try await checkReminderDuplicate(r, a)
            return try await saveReminder(r)
        case "update_reminder", "delete_reminder":
            let r = try reminder(a)
            try checkVersion(reminderData(r), a)
            guard r.calendar.allowsContentModifications else { throw BridgeError("READ_ONLY", "This reminder list is read-only.") }
            if r.hasRecurrenceRules && a["allow_recurring"] as? Bool != true {
                throw BridgeError("RECURRING_CONFIRMATION_REQUIRED", "This is a recurring reminder. Set allow_recurring=true only when the user's request covers the series or completing its current occurrence.")
            }
            if op == "delete_reminder" {
                let old = reminderData(r); let id = r.calendarItemIdentifier
                writeAttempted = true; try store.remove(r, commit: true); testCrashAfterWrite(); store.reset()
                guard store.calendarItem(withIdentifier: id) == nil else { throw BridgeError("VERIFICATION_FAILED", "Deleted reminder is still present.") }
                return ["deleted": true, "item": old]
            }
            try applyReminder(r, a); return try await saveReminder(r)
        case "list_events":
            let start = try date(required(a, "start")); let end = try date(required(a, "end"))
            guard end > start, end.timeIntervalSince(start) <= 366 * 86400 else { throw BridgeError("INVALID_RANGE", "Use a positive range no longer than 366 days.") }
            let containers = try (a["calendar_id"] as? String).map { [try calendar($0, .event)] }
            let p = store.predicateForEvents(withStart: start, end: end, calendars: containers)
            let events = store.events(matching: p).filter { matching($0.title, $0.notes, a["query"] as? String) }
                .sorted { $0.startDate == $1.startDate ? ($0.eventIdentifier ?? "") < ($1.eventIdentifier ?? "") : $0.startDate < $1.startDate }
            let offset = a["offset"] as? Int ?? 0; let limit = a["limit"] as? Int ?? 50
            let items = events.dropFirst(offset).prefix(limit).map(eventData)
            return ["items": items, "total": events.count, "next_offset": offset + items.count < events.count ? offset + items.count : null, "warnings": recurrenceWarnings(end: end)]
        case "get_event_series": return eventData(try seriesRoot(try required(a, "id")))
        case "get_event": return eventData(try event(a))
        case "create_event":
            let e = EKEvent(eventStore: store)
            e.calendar = try resolveCalendar(a["calendar_id"] as? String, .event)
            try applyEvent(e, a); try checkEventDuplicate(e, a)
            return try saveEvent(e, span: .thisEvent)
        case "update_event", "delete_event", "reschedule_event":
            let e = a["scope"] as? String == "all" ? try seriesRoot(required(a, "id")) : try event(a); try checkEventWrite(e)
            try checkVersion(eventData(e), a)
            let span: EKSpan = ["future", "all"].contains(a["scope"] as? String ?? "this") ? .futureEvents : .thisEvent
            if a["recurrence"] != nil && e.hasRecurrenceRules && span == .thisEvent { throw BridgeError("RECURRENCE_SCOPE_REQUIRED", "Changing a recurring rule requires scope=future or all.") }
            if op == "delete_event" {
                let old = eventData(e)
                let ref: [String: Any] = ["id": old["id"]!, "occurrence_start": old["occurrence_start"]!]
                writeAttempted = true; try store.remove(e, span: span, commit: true); testCrashAfterWrite(); store.reset()
                do { _ = try event(ref); throw BridgeError("VERIFICATION_FAILED", "Deleted occurrence is still present.") }
                catch let error as BridgeError where error.code == "NOT_FOUND" { /* verified absent */ }
                return ["deleted": true, "item": old]
            }
            let oldRef = eventData(e)
            try applyEvent(e, a)
            if op == "reschedule_event" {
                let conflicts = try conflictingEvents(e, original: oldRef, calendarIDs: a["calendar_ids"] as? [String])
                if !conflicts.isEmpty && a["conflict_policy"] as? String != "allow" { throw BridgeError("SCHEDULE_CONFLICT", "The proposed time overlaps existing events.", ["conflicts": conflicts]) }
                var result = try saveEvent(e, span: span); result["conflicts"] = conflicts; result["conflict_checked_scope"] = "selected_occurrence"; return result
            }
            return try saveEvent(e, span: span, recurrenceChanged: a["recurrence"] != nil)
        default: throw BridgeError("UNKNOWN_OPERATION", "Unknown operation.")
        }
    }
}

@main struct Main {
    static func main() async {
        #if TESTING
        if CommandLine.arguments.contains("--self-test") { runNativeTests(); return }
        #endif
        var response: [String: Any]
        do {
            guard #available(macOS 14.0, *) else { throw BridgeError("UNSUPPORTED_OS", "macOS 14 or later is required.") }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let operation = request["operation"] as? String else { throw BridgeError("INVALID_INPUT", "Expected a JSON operation and arguments.") }
            let result = try await Bridge().execute(operation, request["arguments"] as? [String: Any] ?? [:])
            response = ["ok": true, "data": result]
        } catch let e as BridgeError {
            response = ["ok": false, "error": e.data]
        } catch {
            response = ["ok": false, "error": ["code": "EVENTKIT_ERROR", "message": error.localizedDescription]]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch { FileHandle.standardError.write(Data("Failed to encode EventKit response.\n".utf8)); exit(1) }
    }
}
