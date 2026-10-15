import XCTest
import AppKit
import Textual
@testable import Deck

@MainActor final class PanelNotesTests: XCTestCase {
    func testPanelTileSwitches() {
        XCTAssertFalse(PanelTile.isOn(.clipboard, in: PanelTile.defaults))
        XCTAssertTrue(PanelTile.isOn(.focus, in: PanelTile.defaults))
        let on = PanelTile.set(.clipboard, true, in: PanelTile.defaults)
        XCTAssertTrue(PanelTile.isOn(.clipboard, in: on))
        let off = PanelTile.set(.note, false, in: on)
        XCTAssertFalse(PanelTile.isOn(.note, in: off))
        XCTAssertTrue(PanelTile.isOn(.nowPlaying, in: off))   // "note" must not match inside other ids
        XCTAssertEqual(PanelTile.set(.note, false, in: ""), "")
    }

    func testOptionDoubleTap() {
        var d = OptionTapDetector()
        // Two quick taps fire on the second release.
        XCTAssertFalse(d.flags(.option, at: 0.00))
        XCTAssertFalse(d.flags([], at: 0.08))
        XCTAssertFalse(d.flags(.option, at: 0.20))
        XCTAssertTrue(d.flags([], at: 0.28))

        // Too slow between taps: no fire, the late tap counts as a new first tap.
        d = OptionTapDetector()
        _ = d.flags(.option, at: 0); _ = d.flags([], at: 0.1)
        _ = d.flags(.option, at: 0.6); XCTAssertFalse(d.flags([], at: 0.7))
        _ = d.flags(.option, at: 0.8); XCTAssertTrue(d.flags([], at: 0.9))

        // Another modifier or a key in between cancels.
        d = OptionTapDetector()
        _ = d.flags(.option, at: 0); _ = d.flags([], at: 0.1)
        _ = d.flags([.option, .command], at: 0.15); _ = d.flags([], at: 0.2)
        _ = d.flags(.option, at: 0.25); XCTAssertFalse(d.flags([], at: 0.3))
        d = OptionTapDetector()
        _ = d.flags(.option, at: 0); _ = d.flags([], at: 0.1)
        d.cancel()
        _ = d.flags(.option, at: 0.2); XCTAssertFalse(d.flags([], at: 0.3))

        // Holding Option is not a tap.
        d = OptionTapDetector()
        _ = d.flags(.option, at: 0); _ = d.flags([], at: 1.0)
        _ = d.flags(.option, at: 1.1); XCTAssertFalse(d.flags([], at: 1.2))
    }

    /// Every image the Markdown parser hands to the renderer goes through the loader gate; web images never pass.
    func testPreviewNeverLoadsWebImages() throws {
        let md = """
        ![a](https://example.com/a.png)
        ![b](http://example.com/b.png "title")
        ![c][ref]
        ![d](//example.com/d.png)
        ![e](pic%20one.png)
        ![f](file:///tmp/f.png)

        [ref]: https://example.com/c.png
        """
        let urls = try AttributedStringMarkdownParser.markdown().attributedString(for: md).runs.compactMap { $0.imageURL }
        XCTAssertEqual(urls.count, 6, "the parser found every image")
        let base = URL(fileURLWithPath: "/notes")
        let allowed = urls.compactMap { NoteFiles.localImage($0, base: base) }
        XCTAssertTrue(allowed.allSatisfy(\.isFileURL))
        XCTAssertFalse(allowed.contains { $0.absoluteString.contains("example.com/a.png") || $0.absoluteString.contains("example.com/b.png") || $0.absoluteString.contains("example.com/c.png") })
        XCTAssertTrue(allowed.contains(URL(fileURLWithPath: "/notes/pic one.png")))
        XCTAssertTrue(allowed.contains(URL(fileURLWithPath: "/tmp/f.png")))
        for web in urls where ["http", "https"].contains(web.scheme) { XCTAssertNil(NoteFiles.localImage(web, base: base)) }
    }

    func testPortCheck() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1") // port 0: the system picks a free one
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &addr) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.bind(fd, $0, len), 0)
                XCTAssertEqual(Darwin.listen(fd, 1), 0)
                try XCTSkipIf(getsockname(fd, $0, &len) != 0)
            }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        XCTAssertFalse(Downloads.portFree(port))
        close(fd)
        XCTAssertTrue(Downloads.portFree(port))
    }

    /// The fallback disk walk (used when searchfs isn't supported) finds hidden files too.
    func testFallbackWalkFindsHiddenFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deck-walk-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".hidden-dir/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("plain"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for f in [".needle-top", "plain/Needle.txt", ".hidden-dir/deep/x-needle", "plain/other.txt"] {
            try Data().write(to: root.appendingPathComponent(f))
        }

        actor Bag { var paths: [String] = []; func add(_ h: [Hit]) { paths += h.map(\.path) } }
        let bag = Bag()
        await Catalog.walk("needle", in: root.path) { await bag.add($0) }
        let found = Set(await bag.paths.map { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(found, [".needle-top", "Needle.txt", "x-needle"])
    }
}
