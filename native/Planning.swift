import Foundation
import EventKit

struct BusyInterval {
    var start: Date
    var end: Date
}

func mergedIntervals(_ intervals: [BusyInterval]) -> [BusyInterval] {
    var result: [BusyInterval] = []
    for interval in intervals.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
        if let last = result.last, interval.start <= last.end { result[result.count - 1].end = max(last.end, interval.end) }
        else { result.append(interval) }
    }
    return result
}

func freeWindows(start: Date, end: Date, busy: [BusyInterval], minimum: TimeInterval) -> [BusyInterval] {
    guard end > start, minimum > 0 else { return [] }
    var cursor = start
    var result: [BusyInterval] = []
    for block in mergedIntervals(busy) where block.end > start && block.start < end {
        if block.start.timeIntervalSince(cursor) >= minimum { result.append(BusyInterval(start: cursor, end: min(block.start, end))) }
        cursor = max(cursor, block.end)
    }
    if end.timeIntervalSince(cursor) >= minimum { result.append(BusyInterval(start: cursor, end: end)) }
    return result
}

func workingInterval(day: Date, start: String, end: String, calendar: Calendar) -> BusyInterval? {
    func boundary(_ time: String, last: Bool) -> Date? {
        let hm = time.split(separator: ":").map { Int($0)! }
        return calendar.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: last ? .last : .first, direction: .forward)
    }
    guard let from = boundary(start, last: false), let until = boundary(end, last: true), until > from,
          calendar.isDate(from, inSameDayAs: day), calendar.isDate(until, inSameDayAs: day) else { return nil }
    return BusyInterval(start: from, end: until)
}

@available(macOS 14.0, *)
extension Bridge {
    func availability(_ e: EKEvent) -> String {
        switch e.availability {
        case .free: return "free"
        case .busy: return "busy"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        default: return "unknown"
        }
    }
    func selectedCalendars(_ ids: [String]?, _ kind: EKEntityType) throws -> [EKCalendar]? {
        try ids.map { try $0.map { try calendar($0, kind) } }
    }
    func planningRange(_ a: [String: Any]) throws -> (Date, Date, Calendar) {
        let start = try date(required(a, "start")), end = try date(required(a, "end"))
        guard end > start && end.timeIntervalSince(start) <= 366 * 86400 else { throw BridgeError("INVALID_RANGE", "Use a positive range no longer than 366 days.") }
        let prefs = try state.get("preferences") ?? [:]
        guard let zone = TimeZone(identifier: a["time_zone"] as? String ?? prefs["time_zone"] as? String ?? TimeZone.current.identifier) else { throw BridgeError("INVALID_TIME_ZONE", "Unknown time zone.") }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        return (start, end, cal)
    }
    func planningEvents(_ start: Date, _ end: Date, _ ids: [String]?) throws -> [EKEvent] {
        try requireAccess(.event)
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: try selectedCalendars(ids, .event)))
    }
    func agenda(_ a: [String: Any]) async throws -> [String: Any] {
        try requireAccess(.event); try requireAccess(.reminder)
        let (start, end, cal) = try planningRange(a)
        let events = try planningEvents(start, end, a["calendar_ids"] as? [String])
        let lists = try selectedCalendars(a["reminder_list_ids"] as? [String], .reminder)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) } }
        var rows: [(Date, String, [String: Any])] = events.map { e in
            (e.startDate, "event:\(e.eventIdentifier ?? ""):\(e.startDate.timeIntervalSince1970)", ["kind": "event", "category": "scheduled", "item": eventData(e)])
        }
        for r in reminders {
            let due: Date?
            if let c = r.dueDateComponents, c.hour == nil { var c = c; c.calendar = cal; c.timeZone = cal.timeZone; due = cal.date(from: c) }
            else { due = reminderAnchor(r) }
            let category: String
            if let due {
                if due >= end { continue }
                if due < start { guard a["include_overdue"] as? Bool == true else { continue }; category = "overdue" }
                else { category = "due" }
            } else { guard a["include_undated"] as? Bool == true else { continue }; category = "undated" }
            rows.append((due ?? Date.distantFuture, "reminder:\(r.calendarItemIdentifier)", ["kind": "reminder", "category": category, "item": reminderData(r)]))
        }
        rows.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var result = page(rows.map { $0.2 }, a)
        result["time_zone"] = cal.timeZone.identifier
        result["range"] = ["start": value(start), "end": value(end)]
        result["warnings"] = recurrenceWarnings(end: end)
        result["counts"] = Dictionary(grouping: rows, by: { $0.2["category"] as! String }).mapValues(\.count)
        return result
    }
    func freeSlots(_ a: [String: Any]) throws -> [String: Any] {
        let (start, end, cal) = try planningRange(a)
        guard end <= recurrenceHorizon() else { throw BridgeError("RECURRENCE_HORIZON", "Availability planning is supported up to 10 years ahead; far-future repeated events may not expand reliably.") }
        let prefs = try state.get("preferences") ?? [:]
        guard let duration = a["duration_minutes"] as? Int ?? prefs["event_duration_minutes"] as? Int,
              let hours = a["work_hours"] as? [String: Any] ?? prefs["work_hours"] as? [String: Any] else {
            throw BridgeError("PLANNING_PREFERENCES_REQUIRED", "Supply duration_minutes and work_hours, or explicitly save those preferences.")
        }
        let days = hours["days"] as! [Int], from = hours["start"] as! String, until = hours["end"] as! String
        let buffer = Double(a["buffer_minutes"] as? Int ?? 0) * 60
        let events = try planningEvents(start.addingTimeInterval(-buffer), end.addingTimeInterval(buffer), a["calendar_ids"] as? [String])
        let blocking = events.filter { $0.status != .canceled && $0.availability != .free && (!($0.isAllDay) || a["all_day_policy"] as? String != "ignore") }
        let busy = mergedIntervals(blocking.map { BusyInterval(start: $0.startDate.addingTimeInterval(-buffer), end: eventEnd($0)!.addingTimeInterval(buffer)) })
        var windows: [[String: Any]] = [], day = cal.startOfDay(for: start)
        while day < end {
            let weekday = (cal.component(.weekday, from: day) + 5) % 7 + 1
            if days.contains(weekday) {
                if let work = workingInterval(day: day, start: from, end: until, calendar: cal) {
                    for window in freeWindows(start: max(start, work.start), end: min(end, work.end), busy: busy, minimum: Double(duration) * 60) {
                        windows.append(["start": value(window.start), "end": value(window.end), "available_minutes": window.end.timeIntervalSince(window.start) / 60,
                                        "suggested_start": value(window.start), "suggested_end": value(window.start.addingTimeInterval(Double(duration) * 60))])
                    }
                }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        var result = page(windows, a)
        result["time_zone"] = cal.timeZone.identifier; result["duration_minutes"] = duration
        result["work_hours"] = hours; result["all_day_policy"] = a["all_day_policy"] ?? "block"; result["buffer_minutes"] = buffer / 60
        result["blocking_event_count"] = blocking.count; result["busy_intervals"] = busy.map { ["start": value(max(start, $0.start)), "end": value(min(end, $0.end))] }
        return result
    }
    func conflictingEvents(_ e: EKEvent, original: [String: Any], calendarIDs: [String]?) throws -> [[String: Any]] {
        try planningEvents(e.startDate, eventEnd(e)!, calendarIDs).filter { other in
            let sameOccurrence = other.calendarItemIdentifier == original["series_id"] as? String && iso.string(from: other.startDate) == original["start"] as? String
            return !sameOccurrence && other.status != .canceled && other.availability != .free && other.startDate < eventEnd(e)! && eventEnd(other)! > e.startDate
        }.map(eventData)
    }
}
