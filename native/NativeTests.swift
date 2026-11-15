#if TESTING
import Foundation

func runNativeTests() {
    let iso = ISO8601DateFormatter()
    func date(_ text: String) -> Date { iso.date(from: text)! }
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
    for (old, new, expected) in [
        ("2027-03-13T00:00:00-05:00", "2027-03-14T00:00:00-05:00", "2027-03-15T00:00:00-04:00"),
        ("2027-11-06T00:00:00-04:00", "2027-11-07T00:00:00-04:00", "2027-11-08T00:00:00-05:00")
    ] {
        let end = shiftedEnd(oldStart: date(old), oldEnd: date(new), newStart: date(new), allDay: true, calendar: cal)
        precondition(end == date(expected), "All-day reschedule must preserve calendar days through DST")
    }
    let spring = workingInterval(day: date("2027-03-14T00:00:00-05:00"), start: "01:00", end: "04:00", calendar: cal)!
    precondition(spring.end.timeIntervalSince(spring.start) == 2 * 3600)
    let fall = workingInterval(day: date("2027-11-07T00:00:00-04:00"), start: "01:00", end: "02:00", calendar: cal)!
    precondition(fall.end.timeIntervalSince(fall.start) == 2 * 3600)
    let missing = workingInterval(day: date("2027-03-14T00:00:00-05:00"), start: "02:30", end: "04:00", calendar: cal)!
    precondition(missing.start == date("2027-03-14T03:00:00-04:00"))
    let start = date("2027-01-01T09:00:00Z"), end = date("2027-01-01T18:00:00Z")
    let windows = freeWindows(start: start, end: end, busy: [
        BusyInterval(start: date("2027-01-01T08:00:00Z"), end: date("2027-01-01T10:00:00Z")),
        BusyInterval(start: date("2027-01-01T09:30:00Z"), end: date("2027-01-01T11:00:00Z")),
        BusyInterval(start: date("2027-01-01T11:00:00Z"), end: date("2027-01-01T12:00:00Z")),
        BusyInterval(start: date("2027-01-01T13:00:00Z"), end: date("2027-01-01T13:15:00Z"))
    ], minimum: 3600)
    precondition(windows.count == 2 && windows[0].start == date("2027-01-01T12:00:00Z") && windows[0].end == date("2027-01-01T13:00:00Z") && windows[1].end == end)
    precondition(freeWindows(start: start, end: end, busy: [BusyInterval(start: start, end: end)], minimum: 1800).isEmpty)
    print("Native DST, interval merge, clipping and minimum-duration tests: PASS")
}
#endif
