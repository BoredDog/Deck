import SwiftUI

enum FileTool: String, CaseIterable, Identifiable {
    case convert = "Convert", smaller = "Make smaller", text = "Copy text", pdf = "PDF tools"
    case background = "Remove background", rename = "Rename", duplicates = "Duplicates", tidy = "Tidy Downloads"
    var id: String { rawValue }
}

struct FilesView: View {
    @AppStorage("filesTool") private var tool = FileTool.convert

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: "Files", subtitle: "Drop files in, pick what you want, done. Your originals are never changed.")
            // Wraps instead of scrolling sideways, so every tool stays visible at 760pt.
            WrapLayout(spacing: 6) {
                ForEach(FileTool.allCases) { t in
                    TabPill(title: t.rawValue, selected: tool == t) { tool = t }
                }
            }
            switch tool {
            case .convert: ConvertView()
            case .smaller: CompressView()
            case .text: CopyTextView()
            case .pdf: PDFToolsView()
            case .background: RemoveBackgroundView()
            case .rename: RenameView()
            case .duplicates: DuplicatesView()
            case .tidy: TidyView()
            }
        }
    }
}

struct TabPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.accent) private var accent
    var body: some View {
        Button(action: action) {
            Text(title).font(F.ui(12, medium: selected))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(selected ? accent.fill : .clear))
                .overlay(Capsule().strokeBorder(selected ? accent.border : C.border, lineWidth: 1))
                .foregroundStyle(selected ? accent.soft : C.text2)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: selected)
    }
}

/// One file moving through a queue.
struct Job: Identifiable {
    enum State: Equatable { case waiting, working(Double), done(URL), skipped(String), failed(String), needs(String) }
    let id = UUID()
    /// Waiting, failed, or waiting for a helper: the next run tries it again.
    var retry: Bool { switch state { case .waiting, .failed, .needs: true; default: false } }
    let url: URL
    var state: State = .waiting
    var saved: Int64 = 0
}

struct JobRow: View {
    let job: Job
    var last = false
    @Environment(\.accent) private var accent

    var body: some View {
        Row(divider: !last) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.url.lastPathComponent).font(F.body).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .waiting: Text("Waiting").font(F.label).foregroundStyle(C.text2)
                case .working(let p): Bar4(value: p).frame(maxWidth: 260)
                case .done(let out):
                    Text(job.saved > 0 ? "\(bytes(job.saved)) smaller — the original is still there" : out.lastPathComponent)
                        .font(F.label).foregroundStyle(job.saved > 0 ? C.lime : C.text2)
                case .skipped(let why): Text(why).font(F.label).foregroundStyle(C.text2)
                case .failed(let why): Text(why).font(F.label).foregroundStyle(C.warn)
                case .needs(let tool):
                    let info = Setup.helperInfo(tool)
                    Text("Needs the \(info.name) (~\(bytes(info.bytes))). Get it, then press the button again.").font(F.label).foregroundStyle(C.text2)
                }
            }
            Spacer()
            if case .done(let out) = job.state {
                Dot(color: C.lime)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }.buttonStyle(.pill)
            } else if case .needs(let tool) = job.state {
                HelperButton(tool: tool)
            } else if case .failed = job.state {
                Dot(color: C.warn)
            }
        }
    }
}

// MARK: - Convert

struct ConvertView: View {
    @State private var jobs: [Job] = []
    @State private var choice: Target?
    @State private var running = false
    @State private var edit = VideoEdit()
    @State private var targets: [Target] = []
    @ObservedObject private var setup = Setup.shared

    /// Only the targets every dropped file can become, plus "all in one" choices for several pictures.
    nonisolated private static func targets(for urls: [URL]) -> [Target] {
        guard let first = urls.first else { return [] }
        let firstTargets = Converters.targets(for: first)
        let ids = urls.dropFirst().reduce(Set(firstTargets.map(\.id))) { $0.intersection(Converters.targets(for: $1).map(\.id)) }
        return Converters.combineTargets(for: urls) + firstTargets.filter { ids.contains($0.id) }
    }

    private var editTimesOK: Bool {
        [edit.start, edit.end].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || VideoEdit.seconds($0) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if setup.showCard { SetupCard().frame(height: 130) }
            DropZone(prompt: "Drop files to convert") { add($0) }
                .onReceive(Incoming.shared.$convert) { if !$0.isEmpty { add($0); Incoming.shared.convert = [] } }
                // Worked out off the main thread: some files need a peek inside first.
                .task(id: jobs.map(\.url)) {
                    let urls = jobs.map(\.url)
                    targets = await Task.detached(priority: .userInitiated) { Self.targets(for: urls) }.value
                    if let c = choice, !targets.contains(c) { choice = nil }
                }
            if !jobs.isEmpty {
                Tile {
                    TileLabel(text: "Turn \(jobs.count == 1 ? "it" : "them") into")
                    if targets.isEmpty {
                        Text("These files can't become the same thing. Try converting one kind at a time.").font(F.body).foregroundStyle(C.text2)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(targets) { t in TargetCard(target: t, selected: choice == t) { choice = t } }
                    }
                }
                if choice?.id == "video.edit" { editOptions }
                Tile {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { i, j in JobRow(job: j, last: i == jobs.count - 1) }
                }
                HStack {
                    Button(running ? "Converting…" : "Convert") { Task { await run() } }
                        .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                        .disabled(running || choice == nil || (choice?.id == "video.edit" && !editTimesOK) || (choice?.addOn).map { id in !Setup.installed(Setup.addOns.first { $0.id == id }!) } == true)
                    Button("Clear") { jobs = []; choice = nil }.buttonStyle(.pill).disabled(running)
                    Spacer()
                    if let need = choice?.addOn, let a = Setup.addOns.first(where: { $0.id == need }), !Setup.installed(a) {
                        AddOnButton(addOn: a)
                    }
                }
            }
        }
    }

    /// "Rotate or trim": turn buttons and two plain time fields.
    private var editOptions: some View {
        Tile {
            TileLabel(text: "Rotate or trim")
            HStack(spacing: 6) {
                ForEach([0, 90, 180, 270], id: \.self) { r in
                    TabPill(title: r == 0 ? "Don't turn" : "Turn \(r)°", selected: edit.rotate == r) { edit.rotate = r }
                }
            }
            HStack(spacing: 8) {
                Text("Start at").font(F.body).foregroundStyle(C.text2)
                TextField("0:00", text: $edit.start).deckField().frame(width: 80)
                Text("End at").font(F.body).foregroundStyle(C.text2)
                TextField("the end", text: $edit.end).deckField().frame(width: 80)
                if !editTimesOK { Text("Use minutes:seconds, like 1:05").font(F.label).foregroundStyle(C.warn) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func add(_ urls: [URL]) {
        jobs += urls.filter { u in !jobs.contains { $0.url == u } }.map { Job(url: $0) }
    }

    private func run() async {
        guard let t = choice else { return }
        running = true
        defer { running = false }
        if t.id.hasPrefix("combine.") {
            for i in jobs.indices { jobs[i].state = .working(0) }
            do {
                let out = try await Converters.combine(jobs.map(\.url), to: t) { p in
                    Task { @MainActor in for i in jobs.indices { if case .working = jobs[i].state { jobs[i].state = .working(p) } } }
                }
                for i in jobs.indices { jobs[i].state = .done(out) }
                Store.log("Made \(t.name) from \(jobs.count) pictures", kind: "convert", file: out)
            } catch let m as Engine.Missing {
                for i in jobs.indices { jobs[i].state = .needs(m.tool) }
            } catch {
                for i in jobs.indices { jobs[i].state = .failed(error.localizedDescription) }
            }
            return
        }
        for i in jobs.indices where jobs[i].retry {
            jobs[i].state = .working(0)
            let id = jobs[i].id
            do {
                let out = try await Converters.convert(jobs[i].url, to: t, edit: edit) { p in
                    Task { @MainActor in
                        if let k = jobs.firstIndex(where: { $0.id == id }), case .working = jobs[k].state { jobs[k].state = .working(p) }
                    }
                }
                jobs[i].state = .done(out)
                Store.log("Converted \(jobs[i].url.lastPathComponent) to \(t.name)", kind: "convert", file: out)
            } catch let m as Engine.Missing {
                jobs[i].state = .needs(m.tool)
            } catch {
                jobs[i].state = .failed(error.localizedDescription)
            }
        }
    }
}

struct TargetCard: View {
    let target: Target
    let selected: Bool
    let action: () -> Void
    @Environment(\.accent) private var accent
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(F.ui(13, medium: true)).foregroundStyle(selected ? accent.soft : C.text)
                Text(target.detail.isEmpty ? "." + target.ext : target.detail).font(F.label).foregroundStyle(C.text2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accent.surface : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? accent.accent : (hover ? C.borderHover : C.border), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.2), value: selected)
    }
}

struct AddOnButton: View {
    let addOn: Setup.AddOn
    @ObservedObject private var setup = Setup.shared

    var body: some View {
        let installed = Setup.installed(addOn)
        let room = Setup.freeSpace > addOn.approxBytes * 2
        HStack(spacing: 8) {
            if setup.busyAddOn == addOn.id {
                if !installed, let done = setup.downloaded {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(bytes(done)) of ~\(bytes(addOn.approxBytes))").font(F.mono(11)).foregroundStyle(C.text2)
                        Bar4(value: Double(done) / Double(addOn.approxBytes)).frame(width: 140)
                    }
                } else {
                    Text(installed ? "Removing…" : "Installing…").font(F.label).foregroundStyle(C.text2)
                }
            } else if setup.waiting.contains(addOn.id) {
                Text("Waiting…").font(F.label).foregroundStyle(C.text2)
            } else if !installed && !room {
                Text("Needs about \(bytes(addOn.approxBytes)), only \(bytes(Setup.freeSpace)) free").font(F.label).foregroundStyle(C.warn)
            } else if installed && !Setup.installedByDeck(addOn) {
                Text("Installed outside Deck").font(F.label).foregroundStyle(C.text2)
            } else {
                if setup.failed.contains(addOn.id) {
                    Text("Couldn't finish. Check your internet and try again.").font(F.label).foregroundStyle(C.warn)
                } else {
                    Text(installed ? "Installed" : "\(addOn.name) · \(bytes(addOn.approxBytes))").font(F.label).foregroundStyle(C.text2)
                }
                Button(installed ? "Remove" : "Turn on") { Task { await setup.toggle(addOn) } }.buttonStyle(.pill)
            }
        }
    }
}

// MARK: - Make smaller

struct CompressView: View {
    @State private var jobs: [Job] = []
    @State private var running = false
    @AppStorage("compressLossy") private var lossyOK = false
    @AppStorage("compressMax") private var max = false
    @ObservedObject private var setup = Setup.shared

    private var totalSaved: Int64 { jobs.reduce(0) { $0 + $1.saved } }
    private var restoreMode: Bool { !jobs.isEmpty && jobs.allSatisfy { Compressor.canRestore($0.url) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if setup.showCard { SetupCard().frame(height: 130) }
            HStack(alignment: .top, spacing: 8) {
                DropZone(prompt: "Drop files or folders to make smaller") { urls in
                    jobs += urls.filter { u in !jobs.contains { $0.url == u } }.map { Job(url: $0) }
                }
                .onReceive(Incoming.shared.$compress) { urls in
                    guard !urls.isEmpty else { return }
                    jobs += urls.filter { u in !jobs.contains { $0.url == u } }.map { Job(url: $0) }
                    Incoming.shared.compress = []
                }
                Tile(style: totalSaved > 0 ? .lime : .plain) {
                    TileLabel(text: "Made smaller", onLime: totalSaved > 0)
                    BigNumber(text: bytes(totalSaved))
                    Text(totalSaved > 0 ? "Delete the originals to free the space." : "Same quality, less space.").font(F.body)
                        .foregroundStyle(totalSaved > 0 ? C.onLime : C.text2)
                }
                .frame(width: 220, height: 140)
            }
            if !jobs.isEmpty {
                if !restoreMode {
                    Tile {
                        Toggle(isOn: $max) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Take longer for a smaller file").font(F.body)
                                Text("Same quality either way.").font(F.label).foregroundStyle(C.text2)
                            }
                        }
                        Rectangle().fill(C.line).frame(height: 0.5)
                        Toggle(isOn: $lossyOK) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Even smaller").font(F.body)
                                Text("Photos, videos, music and PDFs may lose a little quality.").font(F.label).foregroundStyle(C.text2)
                            }
                        }
                    }
                    .toggleStyle(.trailingSwitch)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Tile {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { i, j in
                        VStack(alignment: .leading, spacing: 0) {
                            JobRow(job: j, last: i == jobs.count - 1)
                            if j.state == .waiting && !restoreMode {
                                Text(plan(for: j.url)).font(F.label).foregroundStyle(C.text2).padding(.leading, 30).padding(.bottom, 6)
                            }
                        }
                    }
                }
                HStack {
                    Button(running ? "Working…" : restoreMode ? "Restore" : "Make smaller") { Task { await run() } }
                        .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(running)
                    Button("Clear") { jobs = [] }.buttonStyle(.pill).disabled(running)
                }
            }
        }
    }

    private func method(_ url: URL) -> Method {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return CompressPolicy.method(for: url, isFolder: isDir.boolValue, max: max, lossyOK: lossyOK)
    }

    private func plan(for url: URL) -> String {
        let m = method(url)
        if case .skip(let why) = m { return why }
        return m.lossless ? "Same quality, less space" : "Smaller, quality may drop a little"
    }

    private func run() async {
        running = true
        defer { running = false }
        var savedTotal: Int64 = 0
        for i in jobs.indices where jobs[i].retry {
            jobs[i].state = .working(0.5)
            do {
                if restoreMode {
                    let out = try await Compressor.restore(jobs[i].url)
                    jobs[i].state = .done(out)
                    Store.log("Restored \(jobs[i].url.lastPathComponent)", kind: "convert", file: out)
                    continue
                }
                let m = method(jobs[i].url)
                if case .skip(let why) = m { jobs[i].state = .skipped(why); continue }
                guard let r = try await Compressor.run(jobs[i].url, method: m) else { continue }
                if r.saved <= 0 {
                    jobs[i].state = .skipped("Already as small as it gets")
                } else {
                    jobs[i].saved = r.saved
                    jobs[i].state = .done(r.output)
                    savedTotal += r.saved
                }
            } catch let m as Engine.Missing {
                jobs[i].state = .needs(m.tool)
            } catch {
                jobs[i].state = .failed(error.localizedDescription)
            }
        }
        if savedTotal > 0 { Store.log("Made files \(bytes(savedTotal)) smaller · the originals are still there", kind: "convert", saved: savedTotal) }
    }
}

/// "Get it" for one missing helper, with download progress while it installs.
struct HelperButton: View {
    let tool: String
    @ObservedObject private var setup = Setup.shared

    var body: some View {
        let id = "tool.\(tool)"
        if setup.busyAddOn == id {
            if let done = setup.downloaded {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(bytes(done)) of ~\(bytes(Setup.helperInfo(tool).bytes))").font(F.mono(11)).foregroundStyle(C.text2)
                    Bar4(value: Double(done) / Double(Setup.helperInfo(tool).bytes)).frame(width: 140)
                }
            } else {
                Text("Installing…").font(F.label).foregroundStyle(C.text2)
            }
        } else if setup.waiting.contains(id) {
            Text("Waiting…").font(F.label).foregroundStyle(C.text2)
        } else if Engine.has(tool) {
            Text("Ready").font(F.label).foregroundStyle(C.lime)
        } else {
            if setup.failed.contains(id) { Text("Couldn't finish. Try again.").font(F.label).foregroundStyle(C.warn) }
            Button("Get it") { Task { await setup.installTool(tool) } }.buttonStyle(.pill).disabled(!setup.hasHomebrew)
        }
    }
}
