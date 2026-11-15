import Foundation
import EventKit
import CoreGraphics

@available(macOS 14.0, *)
extension Bridge {
    func colorHex(_ color: CGColor?) -> Any {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let rgb = color?.converted(to: space, intent: .defaultIntent, options: nil), let parts = rgb.components, parts.count >= 3 else { return null }
        return String(format: "#%02X%02X%02X", Int((parts[0] * 255).rounded()), Int((parts[1] * 255).rounded()), Int((parts[2] * 255).rounded()))
    }
    func containerOperation(_ op: String, _ a: [String: Any]) throws -> [String: Any] {
        if op == "list_sources" {
            guard status(.event) == "full_access" || status(.reminder) == "full_access" else { throw BridgeError("PERMISSION_REQUIRED", "Grant Calendar or Reminders full access first.") }
            return ["items": store.sources.map { ["id": $0.sourceIdentifier, "name": $0.title, "type": $0.sourceType.rawValue, "delegated": $0.isDelegate] }]
        }
        let kind: EKEntityType = op.hasSuffix("reminder_list") ? .reminder : .event
        try requireAccess(kind)
        let c: EKCalendar
        if op.hasPrefix("create_") {
            c = EKCalendar(for: kind, eventStore: store)
            if let sourceID = a["source_id"] as? String {
                guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceID }) else { throw BridgeError("NOT_FOUND", "Source not found; use list_sources.") }
                c.source = source
            } else {
                let defaultContainer = kind == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
                guard let source = defaultContainer?.source else { throw BridgeError("SOURCE_REQUIRED", "No system default account is available; select source_id from list_sources.") }
                c.source = source
            }
            c.title = try required(a, "name")
            if a["allow_duplicate"] as? Bool != true && store.calendars(for: kind).contains(where: { $0.source.sourceIdentifier == c.source.sourceIdentifier && $0.title == c.title }) {
                throw BridgeError("DUPLICATE_FOUND", "A container with this name already exists in the selected account.")
            }
        } else {
            c = try calendar(required(a, "id"), kind, write: true)
            try checkVersion(containerData(c), a)
            guard !c.isImmutable else { throw BridgeError("READ_ONLY", "This system calendar/list cannot be renamed or removed.") }
        }
        if op.hasPrefix("delete_") {
            guard a["delete_contents"] as? Bool == true else { throw BridgeError("CONTENTS_SCOPE_REQUIRED", "Deleting a container deletes ALL its contents; pass delete_contents=true only for that user-authorized scope.") }
            let old = containerData(c), id = c.calendarIdentifier
            writeAttempted = true; try store.removeCalendar(c, commit: true); testCrashAfterWrite(); store.reset()
            guard !store.calendars(for: kind).contains(where: { $0.calendarIdentifier == id }) else { throw BridgeError("VERIFICATION_FAILED", "Container still exists after deletion.") }
            return ["deleted": true, "contents_deleted": true, "item": old]
        }
        if let name = a["name"] as? String { c.title = name }
        if let hex = a["color"] as? String, let value = UInt32(hex.dropFirst(), radix: 16) {
            c.cgColor = CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        let expectedName = c.title, expectedColor = colorHex(c.cgColor), sourceID = c.source.sourceIdentifier
        writeAttempted = true; try store.saveCalendar(c, commit: true)
        let id = c.calendarIdentifier; testCrashAfterWrite(); store.reset()
        let actual = containerData(try calendar(id, kind))
        var expected: [String: Any] = ["name": expectedName, "source_id": sourceID]
        if a["color"] != nil { expected["color"] = expectedColor }
        try verify(expected, actual, keys: Array(expected.keys))
        return actual
    }
}
