import SwiftUI
import UniformTypeIdentifiers

/// Sorts new files in Downloads into folders by kind, and clears out old ones (to the Trash).
@MainActor final class Tidy: ObservableObject {
    static let shared = Tidy()
    static let folders = ["Images", "Videos", "Audio", "Documents", "Archives", "Installers", "Other"]
    static let unfinished: Set<String> = ["download", "crdownload", "part", "partial", "aria2", "tmp"]

    @AppStorage("tidyOn") var on = false { didSet { objectWillChange.send(); on ? start() : stop() } }
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    /// Which folder a file type belongs in.
    nonisolated static func folder(for ext: String) -> String {
        let e = ext.lowercased()
        if ["dmg", "pkg", "mpkg", "app", "iso"].contains(e) { return "Installers" }
        guard let t = UTType(filenameExtension: e) else { return "Other" }
        if t.conforms(to: .image) { return "Images" }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return "Videos" }
        if t.conforms(to: .audio) { return "Audio" }
        if t.conforms(to: .archive) || ["zip", "rar", "7z", "gz", "tgz", "xz", "zst", "bz2", "tar"].contains(e) { return "Archives" }
        if t.conforms(to: .pdf) || t.conforms(to: .text) || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet)
            || t.conforms(to: .rtf) || ["doc", "docx", "odt", "pages", "key", "numbers", "epub", "xls", "xlsx", "ppt", "pptx"].contains(e) {
            return "Documents"
        }
        return "Other"
    }

    func startIfOn() { if on { start() } }

    private func start() {
        guard source == nil else { return }
        if UserDefaults.standard.object(forKey: "tidySince") == nil { UserDefaults.standard.set(Date.now, forKey: "tidySince") }
        let fd = open(downloads.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { Tidy.shared.later(2) } }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
        later(0)
    }

    private func stop() {
        source?.cancel(); source = nil
        UserDefaults.standard.removeObject(forKey: "tidySince")
    }

    /// Waits a moment so files that are still arriving can finish.
    private func later(_ seconds: Double) {
        pending?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { Tidy.shared.sortNew() } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func sortNew() {
        guard on, let since = UserDefaults.standard.object(forKey: "tidySince") as? Date else { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        let items = (try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        let names = Set(items.map(\.lastPathComponent))
        var busy = false
        for url in items {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  (v.addedToDirectoryDate ?? .distantPast) > since,
                  !Self.unfinished.contains(url.pathExtension.lowercased()),
                  !names.contains(url.lastPathComponent + ".aria2") else { continue }   // Deck's own downloads still in progress
            if let m = v.contentModificationDate, m > .now.addingTimeInterval(-5) { busy = true; continue }
            let folder = downloads.appendingPathComponent(Self.folder(for: url.pathExtension))
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = fm.freeURL(in: folder, name: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
            try? fm.moveItem(at: url, to: dest)
        }
        if busy { later(5) }
    }

    /// Files in Downloads (and its kind folders) not touched for `days` days.
    func old(days: Int = 30) -> [(url: URL, size: Int64)] {
        let fm = FileManager.default
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86400)
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let places = [downloads] + Self.folders.map { downloads.appendingPathComponent($0) }
        return places.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? [] }
            .filter { url in
                guard !(url.deletingLastPathComponent() == downloads && Self.folders.contains(url.lastPathComponent)) else { return false }
                let v = try? url.resourceValues(forKeys: Set(keys))
                return max(v?.addedToDirectoryDate ?? .distantPast, v?.contentModificationDate ?? .distantPast) < cutoff
            }
            .map { ($0, fm.size(of: $0)) }
    }
}

struct TidyView: View {
    @ObservedObject private var tidy = Tidy.shared
    @State private var old: [(url: URL, size: Int64)]?
    @State private var freed: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Tile {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Downloads tidy").font(F.ui(14, medium: true))
                        Text("New downloads go into folders: \(Tidy.folders.joined(separator: ", ")).").font(F.label).foregroundStyle(C.text2)
                    }
                    Spacer()
                    Toggle("Keep Downloads tidy", isOn: $tidy.on).labelsHidden().toggleStyle(.switch)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Tile {
                TileLabel(text: "Old files")
                Text("Find files in Downloads you haven't touched in 30 days. They go to the Trash, so you can still get them back.")
                    .font(F.body).foregroundStyle(C.text2)
                if let freed { Text("Freed \(bytes(freed))").font(F.ui(16, medium: true)).foregroundStyle(C.lime) }
                if let old {
                    if old.isEmpty { Text("Nothing older than 30 days.").font(F.body) }
                    VStack(spacing: 0) {
                        ForEach(Array(old.enumerated()), id: \.offset) { i, f in
                            Row(divider: i < old.count - 1) {
                                Text(f.url.lastPathComponent).font(F.body).lineLimit(1)
                                Spacer()
                                Text(bytes(f.size)).font(F.mono(11)).foregroundStyle(C.text2)
                            }
                        }
                    }
                    if !old.isEmpty {
                        Button("Move \(old.count) to Trash · \(bytes(old.reduce(0) { $0 + $1.size }))") { clean(old) }.buttonStyle(.primary)
                    }
                } else {
                    Button("Show old files") { old = tidy.old(); freed = nil }.buttonStyle(.pill)
                }
            }
        }
    }

    private func clean(_ files: [(url: URL, size: Int64)]) {
        var total: Int64 = 0
        for f in files where (try? FileManager.default.trashItem(at: f.url, resultingItemURL: nil)) != nil { total += f.size }
        old = nil
        freed = total
        if total > 0 { Store.log("Moved old downloads to the Trash", saved: total) }
    }
}
