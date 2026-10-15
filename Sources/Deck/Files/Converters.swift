import Foundation
import PDFKit
import AppKit

enum Kind: String { case image, video, audio, document, pdf, subtitle, data, archive, office, ebook }

/// A thing a file can become, named by outcome.
struct Target: Hashable, Identifiable {
    let id: String      // unique key, e.g. "video.iphone"
    let name: String    // what the user reads
    let ext: String
    var detail: String = ""
    var addOn: String?  // needs an opt-in add-on
}

enum Converters {
    static let kinds: [Kind: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "jxl", "gif", "tif", "tiff", "bmp", "ico", "icns",
                 "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "psd", "svg"],
        .video: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mts", "m2ts", "3gp", "mpg", "mpeg", "ts"],
        .audio: ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "opus", "ogg", "wma", "caf", "alac"],
        .document: ["md", "markdown", "txt", "html", "htm", "rtf", "odt", "epub", "tex", "ipynb", "org", "rst", "doc", "webarchive"],
        .pdf: ["pdf"],
        .subtitle: ["srt", "vtt", "ass", "ssa"],
        .data: ["csv", "json", "plist"],
        .archive: ["zip", "7z", "rar", "tar", "gz", "tgz", "zst", "xz", "bz2"],
        .office: ["docx", "xlsx", "xls", "pptx", "ppt", "ods", "odp"],
        .ebook: ["mobi", "azw3", "azw"],
    ]

    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        return kinds.first { $0.value.contains(ext) }?.key
    }

    static let office = Setup.addOns[0].id, ebooks = Setup.addOns[1].id

    static func targets(for url: URL) -> [Target] {
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
                Target(id: "img.icns", name: "Mac app icon", ext: "icns"),
                Target(id: "img.pdf", name: "PDF", ext: "pdf"),
            ]
        case .video:
            t = [
                Target(id: "video.mp4", name: "MP4", ext: "mp4", detail: "Plays everywhere"),
                Target(id: "video.iphone", name: "For iPhone", ext: "mp4", detail: "Smaller, fast to make"),
                Target(id: "video.av1", name: "Smallest MP4", ext: "mp4", detail: "Takes longer"),
                Target(id: "video.share", name: "Fit under 25 MB", ext: "mp4", detail: "WhatsApp, Discord, email"),
                Target(id: "video.mov", name: "MOV", ext: "mov"),
                Target(id: "video.prores", name: "For editing", ext: "mov", detail: "Big, best for editing apps"),
                Target(id: "video.mkv", name: "MKV", ext: "mkv", detail: "Instant, same quality"),
                Target(id: "video.webm", name: "WebM", ext: "webm", detail: "For websites"),
                Target(id: "video.m4v", name: "M4V", ext: "m4v"),
                Target(id: "video.avi", name: "AVI", ext: "avi", detail: "Older players"),
                Target(id: "video.gif", name: "GIF", ext: "gif", detail: "Short animated clip"),
                Target(id: "video.audio", name: "Just the audio", ext: "m4a"),
            ]
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
            ]
        case .document:
            t = [
                Target(id: "doc.pdf", name: "PDF", ext: "pdf"),
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
                 Target(id: "data.yaml", name: "YAML", ext: "yaml"), Target(id: "data.plist", name: "Property list", ext: "plist")]
        case .archive:
            t = [Target(id: "arc.extract", name: "Unpack", ext: "", detail: "Get the files out")]
        case .office:
            t = [Target(id: "office.pdf", name: "PDF", ext: "pdf", addOn: office),
                 Target(id: "office.csv", name: "Spreadsheet (CSV)", ext: "csv", addOn: office),
                 Target(id: "office.docx", name: "Word", ext: "docx", addOn: office)]
            if ext == "docx" { t.insert(contentsOf: [Target(id: "doc.md", name: "Markdown", ext: "md"), Target(id: "doc.html", name: "Web page", ext: "html"),
                                                    Target(id: "doc.pdf", name: "PDF (simple)", ext: "pdf"), Target(id: "doc.txt", name: "Plain text", ext: "txt")], at: 0) }
        case .ebook:
            t = [Target(id: "ebook.epub", name: "EPUB", ext: "epub", addOn: ebooks), Target(id: "ebook.pdf", name: "PDF", ext: "pdf", addOn: ebooks)]
        case nil:
            t = []
        }
        // Folders and any file can be packed into an archive.
        t += [Target(id: "arc.zip", name: "ZIP", ext: "zip", detail: "Opens anywhere"),
              Target(id: "arc.7z", name: "7z", ext: "7z", detail: "Smaller archive")]
        let same = ext == "jpeg" ? "jpg" : ext == "tif" ? "tiff" : ext
        return t.filter { !($0.ext == same && !$0.id.hasPrefix("video.") && !$0.id.hasPrefix("audio.")) && !(kind(of: url) == .data && $0.ext == same) }
    }

    /// Converts one file. Returns the new file's location (the original is never touched).
    static func convert(_ src: URL, to t: Target, progress: @escaping (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let folder = src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent
        let out = fm.freeURL(in: folder, name: base, ext: t.ext)
        let inExt = src.pathExtension.lowercased()
        let ff = ["-hide_banner", "-nostdin", "-y", "-protocol_whitelist", "file,pipe", "-i", src.path]

        func ffmpeg(_ args: [String]) async throws {
            let duration = await mediaDuration(src)
            try await Engine.run("ffmpeg", ff + args + ["-progress", "pipe:1", "-nostats", out.path]) { line in
                if line.hasPrefix("out_time_us="), duration > 0, let us = Double(line.dropFirst(12)) {
                    progress(min(1, us / 1_000_000 / duration))
                }
            }
        }

        do {
        switch t.id {
        // Images
        case "img.icns" where inExt != "svg", "img.jpg" where ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "psd", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"].contains(inExt),
             "img.png" where inExt != "svg" && inExt != "jxl" && inExt != "webp" && inExt != "avif",
             "img.heic" where inExt != "svg", "img.tiff" where inExt != "svg", "img.bmp" where inExt != "svg", "img.pdf" where inExt != "svg":
            let fmt = ["img.jpg": "jpeg", "img.png": "png", "img.heic": "heic", "img.tiff": "tiff", "img.bmp": "bmp", "img.pdf": "pdf", "img.icns": "icns"][t.id]!
            try await Engine.run("sips", ["-s", "format", fmt, src.path, "--out", out.path])
        case "img.jxl":
            if inExt == "jpg" || inExt == "jpeg" || inExt == "png" {
                try await Engine.run("cjxl", [src.path, out.path])
            } else {
                try await Engine.run("magick", [src.path, out.path])
            }
        case "img.webp" where inExt == "png" || inExt == "jpg" || inExt == "jpeg":
            try await Engine.run("cwebp", ["-q", "85", src.path, "-o", out.path])
        case let id where id.hasPrefix("img."):
            try await Engine.run("magick", [src.path + (inExt == "gif" ? "[0]" : ""), out.path])

        // Video
        case "video.mp4", "video.m4v": try await ffmpeg(["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"])
        case "video.iphone": try await ffmpeg(["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"])
        case "video.av1": try await ffmpeg(["-c:v", "libsvtav1", "-crf", "32", "-preset", "8", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"])
        case "video.share":
            // Bitrate chosen so the whole file lands just under 25 MB.
            let d = max(await mediaDuration(src), 1)
            let kbps = max(150, Int((24.0 * 8 * 1024) / d) - 128)
            try await ffmpeg(["-c:v", "libx264", "-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k",
                              "-vf", "scale='min(1280,iw)':-2", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart"])
        case "video.mov": try await ffmpeg(["-c:v", "libx264", "-crf", "20", "-c:a", "aac", "-b:a", "192k"])
        case "video.prores": try await ffmpeg(["-c:v", "prores_videotoolbox", "-profile:v", "hq", "-c:a", "pcm_s16le"])
        case "video.mkv": try await ffmpeg(["-map", "0", "-c", "copy"])
        case "video.webm": try await ffmpeg(["-c:v", "libsvtav1", "-crf", "34", "-preset", "8", "-c:a", "libopus", "-b:a", "128k"])
        case "video.avi": try await ffmpeg(["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"])
        case "video.gif": try await ffmpeg(["-vf", "fps=12,scale='min(480,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"])
        case "video.audio": try await ffmpeg(["-vn", "-c:a", "aac", "-b:a", "256k"])

        // Audio
        case "audio.mp3": try await ffmpeg(["-vn", "-c:a", "libmp3lame", "-q:a", "2"])
        case "audio.aac": try await ffmpeg(["-vn", "-c:a", "aac", "-b:a", "256k"])
        case "audio.alac": try await ffmpeg(["-vn", "-c:a", "alac"])
        case "audio.flac": try await ffmpeg(["-vn", "-c:a", "flac", "-compression_level", "8"])
        case "audio.wav": try await ffmpeg(["-vn", "-c:a", "pcm_s16le"])
        case "audio.aiff": try await ffmpeg(["-vn", "-c:a", "pcm_s16be"])
        case "audio.opus", "audio.ogg": try await ffmpeg(["-vn", "-c:a", "libopus", "-b:a", "128k"])

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
                try await Engine.run("pandoc", args)
            }

        // PDF
        case "pdf.png":
            try fm.createDirectory(at: out.deletingPathExtension(), withIntermediateDirectories: true)
            try PDFTools.pagesToImages(src, into: out.deletingPathExtension(), progress: progress)
            return out.deletingPathExtension()
        case "pdf.txt":
            guard let doc = PDFDocument(url: src) else { throw Engine.Failed(tool: "pdfkit", detail: "unreadable") }
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)

        // Data
        case let id where id.hasPrefix("data."):
            try DataConvert.convert(src, toExt: t.ext, out: out)

        // Archives
        case "arc.zip":
            try await Engine.run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, out.path])
        case "arc.7z":
            try await Engine.run("7zz", ["a", "-mx=7", out.path, src.path])
        case "arc.extract":
            let dest = fm.freeURL(in: folder, name: base.replacingOccurrences(of: ".tar", with: ""), ext: "")
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            if Engine.has("7zz") && !["gz", "tgz", "xz", "bz2", "zst", "tar"].contains(inExt) {
                try await Engine.run("7zz", ["x", "-y", "-o" + dest.path, src.path])
            } else if inExt == "zst" {
                try await Engine.pipeline([("zstd", ["-d", "-c", "--long=31", src.path]), ("tar", ["-xf", "-", "-C", dest.path])])
            } else {
                try await Engine.run("ditto", ["-x", "-k", src.path, dest.path].filter { inExt == "zip" || $0 != "-k" })
            }
            return dest

        // Optional add-ons
        case "office.pdf", "office.docx", "office.csv", "pdf.docx":
            let soffice = Setup.addOns[0].appPath
            let profile = fm.temporaryDirectory.appendingPathComponent("deck-lo-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: profile) }
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let filter = t.id == "pdf.docx" ? "docx:\"MS Word 2007 XML\"" : t.ext
            var args = ["-env:UserInstallation=file://" + profile.path, "--headless", "--norestore", "--nologo", "--convert-to", filter, "--outdir", tmp.path]
            if t.id == "pdf.docx" { args.insert("--infilter=writer_pdf_import", at: 3) }
            try await runApp(soffice, args + [src.path])
            guard let made = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil).first else {
                throw Engine.Failed(tool: "soffice", detail: "no output")
            }
            try fm.moveItem(at: made, to: out)
        case let id where id.hasPrefix("ebook."):
            try await runApp(Setup.addOns[1].appPath, [src.path, out.path])

        default:
            throw Engine.Failed(tool: "deck", detail: "unsupported \(t.id)")
        }
        } catch {
            // Don't leave half-written files behind.
            try? fm.removeItem(at: out)
            throw error
        }
        progress(1)
        return out
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
        let body = try await Engine.run("pandoc", ["--sandbox", "-t", "html5", src.path])
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
    static func render(html: String, baseURL: URL, to out: URL) async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1100))
        let nav = NavDelegate()
        web.navigationDelegate = nav
        // Documents stay offline: no network loads for the page.
        web.configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            nav.done = { c.resume() }
            web.loadHTMLString(html, baseURL: baseURL)
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
        default: throw Engine.Failed(tool: "data", detail: "unknown input")
        }
        let result: Data
        switch toExt {
        case "json": result = try JSONSerialization.data(withJSONObject: jsonSafe(value), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        case "plist": result = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        case "yaml": result = Data(yaml(value).utf8)
        case "csv": result = Data(try csv(value).utf8)
        default: throw Engine.Failed(tool: "data", detail: "unknown output")
        }
        try result.write(to: out)
    }

    static func parseCSV(_ text: String) -> [[String: String]] {
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
        guard let header = rows.first else { return [] }
        return rows.dropFirst().filter { $0 != [""] }.map { r in
            Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0 < r.count ? r[$0] : "") })
        }
    }

    static func csv(_ value: Any) throws -> String {
        guard let rows = value as? [[String: Any]] else { throw Engine.Failed(tool: "data", detail: "This file isn't a list of rows, so it can't become a spreadsheet.") }
        var keys: [String] = []
        for r in rows { for k in r.keys.sorted() where !keys.contains(k) { keys.append(k) } }
        func esc(_ v: Any?) -> String {
            let s = v.map { "\($0)" } ?? ""
            return s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        return ([keys.map { esc($0) }.joined(separator: ",")] + rows.map { r in keys.map { esc(r[$0]) }.joined(separator: ",") }).joined(separator: "\n") + "\n"
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

    private static func jsonSafe(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return d.mapValues(jsonSafe) }
        if let a = v as? [Any] { return a.map(jsonSafe) }
        if let date = v as? Date { return ISO8601DateFormatter().string(from: date) }
        if let data = v as? Data { return data.base64EncodedString() }
        return v
    }
}
