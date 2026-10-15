import XCTest
import PDFKit
@testable import Deck

final class CoreTests: XCTestCase {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("deck-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testPolicyRouting() {
        let f = { (n: String, lossy: Bool) in CompressPolicy.method(for: URL(fileURLWithPath: "/x/" + n), isFolder: false, max: false, lossyOK: lossy) }
        XCTAssertEqual(f("a.jpg", false), .jxl)
        XCTAssertEqual(f("a.JPEG", true), .jxlLossy)
        XCTAssertEqual(f("a.png", false), .oxipng)
        XCTAssertEqual(f("a.wav", false), .flac)
        XCTAssertEqual(f("a.pdf", false), .qpdf)
        XCTAssertEqual(f("a.pdf", true), .gsEbook)
        XCTAssertEqual(f("a.txt", false), .zstd)
        XCTAssertEqual(f("a.mov", true), .hevcFast)
        if case .skip = f("a.mp4", false) {} else { XCTFail("video should be skipped unless lossy is allowed") }
        if case .skip = f("a.zip", false) {} else { XCTFail("zip is already compact") }
        XCTAssertEqual(CompressPolicy.method(for: URL(fileURLWithPath: "/x/dir"), isFolder: true, max: true, lossyOK: false), .xz)
        XCTAssertTrue(Method.jxl.lossless)
        XCTAssertFalse(Method.gsEbook.lossless)
    }

    /// Lossless means byte-identical after restore.
    func testRoundTrips() async throws {
        let dir = try tmp()
        let original = dir.appendingPathComponent("notes.txt")
        try String(repeating: "Deck keeps every byte. ", count: 20_000).write(to: original, atomically: true, encoding: .utf8)
        let originalData = try Data(contentsOf: original)

        for m in [Method.zstd, .xz] where Engine.has(m.tool!) {
            let r = try await Compressor.run(original, method: m)
            let packed = try XCTUnwrap(r).output
            XCTAssertLessThan(r!.after, r!.before)
            XCTAssertTrue(Compressor.canRestore(packed))
            let restored = try await Compressor.restore(packed)
            XCTAssertEqual(try Data(contentsOf: restored), originalData, "\(m) round trip")
        }
    }

    func testFolderRoundTrip() async throws {
        guard Engine.has("zstd") else { throw XCTSkip("zstd not installed") }
        let dir = try tmp()
        let folder = dir.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try String(repeating: "a", count: 100_000).write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "b", count: 50_000).write(to: folder.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

        let r = try await Compressor.run(folder, method: .zstd)
        let packed = try XCTUnwrap(r).output
        XCTAssertEqual(packed.lastPathComponent, "Project.tar.zst")
        let restored = try await Compressor.restore(packed)
        XCTAssertEqual(try String(contentsOf: restored.appendingPathComponent("Project/sub/b.txt"), encoding: .utf8).count, 50_000)
    }

    func testOriginalNeverOverwritten() {
        let dir = FileManager.default.temporaryDirectory
        let name = "deck-\(UUID().uuidString)"
        let a = FileManager.default.freeURL(in: dir, name: name, ext: "txt")
        FileManager.default.createFile(atPath: a.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: a) }
        XCTAssertEqual(FileManager.default.freeURL(in: dir, name: name, ext: "txt").lastPathComponent, "\(name) 2.txt")
    }

    func testConverterTargets() {
        let ids = { (n: String) in Converters.targets(for: URL(fileURLWithPath: "/x/" + n)).map(\.id) }
        XCTAssertTrue(ids("a.png").contains("img.jpg"))
        XCTAssertFalse(ids("a.png").contains("img.png"), "don't offer the same format")
        XCTAssertTrue(ids("a.mov").contains("video.iphone"))
        XCTAssertTrue(ids("a.wav").contains("audio.flac"))
        XCTAssertTrue(ids("a.md").contains("doc.pdf"))
        XCTAssertTrue(ids("a.csv").contains("data.json"))
        XCTAssertFalse(ids("a.csv").contains("data.csv"))
        XCTAssertEqual(Converters.kind(of: URL(fileURLWithPath: "/x/A.HEIC")), .image)
    }

    func testDataConvert() throws {
        let rows = DataConvert.parseCSV("name,note\nSam,\"Hi, there\"\nAlex,\"say \"\"yo\"\"\"\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["note"], "Hi, there")
        XCTAssertEqual(rows[1]["note"], "say \"yo\"")
        let csv = try DataConvert.csv(rows)
        XCTAssertEqual(DataConvert.parseCSV(csv), rows)
        let yaml = DataConvert.yaml(["name": "Sam", "tags": ["a", "b"], "on": true] as [String: Any])
        XCTAssertEqual(yaml, "name: Sam\non: true\ntags:\n  - a\n  - b\n")
    }

    func testStreak() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let day = { (n: Int) in cal.date(byAdding: .day, value: -n, to: now)! }
        XCTAssertEqual(Stats.streak(days: [], now: now), 0)
        XCTAssertEqual(Stats.streak(days: [day(0), day(1), day(2), day(4)], now: now), 3)
        XCTAssertEqual(Stats.streak(days: [day(1), day(2)], now: now), 2, "today not done yet keeps the streak")
        XCTAssertEqual(Stats.streak(days: [day(2)], now: now), 0)
        XCTAssertEqual(Stats.minutesPerDay([(day(0), 25), (day(0), 25), (day(6), 10), (day(7), 99)], count: 7, now: now), [10, 0, 0, 0, 0, 0, 50])
        XCTAssertEqual(Stats.hours(90), "1h 30m")
    }
}

final class ConvertEndToEndTests: XCTestCase {
    func testRealConversions() async throws {
        guard Engine.has("ffmpeg"), Engine.has("pandoc") else { throw XCTSkip("helpers not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("tone.wav")
        try await Engine.run("ffmpeg", ["-hide_banner", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", wav.path])
        let mov = dir.appendingPathComponent("clip.mov")
        try await Engine.run("ffmpeg", ["-hide_banner", "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=15", "-c:v", "libx264", mov.path])
        let md = dir.appendingPathComponent("doc.md")
        try "# Hello\n\nDeck *converts* things.".write(to: md, atomically: true, encoding: .utf8)
        let png = dir.appendingPathComponent("pic.png")
        try await Engine.run("ffmpeg", ["-hide_banner", "-f", "lavfi", "-i", "testsrc=size=64x64", "-frames:v", "1", png.path])

        let cases: [(URL, String)] = [(wav, "audio.flac"), (wav, "audio.mp3"), (mov, "video.mp4"), (mov, "video.gif"),
                                      (md, "doc.docx"), (md, "doc.html"), (png, "img.jpg"), (png, "img.heic"), (png, "arc.zip")]
        for (src, id) in cases {
            let t = try XCTUnwrap(Converters.targets(for: src).first { $0.id == id }, id)
            let out = try await Converters.convert(src, to: t) { _ in }
            XCTAssertGreaterThan(FileManager.default.size(of: out), 0, id)
            XCTAssertEqual(out.pathExtension, t.ext, id)
        }
    }
}

final class WebPDFTests: XCTestCase {
    @MainActor func testMarkdownToPDF() async throws {
        guard Engine.has("pandoc") else { throw XCTSkip("pandoc not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = dir.appendingPathComponent("notes.md")
        try "# Hello\n\nDeck makes **PDFs** without LaTeX.\n\n- one\n- two".write(to: md, atomically: true, encoding: .utf8)
        let t = try XCTUnwrap(Converters.targets(for: md).first { $0.id == "doc.pdf" })
        let out = try await Converters.convert(md, to: t) { _ in }
        let data = try Data(contentsOf: out)
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))
        let text = PDFDocument(url: out)?.string ?? ""
        XCTAssertTrue(text.contains("Hello"), "PDF text: \(text)")
    }
}

final class SetupQueueTests: XCTestCase {
    func testDownloadProgressReadsNewestIncompleteFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-brew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(Setup.incompleteBytes(in: dir))
        try Data(count: 5000).write(to: dir.appendingPathComponent("abc--calibre.dmg.incomplete"))
        try Data(count: 9000).write(to: dir.appendingPathComponent("done--other.dmg"))
        XCTAssertEqual(Setup.incompleteBytes(in: dir), 5000)
    }

    /// Homebrew can't run two installs at once: queued jobs must run one after another, in order.
    @MainActor func testInstallsRunOneAtATime() async {
        var running = 0, maxRunning = 0, order: [Int] = []
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<3 {
                group.addTask { @MainActor in
                    await Setup.shared.enqueue {
                        running += 1; maxRunning = max(maxRunning, running)
                        try? await Task.sleep(for: .milliseconds(50))
                        order.append(i); running -= 1
                    }
                }
                await Task.yield()
            }
        }
        XCTAssertEqual(maxRunning, 1)
        XCTAssertEqual(order.count, 3)
    }
}
