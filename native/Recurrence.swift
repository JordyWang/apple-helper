import Foundation
import EventKit

func shiftedEnd(oldStart: Date, oldEnd: Date, newStart: Date, allDay: Bool, calendar: Calendar) -> Date {
    if allDay {
        let days = calendar.dateComponents([.day], from: oldStart, to: oldEnd).day ?? 1
        return calendar.date(byAdding: .day, value: days, to: newStart)!
    }
    return newStart.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
}

@available(macOS 14.0, *)
extension Bridge {
    func recurrenceHorizon() -> Date { Calendar(identifier: .gregorian).date(byAdding: .year, value: 10, to: Date())! }
    func recurrenceWarnings(end: Date) -> [String] {
        end > recurrenceHorizon() ? ["This query extends beyond the supported 10-year recurrence planning horizon. EventKit may omit repeated occurrences; do not infer complete availability."] : []
    }
    func recurrenceData(_ rules: [EKRecurrenceRule]?) -> [[String: Any]] {
        (rules ?? []).map { rule in
            let frequencies = ["daily", "weekly", "monthly", "yearly"]
            return ["frequency": frequencies[rule.frequency.rawValue], "interval": rule.interval,
                    "days_of_week": (rule.daysOfTheWeek ?? []).map { ["day": ($0.dayOfTheWeek.rawValue + 5) % 7 + 1, "week": $0.weekNumber] }.sorted { ($0["day"]!, $0["week"]!) < ($1["day"]!, $1["week"]!) },
                    "days_of_month": (rule.daysOfTheMonth ?? []).map(\.intValue).sorted(),
                    "months_of_year": (rule.monthsOfTheYear ?? []).map(\.intValue).sorted(),
                    "weeks_of_year": (rule.weeksOfTheYear ?? []).map(\.intValue).sorted(),
                    "days_of_year": (rule.daysOfTheYear ?? []).map(\.intValue).sorted(),
                    "set_positions": (rule.setPositions ?? []).map(\.intValue).sorted(),
                    "count": rule.recurrenceEnd?.occurrenceCount ?? 0,
                    "until": value(rule.recurrenceEnd?.endDate)] as [String: Any]
        }
    }
    func applyRecurrence(_ item: EKCalendarItem, _ args: [String: Any], anchor: Date?) throws {
        guard let spec = args["recurrence"] else { return }
        if spec is NSNull { item.recurrenceRules = nil; return }
        guard let r = spec as? [String: Any], let name = r["frequency"] as? String,
              let frequency = ["daily": EKRecurrenceFrequency.daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly][name] else {
            throw BridgeError("INVALID_RECURRENCE", "Unknown recurrence frequency.")
        }
        guard let anchor else { throw BridgeError("RECURRENCE_ANCHOR_REQUIRED", "A recurring reminder needs a due date.") }
        guard anchor <= recurrenceHorizon() else { throw BridgeError("RECURRENCE_HORIZON", "New recurrence anchors are supported up to 10 years ahead; far-future EventKit expansion is unreliable.") }
        var ending: EKRecurrenceEnd?
        if let count = r["count"] as? Int { ending = EKRecurrenceEnd(occurrenceCount: count) }
        if let text = r["until"] as? String {
            let until = try date(text)
            guard until >= anchor else { throw BridgeError("INVALID_RECURRENCE", "Recurrence until must not precede the first occurrence.") }
            ending = EKRecurrenceEnd(end: until)
        }
        let days = (r["days_of_week"] as? [[String: Int]])?.map {
            EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0["day"]! % 7 + 1)!, weekNumber: $0["week"] ?? 0)
        }
        func numbers(_ key: String) -> [NSNumber]? { (r[key] as? [Int])?.map { NSNumber(value: $0) } }
        let rule = EKRecurrenceRule(recurrenceWith: frequency, interval: r["interval"] as? Int ?? 1,
                                    daysOfTheWeek: days, daysOfTheMonth: numbers("days_of_month"), monthsOfTheYear: numbers("months_of_year"),
                                    weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: numbers("set_positions"), end: ending)
        item.recurrenceRules = [rule]
    }
    func seriesRoot(_ id: String) throws -> EKEvent {
        guard let base = store.event(withIdentifier: id) else { throw BridgeError("NOT_FOUND", "Series not found; query current events again.") }
        if !base.isDetached { return base }
        if let externalID = base.calendarItemExternalIdentifier {
            let parents = store.calendarItems(withExternalIdentifier: externalID).compactMap { $0 as? EKEvent }
                .filter { $0.calendar.calendarIdentifier == base.calendar.calendarIdentifier && !$0.isDetached && $0.hasRecurrenceRules }
            if parents.count == 1 { return parents[0] }
        }
        throw BridgeError("SERIES_AMBIGUOUS", "Cannot identify the parent from this detached exception. Query an unchanged series occurrence and use its ID.")
    }
}
