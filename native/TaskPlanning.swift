import Foundation
import EventKit

@available(macOS 14.0, *)
extension Bridge {
    func loadPlan(_ id: String) throws -> [String: Any] {
        guard let plan = try state.get("plan:" + id), let until = plan["expires_at"] as? String, try date(until) > Date() else { throw BridgeError("PLAN_EXPIRED", "Plan was not found or expired; generate a new plan.") }
        return plan
    }
    func getPlan(_ id: String) throws -> [String: Any] {
        let plan = try loadPlan(id)
        try requireAccess(.event)
        var result = plan; result["version"] = try fingerprint(plan)
        result["links"] = try (plan["assignments"] as? [[String: Any]] ?? []).compactMap { assignment -> [String: Any]? in
            guard var link = try state.get("task-link:" + (assignment["reminder_id"] as! String)), link["plan_id"] as? String == id else { return nil }
            if let eventID = link["event_id"] as? String, let event = store.event(withIdentifier: eventID) {
                link["state"] = "present"; link["current_event"] = eventData(event)
            } else { link["state"] = "missing" }
            return link
        }
        return result
    }
    func planTasks(_ a: [String: Any]) throws -> [String: Any] {
        try requireAccess(.reminder); try requireAccess(.event)
        let (requestedStart, end, cal) = try planningRange(a)
        let start = max(requestedStart, Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970 / 60) * 60))
        guard end > start else { throw BridgeError("INVALID_RANGE", "Task planning requires a future time window.") }
        let destination = try resolveCalendar(a["destination_calendar_id"] as? String, .event)
        let calendars = Array(Set((a["calendar_ids"] as? [String] ?? store.calendars(for: .event).map(\.calendarIdentifier)) + [destination.calendarIdentifier])).sorted()
        let prefs = try state.get("preferences") ?? [:]
        let defaultDuration = a["duration_minutes"] as? Int ?? prefs["event_duration_minutes"] as? Int
        var query = a; query["start"] = iso.string(from: start); query["calendar_ids"] = calendars; query["duration_minutes"] = 1
        let free = try freeSlots(query, unpaginated: true)
        var windows = try (free["items"] as! [[String: Any]]).map { BusyInterval(start: try date($0["start"] as! String), end: try date($0["end"] as! String)) }
        let buffer = Double(a["buffer_minutes"] as? Int ?? 0) * 60
        struct Task {
            let reminder: EKReminder
            let duration: Int
            let earliest: Date
            let deadline: Date
        }
        var tasks: [Task] = [], unscheduled: [[String: Any]] = []
        for specification in a["tasks"] as! [[String: Any]] {
            let r = try reminder(["id": specification["reminder_id"]!])
            if r.isCompleted { unscheduled.append(["reminder_id": r.calendarItemIdentifier, "title": r.title ?? "", "reason": "already_completed"]); continue }
            if let link = try state.get("task-link:" + r.calendarItemIdentifier), let id = link["event_id"] as? String, store.event(withIdentifier: id) != nil {
                unscheduled.append(["reminder_id": r.calendarItemIdentifier, "title": r.title ?? "", "reason": "already_scheduled", "link": link]); continue
            }
            guard let duration = specification["duration_minutes"] as? Int ?? defaultDuration else { throw BridgeError("DURATION_REQUIRED", "Supply a duration for each task or a default duration.", ["reminder_id": r.calendarItemIdentifier]) }
            let earliest = max(start, try (specification["earliest_start"] as? String).map(date) ?? start)
            let deadline = min(end, try (specification["deadline"] as? String).map(date) ?? reminderDue(r, calendar: cal, deadline: true) ?? end)
            tasks.append(Task(reminder: r, duration: duration, earliest: earliest, deadline: deadline))
        }
        tasks.sort {
            let lhs = $0.reminder.priority == 0 ? 10 : $0.reminder.priority, rhs = $1.reminder.priority == 0 ? 10 : $1.reminder.priority
            if a["order"] as? String == "priority_then_deadline", lhs != rhs { return lhs < rhs }
            if $0.deadline != $1.deadline { return $0.deadline < $1.deadline }
            if lhs != rhs { return lhs < rhs }
            return $0.reminder.calendarItemIdentifier < $1.reminder.calendarItemIdentifier
        }
        var assignments: [[String: Any]] = []
        for task in tasks {
            var found: (Int, Date, Date)?
            for (i, window) in windows.enumerated() {
                let from = max(window.start, task.earliest), until = from.addingTimeInterval(Double(task.duration) * 60)
                if until <= min(window.end, task.deadline) { found = (i, from, until); break }
            }
            let data = reminderData(task.reminder)
            guard let (i, from, until) = found else {
                unscheduled.append(["reminder_id": task.reminder.calendarItemIdentifier, "title": task.reminder.title ?? "", "duration_minutes": task.duration,
                                    "reason": task.deadline <= task.earliest ? "deadline_before_available_start" : "no_contiguous_slot_before_deadline"]); continue
            }
            let old = windows.remove(at: i)
            let beforeEnd = from.addingTimeInterval(-buffer), afterStart = until.addingTimeInterval(buffer)
            if old.start < beforeEnd { windows.append(BusyInterval(start: old.start, end: beforeEnd)) }
            if afterStart < old.end { windows.append(BusyInterval(start: afterStart, end: old.end)) }
            windows.sort { $0.start < $1.start }
            assignments.append(["key": String(assignments.count), "reminder_id": task.reminder.calendarItemIdentifier, "reminder_version": data["version"]!,
                                "title": task.reminder.title ?? "", "priority": task.reminder.priority, "start": value(from), "end": value(until), "deadline": value(task.deadline), "duration_minutes": task.duration])
        }
        let id = UUID().uuidString, now = Date()
        let plan: [String: Any] = ["plan_id": id, "created_at": value(now), "expires_at": value(now.addingTimeInterval(7 * 86400)), "range": ["start": value(start), "end": value(end)],
                                  "time_zone": cal.timeZone.identifier, "destination_calendar_id": destination.calendarIdentifier, "calendar_ids": calendars,
                                  "work_hours": free["work_hours"]!, "buffer_minutes": buffer / 60, "all_day_policy": a["all_day_policy"] ?? "block", "order": a["order"] ?? "deadline_then_priority",
                                  "assignments": assignments, "unscheduled": unscheduled]
        try state.begin()
        do {
            try state.sql("DELETE FROM records WHERE key LIKE 'plan:%' AND json_extract(value,'$.expires_at') < ?", [iso.string(from: now)])
            try state.set("plan:" + id, plan); try state.commit()
        } catch { state.rollback(); throw error }
        return try getPlan(id)
    }
    func createTaskEvent(_ a: [String: Any]) async throws -> [String: Any] {
        try requireAccess(.reminder); try requireAccess(.event)
        let r = try reminder(["id": a["reminder_id"]!])
        try checkVersion(reminderData(r), ["expected_version": a["reminder_version"]!])
        guard !r.isCompleted else { throw BridgeError("TASK_COMPLETED", "Reminder was completed after planning.") }
        if let link = try state.get("task-link:" + r.calendarItemIdentifier), let id = link["event_id"] as? String, store.event(withIdentifier: id) != nil {
            throw BridgeError("TASK_ALREADY_SCHEDULED", "This reminder already has a linked event.", ["link": link])
        }
        let start = try date(required(a, "start")), end = try date(required(a, "end")), buffer = Double(a["buffer_minutes"] as? Int ?? 0) * 60
        guard start >= Date() else { throw BridgeError("PLAN_STALE", "Proposed slot is in the past; generate a new plan.") }
        let conflicts = try planningEvents(start.addingTimeInterval(-buffer), end.addingTimeInterval(buffer), a["calendar_ids"] as? [String]).filter {
            $0.status != .canceled && $0.availability != .free && (!$0.isAllDay || a["all_day_policy"] as? String != "ignore") && $0.startDate < end.addingTimeInterval(buffer) && eventEnd($0)! > start.addingTimeInterval(-buffer)
        }
        guard conflicts.isEmpty else { throw BridgeError("SCHEDULE_CONFLICT", "Calendar changed after planning; generate a new plan or resolve the conflict.", ["conflicts": conflicts.map(eventData)]) }
        var args = a; args["calendar_id"] = a["destination_calendar_id"]
        var result = try await run("create_event", args)
        let link: [String: Any] = ["reminder_id": r.calendarItemIdentifier, "event_id": result["id"]!, "occurrence_start": result["occurrence_start"]!, "plan_id": a["plan_id"]!, "request_id": a["request_id"]!]
        try state.set("task-link:" + r.calendarItemIdentifier, link)
        result["task_link"] = link
        return result
    }
}
