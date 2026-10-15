import Foundation

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

    /// Runs one helper. `onLine` gets each output line (used for progress). Throws if it fails.
    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, stdoutTo: URL? = nil, onLine: ((String) -> Void)? = nil) async throws -> String {
        try await pipeline([(tool, args)], cwd: cwd, stdoutTo: stdoutTo, onLine: onLine)
    }

    /// Runs helpers connected end to end (`a | b`). Returns the last one's standard output.
    @discardableResult
    static func pipeline(_ steps: [(String, [String])], cwd: URL? = nil, stdoutTo: URL? = nil, onLine: ((String) -> Void)? = nil) async throws -> String {
        var procs: [Process] = []
        for (tool, args) in steps {
            guard let exe = path(tool) else { throw Missing(tool: tool) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = searchPaths.joined(separator: ":")
            env["HOMEBREW_NO_ANALYTICS"] = "1"
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
                    p.terminationHandler = { _ in group.leave() }
                }
                do {
                    for p in procs { try p.run() }
                    try? err.fileHandleForWriting.close()
                    try? fileOut?.close()
                } catch {
                    procs.forEach { if $0.isRunning { $0.terminate() } }
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

/// Splits helper output into lines and keeps the tail of the error output for diagnostics.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: ((String) -> Void)?
    private var partial: [String: String] = [:]
    private(set) var stdout = ""
    private var errLines: [String] = []

    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    var errTail: String { lock.withLock { errLines.suffix(8).joined(separator: "\n") } }

    func feed(_ data: Data, isOut: Bool) {
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        if isOut, stdout.utf8.count < 4_000_000 { stdout += s }
        let key = isOut ? "o" : "e"
        let text = (partial[key] ?? "") + s
        // ffmpeg and others redraw progress with \r, so treat it as a line break too.
        var parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        partial[key] = parts.removeLast()
        if !isOut { errLines.append(contentsOf: parts); if errLines.count > 50 { errLines.removeFirst(errLines.count - 50) } }
        lock.unlock()
        parts.forEach { onLine?($0) }
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
