import Foundation
import Darwin

@available(macOS 14.0, *)
extension Bridge {
    func cancellationRequested() -> Bool {
        guard let file = ProcessInfo.processInfo.environment["APPLE_HELPER_CANCEL_FILE"] else { return false }
        return FileManager.default.fileExists(atPath: file)
    }
    func batchSteps(_ op: String, _ a: [String: Any]) throws -> [[String: Any]] {
        let id = try required(a, "request_id")
        if op == "batch_update" {
            return try (a["items"] as! [[String: Any]]).map { item in
                let key = item["key"] as! String, kind = item["kind"] as! String
                var args = item; args.removeValue(forKey: "key"); args.removeValue(forKey: "kind"); args.removeValue(forKey: "changes")
                args.merge(item["changes"] as! [String: Any]) { _, new in new }
                let base = "batch-" + (try fingerprint(["batch": id, "key": key]))
                return ["key": key, "tool": "update_" + kind, "arguments": args, "child_base": base, "attempt": 0]
            }
        }
        let planID = try required(a, "plan_id"), plan = try loadPlan(planID)
        guard try fingerprint(plan) == a["expected_plan_version"] as? String else { throw BridgeError("VERSION_CONFLICT", "Plan version differs; read get_plan again.") }
        return try (plan["assignments"] as! [[String: Any]]).map { assignment in
            var args = assignment
            for key in ["destination_calendar_id", "calendar_ids", "time_zone", "buffer_minutes", "all_day_policy", "plan_id"] { args[key] = plan[key] }
            args["allow_duplicate"] = false; args["alarm_policy"] = "shift"
            let key = assignment["key"] as! String, base = "plan-" + (try fingerprint(["plan": planID, "key": key]))
            return ["key": key, "tool": "create_task_event", "arguments": args, "child_base": base, "attempt": 0]
        }
    }
    func checkpointBatch(_ id: String, _ record: [String: Any]) throws {
        try state.begin()
        do { try state.set(operationKey(id), record); try state.commit() }
        catch { state.rollback(); throw error }
    }
    func executeBatch(_ op: String, _ a: [String: Any]) async throws -> [String: Any] {
        let id = try required(a, "request_id"), hash = try fingerprint(["tool": op, "arguments": a])
        var record: [String: Any]
        try state.begin()
        do {
            if let old = try state.get(operationKey(id)) {
                guard old["fingerprint"] as? String == hash else { throw BridgeError("REQUEST_ID_REUSED", "A changed batch requires a new request_id.") }
                if old["compacted_at"] != nil { throw BridgeError("RESULT_PRUNED", "Batch result was compacted; it will not execute again.") }
                if old["status"] as? String == "succeeded", var result = old["result"] as? [String: Any] {
                    state.rollback(); result["operation"] = ["request_id": id, "replayed": true, "verified": true]; return result
                }
                if let pid = old["owner_pid"] as? Int32, kill(pid, 0) == 0 { throw BridgeError("OPERATION_ACTIVE", "This batch is still executing in another process.") }
                guard old["steps"] != nil else { throw BridgeError("RESULT_UNKNOWN", "Batch manifest is unavailable; inspect the operation record.") }
                record = old
            } else {
                record = ["request_id": id, "tool": op, "fingerprint": hash, "arguments": a, "created_at": value(Date()), "steps": try batchSteps(op, a)]
            }
            record["status"] = "running"; record["owner_pid"] = ProcessInfo.processInfo.processIdentifier
            try state.set(operationKey(id), record); try state.commit()
        } catch { state.rollback(); throw error }
        var steps = record["steps"] as! [[String: Any]], cancelled = false
        for i in steps.indices {
            if cancellationRequested() { cancelled = true; break }
            if steps[i]["status"] as? String == "succeeded" { continue }
            var attempt = steps[i]["attempt"] as? Int ?? 0
            var child = "\(steps[i]["child_base"]!):\(attempt)"
            if let prior = try state.get(operationKey(child)), prior["status"] as? String == "failed" {
                // Only a proven pre-write failure may start a fresh attempt. Unknown writes never do.
                attempt += 1; child = "\(steps[i]["child_base"]!):\(attempt)"
            }
            steps[i]["attempt"] = attempt; steps[i]["request_id"] = child; steps[i]["status"] = "running"
            record["steps"] = steps; try checkpointBatch(id, record)
            var args = steps[i]["arguments"] as! [String: Any]; args["request_id"] = child
            do {
                let result = try await execute(steps[i]["tool"] as! String, args)
                steps[i]["status"] = "succeeded"; steps[i]["result"] = result; steps[i].removeValue(forKey: "error")
            } catch {
                let failure = error as? BridgeError ?? BridgeError("BATCH_STEP_ERROR", error.localizedDescription)
                let childRecord = try state.get(operationKey(child))
                let knownFailure = childRecord == nil || childRecord?["status"] as? String == "failed"
                steps[i]["status"] = knownFailure ? "failed" : "uncertain"
                steps[i]["error"] = failure.data
                record["steps"] = steps; try checkpointBatch(id, record)
                if !knownFailure || a["on_error"] as? String != "continue" { break }
            }
            record["steps"] = steps; try checkpointBatch(id, record)
        }
        let succeeded = steps.filter { $0["status"] as? String == "succeeded" }.count
        let failed = steps.filter { $0["status"] as? String == "failed" }.count
        let uncertain = steps.filter { $0["status"] as? String == "uncertain" }.count
        let complete = succeeded == steps.count
        let items = steps.map { step in step.filter { ["key", "tool", "status", "request_id", "attempt", "result", "error"].contains($0.key) } }
        let result: [String: Any] = ["status": complete ? "succeeded" : "partial", "items": items, "total": steps.count, "succeeded_count": succeeded, "failed_count": failed,
                                    "uncertain_count": uncertain, "not_started_count": steps.count - succeeded - failed - uncertain, "cancelled": cancelled,
                                    "resume_with_same_request": !complete, "operation": ["request_id": id, "replayed": false, "verified": complete]]
        record["status"] = complete ? "succeeded" : "partial"; record["steps"] = steps; record["result"] = result
        record["finished_at"] = value(Date()); record.removeValue(forKey: "owner_pid")
        try checkpointBatch(id, record)
        return result
    }
}
