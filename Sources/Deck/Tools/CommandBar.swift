import SwiftUI
import AppKit

/// One line in the command bar.
struct Command: Identifiable {
    let id: String
    let title: String
    let icon: String
    var hint = ""
    var file: String?   // a file result shows its own icon
    let run: () -> Void
}

/// ⌘K: jump to a screen, run an action or find a file, all from the keyboard.
@MainActor final class CommandBar: ObservableObject {
    static let shared = CommandBar()
    @Published var shown = false

    /// Also callable from the quick panel or menu bar: opens the main window with the bar showing.
    func show() { MainWindow.open(); shown = true }
    func hide() { shown = false }
    func toggle() { shown ? hide() : show() }

    /// How well `title` matches what was typed; nil means no match. Start of the title beats start of a word,
    /// which beats anywhere inside, which beats the letters in order ("kma" → "Keep Mac awake").
    nonisolated static func score(_ title: String, _ query: String) -> Int? {
        let t = title.lowercased(), q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty || t.hasPrefix(q) { return 3 }
        if t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 2 }
        if t.contains(q) { return 1 }
        var rest = Substring(q)
        for c in t where c == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty ? 0 : nil
    }

    /// Matching commands, best first; equal matches keep their listed order.
    nonisolated static func rank(_ items: [Command], _ query: String) -> [Command] {
        items.enumerated().compactMap { i, c in score(c.title, query).map { (c, $0, i) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
    }

    /// "add task buy milk" and "buy milk" both add "buy milk".
    nonisolated static func taskText(_ query: String) -> String {
        var t = query.trimmingCharacters(in: .whitespaces)
        for prefix in ["add task ", "add "] where t.lowercased().hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return t
    }
}

/// The Spotlight half of Find, cut down to the newest 8 matches.
@MainActor final class QuickFileSearch: ObservableObject {
    @Published var paths: [String] = []
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    func search(_ text: String) {
        cancel()
        paths = []
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        let mq = NSMetadataQuery()
        mq.predicate = NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey, "*\(q)*")
        mq.searchScopes = [NSMetadataQueryLocalComputerScope]
        mq.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: mq, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.take() }
        }
        query = mq
        mq.start()
    }

    func cancel() {
        query?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        query = nil; observer = nil
    }

    private func take() {
        guard let mq = query else { return }
        mq.stop()
        paths = (0..<min(8, mq.resultCount)).compactMap { (mq.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
    }
}

struct CommandBarView: View {
    @ObservedObject private var bar = CommandBar.shared
    @StateObject private var files = QuickFileSearch()
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool
    @AppStorage("place") private var place = Place.home
    @AppStorage("filesTool") private var tool = FileTool.convert
    @AppStorage("macTab") private var macTab = MacView.Tab.monitor
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accent) private var accent

    private var results: [Command] {
        var list = CommandBar.rank(commands, query)
        let task = CommandBar.taskText(query)
        if !task.isEmpty {
            list.append(Command(id: "addtask", title: "Add task “\(task)”", icon: "plus.circle", hint: "Plan") { addTask(task) })
        }
        list += files.paths.map { path in
            Command(id: path, title: (path as NSString).lastPathComponent, icon: "doc", hint: (path as NSString).deletingLastPathComponent
                .replacingOccurrences(of: NSHomeDirectory(), with: "~"), file: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        return list
    }

    private var commands: [Command] {
        let go = Place.allCases.map { p in Command(id: "go.\(p.rawValue)", title: p.rawValue, icon: p.icon, hint: "Go to") { place = p } }
        let focusMinutes = UserDefaults.standard.integer(forKey: FocusKey.minutes)
        return go + [
            Command(id: "focus", title: "Start focus", icon: "timer") {
                FocusTimer.shared.start(minutes: focusMinutes > 0 ? focusMinutes : 25); place = .focus
            },
            Command(id: "note", title: "New note", icon: "square.and.pencil") {
                _ = NoteFiles.create()
                NotificationCenter.default.post(name: .notesChanged, object: nil)
                place = .notes
            },
            Command(id: "smaller", title: "Make smaller…", icon: "arrow.down.right.and.arrow.up.left") { tool = .smaller; place = .files },
            Command(id: "convert", title: "Convert…", icon: "arrow.triangle.2.circlepath") { tool = .convert; place = .files },
            Command(id: "organize", title: "Organize a folder…", icon: "folder") { tool = .organize; place = .files },
            Command(id: "awake", title: KeepAwake.shared.on ? "Let Mac sleep" : "Keep Mac awake", icon: "cup.and.saucer") { KeepAwake.shared.on.toggle() },
            Command(id: "eq", title: Equalizer.shared.on ? "Turn equalizer off" : "Turn equalizer on", icon: "slider.vertical.3") {
                Equalizer.shared.setOn(!Equalizer.shared.on)
            },
            Command(id: "screen", title: "Screen time", icon: "hourglass") { macTab = .screen; place = .mac },
            Command(id: "clipboard", title: "Clipboard", icon: "doc.on.clipboard") { openWindow(id: "clipboard") },
            Command(id: "settings", title: "Open Settings", icon: "gearshape") { openSettings() },
        ]
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { bar.hide() }
            panel.padding(.top, 72)
        }
        .onAppear { focused = true }
        .onDisappear { files.cancel() }
        .onChange(of: query) { selection = 0 }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))   // wait for typing to pause
            if !Task.isCancelled { files.search(query) }
        }
    }

    private var panel: some View {
        let list = results
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(C.text2)
                TextField("Go to, do or find…", text: $query).textFieldStyle(.plain).font(F.ui(15))
                    .focused($focused)
                    .onSubmit { if list.indices.contains(selection) { run(list[selection]) } }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, list.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { bar.hide(); return .handled }
                    .onExitCommand { bar.hide() }
                Text("esc").font(F.mono(10)).foregroundStyle(C.muted)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(C.bg))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(C.border, lineWidth: 1))
            .padding(10)

            if !list.isEmpty {
                Rectangle().fill(C.line).frame(height: 0.5)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                                row(c, selected: i == selection)
                                    .id(i)
                                    .onHover { if $0 { selection = i } }
                                    .onTapGesture { run(c) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 12).fill(C.tile))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(C.border, lineWidth: 1))
    }

    private func row(_ c: Command, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if let file = c.file {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file)).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: c.icon).frame(width: 18)
            }
            Text(c.title).font(F.ui(13)).lineLimit(1)
            Spacer(minLength: 12)
            Text(c.hint).font(F.mono(11)).foregroundStyle(C.muted).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accent.fill : .clear))
        .foregroundStyle(selected ? accent.soft : C.text)
        .contentShape(Rectangle())
    }

    private func run(_ c: Command) {
        bar.hide()
        query = ""
        c.run()
    }

    /// Adds through Plan's own quick add, so "Dentist tomorrow 3pm" works here too.
    private func addTask(_ text: String) {
        Task { @MainActor in
            let planner = Planner.shared
            if !planner.reminderAccess { await planner.requestAccess() }
            if planner.reminderAccess { planner.quickAdd(text) } else { place = .plan }
        }
    }
}
