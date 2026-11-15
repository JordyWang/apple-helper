import Foundation
import EventKit

@available(macOS 14.0, *)
extension Bridge {
    func checkConflicts(_ a: [String: Any]) throws -> [String: Any] {
        let (start, end, cal) = try planningRange(a)
        guard end <= recurrenceHorizon() else { throw BridgeError("RECURRENCE_HORIZON", "Conflict checks support the next 10 years.") }
        let buffer = Double(a["buffer_minutes"] as? Int ?? 0) * 60
        let events = try planningEvents(start.addingTimeInterval(-buffer), end.addingTimeInterval(buffer), a["calendar_ids"] as? [String])
            .filter { $0.status != .canceled && $0.availability != .free && (!$0.isAllDay || a["all_day_policy"] as? String != "ignore") }
            .sorted { $0.startDate == $1.startDate ? ($0.eventIdentifier ?? "") < ($1.eventIdentifier ?? "") : $0.startDate < $1.startDate }
        var conflicts: [[String: Any]] = []
        var active: [EKEvent] = []
        for event in events {
            let from = event.startDate!, until = eventEnd(event)!.addingTimeInterval(buffer)
            active.removeAll { eventEnd($0)!.addingTimeInterval(buffer) <= from }
            for previous in active {
                let overlapStart = max(start, max(from, previous.startDate))
                let overlapEnd = min(end, min(until, eventEnd(previous)!.addingTimeInterval(buffer)))
                if overlapEnd > overlapStart {
                    conflicts.append(["first": eventData(previous), "second": eventData(event), "overlap_start": value(overlapStart), "overlap_end": value(overlapEnd), "overlap_minutes": overlapEnd.timeIntervalSince(overlapStart) / 60])
                    guard conflicts.count <= 10000 else { throw BridgeError("QUERY_TOO_LARGE", "More than 10000 conflict pairs; narrow the range/calendars.") }
                }
            }
            active.append(event)
        }
        var result = page(conflicts, a)
        result["range"] = ["start": value(start), "end": value(end)]; result["time_zone"] = cal.timeZone.identifier
        result["checked_event_count"] = events.count; result["buffer_minutes"] = buffer / 60
        result["all_day_policy"] = a["all_day_policy"] ?? "block"
        return result
    }
    func reminderDue(_ r: EKReminder, calendar: Calendar, deadline: Bool = false) -> Date? {
        guard var components = r.dueDateComponents else { return nil }
        if components.hour == nil {
            components.calendar = calendar; components.timeZone = calendar.timeZone
            guard let day = calendar.date(from: components) else { return nil }
            return deadline ? calendar.date(byAdding: .day, value: 1, to: day) : day
        }
        return reminderAnchor(r)
    }
    func statistics(_ a: [String: Any]) async throws -> [String: Any] {
        let (start, end, cal) = try planningRange(a)
        try requireAccess(.reminder)
        let asOf = try (a["as_of"] as? String).map(date) ?? Date()
        let events = try planningEvents(start, end, a["calendar_ids"] as? [String]).filter { $0.status != .canceled }
        let reminders = try await fetchReminders(selectedCalendars(a["reminder_list_ids"] as? [String], .reminder))
        let timed = events.filter { !$0.isAllDay }
        let intervals = timed.map { BusyInterval(start: max(start, $0.startDate), end: min(end, eventEnd($0)!)) }
        let busy = mergedIntervals(timed.filter { $0.availability != .free }.map { BusyInterval(start: max(start, $0.startDate), end: min(end, eventEnd($0)!)) })
        let completed = reminders.filter { $0.isCompleted && ($0.completionDate.map { $0 >= start && $0 < end } ?? false) }
        let due = reminders.filter { reminderDue($0, calendar: cal).map { $0 >= start && $0 < end } ?? false }
        let open = reminders.filter { !$0.isCompleted }
        let overdue = open.filter { reminderDue($0, calendar: cal, deadline: true).map { $0 < asOf } ?? false }
        let dateFormat = DateFormatter(); dateFormat.calendar = cal; dateFormat.timeZone = cal.timeZone; dateFormat.locale = Locale(identifier: "en_US_POSIX"); dateFormat.dateFormat = "yyyy-MM-dd"
        var daily: [[String: Any]] = [], day = cal.startOfDay(for: start)
        while day < end {
            let next = cal.date(byAdding: .day, value: 1, to: day)!, ds = max(start, day), de = min(end, next)
            let minutes = intervals.reduce(0.0) { $0 + max(0, min(de, $1.end).timeIntervalSince(max(ds, $1.start))) / 60 }
            let occupancy = busy.reduce(0.0) { $0 + max(0, min(de, $1.end).timeIntervalSince(max(ds, $1.start))) / 60 }
            daily.append(["date": dateFormat.string(from: day), "scheduled_minutes_sum": minutes, "timed_busy_minutes_union": occupancy,
                          "completed_reminders": completed.filter { $0.completionDate! >= ds && $0.completionDate! < de }.count,
                          "due_reminders": due.filter { let d = reminderDue($0, calendar: cal)!; return d >= ds && d < de }.count,
                          "all_day_events": events.filter { $0.isAllDay && $0.startDate < de && eventEnd($0)! > ds }.count])
            day = next
        }
        return ["range": ["start": value(start), "end": value(end)], "as_of": value(asOf), "time_zone": cal.timeZone.identifier,
                "events": ["count": events.count, "timed_count": timed.count, "all_day_count": events.count - timed.count,
                           "scheduled_minutes_sum": intervals.reduce(0.0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) / 60 },
                           "timed_busy_minutes_union": busy.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }],
                "reminders": ["completed_in_range": completed.count, "due_in_range": due.count, "open_due_in_range": due.filter { !$0.isCompleted }.count, "total_open": open.count,
                              "overdue_as_of": overdue.count, "undated_open": open.filter { $0.dueDateComponents == nil }.count],
                "daily": daily, "warnings": recurrenceWarnings(end: end), "time_measurement": "planned_calendar_time_not_actual_work"]
    }
    func changes(_ a: [String: Any]) async throws -> [String: Any] {
        if let token = a["page_token"] as? String {
            let parts = token.split(separator: ":")
            guard parts.count == 2, let offset = Int(parts[1]), offset >= 0,
                  let report = try state.get("change-report:" + String(parts[0])), let expires = report["expires_at"] as? String, try date(expires) > Date() else {
                throw BridgeError("CURSOR_EXPIRED", "Change report expired or is invalid; start a new baseline.")
            }
            return try changePage(report, offset: offset)
        }
        let (start, end, _) = try planningRange(a)
        guard end <= recurrenceHorizon() else { throw BridgeError("RECURRENCE_HORIZON", "Change snapshots support the next 10 years.") }
        try requireAccess(.reminder)
        var query = a; query.removeValue(forKey: "cursor"); query.removeValue(forKey: "limit"); query.removeValue(forKey: "offset")
        let queryHash = try fingerprint(query)
        var previous: [String: [String: Any]] = [:]
        if let cursor = a["cursor"] as? String {
            guard let saved = try state.get("snapshot:" + cursor), let expires = saved["expires_at"] as? String, try date(expires) > Date() else { throw BridgeError("CURSOR_EXPIRED", "Snapshot expired; establish a new baseline.") }
            guard saved["query_hash"] as? String == queryHash else { throw BridgeError("CURSOR_SCOPE_MISMATCH", "Use the identical range and selected containers for this cursor.") }
            previous = saved["items"] as? [String: [String: Any]] ?? [:]
        }
        var current: [String: [String: Any]] = [:]
        for event in try planningEvents(start, end, a["calendar_ids"] as? [String]) {
            let occurrence = event.hasRecurrenceRules || event.isDetached ? iso.string(from: event.occurrenceDate ?? event.startDate) : "single"
            let key = "event:\(event.eventIdentifier ?? event.calendarItemIdentifier):\(occurrence)"
            current[key] = ["kind": "event", "item": eventData(event)]
        }
        for reminder in try await fetchReminders(selectedCalendars(a["reminder_list_ids"] as? [String], .reminder)) {
            current["reminder:" + reminder.calendarItemIdentifier] = ["kind": "reminder", "item": reminderData(reminder)]
        }
        guard current.count <= 10000 else { throw BridgeError("QUERY_TOO_LARGE", "More than 10000 items; narrow the selected calendars/lists.") }
        var differences: [[String: Any]] = []
        for key in Set(previous.keys).union(current.keys).sorted() {
            let old = previous[key], new = current[key]
            if let old, let new {
                if try fingerprint(old) != fingerprint(new) { differences.append(["change": "updated", "kind": new["kind"]!, "before": old["item"]!, "after": new["item"]!]) }
            } else if let new { differences.append(["change": "added", "kind": new["kind"]!, "after": new["item"]!]) }
            else if let old { differences.append(["change": "removed", "kind": old["kind"]!, "before": old["item"]!, "meaning": "absent_from_scope_not_proof_of_deletion"]) }
        }
        let cursor = UUID().uuidString, reportID = UUID().uuidString, now = Date(), expires = now.addingTimeInterval(7 * 86400)
        let report: [String: Any] = ["id": reportID, "cursor": cursor, "baseline": a["cursor"] == nil, "changes": differences, "limit": a["limit"] as? Int ?? 50,
                                   "created_at": value(now), "expires_at": value(expires), "warnings": recurrenceWarnings(end: end)]
        try state.begin()
        do {
            try state.sql("DELETE FROM records WHERE (key LIKE 'snapshot:%' OR key LIKE 'change-report:%') AND json_extract(value,'$.expires_at') < ?", [iso.string(from: now)])
            try state.set("snapshot:" + cursor, ["query_hash": queryHash, "items": current, "expires_at": value(expires)])
            try state.set("change-report:" + reportID, report); try state.commit()
        } catch { state.rollback(); throw error }
        return try changePage(report, offset: 0)
    }
    func changePage(_ report: [String: Any], offset: Int) throws -> [String: Any] {
        let items = report["changes"] as! [[String: Any]], limit = report["limit"] as! Int
        guard offset <= items.count else { throw BridgeError("INVALID_CURSOR", "Invalid page offset.") }
        let slice = Array(items.dropFirst(offset).prefix(limit)), next = offset + min(limit, items.count - offset)
        return ["items": slice, "total": items.count, "baseline": report["baseline"]!, "observed_at": report["created_at"]!, "expires_at": report["expires_at"]!,
                "next_page_token": next < items.count ? "\(report["id"]!):\(next)" : null,
                "cursor": next < items.count ? null : report["cursor"]!, "warnings": report["warnings"] ?? []]
    }
}
