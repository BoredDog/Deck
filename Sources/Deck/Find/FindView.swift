import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers

struct Hit: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var size: Int64
    var modified: Date
    var isFolder: Bool

    /// Reads size/date for a path from the disk. nil if it's gone.
    init?(path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        self.path = path
        size = Int64(st.st_size)
        modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        isFolder = (st.st_mode & S_IFMT) == S_IFDIR
    }

    init(path: String, size: Int64, modified: Date, isFolder: Bool) {
        self.path = path; self.size = size; self.modified = modified; self.isFolder = isFolder
    }
}

enum FindKind: String, CaseIterable { case any = "Anything", folder = "Folders", image = "Images", video = "Videos", audio = "Music", document = "Documents", app = "Apps" }
enum FindSize: String, CaseIterable { case any = "Any size", big = "Over 100 MB", huge = "Over 1 GB" }
enum FindDate: String, CaseIterable { case any = "Any time", today = "Today", week = "This week", month = "This month", year = "This year" }

struct FindFilter: Equatable {
    var kind = FindKind.any, size = FindSize.any, date = FindDate.any

    func matches(_ h: Hit, now: Date = .now) -> Bool {
        switch size {
        case .any: break
        case .big: if h.isFolder || h.size <= 100_000_000 { return false }
        case .huge: if h.isFolder || h.size <= 1_000_000_000 { return false }
        }
        let days: Double? = switch date { case .any: nil; case .today: 1; case .week: 7; case .month: 31; case .year: 365 }
        if let days, h.modified < now.addingTimeInterval(-days * 86400) { return false }
        if kind == .any { return true }
        let ext = (h.path as NSString).pathExtension
        if kind == .app { return ext == "app" }
        if kind == .folder { return h.isFolder && ext != "app" }
        if h.isFolder { return false }
        guard let t = UTType(filenameExtension: ext) else { return false }
        switch kind {
        case .image: return t.conforms(to: .image)
        case .video: return t.conforms(to: .movie)
        case .audio: return t.conforms(to: .audio)
        default: return [.text, .pdf, .presentation, .spreadsheet, .rtf, .epub].contains { t.conforms(to: $0) }
                     || ["doc", "docx", "pages", "odt", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "md"].contains(ext.lowercased())
        }
    }
}

/// Full Disk Access can't be queried directly; reading a TCC-protected file is the standard tell.
func hasFullDiskAccess() -> Bool {
    let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
    if fd >= 0 { close(fd); return true }
    return false
}

@MainActor final class FindModel: ObservableObject {
    static let cap = 5000
    @Published var hits: [Hit] = []
    @Published var searching = false
    private var seen: Set<String> = []
    private var generation = 0   // late batches from a cancelled search are dropped
    private var query: NSMetadataQuery?
    private var catalog: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    func search(_ text: String) {
        cancel()
        hits = []; seen = []
        generation += 1
        let gen = generation
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true

        // Spotlight: instant, but skips hidden and system files.
        let mq = NSMetadataQuery()
        mq.predicate = NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey, "*\(q)*")
        mq.searchScopes = [NSMetadataQueryLocalComputerScope]
        let gather: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.takeSpotlight() } }
        observers = [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate, .NSMetadataQueryGatheringProgress]
            .map { NotificationCenter.default.addObserver(forName: $0, object: mq, queue: .main, using: gather) }
        query = mq
        mq.start()

        // Catalog search: everything on disk, streamed as it's found.
        catalog = Task.detached(priority: .userInitiated) { [self] in
            let send: @Sendable ([Hit]) async -> Void = { batch in await self.merge(batch, gen) }
            if !(await Catalog.searchfs(q, send: send)) { await Catalog.walk(q, send: send) }
            await MainActor.run { if !Task.isCancelled { self.searching = false } }
        }
    }

    func cancel() {
        catalog?.cancel()
        query?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query = nil
        searching = false
    }

    func remove(_ hit: Hit) { hits.removeAll { $0.path == hit.path } }

    private func takeSpotlight() {
        guard let mq = query else { return }
        mq.disableUpdates()
        let n = min(mq.resultCount, Self.cap)
        var batch: [Hit] = []
        for i in 0..<n {
            guard let item = mq.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String, !seen.contains(path) else { continue }
            let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
            let date = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date ?? .distantPast
            let folder = (item.value(forAttribute: NSMetadataItemContentTypeKey) as? String) == UTType.folder.identifier
            batch.append(Hit(path: path, size: size, modified: date, isFolder: folder))
        }
        mq.enableUpdates()
        merge(batch)
    }

    private func merge(_ batch: [Hit], _ gen: Int? = nil) {
        guard gen == nil || gen == generation else { return }
        guard hits.count < Self.cap else { catalog?.cancel(); query?.stop(); return }
        let fresh = batch.filter { seen.insert($0.path).inserted }.prefix(Self.cap - hits.count)
        if !fresh.isEmpty { hits.append(contentsOf: fresh) }
    }
}

/// The disk-catalog half of Find. Runs off the main thread.
enum Catalog {
    /// Asks APFS to search its catalog directly (what Find Any File does). Returns false if the volume can't.
    static func searchfs(_ q: String, send: @Sendable ([Hit]) async -> Void) async -> Bool {
        var any = false
        for volume in ["/System/Volumes/Data", "/"] {
            if await searchVolume(volume, q, send: send) { any = true }
            if Task.isCancelled { break }
        }
        return any
    }

    private static func searchVolume(_ volume: String, _ q: String, send: @Sendable ([Hit]) async -> Void) async -> Bool {
        var fs = statfs()
        guard statfs(volume, &fs) == 0 else { return false }
        var fsid = fs.f_fsid
        let wanted = UnsafeMutablePointer<attrlist>.allocate(capacity: 1)
        wanted.initialize(to: attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
                                       commonattr: attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_FILEID),
                                       volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0))
        let match = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_NAME),
                             volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)

        // Search params: [u32 total size][attrreference_t][name bytes]. The second block is required but unused for names.
        let name = Array(q.utf8) + [0]
        let refSize = MemoryLayout<attrreference_t>.size
        let paramSize = 4 + refSize + name.count
        let params = UnsafeMutableRawPointer.allocate(byteCount: paramSize, alignment: 8)
        let params2 = UnsafeMutableRawPointer.allocate(byteCount: paramSize, alignment: 8)
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { wanted.deallocate(); params.deallocate(); params2.deallocate(); buf.deallocate() }
        params.storeBytes(of: UInt32(paramSize), as: UInt32.self)
        params.storeBytes(of: attrreference_t(attr_dataoffset: Int32(refSize), attr_length: UInt32(name.count)), toByteOffset: 4, as: attrreference_t.self)
        name.withUnsafeBytes { (params + 4 + refSize).copyMemory(from: $0.baseAddress!, byteCount: name.count) }
        params2.copyMemory(from: params, byteCount: paramSize)

        var state = searchstate()
        var options = UInt32(SRCHFS_START | SRCHFS_MATCHPARTIALNAMES | SRCHFS_MATCHFILES | SRCHFS_MATCHDIRS)
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        while !Task.isCancelled {
            var found: UInt = 0
            var block = fssearchblock(returnattrs: wanted, returnbuffer: buf, returnbuffersize: bufSize, maxmatches: 500,
                                      timelimit: timeval(tv_sec: 0, tv_usec: 250_000), searchparams1: params, sizeofsearchparams1: paramSize,
                                      searchparams2: params2, sizeofsearchparams2: paramSize, searchattrs: match)
            let r = Darwin.searchfs(volume, &block, &found, 0x08000100, options, &state) // 0x08000100: Unicode script code
            let err = errno
            options &= ~UInt32(SRCHFS_START)
            var batch: [Hit] = []
            var offset = 0
            for _ in 0..<Int(found) {
                let length = Int(buf.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let fileID = buf.loadUnaligned(fromByteOffset: offset + 4 + refSize, as: UInt64.self)
                if fsgetpath(&path, path.count, &fsid, fileID) > 0, let hit = Hit(path: String(cString: path)) { batch.append(hit) }
                offset += length
            }
            if !batch.isEmpty { await send(batch) }
            if r == 0 { return true }
            if err != EAGAIN { return false }
        }
        return true
    }

    /// Fallback when searchfs isn't supported: walk the disk in parallel, hidden files included.
    static func walk(_ q: String, send: @escaping @Sendable ([Hit]) async -> Void) async {
        let skip: Set<String> = ["/System/Volumes", "/Volumes", "/dev"]
        let roots = ((try? FileManager.default.contentsOfDirectory(atPath: "/")) ?? []).map { "/" + $0 }.filter { !skip.contains($0) }
        await withTaskGroup(of: Void.self) { group in
            for root in roots {
                group.addTask {
                    var batch: [Hit] = []
                    if root.localizedCaseInsensitiveContains(q), let h = Hit(path: root) { batch.append(h) }
                    let e = FileManager.default.enumerator(atPath: root)
                    while let rel = e?.nextObject() as? String, !Task.isCancelled {
                        if (rel as NSString).lastPathComponent.localizedCaseInsensitiveContains(q), let h = Hit(path: root + "/" + rel) {
                            batch.append(h)
                            if batch.count >= 200 { await send(batch); batch = [] }
                        }
                    }
                    if !batch.isEmpty { await send(batch) }
                }
            }
        }
    }
}

struct FindView: View {
    @StateObject private var model = FindModel()
    @State private var text = ""
    @State private var filter = FindFilter()
    @State private var preview: URL?
    @State private var trashing: Hit?
    @State private var fullAccess = hasFullDiskAccess()
    @Environment(\.accent) private var accent

    private var shown: [Hit] { model.hits.filter { filter.matches($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: "Find", subtitle: "Type part of a name. Finds anything on this Mac, including hidden and system files.")
            if !fullAccess {
                Tile(style: .accent) {
                    Text("To search everywhere, Deck needs Full Disk Access. Without it, Find still works in your own folders.")
                        .font(F.body).foregroundStyle(accent.soft)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }.buttonStyle(.pill)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(C.text2)
                TextField("Search by name", text: $text).textFieldStyle(.plain).font(F.ui(15))
                if model.searching { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(C.tile))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(C.border, lineWidth: 0.5))

            HStack(spacing: 8) {
                picker($filter.kind)
                picker($filter.size)
                picker($filter.date)
                Spacer()
                if !text.isEmpty {
                    Text(model.hits.count >= FindModel.cap ? "first \(FindModel.cap) results" : "\(shown.count) found")
                        .font(F.mono(11)).foregroundStyle(C.text2)
                }
            }
            results
        }
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(250)) // wait for typing to pause
            if !Task.isCancelled { model.search(text) }
        }
        .onAppear { fullAccess = hasFullDiskAccess() }
        .onDisappear { model.cancel() }
        .quickLookPreview($preview)
        .confirmationDialog("Move \(trashing?.name ?? "this") to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let hit = trashing, (try? FileManager.default.trashItem(at: URL(fileURLWithPath: hit.path), resultingItemURL: nil)) != nil {
                    model.remove(hit)
                }
                trashing = nil
            }
        }
    }

    private func picker<T: RawRepresentable & CaseIterable & Hashable>(_ value: Binding<T>) -> some View where T.RawValue == String, T.AllCases: RandomAccessCollection {
        Picker("", selection: value) {
            ForEach(T.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden().fixedSize()
    }

    @ViewBuilder private var results: some View {
        let list = shown
        if !list.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(list) { hit in
                    Row(divider: hit.id != list.last?.id) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path)).resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.name).font(F.ui(13)).lineLimit(1)
                            Text(hit.folder).font(F.label).foregroundStyle(C.muted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(hit.isFolder ? "" : bytes(hit.size)).font(F.mono(11)).foregroundStyle(C.text2).frame(width: 80, alignment: .trailing)
                        Text(hit.modified.formatted(date: .abbreviated, time: .omitted)).font(F.mono(11)).foregroundStyle(C.text2).frame(width: 96, alignment: .trailing)
                        Menu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
                            Button("Quick Look") { preview = URL(fileURLWithPath: hit.path) }
                            Divider()
                            Button("Move to Trash…") { trashing = hit }
                        } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(C.tile))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(C.border, lineWidth: 0.5))
        } else if !text.isEmpty && !model.searching {
            Text("Nothing found.").font(F.body).foregroundStyle(C.text2)
        }
    }
}
