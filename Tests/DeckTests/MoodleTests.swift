import XCTest
import SwiftData
@testable import Deck

/// Deadline as the first Study build stored it, before `source` / `sourceUID`.
enum OldDeadlineSchema {
    @Model final class Deadline {
        var title: String; var course: String = ""; var due: Date; var kind: String = "assignment"
        var done: Bool = false; var remindedDay: Bool = false; var remindedHours: Bool = false
        init(title: String, due: Date) { self.title = title; self.due = due }
    }
}

final class MoodleTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let now = ISO8601DateFormatter().date(from: "2026-10-16T10:00:00Z")!

    func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // A Moodle 4.x export with made-up data: CRLF endings, folded lines, escapes, UTC times.
    let fixture = [
        "BEGIN:VCALENDAR",
        "METHOD:PUBLISH",
        "PRODID:-//Moodle Pty Ltd//NONSGML Moodle Version 2024042200//EN",
        "VERSION:2.0",
        "BEGIN:VEVENT",
        "UID:1201@moodle.example.edu",
        "SUMMARY:Lab Report 3: Pendulum is due",
        "DESCRIPTION:Submit your report as a PDF\\, max 5 pages.\\nLate work loses 10%\\; no",
        "  exceptions.",
        "CLASS:PUBLIC",
        "LAST-MODIFIED:20261001T080000Z",
        "DTSTAMP:20261016T090000Z",
        "DTSTART:20261020T235900Z",
        "DTEND:20261020T235900Z",
        "CATEGORIES:PHY101",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:1202@moodle.example.edu",
        "SUMMARY:Weekly check 4 closes",
        "DESCRIPTION:Quiz on chapters 3 and 4.",
        "DTSTART:20261018T170000Z",
        "DTEND:20261018T170000Z",
        "CATEGORIES:MA201",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:1203@moodle.example.edu",
        "SUMMARY:Weekly check 4 opens",
        "DTSTART:20261017T090000Z",
        "CATEGORIES:MA201",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:1204@moodle.example.edu",
        "SUMMARY:Midterm Exam",
        "DTSTART;TZID=Asia/Kolkata:20261023T100000",
        "DTEND;TZID=Asia/Kolkata:20261023T120000",
        "CATEGORIES:CS102",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:1205@moodle.example.edu",
        "SUMMARY:Team project demo",
        "DTSTART;VALUE=DATE:20261030",
        "CATEGORIES:CS102,Group A",
        "END:VEVENT",
        "END:VCALENDAR",
    ].joined(separator: "\r\n")

    // MARK: ICS

    func testFixtureParses() throws {
        let events = ICS.parse(fixture)
        XCTAssertEqual(events.map(\.uid), (1201...1205).map { "\($0)@moodle.example.edu" })
        let lab = events[0]
        XCTAssertEqual(lab.summary, "Lab Report 3: Pendulum is due")
        XCTAssertEqual(lab.description, "Submit your report as a PDF, max 5 pages.\nLate work loses 10%; no exceptions.", "folded + escaped")
        XCTAssertEqual(lab.start, date("2026-10-20T23:59:00Z"))
        XCTAssertEqual(lab.categories, ["PHY101"])
        XCTAssertEqual(events[3].start, date("2026-10-23T04:30:00Z"), "TZID Asia/Kolkata is UTC+5:30")
        XCTAssertEqual(events[3].end, date("2026-10-23T06:30:00Z"))
        XCTAssertTrue(events[4].allDay)
        XCTAssertEqual(events[4].categories, ["CS102", "Group A"])
    }

    func testFoldingWithTabAndLFOnly() {
        let e = ICS.parse("BEGIN:VEVENT\nUID:a\nSUMMARY:Very long\n\t title here\nDTSTART:20261020T120000Z\nEND:VEVENT")
        XCTAssertEqual(e.first?.summary, "Very long title here")
    }

    func testUnescape() {
        XCTAssertEqual(ICS.unescape(#"a\,b\;c\nd\\n"#), ["a,b;c\nd\\n"])
        XCTAssertEqual(ICS.unescape(#"A\,B,C"#, list: true), ["A,B", "C"])
    }

    func testDates() {
        XCTAssertEqual(ICS.date("20261020T120000Z", params: [:])?.0, date("2026-10-20T12:00:00Z"))
        XCTAssertEqual(ICS.date("20261020T120000", params: ["TZID": "Europe/London"])?.0, date("2026-10-20T11:00:00Z"), "BST in October")
        let allDay = ICS.date("20261020", params: ["VALUE": "DATE"])
        XCTAssertEqual(allDay?.1, true)
        XCTAssertEqual(allDay.map { Calendar.current.dateComponents([.year, .month, .day, .hour], from: $0.0) },
                       DateComponents(year: 2026, month: 10, day: 20, hour: 0))
        XCTAssertNotNil(ICS.date("20261020T120000", params: ["TZID": "Not A Zone"]), "unknown zone falls back to local")
        XCTAssertNil(ICS.date("garbage", params: [:]))
    }

    func testQuotedParamWithColon() {
        let s = ICS.split(#"DTSTART;TZID="America/New_York:x":20261020T120000"#)
        XCTAssertEqual(s?.0, "DTSTART")
        XCTAssertEqual(s?.2, "20261020T120000")
    }

    // MARK: mapping

    func testMapping() throws {
        let items = ICS.parse(fixture).compactMap { Moodle.item($0) }
        XCTAssertEqual(items.map(\.title), ["Lab Report 3: Pendulum", "Weekly check 4", "Midterm Exam", "Team project demo"], "opens skipped, suffixes trimmed")
        XCTAssertEqual(items.map(\.kind), [.assignment, .quiz, .exam, .project])
        XCTAssertEqual(items.map(\.course), ["PHY101", "MA201", "CS102", "CS102"])
        let demo = try XCTUnwrap(items.last)
        XCTAssertEqual(Calendar.current.component(.hour, from: demo.due), 23, "all-day means end of that day")
    }

    func testOldStyleSuffixes() {
        let e = ICSEvent(uid: "x", summary: "Quiz 1 (Quiz closes)", start: now)
        XCTAssertEqual(Moodle.item(e)?.title, "Quiz 1")
        XCTAssertEqual(Moodle.item(e)?.kind, .quiz)
        XCTAssertNil(Moodle.item(ICSEvent(uid: "y", summary: "Quiz 1 (Quiz opens)", start: now)))
        XCTAssertNil(Moodle.item(ICSEvent(uid: "", summary: "No uid", start: now)))
        XCTAssertEqual(Moodle.kind(summary: "Unit test 2", description: ""), .exam)
        XCTAssertEqual(Moodle.kind(summary: "Contest entry", description: ""), .assignment, "whole words only")
    }

    // MARK: merge

    func imported(_ uid: String, due: Date, done: Bool = false) -> Deadline {
        let d = Deadline(title: "old", due: due)
        (d.source, d.sourceUID, d.done) = (Moodle.source, uid, done)
        return d
    }

    func testMergeAddsUpdatesAndKeepsDone() {
        let lab = imported("1201@moodle.example.edu", due: date("2026-10-19T12:00:00Z"), done: true)
        lab.remindedDay = true
        let (added, removed) = Moodle.merge(ICS.parse(fixture), into: [lab], now: now)
        XCTAssertEqual(added.map(\.sourceUID), (1202...1205).filter { $0 != 1203 }.map { "\($0)@moodle.example.edu" })
        XCTAssertTrue(added.allSatisfy { $0.source == Moodle.source })
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(lab.done, "done is the user's")
        XCTAssertEqual(lab.title, "Lab Report 3: Pendulum")
        XCTAssertEqual(lab.due, date("2026-10-20T23:59:00Z"))
        XCTAssertFalse(lab.remindedDay, "new due time, new reminders")
    }

    func testMergeSkipsNewPastEvents() {
        let past = ICSEvent(uid: "p", summary: "Old essay is due", start: now - 86_400)
        XCTAssertTrue(Moodle.merge([past], into: [], now: now).added.isEmpty)
    }

    func testRemovalRules() {
        let futureOpen = imported("gone-1", due: now + 86_400)
        let futureDone = imported("gone-2", due: now + 86_400, done: true)
        let pastOpen = imported("gone-3", due: now - 86_400)
        let stillThere = imported("1202@moodle.example.edu", due: now + 3600)
        let removed = Moodle.merge(ICS.parse(fixture), into: [futureOpen, futureDone, pastOpen, stillThere], now: now).removed
        XCTAssertEqual(removed.map(\.sourceUID), ["gone-1"])
    }

    // MARK: link

    func testLinkValidation() {
        XCTAssertNotNil(Moodle.link("  https://moodle.example.edu/calendar/export_execute.php?userid=7&authtoken=abc&preset_what=all&preset_time=recentupcoming\n"))
        XCTAssertNotNil(Moodle.link("https://example.edu/feeds/me.ics"))
        XCTAssertNil(Moodle.link("http://moodle.example.edu/calendar/export_execute.php?userid=7"), "https only")
        XCTAssertNil(Moodle.link("https://moodle.example.edu/my/"))
        XCTAssertNil(Moodle.link("moodle.example.edu/calendar/export_execute.php"))
        XCTAssertNil(Moodle.link(""))
    }

    func testAgo() {
        XCTAssertEqual(Moodle.ago(now - 20, now: now), "just now")
        XCTAssertEqual(Moodle.ago(now - 12 * 60, now: now), "12 min ago")
        XCTAssertEqual(Moodle.ago(now - 3 * 3600, now: now), "3 h ago")
    }

    // MARK: migration

    @MainActor func testOldDeadlinesOpenWithoutSource() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer { for s in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        do {
            let old = Schema([OldDeadlineSchema.Deadline.self])
            let c = try ModelContainer(for: old, configurations: ModelConfiguration(schema: old, url: url))
            c.mainContext.insert(OldDeadlineSchema.Deadline(title: "Essay", due: now))
            try c.mainContext.save()
        }
        let schema = Schema([Deadline.self])
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let all = try c.mainContext.fetch(FetchDescriptor<Deadline>())
        XCTAssertEqual(all.map(\.title), ["Essay"])
        XCTAssertNil(all.first?.source)
        XCTAssertNil(all.first?.sourceUID)
    }
}
