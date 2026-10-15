import XCTest
@testable import Deck

final class DownloadsFindMacTests: XCTestCase {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("deck-test-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    // MARK: Downloads

    func testParseHTTPDownload() throws {
        let item = try XCTUnwrap(DownloadItem.parse([
            "gid": "abc", "status": "active", "totalLength": "1000", "completedLength": "250", "downloadSpeed": "75",
            "files": [["path": "/Users/me/Downloads/movie.mp4", "uris": [["uri": "https://x.com/movie.mp4"]]]],
        ]))
        XCTAssertEqual(item.name, "movie.mp4")
        XCTAssertEqual(item.progress, 0.25)
        XCTAssertEqual(item.timeLeft, 10)
        XCTAssertEqual(item.file?.path, "/Users/me/Downloads/movie.mp4")
    }

    func testParseBeforeFileNameKnownUsesLink() throws {
        let item = try XCTUnwrap(DownloadItem.parse([
            "gid": "a", "status": "waiting", "totalLength": "0", "completedLength": "0", "downloadSpeed": "0",
            "files": [["path": "", "uris": [["uri": "https://x.com/files/report.pdf"]]]],
        ]))
        XCTAssertEqual(item.name, "report.pdf")
        XCTAssertNil(item.file)
        XCTAssertNil(item.timeLeft)
    }

    func testParseTorrentAndSkipMetadataStub() throws {
        let t = try XCTUnwrap(DownloadItem.parse([
            "gid": "t", "status": "active", "dir": "/D", "bittorrent": ["info": ["name": "Album"]],
            "files": [["path": "/D/Album/1.flac"], ["path": "/D/Album/2.flac"]],
        ]))
        XCTAssertEqual(t.name, "Album")
        XCTAssertEqual(t.file?.path, "/D/Album")
        XCTAssertNil(DownloadItem.parse(["gid": "m", "status": "complete", "followedBy": ["t"]]))
    }

    // MARK: Find

    func testFindFilters() {
        let now = Date()
        let movie = Hit(path: "/a/clip.mov", size: 2_000_000_000, modified: now, isFolder: false)
        let photo = Hit(path: "/a/pic.HEIC", size: 3_000_000, modified: now.addingTimeInterval(-40 * 86400), isFolder: false)
        let folder = Hit(path: "/a/stuff", size: 0, modified: now, isFolder: true)
        let app = Hit(path: "/Applications/Deck.app", size: 0, modified: now, isFolder: true)
        let doc = Hit(path: "/a/notes.md", size: 10, modified: now, isFolder: false)

        XCTAssertTrue(FindFilter(kind: .video).matches(movie, now: now))
        XCTAssertFalse(FindFilter(kind: .video).matches(photo, now: now))
        XCTAssertTrue(FindFilter(kind: .image).matches(photo, now: now))
        XCTAssertTrue(FindFilter(kind: .folder).matches(folder, now: now))
        XCTAssertFalse(FindFilter(kind: .folder).matches(app, now: now))
        XCTAssertTrue(FindFilter(kind: .app).matches(app, now: now))
        XCTAssertTrue(FindFilter(kind: .document).matches(doc, now: now))
        XCTAssertTrue(FindFilter(size: .huge).matches(movie, now: now))
        XCTAssertFalse(FindFilter(size: .big).matches(photo, now: now))
        XCTAssertFalse(FindFilter(size: .big).matches(folder, now: now))
        XCTAssertTrue(FindFilter(date: .year).matches(photo, now: now))
        XCTAssertFalse(FindFilter(date: .month).matches(photo, now: now))
    }

    // MARK: Cleanup allowlist

    func testCleanupOnlyTouchesAllowlist() throws {
        let home = try tmp()
        let lib = home.appendingPathComponent("Library")
        let fm = FileManager.default
        for dir in ["Library/Caches/com.x.app/deep", "Library/Logs/x", "Library/Preferences", "Library/Developer/Xcode/DerivedData",
                    "Library/Application Support/MobileSync/Backup/old", "Library/Application Support/MobileSync/Backup/new", "Downloads", ".Trash", "Documents"] {
            try fm.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for f in ["Downloads/a.dmg", "Downloads/b.PKG", "Downloads/c.zip", ".Trash/junk", "Documents/keep.dmg"] {
            fm.createFile(atPath: home.appendingPathComponent(f).path, contents: Data("x".utf8))
        }
        let backup = lib.appendingPathComponent("Application Support/MobileSync/Backup")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 86400)], ofItemAtPath: backup.appendingPathComponent("old").path)

        func group(_ rel: String) -> CleanItem.Group? { Cleanup.groupFor(home.appendingPathComponent(rel), home: home) }
        XCTAssertEqual(group("Library/Caches/com.x.app"), .caches)
        XCTAssertNil(group("Library/Caches/com.x.app/deep"))
        XCTAssertNil(group("Library/Caches"))
        XCTAssertNil(group("Library/Caches/../Preferences/x.plist"))
        XCTAssertEqual(group("Library/Logs/x"), .logs)
        XCTAssertEqual(group("Library/Developer/Xcode/DerivedData"), .xcode)
        XCTAssertEqual(group("Library/Application Support/MobileSync/Backup/old"), .backups)
        XCTAssertNil(group("Library/Application Support/MobileSync/Backup/new"))
        XCTAssertEqual(group("Downloads/b.PKG"), .installers)
        XCTAssertNil(group("Downloads/c.zip"))
        XCTAssertNil(group("Documents/keep.dmg"))
        XCTAssertEqual(group(".Trash"), .trash)
        XCTAssertNil(group(".Trash/junk"))
        XCTAssertNil(group("Documents"))

        let found = Set(Cleanup.candidates(home: home).map { $0.url.standardizedFileURL.path })
        let expected = ["Library/Caches/com.x.app", "Library/Logs/x", "Library/Developer/Xcode/DerivedData",
                        "Library/Application Support/MobileSync/Backup/old", "Downloads/a.dmg", "Downloads/b.PKG", ".Trash"]
        XCTAssertEqual(found, Set(expected.map { home.appendingPathComponent($0).path }))
    }

    // MARK: App remover

    func testAppRemoverRules() throws {
        let home = try tmp()
        let prefs = home.appendingPathComponent("Library/Preferences")
        let support = home.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Foo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("FooBar"), withIntermediateDirectories: true)
        for n in ["com.foo.app.plist", "com.foo.application.plist", "com.other.plist"] {
            FileManager.default.createFile(atPath: prefs.appendingPathComponent(n).path, contents: Data())
        }
        let found = AppRemover.leftovers(bundleID: "com.foo.app", appName: "Foo", home: home).map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, ["Foo", "com.foo.app.plist"])

        XCTAssertNil(AppRemover.refusal(app: URL(fileURLWithPath: "/Applications/Foo.app"), bundleID: "com.foo.app", home: home))
        XCTAssertNotNil(AppRemover.refusal(app: URL(fileURLWithPath: "/Applications/Safari.app"), bundleID: "com.apple.Safari", home: home))
        XCTAssertNotNil(AppRemover.refusal(app: URL(fileURLWithPath: "/Users/x/Desktop/Foo.app"), bundleID: "com.foo.app", home: home))
        XCTAssertNotNil(AppRemover.refusal(app: URL(fileURLWithPath: "/Applications/Utilities/../Foo.txt"), bundleID: "com.foo.app", home: home))
    }

    // MARK: Mac

    func testOuterApp() {
        XCTAssertEqual(SystemMonitor.outerApp("/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"), "/Applications/Chrome.app")
        XCTAssertEqual(SystemMonitor.outerApp("/Applications/Foo.app"), "/Applications/Foo.app")
        XCTAssertNil(SystemMonitor.outerApp("/usr/sbin/cfprefsd"))
    }

    func testSpaceScanAddsUp() throws {
        let root = try tmp()
        let sub = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: sub.appendingPathComponent("big"))
        try Data(count: 10).write(to: root.appendingPathComponent("small"))
        let node = SpaceScan.scan(root, big: BigFiles())
        XCTAssertGreaterThanOrEqual(node.size, 3_000_000)
        XCTAssertEqual(node.children.map(\.name), ["a"])
        XCTAssertEqual(node.children.first?.children.first?.name, "b")
    }

    @MainActor func testMonitorReadsRealNumbers() async throws {
        let m = SystemMonitor.shared
        m.sample()
        try await Task.sleep(for: .milliseconds(500))
        m.sample()
        XCTAssert((0...1).contains(m.cpu))
        XCTAssertGreaterThan(m.memory, 0)
        XCTAssertGreaterThan(m.diskTotal, m.diskFree)
        XCTAssertFalse(m.topMemory.isEmpty)
        XCTAssertEqual(m.cpuHistory.count, 2)
        print("monitor:", m.cpu, m.memory, bytes(m.diskFree), m.netDown, m.battery as Any, m.topMemory.map(\.name), m.topCPU.map(\.name), m.moodLine)
    }
}
