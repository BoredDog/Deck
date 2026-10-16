import XCTest
@testable import Deck

final class ToolsTests: XCTestCase {
    let cal = Calendar.current
    private func at(_ h: Int, _ m: Int = 0, day: Int = 16) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    // MARK: screen time

    func testAggregatesPerAppPerDay() {
        var c = UsageClock()
        c.front("com.a", name: "A", at: at(9))
        c.front("com.b", name: "B", at: at(9, 30))
        c.front("com.a", name: "A", at: at(9, 40))
        c.flush(at: at(10))
        XCTAssertEqual(c.log.days["2026-10-16"]?["com.a"], 50 * 60)
        XCTAssertEqual(c.log.days["2026-10-16"]?["com.b"], 10 * 60)
        XCTAssertEqual(c.log.total(at(12)), 3600)
        XCTAssertEqual(c.log.top(at(12)).map(\.id), ["com.a", "com.b"])
        XCTAssertEqual(c.log.names["com.b"], "B")
    }

    func testSplitsAtMidnight() {
        var c = UsageClock()
        c.front("com.a", name: "A", at: at(23, 30))
        c.flush(at: at(0, 15, day: 17))
        XCTAssertEqual(c.log.days["2026-10-16"]?["com.a"], 30 * 60)
        XCTAssertEqual(c.log.days["2026-10-17"]?["com.a"], 15 * 60)
    }

    func testIdleIsNotCounted() {
        var c = UsageClock()
        c.front("com.a", name: "A", at: at(9))
        c.idleCheck(secondsIdle: 10, now: at(9, 1))          // active: booked up to the last input
        c.idleCheck(secondsIdle: 5 * 60, now: at(9, 10))     // last input at 9:05, idle since
        c.idleCheck(secondsIdle: 30 * 60, now: at(9, 40))    // still idle: nothing added
        c.idleCheck(secondsIdle: 60, now: at(9, 50))         // back at 9:49
        c.flush(at: at(10))
        XCTAssertEqual(c.log.total(at(9)), Double((5 + 11) * 60))
    }

    func testLockAndScreenOffPause() {
        var c = UsageClock()
        c.front("com.a", name: "A", at: at(9))
        c.pause(.locked, at: at(9, 10))
        c.pause(.screenOff, at: at(9, 11))
        c.resume(.screenOff, at: at(9, 30))   // screen on but still locked: not counted
        c.resume(.locked, at: at(9, 40))
        c.flush(at: at(9, 50))
        XCTAssertEqual(c.log.total(at(9)), 20 * 60)
    }

    func testLoginWindowStopsCounting() {
        var c = UsageClock()
        c.front("com.a", name: "A", at: at(9))
        c.front(nil, name: nil, at: at(9, 5))
        c.flush(at: at(10))
        XCTAssertEqual(c.log.total(at(9)), 5 * 60)
    }

    func testPruneKeeps30Days() {
        var log = UsageLog()
        log.add("old", from: at(9, day: 1), to: at(10, day: 1))
        log.names["old"] = "Old"
        log.add("new", from: at(9), to: at(10))
        log.prune(keep: 30, now: at(12, day: 31))
        XCTAssertNil(log.days["2026-10-01"])
        XCTAssertNil(log.names["old"])
        XCTAssertNotNil(log.days["2026-10-16"])
    }

    func testUsageTimeText() {
        XCTAssertEqual(usageTime(30), "<1m")
        XCTAssertEqual(usageTime(45 * 60), "45m")
        XCTAssertEqual(usageTime(3 * 3600 + 12 * 60), "3h 12m")
    }

    // MARK: command bar

    private func cmds(_ titles: [String]) -> [Command] { titles.map { Command(id: $0, title: $0, icon: "") {} } }

    func testRankingPrefersStartOfTitle() {
        let list = cmds(["Start focus", "Focus", "Files", "Find"])
        XCTAssertEqual(CommandBar.rank(list, "foc").map(\.title), ["Focus", "Start focus"])
        XCTAssertEqual(CommandBar.rank(list, "fi").map(\.title), ["Files", "Find"])
    }

    func testEmptyQueryKeepsOrder() {
        let list = cmds(["Home", "Files", "Find"])
        XCTAssertEqual(CommandBar.rank(list, "  ").map(\.title), ["Home", "Files", "Find"])
    }

    func testFuzzyAndNoMatch() {
        let list = cmds(["Keep Mac awake", "Convert…", "Notes"])
        XCTAssertEqual(CommandBar.rank(list, "kma").map(\.title), ["Keep Mac awake"])
        XCTAssertEqual(CommandBar.rank(list, "VERT").map(\.title), ["Convert…"])
        XCTAssertTrue(CommandBar.rank(list, "zzz").isEmpty)
    }

    func testTaskText() {
        XCTAssertEqual(CommandBar.taskText("add task Buy milk"), "Buy milk")
        XCTAssertEqual(CommandBar.taskText("Add dentist tomorrow 3pm"), "dentist tomorrow 3pm")
        XCTAssertEqual(CommandBar.taskText(" Buy milk "), "Buy milk")
    }
}
