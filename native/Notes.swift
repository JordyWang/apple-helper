import Foundation
import AppKit
import Carbon

enum NotesPermission {
    static func status() -> [String: Any] {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") != nil
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty
        var permission = installed ? "not_running" : "not_installed"
        var code: OSStatus = -600
        if running {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
            code = AEDeterminePermissionToAutomateTarget(target.aeDesc!, typeWildCard, typeWildCard, false)
            switch code {
            case 0: permission = "authorized"
            case -1743: permission = "denied"
            case -1744: permission = "not_determined"
            default: permission = "unavailable"
            }
        }
        return ["installed": installed, "running": running, "automation": permission, "native_code": code]
    }
}

func notesPlainText(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}
func notesHTML(_ text: String) -> String {
    notesPlainText(text).components(separatedBy: "\n").map { line in
        let escaped = line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        return "<div style=\"white-space: pre-wrap;\">\(escaped.isEmpty ? "<br>" : escaped)</div>"
    }.joined(separator: "\n")
}
func notesPreservingWhitespaceHTML(_ html: String) -> String {
    // Notes exports plain divs without the whitespace style that its importer needs.
    html.replacingOccurrences(of: "<div>", with: "<div style=\"white-space: pre-wrap;\">")
        .replacingOccurrences(of: "<p>", with: "<p style=\"white-space: pre-wrap;\">")
}
func notesComparableHTML(_ html: String) -> String {
    // Notes asynchronously removes end-of-block <br> markers without changing plaintext.
    // Plaintext remains part of the version, so meaningful blank lines still change it.
    let pattern = try! NSRegularExpression(pattern: "<br\\s*/?>\\s*(</(?:div|p)>)", options: .caseInsensitive)
    return pattern.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "$1").trimmingCharacters(in: .whitespacesAndNewlines)
}
func notesVersion(_ data: [String: Any]) throws -> String {
    var stable = data
    stable.removeValue(forKey: "modified_at") // Notes' delayed save time is not a content revision.
    if let html = stable["html"] as? String { stable["html"] = notesComparableHTML(html) }
    return try fingerprint(stable)
}
func notesTextComparable(_ text: String) -> String {
    // Notes supplies a final line terminator independently of input.
    var result = notesPlainText(text)
    while result.hasSuffix("\n") { result.removeLast() }
    return result
}
func notesHasComplexHTML(_ html: String) -> Bool {
    // A body write cannot promise to round-trip checklists, tables, embeds or other structures.
    let tags = try! NSRegularExpression(pattern: "<\\s*/?\\s*([a-zA-Z][a-zA-Z0-9]*)\\b")
    let text = html as NSString
    let simple: Set<String> = ["div", "br", "b", "strong", "i", "em", "u", "s", "strike", "p", "span", "font", "a", "h1", "h2", "h3", "h4", "h5", "h6"]
    return tags.matches(in: html, range: NSRange(location: 0, length: text.length)).contains { !simple.contains(text.substring(with: $0.range(at: 1)).lowercased()) }
        || html.range(of: "<[^>]*(?:checklist|data-list|Apple-dash-list)[^>]*>", options: [.regularExpression, .caseInsensitive]) != nil
}
func notesHasRichFormatting(_ html: String) -> Bool {
    notesHasComplexHTML(html) || html.range(of: "<(?:b|strong|i|em|u|s|strike|span|font|a|h[1-6])(?:\\s|>)|<(?:div|p)\\s", options: [.regularExpression, .caseInsensitive]) != nil
}

@available(macOS 14.0, *)
@MainActor final class NotesAdapter {
    let bridge: Bridge
    let script: NSAppleScript
    init(bridge: Bridge) throws {
        self.bridge = bridge
        guard let script = NSAppleScript(source: NotesScripts.source) else { throw BridgeError("NOTES_BRIDGE_ERROR", "Could not load Notes adapter.") }
        self.script = script
    }
    func call(_ handler: String, _ args: [Any] = []) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (i, arg) in args.enumerated() {
            let value: NSAppleEventDescriptor
            if let b = arg as? Bool { value = NSAppleEventDescriptor(boolean: b) }
            else if let s = arg as? String { value = NSAppleEventDescriptor(string: s) }
            else { throw BridgeError("NOTES_BRIDGE_ERROR", "Unsupported typed Notes parameter.") }
            parameters.insert(value, at: i + 1)
        }
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let mapped: String
            switch code {
            case -1743, -1744: mapped = "PERMISSION_REQUIRED"
            case -1728: mapped = "NOT_FOUND"
            case -1712: mapped = "NOTES_TIMEOUT"
            case -1719: mapped = "NOTES_CHANGED"
            case 7101: mapped = "QUERY_TOO_LARGE"
            default: mapped = "NOTES_ERROR"
            }
            let message = mapped == "PERMISSION_REQUIRED" ? "Allow this host to control Notes in macOS Privacy & Security > Automation; request_access(target: notes) requests access." : error[NSAppleScript.errorMessage] as? String ?? "Notes command failed."
            throw BridgeError(mapped, message, ["native_code": code])
        }
        return result
    }
    func read(_ handler: String, _ args: [Any] = []) throws -> NSAppleEventDescriptor {
        for attempt in 0..<3 {
            do { return try call(handler, args) }
            catch let error as BridgeError {
                guard error.code == "NOTES_CHANGED", attempt < 2 else { throw error }
                // Notes can remove a transient preview attachment during a read. Never retry a write.
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw BridgeError("NOTES_CHANGED", "Notes changed repeatedly while reading; retry the read.")
    }
    func rows(_ value: NSAppleEventDescriptor) throws -> [NSAppleEventDescriptor] {
        guard value.descriptorType == typeAEList else { throw BridgeError("NOTES_BRIDGE_ERROR", "Expected a Notes result list.") }
        return (0..<value.numberOfItems).compactMap { value.atIndex($0 + 1) }
    }
    func string(_ value: NSAppleEventDescriptor, _ position: Int) throws -> String {
        guard let text = value.atIndex(position)?.stringValue else { throw BridgeError("NOTES_BRIDGE_ERROR", "Missing Notes response field.", ["position": position, "native_type": value.atIndex(position)?.descriptorType ?? 0]) }
        return text
    }
    func strings(_ value: NSAppleEventDescriptor?) throws -> [String] {
        guard let value else { throw BridgeError("NOTES_BRIDGE_ERROR", "Missing Notes list.") }
        return try rows(value).map { item in
            guard let text = item.stringValue else { throw BridgeError("NOTES_BRIDGE_ERROR", "Invalid Notes list item.") }; return text
        }
    }
    func accounts() throws -> [[String: Any]] {
        try rows(read("accountRows")).map { row in
            ["id": try string(row, 1), "name": try string(row, 2), "upgraded": row.atIndex(3)!.booleanValue,
             "default_folder_id": try string(row, 4), "is_default": row.atIndex(5)!.booleanValue]
        }
    }
    func folders() throws -> [[String: Any]] {
        let defaults = Set(try accounts().compactMap { $0["default_folder_id"] as? String })
        return try rows(read("folderRows")).map { try folderData($0, defaults) }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
    }
    func folderData(_ row: NSAppleEventDescriptor, _ defaults: Set<String>) throws -> [String: Any] {
        let id = try string(row, 1), noteIDs = try strings(row.atIndex(7)).sorted(), childIDs = try strings(row.atIndex(8)).sorted()
        return bridge.versioned(["id": id, "name": try string(row, 2), "parent_id": try string(row, 3),
            "parent_kind": row.atIndex(4)!.booleanValue ? "account" : "folder", "account_id": try string(row, 5),
            "shared": row.atIndex(6)!.booleanValue, "is_default": defaults.contains(id), "note_count": noteIDs.count, "child_folder_count": childIDs.count,
            "note_ids": noteIDs, "child_folder_ids": childIDs], modified: nil)
    }
    func folder(_ id: String) throws -> [String: Any] {
        try folderData(read("readFolder", [id]), Set(accounts().compactMap { $0["default_folder_id"] as? String }))
    }
    func metadata(_ row: NSAppleEventDescriptor) throws -> [String: Any] {
        ["id": try string(row, 1), "title": try string(row, 2), "folder_id": try string(row, 3),
         "created_at": bridge.value(row.atIndex(4)?.dateValue), "modified_at": bridge.value(row.atIndex(5)?.dateValue),
         "locked": row.atIndex(6)!.booleanValue, "shared": row.atIndex(7)!.booleanValue]
    }
    func note(_ id: String) throws -> [String: Any] {
        let row = try read("readNote", [id])
        guard let info = row.atIndex(1) else { throw BridgeError("NOTES_BRIDGE_ERROR", "Missing note metadata.") }
        var result = try metadata(info)
        let locked = result["locked"] as? Bool == true
        let html = try string(row, 2)
        result["html"] = locked ? bridge.null : html as Any
        result["text"] = locked ? bridge.null : try string(row, 3) as Any
        // Notes may expose the same attachment ID twice while generating its preview.
        var seenAttachments = Set<String>()
        result["attachments"] = try rows(row.atIndex(4)!).map { ["id": try string($0, 1), "name": $0.atIndex(2)?.stringValue as Any? ?? bridge.null, "content_id": $0.atIndex(3)?.stringValue as Any? ?? bridge.null, "created_at": bridge.value($0.atIndex(4)?.dateValue), "modified_at": bridge.value($0.atIndex(5)?.dateValue)] }.filter { seenAttachments.insert($0["id"] as! String).inserted }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
        result["complex_content"] = !locked && notesHasComplexHTML(html)
        result["rich_formatting"] = !locked && notesHasRichFormatting(html)
        result["version"] = try notesVersion(result)
        return result
    }
    func requireEditable(_ item: [String: Any]) throws {
        if item["locked"] as? Bool == true { throw BridgeError("NOTE_LOCKED", "Password-protected notes are metadata-only through this adapter; edit them in Notes.") }
        if item["shared"] as? Bool == true { throw BridgeError("SHARED_UNSUPPORTED", "Shared notes/folders are read-only through this adapter.") }
    }
    func destination(_ a: [String: Any]) throws -> [String: Any] {
        if let id = a["folder_id"] as? String { let f = try folder(id); try requireEditable(f); return f }
        let list = try accounts()
        let account = list.first { a["account_id"] != nil ? $0["id"] as? String == a["account_id"] as? String : $0["is_default"] as? Bool == true }
        guard let id = account?["default_folder_id"] as? String else { throw BridgeError("DESTINATION_REQUIRED", "No matching Notes account/default folder; choose a folder ID.") }
        let f = try folder(id); try requireEditable(f); return f
    }
    func checkDuplicate(_ folderID: String, _ title: String, excluding: String? = nil, allow: Bool = false) throws {
        guard !allow else { return }
        let matches = try rows(read("noteRows", [folderID, "", title, false])).map(metadata).filter { $0["title"] as? String == title && $0["id"] as? String != excluding }
        if !matches.isEmpty { throw BridgeError("DUPLICATE_FOUND", "A note with this title already exists in the destination folder.", ["ids": matches.map { $0["id"]! }]) }
    }
    func verifyText(_ item: [String: Any], _ expected: String) throws {
        guard let text = item["text"] as? String, notesTextComparable(text) == notesTextComparable(expected) else { throw BridgeError("VERIFICATION_FAILED", "Notes changed the saved text; inspect the current note.", ["current": item]) }
    }
    func run(_ op: String, _ a: [String: Any]) throws -> [String: Any] {
        guard ["request_notes_access", "list_note_accounts", "list_note_folders", "list_notes", "get_note", "create_note", "update_note", "append_note", "move_note", "delete_note", "create_note_folder", "update_note_folder", "delete_note_folder"].contains(op) else {
            throw BridgeError("UNKNOWN_OPERATION", "Unknown Notes operation.")
        }
        if op == "request_notes_access" { _ = try accounts(); return NotesPermission.status() }
        let status = NotesPermission.status()["automation"] as? String
        if status == "not_running" {
            var error: NSDictionary?
            _ = NSAppleScript(source: "tell application \"Notes\" to launch")!.executeAndReturnError(&error)
        }
        guard NotesPermission.status()["automation"] as? String == "authorized" else { throw BridgeError("PERMISSION_REQUIRED", "Run request_access with target=notes and allow Notes Automation access.", ["notes": NotesPermission.status()]) }
        if op == "list_note_accounts" { return ["items": try accounts()] }
        if op == "list_note_folders" {
            let all = try folders()
            if let accountID = a["account_id"] as? String {
                guard try accounts().contains(where: { $0["id"] as? String == accountID }) else { throw BridgeError("NOT_FOUND", "Notes account not found.") }
                return ["items": all.filter { $0["account_id"] as? String == accountID }]
            }
            return ["items": all]
        }
        if op == "list_notes" {
            let items = try rows(read("noteRows", [a["folder_id"] as? String ?? "", a["account_id"] as? String ?? "", a["query"] as? String ?? "", a["search_in"] as? String == "text"]))
                .map(metadata).sorted { lhs, rhs in
                    let l = lhs["modified_at"] as? String ?? "", r = rhs["modified_at"] as? String ?? ""
                    return l == r ? (lhs["id"] as! String) < (rhs["id"] as! String) : l > r
                }
            var result = bridge.page(items, a); result["search_in"] = a["search_in"] ?? "title"; result["text_search_excludes_locked"] = true
            return result
        }
        if op == "get_note" { return try note(bridge.required(a, "id")) }
        if op.hasSuffix("note_folder") { return try folderWrite(op, a) }
        if op == "create_note" {
            let f = try destination(a), title = try bridge.required(a, "title"), body = a["body_text"] as? String ?? ""
            try checkDuplicate(f["id"] as! String, title, allow: a["allow_duplicate"] as? Bool == true)
            let text = title + (body.isEmpty ? "" : "\n" + notesPlainText(body))
            bridge.writeAttempted = true
            let id = try call("makeNote", [f["id"]!, notesHTML(text)]).stringValue!
            bridge.testCrashAfterWrite()
            let actual = try note(id)
            try bridge.verify(["title": title, "folder_id": f["id"]!], actual, keys: ["title", "folder_id"])
            try verifyText(actual, text); return actual
        }
        let id = try bridge.required(a, "id"), before = try note(id)
        try bridge.checkVersion(before, a); try requireEditable(before)
        if op == "delete_note" {
            bridge.writeAttempted = true; _ = try call("removeNote", [id]); bridge.testCrashAfterWrite()
            let source = try folder(before["folder_id"] as! String)
            guard !(source["note_ids"] as! [String]).contains(id) else { throw BridgeError("VERIFICATION_FAILED", "Note remains in its original folder.") }
            return ["deleted": true, "original_id": id, "item": before, "deletion_scope": "removed_from_original_folder", "retention": "controlled_by_notes_recently_deleted"]
        }
        if op == "move_note" { return try move(before, a) }
        let title = a["title"] as? String ?? before["title"] as! String
        var html: String? = nil, expectedText: String? = nil
        let attachments = before["attachments"] as! [[String: Any]]
        if op == "append_note" || a["body_text"] != nil {
            guard attachments.isEmpty else { throw BridgeError("ATTACHMENTS_UNSUPPORTED", "Body rewriting cannot preserve Notes attachments; use Notes to edit this note.") }
            if op == "append_note" {
                guard before["complex_content"] as? Bool != true else { throw BridgeError("COMPLEX_CONTENT", "Appending cannot guarantee preservation of this note's structures; edit it in Notes.") }
                let text = notesPlainText(try bridge.required(a, "text"))
                html = notesPreservingWhitespaceHTML(before["html"] as! String) + "\n" + notesHTML(text)
                let previous = notesPlainText(before["text"] as! String)
                expectedText = previous + (previous.hasSuffix("\n") ? "" : "\n") + text
            } else {
                guard before["rich_formatting"] as? Bool != true || a["allow_format_loss"] as? Bool == true else { throw BridgeError("FORMAT_LOSS_CONFIRMATION_REQUIRED", "Replacing this body removes rich formatting; allow_format_loss=true is required for that scope.") }
                let text = notesPlainText(a["body_text"] as! String)
                expectedText = title + (text.isEmpty ? "" : "\n" + text); html = notesHTML(expectedText!)
            }
        }
        bridge.writeAttempted = true
        // Notes derives name again after a body write; restore an independently renamed title.
        _ = try call("changeNote", [id, a["title"] != nil || html != nil, title, html != nil, html ?? ""])
        bridge.testCrashAfterWrite()
        let actual = try note(id)
        try bridge.verify(["title": title, "folder_id": before["folder_id"]!], actual, keys: ["title", "folder_id"])
        if let expectedText { try verifyText(actual, expectedText) }
        else {
            try bridge.verify(before, actual, keys: ["text", "attachments"])
            guard notesComparableHTML(before["html"] as! String) == notesComparableHTML(actual["html"] as! String) else { throw BridgeError("VERIFICATION_FAILED", "Notes changed body formatting during the title edit.", ["current": actual]) }
        }
        if op == "append_note" {
            let prefix = notesComparableHTML(before["html"] as! String)
            guard notesComparableHTML(actual["html"] as! String).hasPrefix(prefix) else { throw BridgeError("VERIFICATION_FAILED", "Notes changed the existing HTML while appending; inspect formatting before any further write.", ["current": actual]) }
        }
        return actual
    }
    func move(_ before: [String: Any], _ a: [String: Any]) throws -> [String: Any] {
        let target = try folder(bridge.required(a, "folder_id")), source = try folder(before["folder_id"] as! String)
        try requireEditable(target)
        let crossAccount = source["account_id"] as? String != target["account_id"] as? String
        if crossAccount && !(before["attachments"] as! [[String: Any]]).isEmpty { throw BridgeError("ATTACHMENTS_UNSUPPORTED", "Cross-account moves with attachments cannot be verified by this adapter.") }
        let id = before["id"] as! String
        if source["id"] as? String == target["id"] as? String { return before }
        try checkDuplicate(target["id"] as! String, before["title"] as! String, excluding: id)
        bridge.writeAttempted = true
        _ = try call("moveNote", [id, target["id"]!]); bridge.testCrashAfterWrite()
        var actual: [String: Any]?
        do { let candidate = try note(id); if candidate["folder_id"] as? String == target["id"] as? String { actual = candidate } }
        catch let e as BridgeError where e.code == "NOT_FOUND" { }
        if actual == nil {
            let current = try folder(target["id"] as! String), oldIDs = Set(target["note_ids"] as! [String])
            let newIDs = (current["note_ids"] as! [String]).filter { !oldIDs.contains($0) }
            if newIDs.count == 1 { actual = try note(newIDs[0]) }
        }
        guard var result = actual else { throw BridgeError("VERIFICATION_FAILED", "Could not uniquely locate the moved note; inspect source and destination.") }
        try bridge.verify(before, result, keys: ["title", "text"] + (crossAccount ? [] : ["attachments"]))
        try bridge.verify(["folder_id": target["id"]!], result, keys: ["folder_id"])
        guard !(try folder(source["id"] as! String)["note_ids"] as! [String]).contains(id) else { throw BridgeError("VERIFICATION_FAILED", "Original note remains in the source folder.") }
        result["original_id"] = id; return result
    }
    func folderWrite(_ op: String, _ a: [String: Any]) throws -> [String: Any] {
        let all = try folders()
        if op == "create_note_folder" {
            let parentID: String, isAccount: Bool
            if let id = a["parent_folder_id"] as? String { let parent = try folder(id); try requireEditable(parent); parentID = id; isAccount = false }
            else {
                guard let account = try accounts().first(where: { a["account_id"] != nil ? $0["id"] as? String == a["account_id"] as? String : $0["is_default"] as? Bool == true }) else { throw BridgeError("NOT_FOUND", "Notes account not found.") }
                parentID = account["id"] as! String; isAccount = true
            }
            let name = try bridge.required(a, "name")
            if a["allow_duplicate"] as? Bool != true && all.contains(where: { $0["parent_id"] as? String == parentID && $0["name"] as? String == name }) { throw BridgeError("DUPLICATE_FOUND", "A folder with this name already exists under the parent.") }
            bridge.writeAttempted = true
            let id = try call("makeFolder", [parentID, isAccount, name]).stringValue!; bridge.testCrashAfterWrite()
            let actual = try folder(id); try bridge.verify(["name": name, "parent_id": parentID], actual, keys: ["name", "parent_id"]); return actual
        }
        let id = try bridge.required(a, "id"), before = try folder(id)
        try bridge.checkVersion(before, a); try requireEditable(before)
        guard before["is_default"] as? Bool != true else { throw BridgeError("PROTECTED_FOLDER", "Default Notes folders cannot be renamed or deleted by this tool.") }
        if op == "delete_note_folder" {
            if a["delete_contents"] as? Bool != true && ((before["note_count"] as! Int) > 0 || (before["child_folder_count"] as! Int) > 0) { throw BridgeError("CONTENTS_SCOPE_REQUIRED", "Deleting a nonempty folder includes every descendant; delete_contents=true is required for that scope.") }
            // Shared descendants must not be removed through a parent deletion.
            var descendants: Set<String> = [id]
            for _ in 0..<all.count {
                let added = all.filter { descendants.contains($0["parent_id"] as! String) }.map { $0["id"] as! String }
                let prior = descendants.count; descendants.formUnion(added); if descendants.count == prior { break }
            }
            guard !all.contains(where: { descendants.contains($0["id"] as! String) && $0["shared"] as? Bool == true }) else { throw BridgeError("SHARED_UNSUPPORTED", "This folder contains shared descendants.") }
            for f in all where descendants.contains(f["id"] as! String) {
                for noteID in f["note_ids"] as! [String] {
                    do { try requireEditable(metadata(read("readMetadata", [noteID]))) }
                    catch let e as BridgeError where e.code == "NOT_FOUND" { }
                }
            }
            bridge.writeAttempted = true; _ = try call("removeFolder", [id]); bridge.testCrashAfterWrite()
            guard try !folders().contains(where: { $0["id"] as? String == id }) else { throw BridgeError("VERIFICATION_FAILED", "Notes folder remains after deletion.") }
            return ["deleted": true, "item": before, "contents_deleted": a["delete_contents"] as? Bool ?? false]
        }
        let name = try bridge.required(a, "name")
        guard !all.contains(where: { $0["id"] as? String != id && $0["parent_id"] as? String == before["parent_id"] as? String && $0["name"] as? String == name }) else { throw BridgeError("DUPLICATE_FOUND", "A sibling folder already has this name.") }
        bridge.writeAttempted = true; _ = try call("renameFolder", [id, name]); bridge.testCrashAfterWrite()
        let actual = try folder(id); try bridge.verify(["name": name], actual, keys: ["name"]); return actual
    }
}
