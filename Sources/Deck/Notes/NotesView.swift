import SwiftUI
import SwiftData

enum NotesModels { static let all: [any PersistentModel.Type] = [] }

/// Notes are plain files in ~/Documents/Deck Notes. Private notes are encrypted `.decknote` files.
enum NoteFiles {
    static let privateExt = "decknote"
    static let inboxName = "Inbox"

    struct Note: Identifiable, Equatable {
        var url: URL
        var modified: Date
        var text: String     // empty for private notes until opened, so search never decrypts everything
        var id: URL { url }
        var title: String { url.deletingPathExtension().lastPathComponent }
        var isPrivate: Bool { url.pathExtension == NoteFiles.privateExt }
    }

    static var folder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Deck Notes")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var inboxURL: URL { folder.appendingPathComponent("\(inboxName).md") }

    static func list() -> [Note] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: .skipsHiddenFiles)) ?? []
        return urls.filter { ["md", privateExt].contains($0.pathExtension) }.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let text = url.pathExtension == "md" ? ((try? String(contentsOf: url, encoding: .utf8)) ?? "") : ""
            return Note(url: url, modified: date, text: text)
        }.sorted { $0.modified > $1.modified }
    }

    static func read(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        if url.pathExtension == privateExt { return Vault.openText(data) ?? "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ text: String, to url: URL) throws {
        let data = url.pathExtension == privateExt ? try Vault.seal(text) : Data(text.utf8)
        try data.write(to: url, options: .atomic)
    }

    static func create(named name: String = "Untitled note") -> URL {
        let url = FileManager.default.freeURL(in: folder, name: name, ext: "md")
        try? Data().write(to: url)
        return url
    }

    /// Switches a note between plain and private. The old file is removed so no plain copy is left behind.
    static func setPrivate(_ on: Bool, _ url: URL) throws -> URL {
        let text = read(url)
        let new = FileManager.default.freeURL(in: folder, name: url.deletingPathExtension().lastPathComponent, ext: on ? privateExt : "md")
        try write(text, to: new)
        try FileManager.default.removeItem(at: url)
        return new
    }

    static func rename(_ url: URL, to name: String) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != url.deletingPathExtension().lastPathComponent else { return url }
        let new = FileManager.default.freeURL(in: folder, name: clean, ext: url.pathExtension)
        return (try? FileManager.default.moveItem(at: url, to: new)) != nil ? new : url
    }

    /// Adds one line to the Inbox note (quick capture, menu bar).
    static func appendToInbox(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        var body = read(inboxURL)
        if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
        body += "- \(Date.now.formatted(date: .abbreviated, time: .shortened))  \(line)\n"
        try? write(body, to: inboxURL)
        NotificationCenter.default.post(name: .notesChanged, object: nil)
    }
}

extension Notification.Name { static let notesChanged = Notification.Name("DeckNotesChanged") }

struct NotesView: View {
    @State private var notes: [NoteFiles.Note] = []
    @State private var selected: URL?
    @State private var text = ""
    @State private var name = ""
    @State private var search = ""
    @State private var saveTask: Task<Void, Never>?
    @AppStorage("notesPreview") private var preview = false
    @Environment(\.accent) private var accent

    private var shown: [NoteFiles.Note] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var current: NoteFiles.Note? { notes.first { $0.url == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ScreenHeader(title: "Notes", subtitle: "Plain notes saved on this Mac." + (QuickCapture.shortcutText.map { " \($0) jots one down from anywhere." } ?? ""))
                Button("New note") { newNote() }.buttonStyle(.primary)
            }
            HStack(alignment: .top, spacing: 8) {
                Tile { list }.frame(width: 260)
                Tile { editor }
            }
            .frame(height: 560)
        }
        .onAppear { reload(); if selected == nil { open(notes.first?.url) } }
        .onDisappear { saveNow() }
        .onReceive(NotificationCenter.default.publisher(for: .notesChanged)) { _ in
            reload()
            if selected == NoteFiles.inboxURL { text = NoteFiles.read(NoteFiles.inboxURL) }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search notes", text: $search)
                .textFieldStyle(.plain).font(F.body)
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(C.bg))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { n in
                        Button { open(n.url) } label: {
                            Row {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(n.title).font(F.ui(13, medium: n.url == selected)).lineLimit(1)
                                        if n.isPrivate { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(C.text2) }
                                    }
                                    Text(n.modified.formatted(date: .abbreviated, time: .shortened)).font(F.mono(11)).foregroundStyle(C.muted)
                                }
                                Spacer()
                            }
                            .foregroundStyle(n.url == selected ? accent.soft : C.text)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if shown.isEmpty {
                        Text(notes.isEmpty ? "No notes yet." : "Nothing matches.").font(F.label).foregroundStyle(C.text2).padding(.top, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if let note = current {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain).font(F.ui(16, medium: true))
                    .onSubmit { renameCurrent() }
                Toggle("Private note", isOn: Binding(get: { note.isPrivate }, set: { setPrivate($0) }))
                    .toggleStyle(.switch).controlSize(.small).font(F.label).foregroundStyle(C.text2)
                    .help("Private notes are locked with a key kept in your Keychain.")
                Toggle("Preview", isOn: $preview)
                    .toggleStyle(.switch).controlSize(.small).font(F.label).foregroundStyle(C.text2)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }.buttonStyle(.pill)
            }
            Rectangle().fill(C.line).frame(height: 0.5)
            HStack(spacing: 12) {
                NoteEditor(text: $text, noteID: note.url)
                    .onChange(of: text) { scheduleSave() }
                if preview {
                    Rectangle().fill(C.line).frame(width: 0.5)
                    NotePreview(text: text)
                }
            }
        } else {
            Text("Pick a note or make a new one.").font(F.body).foregroundStyle(C.text2)
        }
    }

    private func reload() { notes = NoteFiles.list() }

    private func open(_ url: URL?) {
        saveNow()
        selected = url
        text = url.map(NoteFiles.read) ?? ""
        name = url?.deletingPathExtension().lastPathComponent ?? ""
    }

    private func newNote() {
        let url = NoteFiles.create()
        reload()
        open(url)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        guard let url = selected, FileManager.default.fileExists(atPath: url.path), NoteFiles.read(url) != text else { return }
        try? NoteFiles.write(text, to: url)
        if let i = notes.firstIndex(where: { $0.url == url }) {
            notes[i].modified = .now
            if !notes[i].isPrivate { notes[i].text = text }
        }
    }

    private func renameCurrent() {
        guard let url = selected else { return }
        saveNow()
        selected = NoteFiles.rename(url, to: name)
        name = selected?.deletingPathExtension().lastPathComponent ?? name
        reload()
    }

    private func setPrivate(_ on: Bool) {
        guard let url = selected else { return }
        saveNow()
        if let new = try? NoteFiles.setPrivate(on, url) { selected = new }
        reload()
    }
}
