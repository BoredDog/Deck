import SwiftUI
import AppKit

struct MacView: View {
    enum Tab: String, CaseIterable { case monitor = "Monitor", space = "Space" }
    @AppStorage("macTab") private var tab = Tab.monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ScreenHeader(title: "Mac", subtitle: tab == .monitor ? "How your Mac is doing right now." : "See what's using space and free some up.")
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            switch tab {
            case .monitor: MonitorView()
            case .space: SpaceView()
            }
        }
    }
}

private let grid = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4)

/// 60 thin rounded bars, newest on the right.
struct MiniChart: View {
    let values: [Double]   // 0…1
    var color: Color
    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(0..<SystemMonitor.historyLength, id: \.self) { i in
                let k = i - (SystemMonitor.historyLength - values.count)
                RoundedRectangle(cornerRadius: 1)
                    .fill(k >= 0 ? color : C.line)
                    .frame(height: max(2, CGFloat(k >= 0 ? min(1, values[k]) : 0) * 32))
            }
        }
        .frame(height: 32, alignment: .bottom)
    }
}

private struct MonitorView: View {
    @ObservedObject private var m = SystemMonitor.shared
    @State private var quitting: AppUsage?
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.moodLine).font(F.ui(18, medium: true)).padding(.bottom, 8)
            LazyVGrid(columns: grid, spacing: 8) {
                stat("Processor", percent(m.cpu), value: m.cpu, history: m.cpuHistory)
                stat("Memory", percent(m.memory), value: m.memory, history: m.memoryHistory)
                Tile {
                    TileLabel(text: "Free space")
                    BigNumber(text: bytes(m.diskFree))
                    Bar4(value: m.diskTotal > 0 ? 1 - Double(m.diskFree) / Double(m.diskTotal) : 0, color: accent.accent)
                    Text("of \(bytes(m.diskTotal))").font(F.mono(11)).foregroundStyle(C.text2)
                }
                Tile {
                    TileLabel(text: "Network")
                    Text("↓ \(bytes(m.netDown))/s").font(F.mono(15))
                    Text("↑ \(bytes(m.netUp))/s").font(F.mono(11)).foregroundStyle(C.text2)
                    let peak = max(1, m.netHistory.max() ?? 1)
                    MiniChart(values: m.netHistory.map { $0 / peak }, color: accent.accent)
                }
                if let b = m.battery {
                    Tile {
                        TileLabel(text: b.charging ? "Battery · charging" : "Battery")
                        BigNumber(text: percent(b.level))
                        Bar4(value: b.level, color: accent.accent)
                        Text("health \(percent(b.health)) · \(b.cycles) cycles").font(F.mono(11)).foregroundStyle(C.text2)
                    }
                }
            }
            FansTile()
            Text("What's slowing it down").font(F.ui(15, medium: true)).padding(.top, 16)
            LazyVGrid(columns: Array(grid.prefix(2)), spacing: 8) {
                apps("Using the most processor", m.topCPU) { percent($0.cpu) }
                apps("Using the most memory", m.topMemory) { bytes($0.memory) }
            }
        }
        .onAppear { m.startPolling() }
        .onDisappear { m.stopPolling() }
        .confirmationDialog("Quit \(quitting?.name ?? "this app")?", isPresented: Binding(get: { quitting != nil }, set: { if !$0 { quitting = nil } })) {
            Button("Quit") { quitting?.app?.terminate(); quitting = nil }
        } message: { Text("Unsaved work in it may ask to be saved first.") }
    }

    private func stat(_ label: String, _ text: String, value: Double, history: [Double]) -> some View {
        Tile {
            TileLabel(text: label)
            BigNumber(text: text)
            Bar4(value: value, color: accent.accent)
            MiniChart(values: history, color: accent.accent)
        }
    }

    private func apps(_ title: String, _ list: [AppUsage], value: @escaping (AppUsage) -> String) -> some View {
        Tile {
            TileLabel(text: title)
            ForEach(list) { a in
                Row(divider: a.id != list.last?.id) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: a.id)).resizable().frame(width: 18, height: 18)
                    Text(a.name).font(F.ui(13)).lineLimit(1)
                    Spacer()
                    Text(value(a)).font(F.mono(11)).foregroundStyle(C.text2)
                    if a.app != nil, a.app?.processIdentifier != getpid() {
                        Button("Quit") { quitting = a }.buttonStyle(.pill)
                    }
                }
            }
            if list.isEmpty { Text("Checking…").font(F.label).foregroundStyle(C.text2) }
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

private struct SpaceView: View {
    @ObservedObject private var s = StorageModel.shared
    @State private var confirmTrash = false
    @State private var trashing: Hit?
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            usage
            if !s.bigFiles.isEmpty { bigFiles }
            cleanup
            remover
        }
        .onAppear {
            if s.root == nil { s.scan() }
            s.loadCleanup()
        }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmTrash) {
            Button("Clean and empty Trash", role: .destructive) { s.runCleanup() }
        } message: { Text("Files in the Trash will be gone for good.") }
        .confirmationDialog("Move \(trashing?.name ?? "this") to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
            Button("Move to Trash", role: .destructive) { if let t = trashing { s.trash(t) }; trashing = nil }
        }
    }

    private var usage: some View {
        Tile {
            HStack {
                TileLabel(text: "What's taking up space")
                Spacer()
                Button(s.scanning ? "Looking…" : "Look again") { s.scan() }.buttonStyle(.pill).disabled(s.scanning)
            }
            if s.scanning { Bar4(value: s.progress) }
            if let root = s.root {
                HStack(spacing: 4) {
                    ForEach(Array(([root] + s.trail).enumerated()), id: \.offset) { i, node in
                        if i > 0 { Text("›").foregroundStyle(C.muted) }
                        Button(i == 0 && node.url.path == s.home.path ? "Home" : node.name) { s.trail = Array(s.trail.prefix(i)) }
                            .buttonStyle(.plain).font(F.label)
                            .foregroundStyle(i == s.trail.count ? C.text : C.text2)
                    }
                }
                if let cur = s.current {
                    let top = max(1, cur.children.first?.size ?? 1)
                    ForEach(cur.children.prefix(30)) { child in
                        Button { if !child.children.isEmpty { s.trail.append(child) } } label: {
                            HStack(spacing: 10) {
                                Text(child.name).font(F.ui(13)).lineLimit(1).frame(width: 180, alignment: .leading)
                                Bar4(value: Double(child.size) / Double(top), color: accent.accent)
                                Text(bytes(child.size)).font(F.mono(11)).foregroundStyle(C.text2).frame(width: 72, alignment: .trailing)
                            }
                            .padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if !s.scanning {
                Text("Nothing scanned yet.").font(F.label).foregroundStyle(C.text2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var bigFiles: some View {
        Tile {
            TileLabel(text: "Large & old files")
            ForEach(s.bigFiles.prefix(20)) { hit in
                Row(divider: hit.id != s.bigFiles.prefix(20).last?.id) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path)).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.name).font(F.ui(13)).lineLimit(1)
                        Text(hit.folder).font(F.label).foregroundStyle(C.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(bytes(hit.size)).font(F.mono(11)).foregroundStyle(C.text2)
                    Text(hit.modified.formatted(date: .abbreviated, time: .omitted)).font(F.mono(11)).foregroundStyle(C.muted)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }.buttonStyle(.pill)
                    Button("Trash") { trashing = hit }.buttonStyle(.pill)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var cleanup: some View {
        Tile {
            TileLabel(text: "Clean up")
            if s.clean.isEmpty { Text("Nothing to clean right now.").font(F.label).foregroundStyle(C.text2) }
            ForEach(CleanItem.Group.allCases, id: \.self) { group in
                let items = s.clean.filter { $0.group == group }
                if !items.isEmpty {
                    Text(group.rawValue).font(F.ui(12, medium: true)).foregroundStyle(C.text2).padding(.top, 6)
                    ForEach(items) { item in
                        Row(divider: item.id != items.last?.id) {
                            Toggle(isOn: Binding(get: { s.selected.contains(item.id) },
                                                 set: { if $0 { s.selected.insert(item.id) } else { s.selected.remove(item.id) } })) {
                                Text(item.label).font(F.ui(13)).lineLimit(1)
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Text(bytes(item.size)).font(F.mono(11)).foregroundStyle(C.text2)
                        }
                    }
                }
            }
            if !s.clean.isEmpty {
                HStack {
                    Text("Everything goes to the Trash first.").font(F.label).foregroundStyle(C.text2)
                    Spacer()
                    Button("Clean \(bytes(s.selectedBytes))") {
                        if s.clean.contains(where: { $0.group == .trash && s.selected.contains($0.id) }) { confirmTrash = true } else { s.runCleanup() }
                    }
                    .buttonStyle(.primary).disabled(s.selected.isEmpty)
                }
                .padding(.top, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var remover: some View {
        Tile {
            TileLabel(text: "Remove an app")
            if let app = s.app {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
                    Text(app.deletingPathExtension().lastPathComponent).font(F.ui(14, medium: true))
                    Spacer()
                    Button("Cancel") { s.app = nil; s.appLeftovers = [] }.buttonStyle(.pill)
                    Button("Move to Trash · \(bytes(s.appLeftovers.reduce(0) { $0 + $1.size }))") { s.removeApp() }.buttonStyle(.pill)
                }
                ForEach(s.appLeftovers) { item in
                    Row(divider: item.id != s.appLeftovers.last?.id) {
                        Text(item.label).font(F.ui(12)).foregroundStyle(C.text2).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(bytes(item.size)).font(F.mono(11)).foregroundStyle(C.text2)
                    }
                }
            } else {
                DropZone(prompt: "Drop an app here to remove it and its leftovers", multiple: false) { urls in
                    if let u = urls.first { s.pickApp(u) }
                }
            }
            if !s.appMessage.isEmpty { Text(s.appMessage).font(F.label).foregroundStyle(C.text2) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
