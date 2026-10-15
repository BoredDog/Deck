import XCTest
@testable import Deck

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(Updater.isNewer("1.9", than: "1.10"))
        XCTAssertFalse(Updater.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(Updater.isNewer("1.2.0", than: "1.2"))
        XCTAssertTrue(Updater.isNewer("v1.3", than: "1.2.9"))
        XCTAssertFalse(Updater.isNewer("v1.3", than: "1.3"))
        XCTAssertTrue(Updater.isNewer("2.0", than: "1.99.99"))
    }
}
