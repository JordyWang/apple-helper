import Foundation
import EventKit
import Darwin

@available(macOS 14.0, *)
extension Bridge {
    func reconcile(_ a: [String: Any]) throws -> [String: Any] {
        let target = try required(a, "target_request_id")
        guard target != a["request_id"] as? String else { throw BridgeError("INVALID_INPUT", "The reconciliation must use a new request ID.") }
        guard var record = try state.get(operationKey(target)) else { throw BridgeError("NOT_FOUND", "Operation not found.") }
        guard try fingerprint(record) == a["expected_operation_version"] as? String else { throw BridgeError("VERSION_CONFLICT", "Operation changed; read get_operation again.") }
        guard ["pending", "uncertain"].contains(record["status"] as? String ?? ""), record["resolution"] == nil else { throw BridgeError("OPERATION_TERMINAL", "Only unresolved pending/uncertain operations can be reconciled.") }
        if let pid = record["owner_pid"] as? Int32, kill(pid, 0) == 0 { throw BridgeError("OPERATION_ACTIVE", "The original process is still alive; wait for its journal to finish.") }
        let conclusion = try required(a, "conclusion"), tool = record["tool"] as? String ?? ""
        let args = record["arguments"] as? [String: Any] ?? [:]
        var observation: [String: Any] = [:]
        if conclusion == "observed_applied" {
            let isReminder = tool.contains("reminder")
            guard tool.contains("event") || isReminder else { throw BridgeError("EVIDENCE_REQUIRED", "For non-item operations, use abandoned with an explanation after checking state.") }
            try requireAccess(isReminder ? .reminder : .event)
            if tool.hasPrefix("delete_") {
                do {
                    if isReminder { _ = try reminder(args) } else { _ = try event(args) }
                    throw BridgeError("EVIDENCE_MISMATCH", "The original target still exists.")
                } catch let error as BridgeError where error.code == "NOT_FOUND" {
                    observation = ["kind": "target_absent", "id": args["id"] ?? null, "scope_verified": "original_reference_only"]
                }
            } else {
                guard let ref = a["evidence"] as? [String: Any], ref["kind"] as? String == (isReminder ? "reminder" : "event") else { throw BridgeError("EVIDENCE_REQUIRED", "Pass a freshly read matching item as evidence.") }
                if isReminder {
                    let r = try reminder(ref); let current = reminderData(r); try checkVersion(current, ref)
                    try applyReminder(r, args)
                    try verify(reminderData(r), current, keys: ["list_id", "title", "notes", "completed", "priority", "due_at", "due_date", "alarms", "recurrence_rules"])
                    observation = ["kind": "current_item_matches", "item": current]
                } else {
                    let e = try event(ref); let current = eventData(e); try checkVersion(current, ref)
                    try applyEvent(e, args)
                    var keys = ["calendar_id", "title", "notes", "location", "start", "end", "all_day", "url", "alarms", "recurrence_rules", "availability"]
                    if current["all_day"] as? Bool == false { keys.append("time_zone") }
                    try verify(eventData(e), current, keys: keys)
                    observation = ["kind": "current_item_matches", "item": current]
                }
            }
        }
        let resolution: [String: Any] = ["conclusion": conclusion, "note": try required(a, "note"), "observation": observation,
                                        "resolved_at": iso.string(from: Date()), "historical_execution_proven": false]
        record["resolution"] = resolution
        record["status"] = "resolved"; record["finished_at"] = iso.string(from: Date())
        try state.set(operationKey(target), record)
        return ["target_request_id": target, "status": "resolved", "resolution": resolution]
    }
    func prune(_ a: [String: Any], dryRun: Bool) throws -> [String: Any] {
        let before = try date(required(a, "before"))
        guard before <= Date() else { throw BridgeError("INVALID_RANGE", "Pruning cutoff must not be in the future.") }
        let predicate = "key LIKE 'operation:%' AND json_extract(value,'$.status') IN ('succeeded','failed','resolved') AND json_extract(value,'$.compacted_at') IS NULL AND json_extract(value,'$.finished_at') < ?"
        let cutoff = iso.string(from: before)
        let count = Int(try state.sql("SELECT COUNT(*) FROM records WHERE " + predicate, [cutoff]).first ?? "0") ?? 0
        if !dryRun {
            try state.sql("UPDATE records SET value = json_set(json_remove(value,'$.arguments','$.result','$.error','$.resolution','$.owner_pid'),'$.compacted_at',?) WHERE " + predicate, [iso.string(from: Date()), cutoff])
        }
        return ["eligible_count": count, "compacted_count": dryRun ? 0 : count, "dry_run": dryRun, "before": cutoff, "request_ids_retained": true]
    }
}
