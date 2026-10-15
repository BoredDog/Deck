import SwiftUI
import PDFKit

/// Merge, split, rearrange pages, or turn pictures into one PDF. New files go next to the originals.
struct PDFToolsView: View {
    private enum Mode: String, CaseIterable { case merge = "Merge", split = "Split", pages = "Rearrange pages", images = "Pictures to PDF" }
    @State private var mode = Mode.merge
    @State private var files: [URL] = []
    @State private var pages: [PDFPage] = []
    @State private var everyPage = true
    @State private var from = 1
    @State private var to = 1
    @State private var result: URL?
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PillPicker(selection: $mode, options: Mode.allCases.map { ($0.rawValue, $0) })
                .onChange(of: mode) { files = []; pages = []; result = nil; message = "" }
            DropZone(prompt: prompt, allowFolders: false, multiple: mode == .merge || mode == .images) { add($0) }
            if !files.isEmpty || !pages.isEmpty {
                Tile {
                    switch mode {
                    case .merge, .images: fileList
                    case .split: splitOptions
                    case .pages: pageGrid
                    }
                    HStack {
                        Button(action: run) { Text(actionTitle) }.buttonStyle(.primary)
                        if let result { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result]) }.buttonStyle(.pill) }
                        Text(message).font(F.label).foregroundStyle(C.text2)
                    }
                }
            }
        }
    }

    private var prompt: String {
        switch mode {
        case .merge: "Drop the PDFs to put together"
        case .split: "Drop a PDF to split"
        case .pages: "Drop a PDF to rearrange"
        case .images: "Drop pictures to make one PDF"
        }
    }

    private var actionTitle: String {
        switch mode {
        case .merge: "Merge into one PDF"
        case .split: "Split"
        case .pages: "Save a copy"
        case .images: "Make PDF"
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.offset) { i, url in
                Row(divider: i < files.count - 1) {
                    Text("\(i + 1)").font(F.mono(11)).foregroundStyle(C.muted).frame(width: 20)
                    Text(url.lastPathComponent).font(F.body).lineLimit(1)
                    Spacer()
                    Button { files.swapAt(i, i - 1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.pill).disabled(i == 0)
                    Button { files.swapAt(i, i + 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.pill).disabled(i == files.count - 1)
                    Button { files.remove(at: i) } label: { Image(systemName: "xmark") }.buttonStyle(.pill)
                }
            }
        }
    }

    private var splitOptions: some View {
        let count = PDFDocument(url: files[0])?.pageCount ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(files[0].lastPathComponent) · \(count) pages").font(F.body)
            PillPicker(selection: $everyPage, options: [("One file per page", true), ("Just some pages", false)])
            if !everyPage {
                HStack {
                    Text("From page")
                    PillStepper(value: $from, range: 1...count)
                    Text("to")
                    PillStepper(value: $to, range: from...max(from, count))
                }
                .font(F.body)
            }
        }
    }

    private var pageGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
            ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                VStack(spacing: 6) {
                    Image(nsImage: page.thumbnail(of: NSSize(width: 110, height: 140), for: .mediaBox))
                        .frame(width: 110, height: 140)
                    Text("\(i + 1)").font(F.mono(11)).foregroundStyle(C.muted)
                    HStack(spacing: 4) {
                        Button { move(i, -1) } label: { Image(systemName: "arrow.left") }.disabled(i == 0)
                        Button { page.rotation += 90; pages = pages } label: { Image(systemName: "rotate.right") }
                        Button { pages.remove(at: i) } label: { Image(systemName: "trash") }
                        Button { move(i, 1) } label: { Image(systemName: "arrow.right") }.disabled(i == pages.count - 1)
                    }
                    .buttonStyle(.plain).foregroundStyle(C.text2)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(C.bg))
            }
        }
    }

    private func move(_ i: Int, _ by: Int) { pages.swapAt(i, i + by) }

    private func add(_ urls: [URL]) {
        result = nil; message = ""
        switch mode {
        case .merge: files += urls.filter { $0.pathExtension.lowercased() == "pdf" }
        case .images: files += urls
        case .split:
            files = Array(urls.prefix(1))
            to = PDFDocument(url: urls[0])?.pageCount ?? 1
            from = 1
        case .pages:
            files = Array(urls.prefix(1))
            guard let doc = PDFDocument(url: urls[0]) else { message = "This PDF can't be opened."; return }
            pages = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.copy() as? PDFPage }
        }
    }

    private func run() {
        guard let first = files.first else { return }
        let folder = first.deletingLastPathComponent(), base = first.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        do {
            switch mode {
            case .merge:
                let doc = PDFDocument()
                for url in files {
                    guard let d = PDFDocument(url: url) else { continue }
                    for i in 0..<d.pageCount { if let p = d.page(at: i)?.copy() as? PDFPage { doc.insert(p, at: doc.pageCount) } }
                }
                result = try write(doc, fm.freeURL(in: folder, name: "\(base) (merged)", ext: "pdf"))
                message = "\(doc.pageCount) pages"
            case .split:
                guard let d = PDFDocument(url: first) else { throw Engine.Failed(tool: "pdfkit", detail: "unreadable") }
                let ranges = everyPage ? (0..<d.pageCount).map { $0...$0 } : [(min(from, to) - 1)...(max(from, to) - 1)]
                for r in ranges {
                    let part = PDFDocument()
                    for i in r { if let p = d.page(at: i)?.copy() as? PDFPage { part.insert(p, at: part.pageCount) } }
                    let name = r.count == 1 ? "\(base) page \(r.lowerBound + 1)" : "\(base) pages \(r.lowerBound + 1)-\(r.upperBound + 1)"
                    result = try write(part, fm.freeURL(in: folder, name: name, ext: "pdf"))
                }
                message = "Made \(ranges.count) file\(ranges.count == 1 ? "" : "s")"
            case .pages:
                let doc = PDFDocument()
                for p in pages { doc.insert(p.copy() as! PDFPage, at: doc.pageCount) }
                result = try write(doc, fm.freeURL(in: folder, name: "\(base) (edited)", ext: "pdf"))
                message = "\(doc.pageCount) pages"
            case .images:
                let out = fm.freeURL(in: folder, name: "\(base) (pictures)", ext: "pdf")
                try PDFTools.imagesToPDF(files, out: out)
                result = out
                message = "\(files.count) pictures"
            }
        } catch {
            message = "Something went wrong. Your original files are untouched."
        }
    }

    private func write(_ doc: PDFDocument, _ url: URL) throws -> URL {
        guard doc.pageCount > 0, doc.write(to: url) else { throw Engine.Failed(tool: "pdfkit", detail: "write") }
        return url
    }
}
