import Foundation
import PDFKit
import AppKit

enum Kind: String { case image, video, audio, document, pdf, subtitle, data, archive, office, ebook, font, iwork }

/// A thing a file can become, named by outcome.
struct Target: Hashable, Identifiable {
    let id: String      // unique key, e.g. "video.iphone"
    let name: String    // what the user reads
    let ext: String
    var detail: String = ""
    var addOn: String?  // needs an opt-in add-on
}

/// Options for "Rotate or trim". Times are typed by the user ("1:05", "90", "1:02:03.5").
struct VideoEdit: Equatable {
    var rotate = 0
    var start = "", end = ""

    static func seconds(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

enum Converters {
    static let kinds: [Kind: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "jxl", "gif", "tif", "tiff", "bmp", "ico", "icns",
                 "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "psd", "svg"],
        .video: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mts", "m2ts", "3gp", "mpg", "mpeg", "ts"],
        .audio: ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "opus", "ogg", "wma", "caf", "alac", "m4r", "ac3", "mp2"],
        .document: ["md", "markdown", "txt", "html", "htm", "rtf", "odt", "epub", "tex", "ipynb", "org", "rst", "doc", "webarchive"],
        .pdf: ["pdf"],
        .subtitle: ["srt", "vtt", "ass", "ssa"],
        .data: ["csv", "json", "plist", "xml", "yaml", "yml", "toml"],
        .archive: ["zip", "7z", "rar", "tar", "gz", "tgz", "zst", "xz", "bz2"],
        .office: ["docx", "xlsx", "xls", "pptx", "ppt", "ods", "odp"],
        .ebook: ["mobi", "azw3", "azw"],
        .font: ["ttf", "otf", "woff", "woff2"],
        .iwork: ["pages", "numbers", "key"],
    ]

    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        return kinds.first { $0.value.contains(ext) }?.key
    }

    static let office = "office", ebooks = "ebooks", latex = "latex", fonts = "fonts"

    /// The .srt that sits next to a video ("Trip.mp4" + "Trip.srt"), if there is one.
    static func sidecarSubtitles(_ video: URL) -> URL? {
        let srt = video.deletingPathExtension().appendingPathExtension("srt")
        return FileManager.default.fileExists(atPath: srt.path) ? srt : nil
    }

    /// This ffmpeg can draw subtitles onto the picture only if it was built with libass.
    static let canBurnSubtitles: Bool = {
        guard let ff = Engine.path("ffmpeg") else { return false }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-h", "filter=subtitles"]
        p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return false }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return !String(decoding: out, as: UTF8.self).contains("Unknown filter")
    }()

    /// WOFF/WOFF2 wrap either a TrueType or an OpenType font; the header says which.
    static func desktopFontExt(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 8), d.count == 8 else { return "ttf" }
        return d[4..<8] == Data("OTTO".utf8) ? "otf" : "ttf"
    }

    private static let speeds: [(String, String, Double)] = [("speed50", "Half speed", 0.5), ("speed150", "1.5× faster", 1.5), ("speed200", "Twice as fast", 2)]

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [Target]] = [:]

    /// Remembered per file and modification date: working them out can open a spreadsheet or ask ffmpeg about itself.
    static func targets(for url: URL) -> [Target] {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let key = "\(url.path)|\(date.timeIntervalSince1970)|\(sidecarSubtitles(url) != nil)"
        if let hit = cacheLock.withLock({ cache[key] }) { return hit }
        let t = makeTargets(for: url)
        cacheLock.withLock { cache[key] = t }
        return t
    }

    private static func makeTargets(for url: URL) -> [Target] {
        let ext = url.pathExtension.lowercased()
        var t: [Target]
        switch kind(of: url) {
        case .image:
            t = [
                Target(id: "img.jpg", name: "JPG", ext: "jpg", detail: "Works everywhere"),
                Target(id: "img.png", name: "PNG", ext: "png", detail: "Sharp, keeps transparency"),
                Target(id: "img.heic", name: "HEIC", ext: "heic", detail: "iPhone photo, small"),
                Target(id: "img.webp", name: "WebP", ext: "webp", detail: "Photo for the web"),
                Target(id: "img.avif", name: "AVIF", ext: "avif", detail: "Smallest for the web"),
                Target(id: "img.jxl", name: "JPEG XL", ext: "jxl", detail: "Next-gen, high quality"),
                Target(id: "img.gif", name: "GIF", ext: "gif"),
                Target(id: "img.tiff", name: "TIFF", ext: "tiff", detail: "For print"),
                Target(id: "img.bmp", name: "BMP", ext: "bmp"),
                Target(id: "img.ico", name: "Windows icon", ext: "ico"),
                Target(id: "img.icns", name: "Mac app icon", ext: "icns", detail: "Every size, ready for apps"),
                Target(id: "img.pdf", name: "PDF", ext: "pdf"),
            ]
            if ext == "gif" {
                t.insert(contentsOf: [Target(id: "anim.webp", name: "Animated WebP", ext: "webp", detail: "Moving picture, much smaller"),
                                      Target(id: "anim.avif", name: "Animated AVIF", ext: "avif", detail: "Moving picture, smallest")], at: 0)
            }
        case .video:
            t = [
                Target(id: "video.mp4", name: "MP4", ext: "mp4", detail: "Plays everywhere"),
                Target(id: "video.iphone", name: "For iPhone", ext: "mp4", detail: "Smaller, fast to make"),
                Target(id: "video.av1", name: "Smallest MP4", ext: "mp4", detail: "Takes longer"),
                Target(id: "video.share", name: "Fit under 25 MB", ext: "mp4", detail: "WhatsApp, Discord, email"),
                Target(id: "video.screen", name: "Small screen recording", ext: "mp4", detail: "Sharp text, tiny file"),
                Target(id: "video.edit", name: "Rotate or trim", ext: "mp4", detail: "Turn it or cut the ends"),
                Target(id: "video.mov", name: "MOV", ext: "mov"),
                Target(id: "video.prores", name: "For editing", ext: "mov", detail: "Big, best for editing apps"),
                Target(id: "video.dnxhd", name: "For editing on PC", ext: "mov", detail: "Big, for Avid and Resolve"),
                Target(id: "video.mkv", name: "MKV", ext: "mkv", detail: "Instant, same quality"),
                Target(id: "video.webm", name: "WebM", ext: "webm", detail: "For websites"),
                Target(id: "video.m4v", name: "M4V", ext: "m4v"),
                Target(id: "video.avi", name: "AVI", ext: "avi", detail: "Older players"),
                Target(id: "video.gif", name: "GIF", ext: "gif", detail: "Short animated clip"),
                Target(id: "anim.webp", name: "Animated WebP", ext: "webp", detail: "Short clip for the web"),
                Target(id: "anim.avif", name: "Animated AVIF", ext: "avif", detail: "Short clip, smallest"),
                Target(id: "video.audio", name: "Just the audio", ext: "m4a"),
                Target(id: "video.mp3", name: "MP3", ext: "mp3", detail: "Just the sound"),
                Target(id: "video.frames", name: "Pictures", ext: "png", detail: "One every second"),
                Target(id: "video.loud", name: "Even out the volume", ext: Self.sameVideoExt(ext), detail: "Fixes too quiet or too loud"),
            ]
            t += speeds.map { Target(id: "video.\($0.0)", name: $0.1, ext: "mp4") }
            if ["mkv", "mp4", "mov", "m4v"].contains(ext) {
                t.append(Target(id: "video.subs", name: "Subtitles", ext: "srt", detail: "Get the captions out"))
            }
            if sidecarSubtitles(url) != nil {
                t.insert(Target(id: "video.burn", name: "With subtitles", ext: "mp4",
                                detail: canBurnSubtitles ? "Puts the .srt next to it on screen" : "Adds the .srt next to it"), at: 0)
            }
        case .audio:
            t = [
                Target(id: "audio.mp3", name: "MP3", ext: "mp3", detail: "Plays everywhere"),
                Target(id: "audio.aac", name: "M4A", ext: "m4a", detail: "Apple, good quality"),
                Target(id: "audio.alac", name: "Apple Lossless", ext: "m4a", detail: "Perfect quality"),
                Target(id: "audio.flac", name: "FLAC", ext: "flac", detail: "Perfect quality, smaller"),
                Target(id: "audio.wav", name: "WAV", ext: "wav", detail: "Uncompressed"),
                Target(id: "audio.aiff", name: "AIFF", ext: "aiff", detail: "Uncompressed, Apple"),
                Target(id: "audio.opus", name: "Opus", ext: "opus", detail: "Smallest, sounds great"),
                Target(id: "audio.ogg", name: "OGG", ext: "ogg"),
                Target(id: "audio.ringtone", name: "iPhone ringtone", ext: "m4r", detail: "First 30 seconds"),
                Target(id: "audio.wma", name: "WMA", ext: "wma", detail: "Older Windows players"),
                Target(id: "audio.ac3", name: "AC3", ext: "ac3", detail: "For DVDs and TVs"),
                Target(id: "audio.mp2", name: "MP2", ext: "mp2", detail: "Radio and old players"),
                Target(id: "audio.loud", name: "Even out the volume", ext: Self.sameAudioExt(ext), detail: "Fixes too quiet or too loud"),
            ]
            t += speeds.map { Target(id: "audio.\($0.0)", name: $0.1, ext: Self.sameAudioExt(ext)) }
        case .document:
            t = [
                Target(id: "doc.pdf", name: "PDF", ext: "pdf", detail: ext == "tex" ? "Quick, math kept" : ""),
                Target(id: "doc.docx", name: "Word", ext: "docx"),
                Target(id: "doc.odt", name: "OpenDocument", ext: "odt"),
                Target(id: "doc.rtf", name: "Rich text", ext: "rtf"),
                Target(id: "doc.html", name: "Web page", ext: "html"),
                Target(id: "doc.epub", name: "Ebook", ext: "epub"),
                Target(id: "doc.md", name: "Markdown", ext: "md"),
                Target(id: "doc.txt", name: "Plain text", ext: "txt"),
                Target(id: "doc.pptx", name: "PowerPoint", ext: "pptx", detail: "Each heading becomes a slide"),
                Target(id: "doc.tex", name: "LaTeX", ext: "tex"),
            ]
            if ext == "tex" { t.insert(Target(id: "latex.pdf", name: "Exact PDF", ext: "pdf", detail: "Typeset like LaTeX", addOn: latex), at: 1) }
            t.append(Target(id: "ebook.mobi", name: "Kindle (MOBI)", ext: "mobi", addOn: ebooks))
            t.append(Target(id: "ebook.azw3", name: "Kindle (AZW3)", ext: "azw3", addOn: ebooks))
        case .pdf:
            t = [
                Target(id: "pdf.png", name: "Images", ext: "png", detail: "One picture per page"),
                Target(id: "pdf.txt", name: "Text", ext: "txt", detail: "All the words"),
                Target(id: "pdf.docx", name: "Word", ext: "docx", addOn: office),
            ]
        case .subtitle:
            t = [Target(id: "sub.srt", name: "SRT", ext: "srt"), Target(id: "sub.vtt", name: "VTT", ext: "vtt", detail: "For the web"),
                 Target(id: "sub.ass", name: "ASS", ext: "ass", detail: "Styled")]
        case .data:
            t = [Target(id: "data.json", name: "JSON", ext: "json"), Target(id: "data.csv", name: "Spreadsheet (CSV)", ext: "csv"),
                 Target(id: "data.xlsx", name: "Excel", ext: "xlsx"), Target(id: "data.yaml", name: "YAML", ext: "yaml"),
                 Target(id: "data.xml", name: "XML", ext: "xml"), Target(id: "data.plist", name: "Property list", ext: "plist")]
        case .archive:
            t = [Target(id: "arc.extract", name: "Unpack", ext: "", detail: "Get the files out")]
        case .office:
            switch ext {
            case "xlsx":
                t = [Target(id: "xlsx.csv", name: "Spreadsheet (CSV)", ext: "csv", detail: "First sheet"),
                     Target(id: "xlsx.json", name: "JSON", ext: "json", detail: "First sheet")]
                if ((try? XLSX.sheets(url).count) ?? 0) > 1 {
                    t.append(Target(id: "xlsx.allcsv", name: "Every sheet", ext: "csv", detail: "One CSV per sheet"))
                }
                t.append(Target(id: "office.pdf", name: "PDF", ext: "pdf", addOn: office))
            case "pptx", "ppt", "odp":
                t = [Target(id: "office.pdf", name: "PDF", ext: "pdf", addOn: office),
                     Target(id: "office.slides", name: "Pictures", ext: "png", detail: "One per slide", addOn: office)]
                if ext == "pptx" { t.insert(Target(id: "pptx.outline", name: "Outline", ext: "txt", detail: "All the slide text"), at: 0) }
            case "xls", "ods":
                t = [Target(id: "office.csv", name: "Spreadsheet (CSV)", ext: "csv", addOn: office),
                     Target(id: "office.pdf", name: "PDF", ext: "pdf", addOn: office)]
            default:
                t = [Target(id: "doc.md", name: "Markdown", ext: "md"), Target(id: "doc.html", name: "Web page", ext: "html"),
                     Target(id: "doc.pdf", name: "PDF (simple)", ext: "pdf"), Target(id: "doc.txt", name: "Plain text", ext: "txt"),
                     Target(id: "office.pdf", name: "PDF", ext: "pdf", addOn: office)]
            }
        case .ebook:
            t = [Target(id: "ebook.epub", name: "EPUB", ext: "epub", addOn: ebooks), Target(id: "ebook.pdf", name: "PDF", ext: "pdf", addOn: ebooks)]
        case .font:
            t = [Target(id: "font.woff2", name: "WOFF2", ext: "woff2", detail: "Smallest web font", addOn: fonts),
                 Target(id: "font.woff", name: "WOFF", ext: "woff", detail: "Web font, older browsers", addOn: fonts)]
            if ext == "woff" || ext == "woff2" {
                t.insert(Target(id: "font.desktop", name: "Desktop font", ext: desktopFontExt(url), detail: "Install it on your Mac", addOn: fonts), at: 0)
            }
        case .iwork:
            let outs: [String: [Target]] = [
                "pages": [Target(id: "iwork.docx", name: "Word", ext: "docx"), Target(id: "iwork.pdf", name: "PDF", ext: "pdf")],
                "numbers": [Target(id: "iwork.xlsx", name: "Excel", ext: "xlsx"), Target(id: "iwork.csv", name: "Spreadsheet (CSV)", ext: "csv"),
                            Target(id: "iwork.pdf", name: "PDF", ext: "pdf")],
                "key": [Target(id: "iwork.pptx", name: "PowerPoint", ext: "pptx"), Target(id: "iwork.pdf", name: "PDF", ext: "pdf"),
                        Target(id: "iwork.images", name: "Pictures", ext: "", detail: "One per slide")],
            ]
            t = IWork.installed(ext) ? outs[ext] ?? [] : []
        case nil:
            t = []
        }
        // Folders and any file can be packed into an archive.
        t += [Target(id: "arc.zip", name: "ZIP", ext: "zip", detail: "Opens anywhere"),
              Target(id: "arc.7z", name: "7z", ext: "7z", detail: "Smaller archive"),
              Target(id: "arc.tgz", name: "TAR.GZ", ext: "tar.gz", detail: "Linux and servers"),
              Target(id: "arc.txz", name: "TAR.XZ", ext: "tar.xz", detail: "Smaller, slower"),
              Target(id: "arc.tzst", name: "TAR.ZST", ext: "tar.zst", detail: "Small and fast")]
        let same = ext == "jpeg" ? "jpg" : ext == "tif" ? "tiff" : ext == "yml" ? "yaml" : ext
        let keepSame = ["video.", "audio.", "anim."]
        return t.filter { !($0.ext == same && !keepSame.contains(where: $0.id.hasPrefix)) && !(kind(of: url) == .data && $0.ext == same) }
    }

    /// Targets that turn several dropped images into one file.
    static func combineTargets(for urls: [URL]) -> [Target] {
        guard urls.count > 1, urls.allSatisfy({ kind(of: $0) == .image }) else { return [] }
        return [Target(id: "combine.video", name: "Slideshow video", ext: "mp4", detail: "3 seconds per picture"),
                Target(id: "combine.tiff", name: "One TIFF", ext: "tiff", detail: "Every picture as a page")]
    }

    /// Loudness and speed keep the container when the video can be copied as is.
    private static func sameVideoExt(_ ext: String) -> String { ["mp4", "mov", "m4v", "mkv"].contains(ext) ? ext : "mp4" }
    private static func sameAudioExt(_ ext: String) -> String { ["mp3", "m4a", "wav", "flac", "aiff", "aif", "opus"].contains(ext) ? ext : "m4a" }

    /// Encoder settings for an audio file type (ffmpeg picks the matching encoder for the rest).
    private static func audioArgs(_ ext: String) -> [String] {
        ["mp3": ["-c:a", "libmp3lame", "-q:a", "2"], "m4a": ["-c:a", "aac", "-b:a", "256k"], "opus": ["-c:a", "libopus", "-b:a", "128k"]][ext] ?? []
    }

    /// Several images → one file (slideshow video or multi-page TIFF). Saved next to the first image.
    static func combine(_ images: [URL], to t: Target, progress: @escaping (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let first = images[0]
        let folder = first.deletingLastPathComponent()
        let out = fm.partialURL(in: folder, ext: t.ext)
        let tmp = fm.temporaryDirectory.appendingPathComponent("deck-combine-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        do {
            switch t.id {
            case "combine.tiff":
                try await Engine.run("magick", images.map { $0.path + ($0.pathExtension.lowercased() == "gif" ? "[0]" : "") } + [out.path])
            case "combine.video":
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                // Same type and size cap for every picture, so ffmpeg can read them as one sequence.
                for (i, img) in images.enumerated() {
                    try await Engine.run("sips", ["-s", "format", "png", "-Z", "1920", img.path, "--out", tmp.appendingPathComponent(String(format: "%04d.png", i)).path])
                    progress(Double(i + 1) / Double(images.count) * 0.5)
                }
                try await Engine.run("ffmpeg", ["-hide_banner", "-nostdin", "-y", "-protocol_whitelist", "file,pipe", "-framerate", "1/3",
                                                "-i", tmp.appendingPathComponent("%04d.png").path,
                                                "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,format=yuv420p",
                                                "-r", "30", "-c:v", "libx264", "-crf", "20", "-movflags", "+faststart", out.path])
            default:
                throw Engine.Failed(tool: "deck", detail: "unsupported \(t.id)")
            }
        } catch {
            try? fm.removeItem(at: out)
            throw error
        }
        progress(1)
        return try fm.finish(out, in: folder, name: first.deletingPathExtension().lastPathComponent + (t.id == "combine.video" ? " slideshow" : " pages"), ext: t.ext)
    }

    /// Converts one file. Returns the new file's location (the original is never touched).
    static func convert(_ src: URL, to t: Target, edit: VideoEdit = VideoEdit(), progress: @escaping (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let folder = src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent
        let out = fm.partialURL(in: folder, ext: t.ext)  // renamed to its real name once it's complete
        var made = out  // what to remove if something fails
        let inExt = src.pathExtension.lowercased()
        let ff = ["-hide_banner", "-nostdin", "-y", "-protocol_whitelist", "file,pipe", "-i", src.path]
        let tmp = fm.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        func ffmpeg(_ args: [String], to dest: String? = nil) async throws {
            let duration = await mediaDuration(src)
            try await Engine.run("ffmpeg", ff + args + ["-progress", "pipe:1", "-nostats", dest ?? out.path]) { line in
                if line.hasPrefix("out_time_us="), duration > 0, let us = Double(line.dropFirst(12)) {
                    progress(min(1, us / 1_000_000 / duration))
                }
            }
        }
        /// A new folder next to the original for results with many files.
        func newFolder(_ suffix: String) throws -> URL {
            let d = fm.freeURL(in: folder, name: base + suffix, ext: "")
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            made = d
            return d
        }
        func scratch() throws -> URL {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            return tmp
        }
        /// LibreOffice, headless, with a throwaway profile. Returns the file it made.
        func soffice(_ convertTo: String, inFilter: String? = nil) async throws -> URL {
            let dir = try scratch().appendingPathComponent("out")
            let profile = tmp.appendingPathComponent("profile")
            var args = ["-env:UserInstallation=file://" + profile.path, "--headless", "--norestore", "--nologo", "--convert-to", convertTo, "--outdir", dir.path]
            if let inFilter { args.insert("--infilter=" + inFilter, at: 3) }
            try await runApp(Setup.addOn(office).appPath!, args + [src.path])
            guard let file = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first else {
                throw Engine.Failed(tool: "soffice", detail: "no output")
            }
            return file
        }
        let reencode = ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        let gifFrame = inExt == "gif" ? "[0]" : ""

        do {
        switch t.id {
        // Images
        case "img.icns":
            // Every size macOS asks for, then iconutil packs them.
            let set = try scratch().appendingPathComponent("icon.iconset")
            try fm.createDirectory(at: set, withIntermediateDirectories: true)
            for size in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let px = size * scale, name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                    try await Engine.run("magick", ["-background", "none", src.path + gifFrame, "-resize", "\(px)x\(px)", "-gravity", "center",
                                                    "-extent", "\(px)x\(px)", set.appendingPathComponent(name).path])
                }
            }
            try await Engine.run("iconutil", ["-c", "icns", "-o", out.path, set.path])
        case "img.jpg" where ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "psd", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"].contains(inExt),
             "img.png" where inExt != "svg" && inExt != "jxl" && inExt != "webp" && inExt != "avif",
             "img.heic" where inExt != "svg", "img.tiff" where inExt != "svg", "img.bmp" where inExt != "svg", "img.pdf" where inExt != "svg":
            let fmt = ["img.jpg": "jpeg", "img.png": "png", "img.heic": "heic", "img.tiff": "tiff", "img.bmp": "bmp", "img.pdf": "pdf"][t.id]!
            try await Engine.run("sips", ["-s", "format", fmt, src.path, "--out", out.path])
        case "img.jxl":
            if inExt == "jpg" || inExt == "jpeg" || inExt == "png" {
                try await Engine.run("cjxl", [src.path, out.path])
            } else {
                // ImageMagick here can't write JPEG XL, so go through a lossless PNG.
                let png = try scratch().appendingPathComponent("in.png")
                try await Engine.run("magick", [src.path + gifFrame, png.path])
                try await Engine.run("cjxl", [png.path, out.path])
            }
        case "img.webp" where inExt == "png" || inExt == "jpg" || inExt == "jpeg":
            try await Engine.run("cwebp", ["-q", "85", src.path, "-o", out.path])
        case let id where id.hasPrefix("img."):
            try await Engine.run("magick", [src.path + gifFrame, out.path])
        case "anim.webp":
            if inExt == "gif" {
                try await Engine.run("magick", [src.path, "-quality", "80", out.path])
            } else {
                // This ffmpeg has no WebP writer: take frames out, then ImageMagick animates them.
                let dir = try scratch()
                try await ffmpeg(["-an", "-vf", "fps=12,scale='min(480,iw)':-2"], to: dir.appendingPathComponent("%04d.png").path)
                let frames = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted().map { dir.appendingPathComponent($0).path }
                try await Engine.run("magick", ["-delay", "8", "-loop", "0"] + frames + ["-quality", "80", out.path])
            }
        case "anim.avif":
            try await ffmpeg(["-an", "-vf", "fps=12,scale='trunc(min(480,iw)/2)*2':-2,format=yuv420p", "-c:v", "libsvtav1", "-crf", "35", "-preset", "8"])

        // Video
        case "video.mp4", "video.m4v": try await ffmpeg(reencode)
        case "video.iphone": try await ffmpeg(["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"])
        case "video.av1": try await ffmpeg(["-c:v", "libsvtav1", "-crf", "32", "-preset", "8", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"])
        case "video.share":
            // Bitrate chosen so the whole file lands just under 25 MB.
            let d = max(await mediaDuration(src), 1)
            let kbps = max(150, Int((24.0 * 8 * 1024) / d) - 128)
            try await ffmpeg(["-c:v", "libx264", "-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k",
                              "-vf", "scale='min(1280,iw)':-2", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart"])
        case "video.screen":
            // Screen content is mostly still: a high CRF stays sharp and gets very small.
            try await ffmpeg(["-vf", "scale='min(1920,iw)':-2,fps=30", "-c:v", "libx264", "-crf", "28", "-preset", "slow", "-tune", "stillimage",
                              "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart"])
        case "video.edit":
            var args: [String] = []
            let turn = [90: "transpose=1", 180: "hflip,vflip", 270: "transpose=2"][edit.rotate]
            if let turn { args += ["-vf", turn] }
            let start = VideoEdit.seconds(edit.start) ?? 0
            if start > 0 { args += ["-ss", "\(start)"] }
            if let end = VideoEdit.seconds(edit.end), end > start { args += ["-t", "\(end - start)"] }
            try await ffmpeg(args + reencode)
        case "video.mov": try await ffmpeg(["-c:v", "libx264", "-crf", "20", "-c:a", "aac", "-b:a", "192k"])
        case "video.prores": try await ffmpeg(["-c:v", "prores_videotoolbox", "-profile:v", "hq", "-c:a", "pcm_s16le"])
        case "video.dnxhd": try await ffmpeg(["-c:v", "dnxhd", "-profile:v", "dnxhr_hq", "-pix_fmt", "yuv422p", "-c:a", "pcm_s16le"])
        case "video.mkv": try await ffmpeg(["-map", "0", "-c", "copy"])
        case "video.webm": try await ffmpeg(["-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"])
        case "video.avi": try await ffmpeg(["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"])
        case "video.gif": try await ffmpeg(["-vf", "fps=12,scale='min(480,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"])
        case "video.audio": try await ffmpeg(["-vn", "-c:a", "aac", "-b:a", "256k"])
        case "video.mp3": try await ffmpeg(["-vn", "-c:a", "libmp3lame", "-q:a", "2"])
        case "video.frames":
            let dir = try newFolder(" pictures")
            try await ffmpeg(["-an", "-vf", "fps=1"], to: dir.appendingPathComponent("picture %04d.png").path)
            progress(1)
            return dir
        case "video.subs": try await ffmpeg(["-map", "0:s:0", "-c:s", "srt"])
        case "video.burn":
            guard let srt = sidecarSubtitles(src) else { throw Engine.Failed(tool: "deck", detail: "no .srt next to the video") }
            if canBurnSubtitles {
                // A plain copy name keeps the filter text free of quotes and colons.
                let copy = try scratch().appendingPathComponent("subs.srt")
                try fm.copyItem(at: srt, to: copy)
                try await ffmpeg(["-vf", "subtitles=" + copy.path] + reencode)
            } else {
                try await ffmpeg(["-protocol_whitelist", "file,pipe", "-i", srt.path, "-map", "0:v", "-map", "0:a?", "-map", "1", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                                  "-c:s", "mov_text", "-movflags", "+faststart"])
            }
        case "video.loud":
            try await ffmpeg(["-map", "0:v", "-map", "0:a", "-c:v", "copy", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000", "-c:a", "aac", "-b:a", "192k"])
        case let id where id.hasPrefix("video.speed"):
            let s = speeds.first { "video." + $0.0 == id }!.2
            try await ffmpeg(["-filter:v", "setpts=PTS/\(s)", "-filter:a", "atempo=\(s)"] + reencode)

        // Audio
        case "audio.mp3": try await ffmpeg(["-vn", "-c:a", "libmp3lame", "-q:a", "2"])
        case "audio.aac": try await ffmpeg(["-vn", "-c:a", "aac", "-b:a", "256k"])
        case "audio.alac": try await ffmpeg(["-vn", "-c:a", "alac"])
        case "audio.flac": try await ffmpeg(["-vn", "-c:a", "flac", "-compression_level", "8"])
        case "audio.wav": try await ffmpeg(["-vn", "-c:a", "pcm_s16le"])
        case "audio.aiff": try await ffmpeg(["-vn", "-c:a", "pcm_s16be"])
        case "audio.opus", "audio.ogg": try await ffmpeg(["-vn", "-c:a", "libopus", "-b:a", "128k"])
        case "audio.ringtone": try await ffmpeg(["-vn", "-t", "30", "-c:a", "aac", "-b:a", "192k", "-f", "ipod"])
        case "audio.wma": try await ffmpeg(["-vn", "-c:a", "wmav2", "-b:a", "192k"])
        case "audio.ac3": try await ffmpeg(["-vn", "-c:a", "ac3", "-b:a", "448k"])
        case "audio.mp2": try await ffmpeg(["-vn", "-c:a", "mp2", "-b:a", "256k"])
        case "audio.loud": try await ffmpeg(["-vn", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000"] + audioArgs(t.ext))
        case let id where id.hasPrefix("audio.speed"):
            let s = speeds.first { "audio." + $0.0 == id }!.2
            try await ffmpeg(["-vn", "-filter:a", "atempo=\(s)"] + audioArgs(t.ext))

        // Subtitles
        case let id where id.hasPrefix("sub."): try await ffmpeg([])

        // Documents
        case "doc.pdf":
            let html = try await pandocHTML(src)
            try await WebPDF.render(html: html, baseURL: folder, to: out)
        case let id where id.hasPrefix("doc."):
            if ["doc", "webarchive"].contains(inExt) || (inExt == "rtf" && ["docx", "html", "txt", "odt"].contains(t.ext)) {
                let fmt = ["docx": "docx", "html": "html", "txt": "txt", "odt": "odt", "rtf": "rtf"][t.ext] ?? "html"
                try await Engine.run("textutil", ["-convert", fmt, src.path, "-output", out.path])
            } else {
                var args = ["--sandbox", "-s", src.path, "-o", out.path]
                if t.ext == "txt" { args += ["-t", "plain"] }
                if t.ext == "html" { args += ["--mathml"] }
                try await Engine.run("pandoc", args)
            }
        case "latex.pdf":
            let dir = try scratch()
            try await Engine.run("tectonic", ["-X", "compile", "--outdir", dir.path, src.path], cwd: folder)
            try fm.moveItem(at: dir.appendingPathComponent(base + ".pdf"), to: out)

        // PDF
        case "pdf.png":
            let dir = try newFolder("")
            try PDFTools.pagesToImages(src, into: dir, progress: progress)
            return dir
        case "pdf.txt":
            guard let doc = PDFDocument(url: src) else { throw Engine.Failed(tool: "pdfkit", detail: "unreadable") }
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)

        // Data
        case let id where id.hasPrefix("data."):
            try DataConvert.convert(src, toExt: t.ext, out: out)

        // Office files, read natively
        case "xlsx.csv":
            try DataConvert.csv(rows: XLSX.rows(src)).write(to: out, atomically: true, encoding: .utf8)
        case "xlsx.json":
            try DataConvert.convert(src, toExt: "json", out: out)
        case "xlsx.allcsv":
            let dir = try newFolder(" sheets")
            for (i, sheet) in try XLSX.sheets(src).enumerated() {
                let name = sheet.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                try DataConvert.csv(rows: XLSX.rows(src, sheet: i)).write(to: fm.freeURL(in: dir, name: name, ext: "csv"), atomically: true, encoding: .utf8)
            }
            progress(1)
            return dir
        case "pptx.outline":
            try PPTX.outline(src).write(to: out, atomically: true, encoding: .utf8)

        // Archives
        case "arc.zip":
            try await Engine.run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, out.path])
        case "arc.7z":
            try await Engine.run("7zz", ["a", "-mx=7", out.path, src.path])
        case "arc.tgz":
            try await Engine.run("tar", ["-czf", out.path, "-C", folder.path, "./" + src.lastPathComponent])
        case "arc.txz":
            try await Engine.pipeline([("tar", ["-cf", "-", "-C", folder.path, "./" + src.lastPathComponent]), ("xz", ["-9", "-T0", "-c"])], stdoutTo: out)
        case "arc.tzst":
            try await Engine.pipeline([("tar", ["-cf", "-", "-C", folder.path, "./" + src.lastPathComponent]), ("zstd", ["-19", "-T0", "-q", "-o", out.path])])
        case "arc.extract":
            let dest = fm.freeURL(in: folder, name: base.replacingOccurrences(of: ".tar", with: ""), ext: "")
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            made = dest
            let isTar = src.lastPathComponent.lowercased().contains(".tar.") || inExt == "tar" || inExt == "tgz"
            let single = ["gz": "gzip", "xz": "xz", "bz2": "bzip2", "zst": "zstd"][inExt]
            if isTar && inExt == "zst" {
                try await Engine.pipeline([("zstd", ["-d", "-c", "--long=31", src.path]), ("tar", ["-xf", "-", "-C", dest.path])])
            } else if isTar {
                // bsdtar recognises gzip, xz and bzip2 by itself.
                try await Engine.run("tar", ["-xf", src.path, "-C", dest.path])
            } else if let single {
                try await Engine.run(single, ["-d", "-c", src.path] + (single == "zstd" ? ["--long=31"] : []), stdoutTo: dest.appendingPathComponent(base))
            } else if inExt == "zip" && !Engine.has("7zz") {
                try await Engine.run("ditto", ["-x", "-k", src.path, dest.path])
            } else {
                try await Engine.run("7zz", ["x", "-y", "-o" + dest.path, src.path])
            }
            return dest

        // Fonts (add-on). Only the wrapper changes, never the letter shapes.
        case "font.woff", "font.woff2", "font.desktop":
            let flavor = t.id == "font.desktop" ? [] : ["--flavor", t.ext]
            try await Engine.run("fonttools", ["ttLib", "-o", out.path] + flavor + [src.path])

        // Apple iWork, through the app itself
        case let id where id.hasPrefix("iwork."):
            try await IWork.export(src, to: out, outExt: t.ext)

        // Optional add-ons
        case "office.pdf", "office.csv", "pdf.docx":
            let file = if t.id == "pdf.docx" { try await soffice("docx:\"MS Word 2007 XML\"", inFilter: "writer_pdf_import") } else { try await soffice(t.ext) }
            try fm.moveItem(at: file, to: out)
        case "office.slides":
            let pdf = try await soffice("pdf")
            let dir = try newFolder(" slides")
            try PDFTools.pagesToImages(pdf, into: dir, progress: progress)
            return dir
        case let id where id.hasPrefix("ebook."):
            try await runApp(Setup.addOn(ebooks).appPath!, [src.path, out.path])

        default:
            throw Engine.Failed(tool: "deck", detail: "unsupported \(t.id)")
        }
        } catch {
            // Don't leave half-written files behind.
            try? fm.removeItem(at: made)
            throw error
        }
        progress(1)
        return try fm.finish(out, in: folder, name: base, ext: t.ext)
    }

    static func mediaDuration(_ url: URL) async -> Double {
        let out = try? await Engine.run("ffprobe", ["-v", "error", "-protocol_whitelist", "file,pipe", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
        return Double(out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    private static func pandocHTML(_ src: URL) async throws -> String {
        let ext = src.pathExtension.lowercased()
        if ext == "html" || ext == "htm" { return try String(contentsOf: src, encoding: .utf8) }
        if ["doc", "webarchive", "rtf"].contains(ext) {
            return try await Engine.run("textutil", ["-convert", "html", "-stdout", src.path])
        }
        let css = "<style>body{font:15px -apple-system,Helvetica;max-width:720px;margin:40px auto;line-height:1.5;color:#111}pre,code{font-family:Menlo,monospace;font-size:13px}img{max-width:100%}</style>"
        let body = try await Engine.run("pandoc", ["--sandbox", "--mathml", "-t", "html5", src.path])
        return "<!doctype html><meta charset=utf-8>\(css)\(body)"
    }

    /// Runs a helper that lives inside an app bundle (LibreOffice, Calibre).
    private static func runApp(_ path: String, _ args: [String]) async throws {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw Engine.Missing(tool: path) }
        // Engine only looks in standard folders, so call through /usr/bin/env with the full path.
        try await Engine.run("env", [path] + args)
    }
}

/// HTML → PDF with WebKit, so documents become PDFs without needing LaTeX.
import WebKit

@MainActor enum WebPDF {
    /// Blocks every web request; compiled once.
    private static var offlineRules: WKContentRuleList?

    /// Documents stay offline: no scripts, no web requests, and a page policy that only allows local files.
    static func render(html: String, baseURL: URL, to out: URL) async throws {
        if offlineRules == nil {
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
            offlineRules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "deck-offline", encodedContentRuleList: rules)
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        config.userContentController.add(offlineRules!)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1100), configuration: config)
        let nav = NavDelegate()
        web.navigationDelegate = nav
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            nav.done = { c.resume() }
            web.loadHTMLString(offline(html), baseURL: baseURL)
        }
        let op = web.printOperation(with: {
            let info = NSPrintInfo()
            info.paperSize = NSSize(width: 595, height: 842)
            info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
            return info
        }())
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = web.bounds
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let runner = PrintRunner(done: { c.resume() })
            op.runModal(for: NSWindow(), delegate: runner, didRun: #selector(PrintRunner.done(_:success:context:)), contextInfo: nil)
            objc_setAssociatedObject(op, "runner", runner, .OBJC_ASSOCIATION_RETAIN)
        }
        guard FileManager.default.fileExists(atPath: out.path) else { throw Engine.Failed(tool: "webkit", detail: "no pdf") }
    }

    /// Puts a content policy first in the page (after the doctype, so the page keeps its normal layout mode).
    static func offline(_ html: String) -> String {
        let policy = #"<meta http-equiv="Content-Security-Policy" content="default-src file: data: 'unsafe-inline'"><meta http-equiv="x-dns-prefetch-control" content="off">"#
        guard html.prefix(9).lowercased() == "<!doctype", let end = html.firstIndex(of: ">") else { return policy + html }
        return String(html[...end]) + policy + html[html.index(after: end)...]
    }

    private final class NavDelegate: NSObject, WKNavigationDelegate {
        var done: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?(); done = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?(); done = nil }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let s = action.request.url?.scheme ?? ""
            return s == "file" || s == "about" ? .allow : .cancel
        }
    }

    private final class PrintRunner: NSObject {
        let callback: () -> Void
        init(done: @escaping () -> Void) { callback = done }
        @objc func done(_ op: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) { callback() }
    }
}

enum PDFTools {
    static func pagesToImages(_ pdf: URL, into folder: URL, progress: (Double) -> Void) throws {
        guard let doc = PDFDocument(url: pdf) else { throw Engine.Failed(tool: "pdfkit", detail: "unreadable") }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let img = page.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: folder.appendingPathComponent(String(format: "page %03d.png", i + 1)))
            progress(Double(i + 1) / Double(doc.pageCount))
        }
    }

    /// Puts images (in the given order) into one PDF.
    static func imagesToPDF(_ images: [URL], out: URL) throws {
        let doc = PDFDocument()
        for url in images {
            if let img = NSImage(contentsOf: url), let page = PDFPage(image: img) { doc.insert(page, at: doc.pageCount) }
        }
        guard doc.pageCount > 0, doc.write(to: out) else { throw Engine.Failed(tool: "pdfkit", detail: "no pages") }
    }
}

/// CSV / JSON / YAML / plist without extra helpers.
enum DataConvert {
    static func convert(_ src: URL, toExt: String, out: URL) throws {
        let data = try Data(contentsOf: src)
        let value: Any
        switch src.pathExtension.lowercased() {
        case "json": value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        case "plist": value = try PropertyListSerialization.propertyList(from: data, format: nil)
        case "csv": value = parseCSV(String(decoding: data, as: UTF8.self))
        case "xml": value = try XMLJSON.parse(data)
        case "yaml", "yml": value = try YAMLInput.parse(String(decoding: data, as: UTF8.self))
        case "toml": value = try TOML.parse(String(decoding: data, as: UTF8.self))
        case "xlsx": value = rowsToRecords(try XLSX.rows(src))
        default: throw Engine.Failed(tool: "data", detail: "unknown input")
        }
        if toExt == "xlsx" {
            // CSV keeps its column order; anything else is laid out like the CSV output.
            let rows: [[Any]] = src.pathExtension.lowercased() == "csv" ? csvRows(String(decoding: data, as: UTF8.self)) : try table(value)
            return try XLSX.write(rows, to: out)
        }
        let result: Data
        switch toExt {
        case "xml": result = Data(XMLJSON.xml(jsonSafe(value)).utf8)
        case "json": result = try JSONSerialization.data(withJSONObject: jsonSafe(value), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        case "plist": result = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        case "yaml": result = Data(yaml(value).utf8)
        case "csv": result = Data(try csv(value).utf8)
        default: throw Engine.Failed(tool: "data", detail: "unknown output")
        }
        try result.write(to: out)
    }

    static func parseCSV(_ text: String) -> [[String: String]] {
        let rows = csvRows(text)
        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { r in
            Dictionary(header.enumerated().map { ($1, $0 < r.count ? r[$0] : "") }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// CSV text → rows of fields, blank lines skipped.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? it.next() {
            pending = nil
            if quoted {
                if ch == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == "," { row.append(field); field = "" }
            else if ch == "\n" || ch == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if ch == "\r" { continue }
            else { field.append(ch) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { $0 != [""] }
    }

    /// A list of records → header row + one row per record (columns in first-seen, sorted-per-record order).
    static func table(_ value: Any) throws -> [[Any]] {
        guard let rows = value as? [[String: Any]] else { throw Engine.Failed(tool: "data", detail: "This file isn't a list of rows, so it can't become a spreadsheet.") }
        var keys: [String] = []
        for r in rows { for k in r.keys.sorted() where !keys.contains(k) { keys.append(k) } }
        return [keys] + rows.map { r in keys.map { r[$0] ?? "" } }
    }

    /// Header row + rows → records, the shape JSON / YAML outputs expect.
    static func rowsToRecords(_ rows: [[Any]]) -> [[String: Any]] {
        guard let header = rows.first?.map({ "\($0)" }) else { return [] }
        return rows.dropFirst().filter { !$0.allSatisfy { "\($0)".isEmpty } }.map { r in
            Dictionary(header.enumerated().map { ($1, $0 < r.count ? r[$0] : "") }, uniquingKeysWith: { a, _ in a })
        }
    }

    static func csv(_ value: Any) throws -> String { csv(rows: try table(value)) }

    static func csv(rows: [[Any]]) -> String {
        func esc(_ v: Any) -> String {
            let s = (v as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? ($0.boolValue ? "TRUE" : "FALSE") : nil } ?? "\(v)"
            return s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        return rows.map { $0.map(esc).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func yaml(_ v: Any, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        func scalar(_ x: Any) -> String {
            if let s = x as? String {
                let needsQuote = s.isEmpty || s.contains(where: { ":#{}[],&*!|>'\"%@`\n".contains($0) }) || ["true", "false", "null", "yes", "no"].contains(s.lowercased()) || Double(s) != nil
                return needsQuote ? "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\"" : s
            }
            if let n = x as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue }
            if x is NSNull { return "null" }
            if let d = x as? Date { return ISO8601DateFormatter().string(from: d) }
            return "\"\(x)\""
        }
        if let dict = v as? [String: Any] {
            if dict.isEmpty { return pad + "{}\n" }
            return dict.keys.sorted().map { k in
                let val = dict[k]!
                if (val is [String: Any] && !(val as! [String: Any]).isEmpty) || (val is [Any] && !(val as! [Any]).isEmpty) {
                    return "\(pad)\(scalar(k)):\n" + yaml(val, indent: indent + 1)
                }
                return "\(pad)\(scalar(k)): \(val is [Any] ? "[]" : val is [String: Any] ? "{}" : scalar(val))\n"
            }.joined()
        }
        if let arr = v as? [Any] {
            if arr.isEmpty { return pad + "[]\n" }
            return arr.map { item in
                if item is [String: Any] || item is [Any] {
                    let inner = yaml(item, indent: indent + 1)
                    return pad + "- " + inner.dropFirst((indent + 1) * 2)
                }
                return "\(pad)- \(scalar(item))\n"
            }.joined()
        }
        return pad + scalar(v) + "\n"
    }

    static func jsonSafe(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return d.mapValues(jsonSafe) }
        if let a = v as? [Any] { return a.map(jsonSafe) }
        if let date = v as? Date { return ISO8601DateFormatter().string(from: date) }
        if let data = v as? Data { return data.base64EncodedString() }
        return v
    }
}
