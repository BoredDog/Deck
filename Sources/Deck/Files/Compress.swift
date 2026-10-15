import Foundation

/// How a file gets smaller. Chosen per file type from the ARS research brief (see plan).
enum Method: Equatable {
    case zstd           // folders / other files, lossless
    case xz             // "Max" for folders / other files, lossless, slower
    case jxl            // JPEG → JPEG XL, lossless and restorable bit-exact
    case jxlLossy
    case oxipng         // PNG, lossless
    case webpLossless
    case flac           // WAV/AIFF, lossless
    case opus
    case av1            // video, lossy
    case hevcFast       // video, lossy, hardware
    case qpdf           // PDF, lossless
    case gsEbook        // PDF, lossy
    case skip(String)   // already compact

    var lossless: Bool {
        switch self {
        case .zstd, .xz, .jxl, .oxipng, .webpLossless, .flac, .qpdf: true
        default: false
        }
    }

    var tool: String? {
        switch self {
        case .zstd: "zstd"
        case .xz: "xz"
        case .jxl, .jxlLossy: "cjxl"
        case .oxipng: "oxipng"
        case .webpLossless: "cwebp"
        case .flac: "flac"
        case .opus, .av1, .hevcFast: "ffmpeg"
        case .qpdf: "qpdf"
        case .gsEbook: "gs"
        case .skip: nil
        }
    }
}

enum CompressPolicy {
    static let alreadyCompact: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "mp3", "m4a", "aac", "opus", "ogg", "heic", "heif",
                                              "avif", "jxl", "webp", "zip", "7z", "rar", "gz", "tgz", "xz", "zst", "bz2", "dmg", "flac"]
    static let video: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "mts", "m2ts"]

    /// `max`: spend more time for a smaller result. `lossyOK`: the user accepted "Even smaller".
    static func method(for url: URL, isFolder: Bool, max: Bool, lossyOK: Bool) -> Method {
        if isFolder { return max ? .xz : .zstd }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return lossyOK ? .jxlLossy : .jxl
        case "png": return lossyOK ? .webpLossless : .oxipng
        case "wav", "aif", "aiff": return lossyOK ? .opus : .flac
        case "pdf": return lossyOK ? .gsEbook : .qpdf
        case let e where video.contains(e): return lossyOK ? (max ? .av1 : .hevcFast) : .skip("Videos are already compact. Turn on “Even smaller” to shrink them.")
        case let e where alreadyCompact.contains(e): return .skip("Already compact")
        default: return max ? .xz : .zstd
        }
    }
}

struct CompressResult {
    let output: URL
    let before: Int64
    let after: Int64
    var saved: Int64 { before - after }
}

enum Compressor {
    static func run(_ src: URL, method: Method) async throws -> CompressResult? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: src.path, isDirectory: &isDir)
        let folder = src.deletingLastPathComponent()
        let name = src.lastPathComponent
        let base = src.deletingPathExtension().lastPathComponent
        let ff = ["-hide_banner", "-nostdin", "-y", "-protocol_whitelist", "file,pipe", "-i", src.path]
        let dir = isDir.boolValue
        let (outName, outExt): (String, String) = switch method {
        case .skip: (name, "")
        case .zstd: (name, dir ? "tar.zst" : "zst")
        case .xz: (name, dir ? "tar.xz" : "xz")
        case .jxl, .jxlLossy: (base, "jxl")
        case .oxipng: (base + " (smaller)", "png")
        case .webpLossless: (base, "webp")
        case .flac: (base, "flac")
        case .opus: (base, "opus")
        case .av1, .hevcFast: (base + " (smaller)", "mp4")
        case .qpdf, .gsEbook: (base + " (smaller)", "pdf")
        }
        if case .skip = method { return nil }
        let out = fm.partialURL(in: folder, ext: outExt)  // renamed to its real name once it's complete

        do {
        switch method {
        case .skip:
            return nil
        case .zstd where isDir.boolValue:
            // Window 27 (128 MB) restores without special flags.
            try await Engine.pipeline([("tar", ["-cf", "-", "-C", folder.path, "./" + name]),
                                       ("zstd", ["-19", "--long=27", "-T0", "-q", "-o", out.path])])
        case .zstd:
            try await Engine.run("zstd", ["-19", "--long=27", "-T0", "-q", src.path, "-o", out.path])
        case .xz where isDir.boolValue:
            try await Engine.pipeline([("tar", ["-cf", "-", "-C", folder.path, "./" + name]), ("xz", ["-9e", "-T0", "-c"])], stdoutTo: out)
        case .xz:
            try await Engine.run("xz", ["-9e", "-T0", "-k", "-c", src.path], stdoutTo: out)
        case .jxl:
            try await Engine.run("cjxl", [src.path, out.path, "--lossless_jpeg=1", "-e", "9", "--quiet"])
        case .jxlLossy:
            try await Engine.run("cjxl", [src.path, out.path, "--lossless_jpeg=0", "-d", "1", "--quiet"])
        case .oxipng:
            try await Engine.run("oxipng", ["-o", "4", "--strip", "safe", "-q", "--out", out.path, src.path])
        case .webpLossless:
            try await Engine.run("cwebp", ["-lossless", "-z", "9", "-quiet", src.path, "-o", out.path])
        case .flac:
            try await Engine.run("flac", ["-8", "--verify", "-s", "-o", out.path, src.path])
        case .opus:
            try await Engine.run("ffmpeg", ff + ["-vn", "-c:a", "libopus", "-b:a", "128k", out.path])
        case .av1:
            try await Engine.run("ffmpeg", ff + ["-c:v", "libsvtav1", "-crf", "30", "-preset", "6", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", out.path])
        case .hevcFast:
            try await Engine.run("ffmpeg", ff + ["-c:v", "hevc_videotoolbox", "-q:v", "60", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", out.path])
        case .qpdf:
            try await Engine.run("qpdf", ["--warning-exit-0", "--object-streams=generate", "--recompress-flate", "--compression-level=9", src.path, out.path])
        case .gsEbook:
            try await Engine.run("gs", ["-sDEVICE=pdfwrite", "-dPDFSETTINGS=/ebook", "-dNOPAUSE", "-dBATCH", "-dQUIET", "-dSAFER", "-sOutputFile=" + out.path, src.path])
        }
        } catch {
            try? fm.removeItem(at: out)
            throw error
        }

        let before = fm.size(of: src), after = fm.size(of: out)
        if after >= before {
            try? fm.removeItem(at: out)
            return CompressResult(output: src, before: before, after: before)
        }
        return CompressResult(output: try fm.finish(out, in: folder, name: outName, ext: outExt), before: before, after: after)
    }

    static func canRestore(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return n.hasSuffix(".zst") || n.hasSuffix(".xz") || n.hasSuffix(".jxl")
    }

    /// Unpacks what Deck made: strips the last extension and never overwrites. JPEG XL comes back as the exact original JPEG.
    static func restore(_ src: URL) async throws -> URL {
        let fm = FileManager.default
        let folder = src.deletingLastPathComponent()
        let n = src.lastPathComponent
        let inner = String(n.dropLast(src.pathExtension.count + 1))   // "foo.txt.zst" → "foo.txt"
        let innerURL = URL(fileURLWithPath: inner)
        let unpack = n.lowercased().hasSuffix(".zst") ? ("zstd", ["-d", "-c", "--long=31", src.path]) : ("xz", ["-d", "-c", src.path])

        if n.lowercased().hasSuffix(".jxl") {
            guard hasJPEGData(src) else { throw Engine.Plain(message: "This one can't go back to the exact original.") }
            let out = fm.partialURL(in: folder, ext: "jpg")
            do { try await Engine.run("djxl", [src.path, out.path, "--quiet"]) } catch { try? fm.removeItem(at: out); throw error }
            return try fm.finish(out, in: folder, name: inner, ext: "jpg")
        }
        // A folder Deck packed holds exactly one top-level folder named like the archive; a packed .tar file comes back as is.
        let folderName = innerURL.deletingPathExtension().lastPathComponent
        if innerURL.pathExtension == "tar", isOneFolder(try await Engine.pipeline([unpack, ("tar", ["-tf", "-"])]), named: folderName) {
            let dest = fm.freeURL(in: folder, name: folderName + " (restored)", ext: "")
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            do { try await Engine.pipeline([unpack, ("tar", ["-xf", "-", "-C", dest.path])]) } catch { try? fm.removeItem(at: dest); throw error }
            return dest
        }
        let out = fm.partialURL(in: folder, ext: innerURL.pathExtension)
        try await Engine.run(unpack.0, unpack.1, stdoutTo: out)
        return try fm.finish(out, in: folder, name: innerURL.deletingPathExtension().lastPathComponent, ext: innerURL.pathExtension)
    }

    /// True when every entry of a tar listing sits inside one folder called `name` ("name/…" or "./name/…").
    /// "Stuff 2" also matches "Stuff": that's what a second packing of the same folder is called.
    static func isOneFolder(_ listing: String, named name: String) -> Bool {
        let entries = listing.split(separator: "\n").map { $0.hasPrefix("./") ? $0.dropFirst(2) : $0[...] }.filter { !$0.isEmpty && $0 != "." && $0 != "./" }
        let names = [name, name.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression)]
        return names.contains { n in entries.allSatisfy { $0 == n || $0.hasPrefix(n + "/") } && entries.contains { $0.hasPrefix(n + "/") } }
    }

    /// JPEG XL keeps the original JPEG's bytes in a "jbrd" box only when it was made losslessly from a JPEG.
    static func hasJPEGData(_ url: URL) -> Bool {
        guard let d = try? Data(contentsOf: url), d.count >= 12, d.prefix(12) == Data([0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]) else { return false }
        var i = 0
        while i + 8 <= d.count {
            var size = d[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: d[i + 4..<i + 8], as: UTF8.self)
            if type == "jbrd" { return true }
            if size == 1, i + 16 <= d.count { size = d[i + 8..<i + 16].reduce(0) { $0 << 8 | Int($1) } }
            if size == 0 { return false }   // last box runs to the end
            guard size >= 8 else { return false }
            i += size
        }
        return false
    }
}
