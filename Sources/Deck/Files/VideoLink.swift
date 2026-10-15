import Foundation

/// Saves a video (or just its sound) from a web page link with yt-dlp, the opt-in "videolinks" add-on.
/// The user starts it, so this is the one place Deck talks to the internet on its own behalf.
enum VideoLink {
    static func download(_ link: String, audioOnly: Bool, into folder: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: link), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
            throw Engine.Failed(tool: "yt-dlp", detail: "not a web link")
        }
        // Half-finished pieces stay in a private folder, so a failed download leaves nothing behind.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("deck-video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var args = ["--ignore-config", "--no-playlist", "--newline", "--progress", "--no-overwrites",
                    "--print", "after_move:filepath", "-o", "%(title)s.%(ext)s", "-P", folder.path, "-P", "temp:" + tmp.path]
        if audioOnly { args += ["-x", "--audio-format", "mp3"] }
        let out = try await Engine.run("yt-dlp", args + ["--", link]) { line in
            if let p = percent(line) { progress(p) }
        }
        guard let path = out.split(whereSeparator: \.isNewline).map(String.init).last(where: { $0.hasPrefix("/") }),
              FileManager.default.fileExists(atPath: path) else { throw Engine.Failed(tool: "yt-dlp", detail: "no file") }
        progress(1)
        return URL(fileURLWithPath: path)
    }

    /// "[download]  42.0% of 10MiB …" → 0.42
    static func percent(_ line: String) -> Double? {
        guard line.hasPrefix("[download]"), let r = line.range(of: #"[0-9.]+(?=%)"#, options: .regularExpression),
              let v = Double(line[r]) else { return nil }
        return min(1, v / 100)
    }
}
