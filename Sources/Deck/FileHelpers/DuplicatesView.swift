import SwiftUI
import CryptoKit

enum DuplicateFinder {
    /// Groups identical files: same size first, then the same fingerprint. Only same-size files are ever read.
    static func groups(_ files: [(url: URL, size: Int64)], hash: (URL) -> String?) -> [[URL]] {
        // Split into steps with explicit types: older Swift compilers time out on the one-expression version.
        let bySize: [Int64: [(url: URL, size: Int64)]] = Dictionary(grouping: files.filter { $0.size > 0 }, by: { $0.size })
        var result: [[URL]] = []
        for same in bySize.values where same.count > 1 {
            var byHash: [String: [URL]] = [:]
            for f in same {
                if let h = hash(f.url) { byHash[h, default: []].append(f.url) }
            }
            result += byHash.values.filter { $0.count > 1 }
        }
        return result
    }

    /// SHA-256 of a file, read 1 MB at a time.
    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func scan(_ folders: [URL]) -> [[URL]] {
        var files: [(url: URL, size: Int64)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        for folder in folders {
            let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = e?.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                files.append((url, Int64(v.fileSize ?? 0)))
            }
        }
        return groups(files, hash: sha256)
    }
}

struct DuplicatesView: View {
    private struct DupSet: Identifiable {
        let id = UUID()
        var files: [(url: URL, date: Date)]
        var keep: URL
        let size: Int64
        var extras: [URL] { files.map(\.url).filter { $0 != keep } }
    }

    @State private var folders: [URL] = []
    @State private var groups: [DupSet] = []
    @State private var busy = false
    @State private var freed: Int64?

    private var extraBytes: Int64 { groups.reduce(0) { $0 + $1.size * Int64($1.extras.count) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropZone(prompt: "Drop folders to check for copies", allowFolders: true) { urls in folders = urls; find() }
            if busy { HStack { ProgressView().controlSize(.small); Text("Looking for copies…").font(F.body).foregroundStyle(C.text2) } }
            if let freed { Text("Freed \(bytes(freed))").font(F.ui(16, medium: true)).foregroundStyle(C.lime) }
            if !busy && !folders.isEmpty && groups.isEmpty && freed == nil {
                Text("No copies found.").font(F.body).foregroundStyle(C.text2)
            }
            if !groups.isEmpty {
                HStack {
                    Button("Move extras to Trash") { trash() }.buttonStyle(.primary)
                    Text("\(groups.count) sets of copies · \(bytes(extraBytes)) to free").font(F.mono(11)).foregroundStyle(C.text2)
                }
                Text("Deck keeps the newest copy in each set. Click another one to keep it instead.").font(F.label).foregroundStyle(C.text2)
                ForEach($groups) { $g in
                    Tile {
                        TileLabel(text: "\(g.files.count) copies · \(bytes(g.size)) each")
                        ForEach(Array(g.files.enumerated()), id: \.offset) { i, f in
                            Button { g.keep = f.url } label: {
                                Row(divider: i < g.files.count - 1) {
                                    Image(systemName: g.keep == f.url ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(g.keep == f.url ? C.lime : C.muted)
                                    Text(f.url.path).font(F.body).lineLimit(1).truncationMode(.head)
                                    Spacer()
                                    Text(f.date.formatted(date: .abbreviated, time: .shortened)).font(F.mono(11)).foregroundStyle(C.muted)
                                    Text(g.keep == f.url ? "keep" : "trash").font(F.mono(11)).foregroundStyle(C.text2).frame(width: 40)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func find() {
        busy = true; groups = []; freed = nil
        let folders = folders
        Task.detached {
            let found = DuplicateFinder.scan(folders).map { urls -> DupSet in
                let dated = urls.map { u in (url: u, date: (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                    .sorted { $0.date > $1.date }
                return DupSet(files: dated, keep: dated[0].url, size: FileManager.default.size(of: dated[0].url))
            }
            .sorted { $0.size > $1.size }
            await MainActor.run { groups = found; busy = false }
        }
    }

    private func trash() {
        var total: Int64 = 0
        for g in groups { for u in g.extras where (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil { total += g.size } }
        groups = []
        freed = total
        if total > 0 { Store.log("Moved duplicate files to the Trash", kind: "info", saved: total) }
    }
}
