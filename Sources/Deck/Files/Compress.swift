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
        let out = fm.freeURL(in: folder, name: outName, ext: outExt)

        do {
        switch method {
        case .skip:
            return nil
        case .zstd where isDir.boolValue:
            // Window 27 (128 MB) restores without special flags.
            try await Engine.pipeline([("tar", ["-cf", "-", "-C", folder.path, name]),
                                       ("zstd", ["-19", "--long=27", "-T0", "-q", "-o", out.path])])
        case .zstd:
            try await Engine.run("zstd", ["-19", "--long=27", "-T0", "-q", src.path, "-o", out.path])
        case .xz where isDir.boolValue:
            try await Engine.pipeline([("tar", ["-cf", "-", "-C", folder.path, name]), ("xz", ["-9e", "-T0", "-c"])], stdoutTo: out)
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
        return CompressResult(output: out, before: before, after: after)
    }

    static func canRestore(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return n.hasSuffix(".zst") || n.hasSuffix(".xz") || n.hasSuffix(".jxl")
    }

    /// Unpacks what Deck made. JPEG XL comes back as the exact original JPEG.
    static func restore(_ src: URL) async throws -> URL {
        let fm = FileManager.default
        let folder = src.deletingLastPathComponent()
        let n = src.lastPathComponent
        if n.hasSuffix(".tar.zst") || n.hasSuffix(".tar.xz") {
            let dest = fm.freeURL(in: folder, name: String(n.dropLast(n.hasSuffix(".zst") ? 8 : 7)) + " (restored)", ext: "")
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let unpack = n.hasSuffix(".zst") ? ("zstd", ["-d", "-c", "--long=31", src.path]) : ("xz", ["-d", "-c", src.path])
            try await Engine.pipeline([unpack, ("tar", ["-xf", "-", "-C", dest.path])])
            return dest
        }
        let inner = src.deletingPathExtension()
        if n.hasSuffix(".zst") {
            let out = fm.freeURL(in: folder, name: inner.deletingPathExtension().lastPathComponent, ext: inner.pathExtension)
            try await Engine.run("zstd", ["-d", "-q", "--long=31", src.path, "-o", out.path])
            return out
        }
        if n.hasSuffix(".xz") {
            let out = fm.freeURL(in: folder, name: inner.deletingPathExtension().lastPathComponent, ext: inner.pathExtension)
            try await Engine.run("xz", ["-d", "-k", "-c", src.path], stdoutTo: out)
            return out
        }
        let out = fm.freeURL(in: folder, name: inner.lastPathComponent, ext: "jpg")
        try await Engine.run("djxl", [src.path, out.path, "--quiet"])
        return out
    }
}
