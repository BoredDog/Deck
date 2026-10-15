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

    /// An opt-in helper. Apps come as a Homebrew cask (and live in /Applications), command-line helpers as a formula.
    struct AddOn: Identifiable {
        let id: String, name: String, detail: String
        var cask: String? = nil, formula: String? = nil
        let tool: String
        var appPath: String? = nil
        let approxBytes: Int64
    }

    nonisolated static let addOns: [AddOn] = [
        AddOn(id: "office", name: "Office files", detail: "Word, Excel and PowerPoint to PDF, slides to pictures",
              cask: "libreoffice", tool: "soffice", appPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice", approxBytes: 700_000_000),
        AddOn(id: "ebooks", name: "Kindle ebooks", detail: "EPUB ↔ MOBI and AZW3",
              cask: "calibre", tool: "ebook-convert", appPath: "/Applications/calibre.app/Contents/MacOS/ebook-convert", approxBytes: 300_000_000),
        AddOn(id: "latex", name: "LaTeX pack", detail: "Exact PDFs from LaTeX. Downloads the LaTeX pieces it needs the first time you use it.",
              formula: "tectonic", tool: "tectonic", approxBytes: 40_000_000),
        AddOn(id: "fonts", name: "Fonts pack", detail: "Desktop fonts ↔ web fonts (WOFF, WOFF2). Same font, different wrapper.",
              formula: "fonttools", tool: "fonttools", approxBytes: 80_000_000),
        AddOn(id: "videolinks", name: "Save video from a link", detail: "Only for videos you have the right to download.",
              formula: "yt-dlp", tool: "yt-dlp", approxBytes: 120_000_000),
    ]

    nonisolated static func addOn(_ id: String) -> AddOn { addOns.first { $0.id == id }! }

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
            if (try? await Engine.run("brew", ["install", "--quiet", formula])) != nil { Self.remember(formula, true) }
        }
        progress = 1
        let left = missing.count
        message = left == 0 ? "All set." : "\(left) helper\(left == 1 ? "" : "s") couldn't be set up. Try again later."
        objectWillChange.send()
    }

    nonisolated static func installed(_ a: AddOn) -> Bool {
        a.appPath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? Engine.has(a.tool)
    }

    static var freeSpace: Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Homebrew packages Deck installed itself. Deck only ever removes these, never something you installed.
    nonisolated static var deckInstalled: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "deckInstalled") ?? []) }

    nonisolated static func remember(_ pkg: String, _ installed: Bool) {
        var set = deckInstalled
        if installed { set.insert(pkg) } else { set.remove(pkg) }
        UserDefaults.standard.set(set.sorted(), forKey: "deckInstalled")
    }

    nonisolated static func installedByDeck(_ a: AddOn) -> Bool { deckInstalled.contains(a.cask ?? a.formula!) }

    func toggle(_ a: AddOn) async {
        busyAddOn = a.id
        defer { busyAddOn = nil; objectWillChange.send() }
        let removing = Self.installed(a)
        guard !removing || Self.installedByDeck(a) else { return }
        let name = a.cask ?? a.formula!
        let pkg = a.cask.map { ["--cask", $0] } ?? [name]
        if (try? await Engine.run("brew", [removing ? "uninstall" : "install", "--quiet"] + pkg)) != nil { Self.remember(name, !removing) }
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
