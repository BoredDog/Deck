import SwiftUI
import AppKit

/// Deck's slide-in panel: full height, 380pt wide, from the right edge of the screen with the pointer.
/// Floats over any app on every Space. Esc, a click outside (on release, not while dragging) or the same trigger closes it.
@MainActor final class QuickPanel {
    static let shared = QuickPanel()
    static let width: CGFloat = 380

    private var panel: SlidePanel?
    private var clickMonitors: [Any] = []
    private var shown = false
    private var downOutside = false
    private var dragCount = 0     // drag pasteboard changes when a drag starts (e.g. files dragged to the drop spots)

    func toggle() { shown ? hide() : show() }

    func show() {
        guard !shown else { return }
        shown = true
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let end = NSRect(x: area.maxX - Self.width, y: area.minY, width: Self.width, height: area.height)
        let p = panel ?? makePanel()
        panel = p
        p.setFrame(end.offsetBy(dx: Self.width, dy: 0), display: false)
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(end, display: true)
        }
        SystemMonitor.shared.startPolling()
        NowPlaying.shared.viewing(true)

        // A click in other apps, or in Deck's other windows, closes the panel when the button comes up.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]
        clickMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: mask) { e in MainActor.assumeIsolated { QuickPanel.shared.mouse(e, outside: true) } },
            NSEvent.addLocalMonitorForEvents(matching: mask) { e in
                MainActor.assumeIsolated { QuickPanel.shared.mouse(e, outside: e.window !== QuickPanel.shared.panel) }
                return e
            },
        ].compactMap { $0 }
    }

    private func mouse(_ e: NSEvent, outside: Bool) {
        if e.type == .leftMouseDown || e.type == .rightMouseDown {
            downOutside = outside
            dragCount = NSPasteboard(name: .drag).changeCount
            return
        }
        let dragged = NSPasteboard(name: .drag).changeCount != dragCount
        let overPanel = panel.map { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false
        if downOutside && !dragged && !overPanel { hide() }
        downOutside = false
    }

    func hide() {
        guard shown, let p = panel else { return }
        shown = false
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        SystemMonitor.shared.stopPolling()
        NowPlaying.shared.viewing(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(p.frame.offsetBy(dx: Self.width, dy: 0), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { if !QuickPanel.shared.shown { p.orderOut(nil) } }
        })
    }

    private func makePanel() -> SlidePanel {
        let p = SlidePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                           styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.hasShadow = true
        p.backgroundColor = .black
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = NSHostingView(rootView: QuickPanelView().modelContainer(Store.container).preferredColorScheme(.dark))
        return p
    }
}

/// Borderless panels can't take typing unless told so. Esc closes.
private final class SlidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { MainActor.assumeIsolated { QuickPanel.shared.hide() } }
}

struct QuickPanelView: View {
    @AppStorage("theme") private var themeID = Accent.all[0].id

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    FocusTile()
                    NextTile()
                }
                .fixedSize(horizontal: false, vertical: true)
                TasksTile()
                QuickNoteTile()
                DownloadTile()
                NowPlayingTile()
                ClipboardTile(limit: 5)
                Tile { KeepAwakeControls() }
                WeatherTile().frame(height: 130)
                MacStatusTile()
                HStack(spacing: 8) {
                    DropSpot(title: "Convert", icon: "arrow.triangle.2.circlepath") { hand($0, tool: .convert) }
                    DropSpot(title: "Make smaller", icon: "arrow.down.right.and.arrow.up.left") { hand($0, tool: .smaller) }
                }
            }
            .padding(10)
        }
        .frame(width: QuickPanel.width)
        .frame(maxHeight: .infinity)
        .background(C.bg)
        .overlay(alignment: .leading) { Rectangle().fill(C.border).frame(width: 0.5) }
        .foregroundStyle(C.text)
        .environment(\.accent, Accent.named(themeID))
    }

    /// Same hand-off as Finder's right-click: the Files screen picks the files up.
    private func hand(_ urls: [URL], tool: FileTool) {
        UserDefaults.standard.set(Place.files.rawValue, forKey: "place")
        UserDefaults.standard.set(tool.rawValue, forKey: "filesTool")
        if tool == .convert { Incoming.shared.convert = urls } else { Incoming.shared.compress = urls }
        QuickPanel.shared.hide()
        MainWindow.open()
    }
}

private struct TasksTile: View {
    @ObservedObject private var planner = Planner.shared
    @State private var ticked: Set<String> = []

    var body: some View {
        Tile {
            TileLabel(text: "Today")
            if planner.todayTasks.isEmpty {
                Text("Nothing due today.").font(F.body).foregroundStyle(C.text2)
            }
            VStack(spacing: 0) {
                ForEach(planner.todayTasks) { t in
                    Row(divider: t.id != planner.todayTasks.last?.id) {
                        Button {
                            ticked.insert(t.id)
                            // Let the tick show for a moment before the task leaves the list.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { planner.complete(t) }
                        } label: {
                            Image(systemName: ticked.contains(t.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(ticked.contains(t.id) ? C.lime : C.muted)
                        }
                        .buttonStyle(.plain)
                        Text(t.title).font(F.body).lineLimit(1)
                        Spacer()
                        if let due = t.due, t.hasTime { Text(clock(due)).font(F.mono(11)).foregroundStyle(C.text2) }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacStatusTile: View {
    @ObservedObject private var mac = SystemMonitor.shared
    @Environment(\.accent) private var accent

    var body: some View {
        Tile {
            TileLabel(text: mac.moodLine)
            meter("Processor", mac.cpu)
            meter("Memory", mac.memory)
            HStack {
                Text("Free space").font(F.label).foregroundStyle(C.text2)
                Spacer()
                Text(bytes(mac.diskFree)).font(F.label)
            }
            if let b = mac.battery {
                HStack {
                    Text(b.charging ? "Battery, charging" : "Battery").font(F.label).foregroundStyle(C.text2)
                    Spacer()
                    Text("\(Int(b.level * 100))%").font(F.label)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func meter(_ name: String, _ value: Double) -> some View {
        HStack(spacing: 10) {
            Text(name).font(F.label).foregroundStyle(C.text2).frame(width: 70, alignment: .leading)
            Bar4(value: value, color: accent.accent)
        }
    }
}

/// Drop files to send them to the Files screen.
private struct DropSpot: View {
    let title: String
    let icon: String
    let onFiles: ([URL]) -> Void
    @Environment(\.accent) private var accent
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(accent.soft)
            Text(title).font(F.body)
            Text("Drop files here").font(F.label).foregroundStyle(C.text2)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? accent.surface : C.tile))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(targeted ? accent.accent : C.border, style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { onFiles(files) }
            return !files.isEmpty
        } isTargeted: { targeted = $0 }
        .animation(.easeInOut(duration: 0.2), value: targeted)
    }
}
