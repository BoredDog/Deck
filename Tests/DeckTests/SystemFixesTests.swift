import XCTest
import Network
@testable import Deck

/// Counts TCP connections to a local port that never answers.
private final class Tripwire: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    var hits: Int { lock.withLock { count } }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in
            self?.lock.withLock { self?.count += 1 }
            c.cancel()
        }
    }

    func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else { throw XCTSkip("can't listen locally") }
        return port
    }
}

final class SystemFixesTests: XCTestCase {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("deck-fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    // MARK: WebPDF stays offline

    @MainActor func testWebPDFMakesNoNetworkRequests() async throws {
        let wire = try Tripwire()
        defer { wire.listener.cancel() }
        let port = try wire.start()
        let dir = try tmp()
        let host = "http://127.0.0.1:\(port)"
        let html = """
        <!doctype html><html><head><link rel="stylesheet" href="\(host)/s.css"><link rel="preconnect" href="\(host)">
        <script src="\(host)/a.js"></script><script>fetch("\(host)/js"); new Image().src = "\(host)/js.png";</script></head>
        <body><h1>Offline</h1><img src="\(host)/x.png"><iframe src="\(host)/frame"></iframe>
        <div style="background:url(\(host)/bg.png)">x</div></body></html>
        """
        let out = dir.appendingPathComponent("out.pdf")
        try await WebPDF.render(html: html, baseURL: dir, to: out)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(wire.hits, 0, "the PDF renderer reached the network")
        XCTAssertEqual(try Data(contentsOf: out).prefix(4), Data("%PDF".utf8))
    }

    // MARK: Helpers run offline

    func testHelpersCantReachTheNetwork() async throws {
        let wire = try Tripwire()
        defer { wire.listener.cancel() }
        let url = "http://127.0.0.1:\(try wire.start())/x"
        do {
            try await Engine.run("curl", ["-s", "-m", "3", url])
            XCTFail("curl reached the network")
        } catch {}
        XCTAssertEqual(wire.hits, 0)
        _ = try? await Engine.run("curl", ["-s", "-m", "3", url], offline: false)
        XCTAssertEqual(wire.hits, 1, "the tripwire works when the network is allowed")
    }

    // MARK: Output is never garbled

    func testLargeUTF8OutputIsExact() async throws {
        let dir = try tmp()
        let line = "Café naïve — 東京 서울 🎉👩‍👩‍👧 ok\n"
        var text = ""
        while text.utf8.count < 1_000_000 { text += line }
        let file = dir.appendingPathComponent("mixed.txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let out = try await Engine.run("cat", [file.path])
        XCTAssertEqual(out, text)
        var lines = 0
        try await Engine.run("cat", [file.path]) { l in XCTAssertEqual(l + "\n", line); lines += 1 }
        XCTAssertEqual(lines, text.components(separatedBy: "\n").count - 1)
    }

    // MARK: File names that look like options

    func testDashNamesThroughTar() async throws {
        let dir = try tmp()
        let file = dir.appendingPathComponent("-rf.txt")
        try "careful".write(to: file, atomically: true, encoding: .utf8)
        for id in ["arc.tgz", "arc.txz", "arc.tzst"] {
            if id == "arc.txz", !Engine.has("xz") { continue }
            if id == "arc.tzst", !Engine.has("zstd") { continue }
            let packed = try await Converters.convert(file, to: XCTUnwrap(Converters.targets(for: file).first { $0.id == id })) { _ in }
            let back = try await Converters.convert(packed, to: XCTUnwrap(Converters.targets(for: packed).first { $0.id == "arc.extract" })) { _ in }
            XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("-rf.txt"), encoding: .utf8), "careful", id)
        }
        guard Engine.has("zstd") else { return }
        let folder = dir.appendingPathComponent("again/-rf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("again/-rf.tar.zst").path, contents: Data())  // so this one is "-rf 2.tar.zst"
        try String(repeating: "x", count: 10_000).write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let r = try await Compressor.run(folder, method: .zstd)
        let packed = try XCTUnwrap(r).output
        let restored = try await Compressor.restore(packed)
        XCTAssertEqual(try String(contentsOf: restored.appendingPathComponent("-rf/a.txt"), encoding: .utf8).count, 10_000)
    }

    // MARK: Atomic outputs

    func testFailureLeavesNoPartialFile() async throws {
        guard Engine.has("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let dir = try tmp()
        let bad = dir.appendingPathComponent("broken.wav")
        try Data("not really audio".utf8).write(to: bad)
        let t = try XCTUnwrap(Converters.targets(for: bad).first { $0.id == "audio.flac" })
        do { _ = try await Converters.convert(bad, to: t) { _ in }; XCTFail("should fail") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["broken.wav"])
    }

    // MARK: Restore names

    func testRestoreNames() async throws {
        guard Engine.has("zstd") else { throw XCTSkip("zstd not installed") }
        let dir = try tmp()
        let txt = dir.appendingPathComponent("foo.txt")
        try String(repeating: "restore me ", count: 5000).write(to: txt, atomically: true, encoding: .utf8)
        let r = try await Compressor.run(txt, method: .zstd)
        let packed = try XCTUnwrap(r).output
        XCTAssertEqual(packed.lastPathComponent, "foo.txt.zst")
        let restored = try await Compressor.restore(packed)
        XCTAssertEqual(restored.lastPathComponent, "foo 2.txt", "never overwrites the original")

        // A .tar FILE packed by Deck comes back as that .tar file, not unpacked.
        let inner = dir.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try "hi".write(to: inner.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        let tar = dir.appendingPathComponent("bundle.tar")
        try await Engine.run("tar", ["-cf", tar.path, "-C", dir.path, "./x"])
        let tarData = try Data(contentsOf: tar)
        let rt = try await Compressor.run(tar, method: .zstd)
        let packedTar = try XCTUnwrap(rt).output
        XCTAssertEqual(packedTar.lastPathComponent, "bundle.tar.zst")
        let back = try await Compressor.restore(packedTar)
        XCTAssertEqual(back.lastPathComponent, "bundle 2.tar")
        XCTAssertEqual(try Data(contentsOf: back), tarData)

        XCTAssertTrue(Compressor.isOneFolder("./Stuff/\n./Stuff/a.txt\n", named: "Stuff"))
        XCTAssertFalse(Compressor.isOneFolder("Stuff\n", named: "Stuff"), "a single file isn't a folder")
        XCTAssertFalse(Compressor.isOneFolder("Stuff/a\nOther/b\n", named: "Stuff"))
        XCTAssertTrue(Compressor.isOneFolder("Stuff/a\n", named: "Stuff 2"), "a second copy is named Stuff 2.tar.zst")
        XCTAssertTrue(Compressor.isOneFolder("Stuff 2/a\n", named: "Stuff 2"))
    }

    func testLossyJXLSaysItCantGoBack() async throws {
        let dir = try tmp()
        let header: [UInt8] = [0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
        let ftyp: [UInt8] = [0, 0, 0, 0x14] + Array("ftypjxl ".utf8) + [0, 0, 0, 0] + Array("jxl ".utf8)
        let codestream: [UInt8] = [0, 0, 0, 0x0C] + Array("jxlc".utf8) + [0xFF, 0x0A, 0, 0]
        let lossy = dir.appendingPathComponent("photo.jxl")
        try Data(header + ftyp + codestream).write(to: lossy)
        XCTAssertFalse(Compressor.hasJPEGData(lossy))
        let exact = dir.appendingPathComponent("exact.jxl")
        try Data(header + ftyp + [0, 0, 0, 0x0C] + Array("jbrd".utf8) + [1, 2, 3, 4] + codestream).write(to: exact)
        XCTAssertTrue(Compressor.hasJPEGData(exact))
        do { _ = try await Compressor.restore(lossy); XCTFail("should refuse") } catch {
            XCTAssertEqual(error.localizedDescription, "This one can't go back to the exact original.")
        }
    }

    // MARK: Storage

    func testPackagesAreOneItemAndNeverListed() throws {
        let root = try tmp()
        let pkg = root.appendingPathComponent("Fake.app/Contents")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        var old = URLResourceValues()
        old.contentModificationDate = Date().addingTimeInterval(-800 * 86400)
        old.contentAccessDate = old.contentModificationDate
        for dir in [pkg, root] {
            var f = dir.appendingPathComponent("big.bin")
            try Data(repeating: 7, count: 51_000_000).write(to: f)
            try f.setResourceValues(old)
        }
        let big = BigFiles()
        let node = SpaceScan.scan(root, big: big)
        let app = try XCTUnwrap(node.children.first { $0.name == "Fake.app" })
        XCTAssertGreaterThanOrEqual(app.size, 51_000_000)
        XCTAssertTrue(app.children.isEmpty, "a package is one opaque item")
        XCTAssertEqual(big.hits.map(\.name), ["big.bin"])
        XCTAssertFalse(big.hits.contains { $0.path.contains("Fake.app") }, "nothing inside the package is listed")
    }

    func testCleanupWordingIsHonest() {
        XCTAssertEqual(Cleanup.summary(.init(emptied: 0, trashed: 2_000_000, failed: 0)), "Moved 2 MB to the Trash. Empty the Trash to free the space.")
        XCTAssertTrue(Cleanup.summary(.init(emptied: 0, trashed: 0, failed: 2)).contains("2 items couldn't be moved"))
    }
}
