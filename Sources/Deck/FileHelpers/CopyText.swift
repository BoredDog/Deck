import SwiftUI
import Vision
import PDFKit
import CoreText

/// Reads text out of pictures and scanned PDFs, on this Mac only.
enum OCR {
    static func lines(in image: CGImage) throws -> [VNRecognizedTextObservation] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([req])
        return req.results ?? []
    }

    static func text(in image: CGImage) throws -> String {
        try lines(in: image).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// A PDF page as a picture, at 2x so small print still reads well.
    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let turned = page.rotation % 180 != 0
        let size = NSSize(width: (turned ? box.height : box.width) * 2, height: (turned ? box.width : box.height) * 2)
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Pages that already have text are read directly; scanned pages go through OCR.
    static func text(inPDF url: URL, progress: (Int, Int) -> Void) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw Engine.Failed(tool: "pdfkit", detail: "unreadable") }
        var out: [String] = []
        for i in 0..<doc.pageCount {
            progress(i + 1, doc.pageCount)
            guard let page = doc.page(at: i) else { continue }
            if let s = page.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(s) }
            else if let img = render(page) { out.append(try text(in: img)) }
        }
        return out.joined(separator: "\n\n")
    }

    /// Writes "<name> (searchable).pdf": each page as a picture with invisible, selectable text on top.
    static func searchablePDF(_ url: URL, progress: (Int, Int) -> Void) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw Engine.Failed(tool: "pdfkit", detail: "unreadable") }
        let dest = FileManager.default.freeURL(in: url.deletingLastPathComponent(),
                                               name: url.deletingPathExtension().lastPathComponent + " (searchable)", ext: "pdf")
        guard let ctx = CGContext(dest as CFURL, mediaBox: nil, nil) else { throw Engine.Failed(tool: "pdf", detail: "can't write") }
        for i in 0..<doc.pageCount {
            progress(i + 1, doc.pageCount)
            guard let page = doc.page(at: i), let raw = render(page) else { continue }
            let image = jpeg(raw) ?? raw
            var rect = CGRect(x: 0, y: 0, width: CGFloat(raw.width) / 2, height: CGFloat(raw.height) / 2)
            ctx.beginPage(mediaBox: &rect)
            ctx.draw(image, in: rect)
            ctx.setTextDrawingMode(.invisible)
            for obs in try lines(in: raw) {
                guard let s = obs.topCandidates(1).first?.string else { continue }
                let box = VNImageRectForNormalizedRect(obs.boundingBox, Int(rect.width), Int(rect.height))
                let font = CTFontCreateWithName("Helvetica" as CFString, max(1, box.height * 0.85), nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: box.minX, y: box.minY + box.height * 0.15)
                if width > 0 { ctx.scaleBy(x: box.width / width, y: 1) }
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            ctx.endPage()
        }
        ctx.closePDF()
        return dest
    }

    /// Re-encodes the page picture as JPEG so the PDF stays a sensible size.
    private static func jpeg(_ img: CGImage) -> CGImage? {
        guard let data = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

struct CopyTextView: View {
    @State private var file: URL?
    @State private var text = ""
    @State private var status = ""
    @State private var busy = false
    @State private var made: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropZone(prompt: "Drop a picture or PDF to copy its text", allowFolders: false, multiple: false) { urls in
                if let u = urls.first { read(u) }
            }
            if !status.isEmpty { Text(status).font(F.mono(11)).foregroundStyle(C.text2) }
            if file != nil {
                Tile {
                    HStack {
                        TileLabel(text: file?.lastPathComponent ?? "")
                        Spacer()
                        if file?.pathExtension.lowercased() == "pdf" {
                            Button("Make searchable PDF") { makeSearchable() }.buttonStyle(.pill).disabled(busy)
                        }
                        if let made { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([made]) }.buttonStyle(.pill) }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            status = "Copied to the clipboard."
                        }
                        .buttonStyle(.primary).disabled(text.isEmpty)
                    }
                    TextEditor(text: $text).font(F.ui(13)).scrollContentBackground(.hidden).frame(minHeight: 300)
                }
            }
        }
    }

    private func read(_ url: URL) {
        file = url; text = ""; made = nil; busy = true; status = "Reading…"
        Task.detached {
            let result: String
            do {
                if url.pathExtension.lowercased() == "pdf" {
                    result = try OCR.text(inPDF: url) { i, n in Task { @MainActor in status = "Reading page \(i) of \(n)" } }
                } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    result = try OCR.text(in: img)
                } else { result = "" }
            } catch { result = "" }
            await MainActor.run {
                text = result; busy = false
                status = result.isEmpty ? "No text found in this file. Try a sharper picture or scan." : "\(result.split(whereSeparator: \.isWhitespace).count) words"
            }
        }
    }

    private func makeSearchable() {
        guard let url = file else { return }
        busy = true
        Task.detached {
            let out = try? OCR.searchablePDF(url) { i, n in Task { @MainActor in status = "Making page \(i) of \(n) searchable" } }
            await MainActor.run {
                busy = false; made = out
                status = out == nil ? "Couldn't make a searchable copy of this PDF." : "Saved \(out!.lastPathComponent)"
            }
        }
    }
}
