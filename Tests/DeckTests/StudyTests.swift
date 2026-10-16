import XCTest
import SwiftData
@testable import Deck

/// FocusSession as Deck 1.0 stored it, before `subject`.
enum OldSchema { @Model final class FocusSession { var start: Date; var minutes: Int; init(start: Date, minutes: Int) { self.start = start; self.minutes = minutes } } }

final class StudyTests: XCTestCase {
    let cal = Calendar.current
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 10, minute: 0))!   // a Friday

    // MARK: countdown

    func testCountdownDaysAndHours() {
        let due = now + 3 * 86_400 + 14 * 3600 + 25 * 60
        XCTAssertEqual(Deadlines.countdownText(to: due, now: now), "03 DAYS 14 HRS")
        XCTAssertEqual(Deadlines.countdownText(to: now + 86_400 + 3600, now: now), "01 DAY 01 HR")
    }

    func testCountdownUnderADayShowsHoursAndMinutes() {
        XCTAssertEqual(Deadlines.countdownText(to: now + 5 * 3600 + 12 * 60 + 40, now: now), "05 HRS 12 MIN")
        XCTAssertEqual(Deadlines.countdownText(to: now + 86_399, now: now), "23 HRS 59 MIN")
        XCTAssertEqual(Deadlines.countdownText(to: now - 60, now: now), "00 HRS 00 MIN", "past due never goes negative")
    }

    // MARK: quick add

    func testParseExam() throws {
        let p = try XCTUnwrap(Deadlines.parse("Physics exam Friday 9am", now: .now))
        XCTAssertEqual(p.title, "Physics exam")
        XCTAssertEqual(p.course, "Physics")
        XCTAssertEqual(p.kind, .exam)
        XCTAssertEqual(cal.component(.weekday, from: p.due), 6)
        XCTAssertEqual(cal.component(.hour, from: p.due), 9)
    }

    func testParseDayOnlyIsEndOfDayAndNoDayIsNil() throws {
        let p = try XCTUnwrap(Deadlines.parse("Essay for History next Monday", now: .now))
        XCTAssertEqual(p.kind, .assignment)
        XCTAssertEqual(cal.component(.hour, from: p.due), 23)
        XCTAssertEqual(cal.component(.minute, from: p.due), 59)
        XCTAssertNil(Deadlines.parse("Read chapter 4", now: .now))
    }

    func testEditTextRoundTrips() throws {
        let due = cal.date(byAdding: .day, value: 5, to: cal.date(bySettingHour: 9, minute: 30, second: 0, of: .now)!)!
        XCTAssertEqual(Deadlines.parse(Deadlines.editText(due), now: .now)?.due, due)
    }

    // MARK: reminders

    func testRemindersOncePerWindow() {
        let due = now + 30 * 3600
        XCTAssertNil(Deadlines.reminder(due: due, now: now, sentDay: false, sentHours: false), "more than a day away")
        let dayBefore = due - 23 * 3600
        XCTAssertEqual(Deadlines.reminder(due: due, now: dayBefore, sentDay: false, sentHours: false), .dayBefore)
        XCTAssertNil(Deadlines.reminder(due: due, now: dayBefore, sentDay: true, sentHours: false), "sent already")
        let close = due - 90 * 60
        XCTAssertEqual(Deadlines.reminder(due: due, now: close, sentDay: true, sentHours: false), .twoHours)
        XCTAssertNil(Deadlines.reminder(due: due, now: close, sentDay: true, sentHours: true))
        XCTAssertNil(Deadlines.reminder(due: due, now: due + 60, sentDay: false, sentHours: false), "nothing after it's due")
    }

    func testAddedLateSendsOnlyTheTwoHourReminder() {
        XCTAssertEqual(Deadlines.reminder(due: now + 3600, now: now, sentDay: false, sentHours: false), .twoHours)
    }

    // MARK: timetable

    func testNextClassSameDay() throws {
        let classes = [ClassSlot(course: "Linear Algebra", weekday: 6, start: 10 * 60 + 12, end: 11 * 60, room: "Room 204"),
                       ClassSlot(course: "Physics", weekday: 6, start: 14 * 60, end: 15 * 60)]
        let next = try XCTUnwrap(Timetable.nextClass(in: classes, now: now))
        XCTAssertEqual(next.title, "Linear Algebra")
        XCTAssertEqual(next.room, "Room 204")
        XCTAssertEqual(next.start.timeIntervalSince(now), 12 * 60)
        XCTAssertEqual(Timetable.when(next.start, now: now), "in 12 min")
    }

    func testNextClassAcrossWeekBoundary() throws {
        // Sunday 23:00; the only class is Monday 9:00, and one already passed on Friday.
        let sunday = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23))!
        let classes = [ClassSlot(course: "Calculus", weekday: 2, start: 9 * 60, end: 10 * 60),
                       ClassSlot(course: "Chemistry", weekday: 6, start: 8 * 60, end: 9 * 60)]
        let next = try XCTUnwrap(Timetable.nextClass(in: classes, now: sunday))
        XCTAssertEqual(next.title, "Calculus")
        XCTAssertNil(next.room)
        XCTAssertEqual(next.start, cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9)))
        // Friday 11:00, after Chemistry: next is Monday's Calculus, not next Friday's Chemistry.
        XCTAssertEqual(Timetable.nextClass(in: classes, now: now + 3600)?.title, "Calculus")
        XCTAssertNil(Timetable.nextClass(in: [], now: now))
    }

    func testTimeParsing() {
        XCTAssertEqual(Timetable.minutes("9"), 540)
        XCTAssertEqual(Timetable.minutes("9:30"), 570)
        XCTAssertEqual(Timetable.minutes("14:05"), 845)
        XCTAssertEqual(Timetable.minutes("2:30 pm"), 870)
        XCTAssertEqual(Timetable.minutes("12am"), 0)
        XCTAssertNil(Timetable.minutes("25:00"))
        XCTAssertNil(Timetable.minutes("9:75"))
        XCTAssertNil(Timetable.minutes("soon"))
    }

    // MARK: focus by subject

    func testSubjectAggregation() {
        let rows = Subjects.minutes([("Physics", 25), (nil, 15), ("Maths", 50), ("Physics", 45), ("", 10)])
        XCTAssertEqual(rows.map(\.name), ["Physics", "Maths", Subjects.none])
        XCTAssertEqual(rows.map(\.minutes), [70, 50, 25])
        XCTAssertTrue(Subjects.minutes([]).isEmpty)
    }

    func testSubjectListDedupesAndSorts() {
        XCTAssertEqual(Subjects.list(["physics", " Maths ", "", "Physics", "biology"]), ["biology", "Maths", "physics"])
    }

    func testFocusSessionSubjectDefaultsToNil() {
        XCTAssertNil(FocusSession(start: now, minutes: 25).subject)
    }

    /// A store saved before `subject` and the study models existed opens with today's models, keeping its sessions.
    @MainActor func testOldStoreOpensWithSubject() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer { for s in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        do {
            let old = Schema([OldSchema.FocusSession.self])
            let c = try ModelContainer(for: old, configurations: ModelConfiguration(schema: old, url: url))
            c.mainContext.insert(OldSchema.FocusSession(start: now, minutes: 25))
            try c.mainContext.save()
        }
        let schema = Schema([Activity.self, FocusSession.self] + PlanModels.all + FocusModels.all + NotesModels.all + InboxModels.all)
        let c = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let sessions = try c.mainContext.fetch(FetchDescriptor<FocusSession>())
        XCTAssertEqual(sessions.map(\.minutes), [25])
        XCTAssertNil(sessions.first?.subject)
        XCTAssertEqual(try c.mainContext.fetchCount(FetchDescriptor<Deadline>()), 0)
    }
}
