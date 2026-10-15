import XCTest
@testable import Deck

final class PermissionsTests: XCTestCase {
    func testEveryNoteIsPlainAndFilledIn() {
        for p in Permission.allCases {
            XCTAssertFalse(p.title.isEmpty, "\(p)")
            XCTAssertGreaterThan(p.why.count, 40, "\(p)")
            for jargon in ["TCC", "entitlement", "XPC", "daemon", "SMC", "sandbox", "API"] {
                XCTAssertFalse((p.title + p.why).localizedCaseInsensitiveContains(jargon), "\(p) says \(jargon)")
            }
        }
    }

    @MainActor func testExplainedOnlyOnce() async {
        let defaults = UserDefaults(suiteName: "deck-perm-test-\(UUID().uuidString)")!
        XCTAssertFalse(Permission.wasExplained(.calendar, in: defaults))
        defaults.set(true, forKey: "explained.calendar")
        // Already explained: returns straight away without showing anything.
        let ok = await Permission.explain(.calendar, in: defaults)
        XCTAssertTrue(ok)
        XCTAssertFalse(Permission.wasExplained(.location, in: defaults))
    }
}
