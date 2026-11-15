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
    precondition(notesHTML("<script> & \"quoted\"\n\nend").contains("&lt;script&gt; &amp; &quot;quoted&quot;"))
    precondition(notesHTML("a\r\nb").components(separatedBy: "\n").count == 2)
    precondition(!notesHasComplexHTML("<div>A checklist is text, not markup.</div>"))
    precondition(notesHasComplexHTML("<table><tr><td>cell</td></tr></table>"))
    precondition(notesHasComplexHTML("<ul class=\"Apple-dash-list\"><li>task</li></ul>"))
    precondition(notesHasRichFormatting("<div><b>bold</b></div>"))
    precondition(!notesHasRichFormatting("<div>&lt;b&gt;literal&lt;/b&gt;</div>"))
    let noteVersionA: [String: Any] = ["id": "note", "title": "Title", "text": "text\n", "html": "<div>text<br></div>\n", "folder_id": "folder", "modified_at": "one"]
    var noteVersionB = noteVersionA; noteVersionB["html"] = "<div>text</div>\n"; noteVersionB["modified_at"] = "two"
    precondition(try! notesVersion(noteVersionA) == notesVersion(noteVersionB), "Notes normalization must not look like a user edit")
    noteVersionB["html"] = "<div><b>text</b></div>"
    precondition(try! notesVersion(noteVersionA) != notesVersion(noteVersionB), "Real formatting changes must invalidate the version")
    noteVersionB = noteVersionA; noteVersionB["title"] = "User edit"
    precondition(try! notesVersion(noteVersionA) != notesVersion(noteVersionB), "Title changes must invalidate the version")
    noteVersionB = noteVersionA; noteVersionB["folder_id"] = "other"
    precondition(try! notesVersion(noteVersionA) != notesVersion(noteVersionB), "Movement must invalidate the version")
    print("Native Notes escaping, newline normalization and structured-content guards: PASS")
}
#endif
