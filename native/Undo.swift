import Foundation
import EventKit

@available(macOS 14.0, *)
extension Bridge {
    func undoSnapshot(_ op: String, _ a: [String: Any]) throws -> [String: Any] {
        let unavailable: (String) -> [String: Any] = { ["supported": false, "reason": $0] }
        if op == "update_preferences" { return ["supported": true, "kind": "preferences", "action": "restore", "before": try state.get("preferences") ?? [:]] }
        let kind: String
        if ["create_event", "create_task_event", "update_event", "reschedule_event", "delete_event"].contains(op) { kind = "event" }
        else if ["create_reminder", "update_reminder", "delete_reminder"].contains(op) { kind = "reminder" }
        else { return unavailable("This operation does not support undo.") }
        if let rule = a["recurrence"], !(rule is NSNull) { return unavailable("Recurring-rule operations are not undoable.") }
        if op.hasPrefix("create_") { return ["supported": true, "kind": kind, "action": "delete"] }
        let item: EKCalendarItem, before: [String: Any]
        if kind == "event" {
            try requireAccess(.event)
            let e = a["scope"] as? String == "all" ? try seriesRoot(required(a, "id")) : try event(a)
            if e.isDetached || e.hasRecurrenceRules || e.hasAttendees { return unavailable("Recurring events, exceptions and attendee meetings are not undoable.") }
            item = e; before = eventData(e)
        } else {
            try requireAccess(.reminder)
            let r = try reminder(a)
            if r.hasRecurrenceRules { return unavailable("Recurring reminders are not undoable.") }
            item = r; before = reminderData(r)
        }
        try checkVersion(before, a)
        if (item.alarms ?? []).contains(where: { $0.structuredLocation != nil || $0.emailAddress != nil || $0.soundName != nil || $0.type == .procedure }) {
            return unavailable("Rich/location alarm metadata cannot be fully restored.")
        }
        return ["supported": true, "kind": kind, "action": op.hasPrefix("delete_") ? "recreate" : "restore", "before": before, "scope": "supported_fields_only"]
    }
    func claimUndo(_ a: [String: Any]) throws {
        let target = try required(a, "target_request_id")
        guard var original = try state.get(operationKey(target)) else { throw BridgeError("NOT_FOUND", "Original operation not found.") }
        guard try fingerprint(original) == a["expected_operation_version"] as? String else { throw BridgeError("VERSION_CONFLICT", "Operation record changed; read get_operation again.") }
        guard original["status"] as? String == "succeeded", original["compacted_at"] == nil,
              let undo = original["undo"] as? [String: Any], undo["supported"] as? Bool == true else {
            throw BridgeError("UNDO_UNSUPPORTED", "No supported undo snapshot is available (older or compacted operations cannot be restored).", ["undo": original["undo"] ?? null])
        }
        guard original["undone_by"] == nil && original["undo_started_by"] == nil else { throw BridgeError("UNDO_ALREADY_STARTED", "An undo already started or finished. Inspect that operation before any new write.", ["request_id": original["undone_by"] ?? original["undo_started_by"] ?? null]) }
        if undo["action"] as? String == "recreate" && a["allow_recreate"] as? Bool != true { throw BridgeError("RECREATE_REQUIRED", "Restoring deletion creates a new ID and restores only supported fields. Pass allow_recreate=true for that scope.") }
        original["undo_started_by"] = a["request_id"]
        try state.set(operationKey(target), original)
    }
    func releaseUndoClaim(_ a: [String: Any]) throws {
        guard let target = a["target_request_id"] as? String, var original = try state.get(operationKey(target)), original["undo_started_by"] as? String == a["request_id"] as? String else { return }
        original.removeValue(forKey: "undo_started_by"); try state.set(operationKey(target), original)
    }
    func undoOperation(_ a: [String: Any]) async throws -> [String: Any] {
        let target = try required(a, "target_request_id")
        guard var original = try state.get(operationKey(target)), original["undo_started_by"] as? String == a["request_id"] as? String,
              let undo = original["undo"] as? [String: Any], let after = original["result"] as? [String: Any] else { throw BridgeError("UNDO_UNAVAILABLE", "Undo claim or original result is unavailable.") }
        let kind = undo["kind"] as! String, action = undo["action"] as! String
        var result: [String: Any]
        if kind == "preferences" {
            try checkVersion(preferences(), ["expected_version": after["version"]!])
            let before = undo["before"] as! [String: Any]
            if let id = before["default_calendar_id"] as? String { try requireAccess(.event); _ = try calendar(id, .event, write: true) }
            if let id = before["default_reminder_list_id"] as? String { try requireAccess(.reminder); _ = try calendar(id, .reminder, write: true) }
            try state.set("preferences", before); result = try preferences()
        } else {
            try requireAccess(kind == "event" ? .event : .reminder)
            if action == "delete" {
                var args: [String: Any] = ["id": after["id"]!, "expected_version": after["version"]!, "request_id": a["request_id"]!, "scope": "this", "allow_recurring": false]
                if kind == "event" { args["occurrence_start"] = after["occurrence_start"] }
                result = try await run("delete_" + kind, args)
            } else {
                let before = undo["before"] as! [String: Any]
                let keys = kind == "event" ? ["calendar_id", "title", "notes", "location", "start", "end", "all_day", "time_zone", "url", "availability", "alarms"] : ["list_id", "title", "notes", "completed", "priority", "time_zone", "alarms"]
                var args = before.filter { keys.contains($0.key) }; args["alarm_policy"] = "preserve"
                if kind == "reminder" {
                    if let due = before["due_date"] as? String { args["due_date"] = due }
                    else { args["due_at"] = before["due_at"] ?? null }
                }
                if action == "restore" {
                    if kind == "event" {
                        let e = try event(["id": after["id"]!]); try checkEventWrite(e); try checkVersion(eventData(e), ["expected_version": after["version"]!])
                        try applyEvent(e, args); result = try saveEvent(e, span: .thisEvent)
                    } else {
                        let r = try reminder(["id": after["id"]!]); try checkVersion(reminderData(r), ["expected_version": after["version"]!])
                        guard r.calendar.allowsContentModifications else { throw BridgeError("READ_ONLY", "Reminder list is read-only.") }
                        try applyReminder(r, args)
                        if let dateText = before["completed_at"] as? String { r.completionDate = try date(dateText) }
                        result = try await saveReminder(r)
                    }
                } else {
                    // Restoration intentionally produces a new native identifier.
                    if kind == "event" {
                        guard store.event(withIdentifier: before["id"] as! String) == nil else { throw BridgeError("RESTORE_CONFLICT", "The deleted event reference exists again.") }
                        result = try await run("create_event", args)
                    } else {
                        guard store.calendarItem(withIdentifier: before["id"] as! String) == nil else { throw BridgeError("RESTORE_CONFLICT", "The deleted reminder reference exists again.") }
                        let r = EKReminder(eventStore: store); r.calendar = try resolveCalendar(args["list_id"] as? String, .reminder)
                        try applyReminder(r, args); try await checkReminderDuplicate(r, args)
                        if let dateText = before["completed_at"] as? String { r.completionDate = try date(dateText) }
                        result = try await saveReminder(r)
                    }
                    result["restored_as_new"] = true; result["original_id"] = before["id"]
                    result["restore_scope"] = "supported_fields_only"
                }
            }
        }
        original["undone_by"] = a["request_id"]; original.removeValue(forKey: "undo_started_by")
        try state.set(operationKey(target), original)
        result["undone_request_id"] = target
        return result
    }
}
