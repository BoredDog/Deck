import Foundation
import SwiftUI

/// "Get Deck ready": installs the basic helpers in the background with one progress bar.
@MainActor final class Setup: ObservableObject {
    static let shared = Setup()

    /// helper program → Homebrew package that provides it
    nonisolated static let basics: [(tool: String, formula: String)] = [
        ("ffmpeg", "ffmpeg"), ("aria2c", "aria2"), ("pandoc", "pandoc"), ("zstd", "zstd"), ("xz", "xz"),
        ("cjxl", "jpeg-xl"), ("oxipng", "oxipng"), ("flac", "flac"), ("qpdf", "qpdf"), ("gs", "ghostscript"),
        ("cwebp", "webp"), ("magick", "imagemagick"), ("7zz", "sevenzip"), ("heif-enc", "libheif"),
    ]

    struct AddOn: Identifiable {
        let id: String, name: String, detail: String, cask: String, tool: String, appPath: String, approxBytes: Int64
    }

    nonisolated static let addOns: [AddOn] = [
        AddOn(id: "office", name: "Office files", detail: "Word, Excel and PowerPoint to PDF, Excel ↔ CSV",
              cask: "libreoffice", tool: "soffice", appPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice", approxBytes: 700_000_000),
        AddOn(id: "ebooks", name: "Kindle ebooks", detail: "EPUB ↔ MOBI and AZW3",
              cask: "calibre", tool: "ebook-convert", appPath: "/Applications/calibre.app/Contents/MacOS/ebook-convert", approxBytes: 300_000_000),
    ]

    @Published var working = false
    @Published var progress = 0.0
    @Published var message = ""
    @Published var busyAddOn: String?

    var missing: [String] { Self.basics.filter { !Engine.has($0.tool) }.map(\.formula) }
    var ready: Bool { missing.isEmpty }
    var hasHomebrew: Bool { Engine.has("brew") }

    func getReady() async {
        let todo = missing
        guard !todo.isEmpty, !working else { return }
        working = true
        defer { working = false }
        for (i, formula) in todo.enumerated() {
            message = "Setting up \(i + 1) of \(todo.count)…"
            progress = Double(i) / Double(todo.count)
            _ = try? await Engine.run("brew", ["install", "--quiet", formula])
        }
        progress = 1
        let left = missing.count
        message = left == 0 ? "All set." : "\(left) helper\(left == 1 ? "" : "s") couldn't be set up. Try again later."
        objectWillChange.send()
    }

    static func installed(_ a: AddOn) -> Bool {
        FileManager.default.isExecutableFile(atPath: a.appPath)
    }

    static var freeSpace: Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func toggle(_ a: AddOn) async {
        busyAddOn = a.id
        defer { busyAddOn = nil; objectWillChange.send() }
        let verb = Self.installed(a) ? "uninstall" : "install"
        _ = try? await Engine.run("brew", [verb, "--cask", "--quiet", a.cask])
    }
}

struct SetupCard: View {
    @ObservedObject var setup = Setup.shared
    @Environment(\.accent) private var accent

    var body: some View {
        Tile(style: .accent) {
            TileLabel(text: "Get Deck ready")
            if !setup.hasHomebrew {
                Text("Deck uses a free helper installer called Homebrew. Install it once from brew.sh, then come back.")
                    .font(F.body).foregroundStyle(accent.soft)
                Button("Open brew.sh") { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }.buttonStyle(.pill)
            } else if setup.working {
                Text(setup.message).font(F.body).foregroundStyle(accent.soft)
                Bar4(value: setup.progress)
            } else if setup.ready {
                Text("Everything is set up.").font(F.body).foregroundStyle(accent.soft)
            } else {
                Text("A few free helpers make converting, shrinking and downloading work. One click, runs in the background.")
                    .font(F.body).foregroundStyle(accent.soft)
                Button("Get Deck ready") { Task { await setup.getReady() } }.buttonStyle(.pill)
                if !setup.message.isEmpty { Text(setup.message).font(F.label).foregroundStyle(C.text2) }
            }
        }
    }
}
