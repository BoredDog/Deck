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

final class UpdateInstallTests: XCTestCase {
    /// Real DMG → swaps the app in place when newer; refuses (and changes nothing) when not.
    func testInstallsNewerAndRefusesSameVersion() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../dist/Deck-1.0.dmg").standardized
        guard FileManager.default.fileExists(atPath: repo.path) else { throw XCTSkip("run scripts/make-dmg.sh first") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deck-install-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("Deck.app/Contents"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("Deck.app")
        try "old".write(to: fake.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)

        // Same version: refused, the old app stays.
        let dmg1 = dir.appendingPathComponent("a.dmg"); try fm.copyItem(at: repo, to: dmg1)
        do { try await Updater.install(dmg: dmg1, replacing: fake, bundleID: "com.nav.deck", version: "1.0"); XCTFail("should refuse") } catch {}
        XCTAssertTrue(fm.fileExists(atPath: fake.appendingPathComponent("Contents/marker.txt").path))

        // Older installed version: swapped for the real app from the DMG.
        let dmg2 = dir.appendingPathComponent("b.dmg"); try fm.copyItem(at: repo, to: dmg2)
        try await Updater.install(dmg: dmg2, replacing: fake, bundleID: "com.nav.deck", version: "0.9")
        XCTAssertFalse(fm.fileExists(atPath: fake.appendingPathComponent("Contents/marker.txt").path))
        XCTAssertEqual(Bundle(url: fake)?.infoDictionary?["CFBundleIdentifier"] as? String, "com.nav.deck")
        XCTAssertTrue(fm.fileExists(atPath: fake.appendingPathComponent("Contents/MacOS/Deck").path))
        // Nothing left behind next to the app.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".Deck-update") }, [])
    }
}
