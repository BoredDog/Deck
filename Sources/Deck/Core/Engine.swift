import Foundation
import AppKit

/// Runs the helper programs (ffmpeg, zstd, …) out of sight. The user never sees any of this.
enum Engine {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/opt/local/bin"]

    static func path(_ tool: String) -> String? {
        searchPaths.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func has(_ tool: String) -> Bool { path(tool) != nil }

    struct Failed: LocalizedError {
        let tool: String
        let detail: String
        var errorDescription: String? { "Something went wrong while working on this file." }
    }

    struct Missing: LocalizedError {
        let tool: String
        var errorDescription: String? { "This needs a helper that isn't set up yet. Open Settings → Get Deck ready." }
    }

    /// An error whose message is already plain words for the user.
    struct Plain: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Helpers that need the internet to do their job. Everything else runs with the network switched off,
    /// so a booby-trapped document can't phone home while it's being converted.
    static let online: Set<String> = ["brew", "aria2c", "yt-dlp", "tectonic", "open", "osascript", "shortcuts"]
    static let noNetwork = "(version 1)(allow default)(deny network*)"

    /// Every helper still running, so they can be stopped when Deck quits.
    private static let live = LiveProcesses()

    /// Runs one helper. `onLine` gets each output line (used for progress). Throws if it fails.
    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, stdoutTo: URL? = nil, offline: Bool = true, onLine: ((String) -> Void)? = nil) async throws -> String {
        try await pipeline([(tool, args)], cwd: cwd, stdoutTo: stdoutTo, offline: offline, onLine: onLine)
    }

    /// Runs helpers connected end to end (`a | b`). Returns the last one's standard output.
    @discardableResult
    static func pipeline(_ steps: [(String, [String])], cwd: URL? = nil, stdoutTo: URL? = nil, offline: Bool = true, onLine: ((String) -> Void)? = nil) async throws -> String {
        var procs: [Process] = []
        let sandbox = "/usr/bin/sandbox-exec"
        for (tool, args) in steps {
            guard let exe = path(tool) else { throw Missing(tool: tool) }
            let p = Process()
            // Children inherit the sandbox, so `env soffice …` is covered too.
            if offline, !online.contains(tool), FileManager.default.isExecutableFile(atPath: sandbox) {
                p.executableURL = URL(fileURLWithPath: sandbox)
                p.arguments = ["-p", noNetwork, exe] + args
            } else {
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
            }
            if let cwd { p.currentDirectoryURL = cwd }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = searchPaths.joined(separator: ":")
            // Homebrew: no surprise upgrades, cleanups or reinstalls of other packages, no analytics.
            for k in ["HOMEBREW_NO_ANALYTICS", "HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] { env[k] = "1" }
            p.environment = env
            procs.append(p)
        }
        for i in procs.indices.dropFirst() {
            let pipe = Pipe()
            procs[i - 1].standardOutput = pipe
            procs[i].standardInput = pipe
        }
        procs.first?.standardInput = FileHandle.nullDevice

        let out = Pipe(), err = Pipe()
        var fileOut: FileHandle?
        if let stdoutTo {
            guard FileManager.default.createFile(atPath: stdoutTo.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: stdoutTo) else { throw Failed(tool: steps[0].0, detail: "can't write output") }
            fileOut = h
            procs.last!.standardOutput = h
        } else {
            procs.last!.standardOutput = out
        }
        // A shared FileHandle (not the Pipe) so launching the first process doesn't close it for the others.
        for p in procs { p.standardError = err.fileHandleForWriting }

        let collected = LineCollector(onLine: onLine)
        let readers = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] where !(isOut && fileOut != nil) {
            readers.enter()
            Thread.detachNewThread {
                let h = pipe.fileHandleForReading
                while let d = try? h.read(upToCount: 65536), !d.isEmpty { collected.feed(d, isOut: isOut) }
                readers.leave()
            }
        }
        if fileOut != nil { try? out.fileHandleForWriting.close() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let group = DispatchGroup()
                for p in procs {
                    group.enter()
                    p.terminationHandler = { p in live.remove(p); group.leave() }
                }
                do {
                    for p in procs { live.add(p); try p.run() }
                    try? err.fileHandleForWriting.close()
                    try? fileOut?.close()
                } catch {
                    procs.forEach { live.remove($0); if $0.isRunning { $0.terminate() } }
                    try? out.fileHandleForWriting.close()
                    try? err.fileHandleForWriting.close()
                    try? fileOut?.close()
                    if let stdoutTo { try? FileManager.default.removeItem(at: stdoutTo) }
                    cont.resume(throwing: Failed(tool: steps[0].0, detail: error.localizedDescription))
                    return
                }
                group.notify(queue: .global()) {
                    readers.wait()
                    if let bad = procs.firstIndex(where: { $0.terminationStatus != 0 }) {
                        if let stdoutTo { try? FileManager.default.removeItem(at: stdoutTo) }
                        cont.resume(throwing: Failed(tool: steps[bad].0, detail: collected.errTail))
                    } else {
                        cont.resume(returning: collected.stdout)
                    }
                }
            }
        } onCancel: {
            procs.forEach { if $0.isRunning { $0.terminate() } }
        }
    }
}

/// Every helper Deck started that hasn't finished yet. Stopped when Deck quits so nothing keeps running behind it.
private final class LiveProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var procs = Set<Process>()
    private var observing = false

    func add(_ p: Process) {
        lock.withLock {
            procs.insert(p)
            guard !observing else { return }
            observing = true
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [self] _ in
                lock.withLock { procs }.forEach { if $0.isRunning { $0.terminate() } }
            }
        }
    }

    func remove(_ p: Process) { _ = lock.withLock { procs.remove(p) } }
}

/// Collects helper output as bytes and splits it into lines only at newline bytes, so a letter split
/// across two reads is never garbled. Keeps the tail of the error output for diagnostics.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: ((String) -> Void)?
    private var partial: [Bool: Data] = [:]
    private var out = Data()
    private var errLines: [String] = []

    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    var stdout: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
    var errTail: String { lock.withLock { errLines.suffix(8).joined(separator: "\n") } }

    func feed(_ data: Data, isOut: Bool) {
        lock.lock()
        if isOut { out.append(data) }
        // Plain standard output with no listener needs no line splitting.
        guard !isOut || onLine != nil else { lock.unlock(); return }
        var buf = (partial[isOut] ?? Data()) + data
        var lines: [String] = []
        // ffmpeg and others redraw progress with \r, so treat it as a line break too.
        while let i = buf.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lines.append(String(decoding: buf[..<i], as: UTF8.self))
            buf = buf[(i + 1)...]
        }
        partial[isOut] = Data(buf)
        if !isOut { errLines.append(contentsOf: lines); if errLines.count > 50 { errLines.removeFirst(errLines.count - 50) } }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }
}

extension FileManager {
    /// Total size of a file or folder in bytes.
    func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        let e = enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    /// A hidden name in the same folder for a file that's still being written. Rename it with `finish` once it's complete,
    /// so a half-written file never shows up under its real name.
    func partialURL(in folder: URL, ext: String) -> URL {
        folder.appendingPathComponent(".deck-partial-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    /// Moves a finished partial file to `folder/name.ext` (or `name 2.ext`…) and returns where it landed.
    func finish(_ partial: URL, in folder: URL, name: String, ext: String) throws -> URL {
        let url = freeURL(in: folder, name: name, ext: ext)
        try moveItem(at: partial, to: url)
        return url
    }

    /// `folder/name.ext`, or `name 2.ext`, `name 3.ext`… so nothing is ever overwritten.
    func freeURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        var n = 2
        while fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(name) \(n)" : "\(name) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
