import XCTest
@testable import Deck

final class PlanFocusTests: XCTestCase {
    let cal = Calendar.current

    // MARK: quick add

    func testTimeMakesEvent() {
        let now = Date()
        let p = QuickAdd.parse("Dentist tomorrow 3pm", now: now)
        XCTAssertEqual(p.title, "Dentist")
        XCTAssertTrue(p.hasTime)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        XCTAssertEqual(p.date, cal.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow))
    }

    func testWeekdayWithTime() {
        let p = QuickAdd.parse("Lunch with Sam Friday 1pm", now: Date())
        XCTAssertEqual(p.title, "Lunch with Sam")
        XCTAssertTrue(p.hasTime)
        XCTAssertEqual(cal.component(.weekday, from: p.date!), 6)
        XCTAssertEqual(cal.component(.hour, from: p.date!), 13)
    }

    func testDayWithoutTimeIsStartOfDay() {
        let p = QuickAdd.parse("Report due next Monday", now: Date())
        XCTAssertEqual(p.title, "Report")
        XCTAssertFalse(p.hasTime)
        XCTAssertEqual(p.date, cal.startOfDay(for: p.date!))
        XCTAssertEqual(cal.component(.weekday, from: p.date!), 2)
    }

    func testNoDate() {
        let p = QuickAdd.parse("  Buy milk ", now: Date())
        XCTAssertEqual(p.title, "Buy milk")
        XCTAssertNil(p.date)
        XCTAssertFalse(p.hasTime)
    }

    func testPassedTimeMovesToTomorrow() {
        let p = QuickAdd.parse("call mom at 5pm", now: Date())
        XCTAssertEqual(p.title, "call mom")
        XCTAssertTrue(p.hasTime)
        XCTAssertEqual(cal.component(.hour, from: p.date!), 17)
        XCTAssertGreaterThan(p.date!, Date())
    }

    func testNoonCountsAsTime() {
        let p = QuickAdd.parse("Meet Jo at noon tomorrow", now: Date())
        XCTAssertEqual(p.title, "Meet Jo")
        XCTAssertTrue(p.hasTime)
    }

    // MARK: streaks

    private func day(_ offset: Int, from base: Date = Date()) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: base))!
    }

    func testStreak() {
        XCTAssertEqual(Days.streak([]), 0)
        XCTAssertEqual(Days.streak([day(0), day(-1), day(-2)]), 3)
        XCTAssertEqual(Days.streak([day(-1), day(-2)]), 2, "today not done yet keeps the streak")
        XCTAssertEqual(Days.streak([day(0), day(-2)]), 1, "a gap breaks it")
        XCTAssertEqual(Days.streak([day(-2), day(-3)]), 0)
        XCTAssertEqual(Days.streak([day(0), day(0).addingTimeInterval(3600)]), 1, "same day twice counts once")
    }

    // MARK: heatmap

    func testHeatmapBuckets() {
        let today = Date()
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let grid = Days.heatmap([weekStart, weekStart.addingTimeInterval(3600), day(-7, from: weekStart), day(-100)], weeks: 12, today: today)
        XCTAssertEqual(grid.count, 12)
        XCTAssertTrue(grid.allSatisfy { $0.count == 7 })
        XCTAssertEqual(grid[11][0], 2, "two ticks on the first day of this week")
        XCTAssertEqual(grid[10][0], 1, "one week back")
        XCTAssertEqual(grid.joined().reduce(0, +), 3, "older than 12 weeks is dropped")
    }

    // MARK: website blocking

    func testValidDomains() {
        XCTAssertEqual(Blocker.validDomains(["https://www.YouTube.com/watch?v=1", "reddit.com", " news.ycombinator.com "]),
                       ["youtube.com", "reddit.com", "news.ycombinator.com"])
        XCTAssertEqual(Blocker.validDomains(["evil.com; rm -rf /", "a'b.com", "x\"y.com", "localhost", "", ".com"]), [])
    }
}
