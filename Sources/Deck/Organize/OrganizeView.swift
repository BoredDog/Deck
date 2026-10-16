import SwiftUI

/// Files → Organize: pick a folder, choose how to sort, preview every move, then organize (with Undo).
struct OrganizeView: View {
    @AppStorage("filesTool") private var tool = FileTool.organize
    @State private var folder: URL?
    @State private var fileCount: Int?
    @State private var recent = UserDefaults.standard.stringArray(forKey: "organizeRecent") ?? []
    @State private var options = OrganizeOptions()
    @State private var rules = OrganizeView.loadRules()
    @State private var showRules = false
    @State private var courses: [String]?
    @State private var working = false
    @State private var moves: [PlannedMove]?
    @State private var findings: CleanupFindings?
    @State private var sizes: [URL: Int64] = [:]
    @State private var justDone: UndoRecord?
    @State private var lastRecord: UndoRecord?
    @State private var message: String?
    @State private var problem: String?
    @State private var trashing: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickFolder
            optionsTile
            rulesTile
            actions
            if let problem { Text(problem).font(F.body).foregroundStyle(C.warn).fixedSize(horizontal: false, vertical: true) }
            if let message { Text(message).font(F.ui(14, medium: true)).foregroundStyle(C.lime) }
            if let justDone { doneTile(justDone) }
            if working {
                Tile { Text("Looking through \(Self.files(fileCount ?? 0))…").font(F.body).foregroundStyle(C.text2) }
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let folder, moves != nil {
                OrganizePreview(folder: folder, moves: Binding(get: { moves ?? [] }, set: { moves = $0 }))
                if let picked = moves?.filter(\.include), !picked.isEmpty {
                    let dirs = Set(picked.map { $0.destination.deletingLastPathComponent() }).count
                    HStack(spacing: 12) {
                        Text("Move \(Self.files(picked.count)) into \(dirs) \(dirs == 1 ? "folder" : "folders")").font(F.body)
                        Spacer()
                        Button("Organize") { organize(picked) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
                    }
                }
            }
            if let findings {
                CleanupView(findings: findings, sizes: sizes, trash: { trashing = $0 }, makeSmaller: { url in
                    Incoming.shared.compress = [url]
                    tool = .smaller
                })
            }
        }
        .task {
            lastRecord = Organizer.lastRecord
            courses = await Organizer.knownCourses()
        }
        // Counted off the main thread: a deep folder can hold thousands of files.
        .task(id: "\(folder?.path ?? "")|\(options.includeSubfolders)") {
            guard let folder else { return }
            fileCount = nil
            let deep = options.includeSubfolders
            fileCount = await Task.detached(priority: .userInitiated) { Self.countFiles(in: folder, deep: deep) }.value
        }
        .onChange(of: options) { moves = nil; findings = nil }
        .onChange(of: options.primary) { _, p in
            if options.secondary == p { options.secondary = nil }
            if p == .rules && rules.isEmpty { showRules = true }
        }
        .onChange(of: rules) { _, r in
            if let data = try? JSONEncoder().encode(r) { UserDefaults.standard.set(data, forKey: "organizeRules") }
        }
        .confirmationDialog(trashing.count == 1 ? "Move \(trashing[0].lastPathComponent) to the Trash?" : "Move \(trashing.count) files to the Trash?",
                            isPresented: Binding(get: { !trashing.isEmpty }, set: { if !$0 { trashing = [] } })) {
            Button("Move to Trash", role: .destructive) { trash(trashing) }
        } message: {
            Text("\(bytes(trashing.reduce(0) { $0 + (sizes[$1] ?? 0) })). You can get them back from the Trash.")
        }
    }

    // MARK: Folder

    private var pickFolder: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                // DropZone adds its own "or click to choose" line underneath.
                DropZone(prompt: "Drop a folder to organize", multiple: false) { choose($0) }
                Tile {
                    TileLabel(text: "Folder")
                    if let folder {
                        Text(folder.lastPathComponent).font(F.ui(16, medium: true)).lineLimit(1).truncationMode(.middle)
                        Text(fileCount.map { Self.files($0) } ?? "Counting…").font(F.mono(12)).foregroundStyle(C.text2)
                    } else {
                        Text("None yet").font(F.ui(16, medium: true)).foregroundStyle(C.text2)
                        Text("Nothing moves until you say so.").font(F.label).foregroundStyle(C.text2)
                    }
                }
                .frame(width: 220, height: 140)
            }
            let existing = recent.filter { FileManager.default.fileExists(atPath: $0) }
            if !existing.isEmpty {
                WrapLayout(spacing: 6) {
                    Text("Recent").font(F.label).foregroundStyle(C.text2).padding(.vertical, 6)
                    ForEach(existing, id: \.self) { path in
                        TabPill(title: URL(fileURLWithPath: path).lastPathComponent, selected: folder?.path == path) {
                            choose([URL(fileURLWithPath: path)])
                        }
                        .help(path)
                    }
                }
            }
        }
    }

    private func choose(_ urls: [URL]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        guard let url = urls.first(where: {
            let v = try? $0.resourceValues(forKeys: keys)
            return v?.isDirectory == true && v?.isPackage != true
        }) else {
            problem = "That's a file, not a folder. Drop or choose a folder to organize."
            return
        }
        folder = url
        moves = nil; findings = nil; justDone = nil; message = nil; problem = nil
        recent = Array(([url.path] + recent.filter { $0 != url.path }).prefix(5))
        UserDefaults.standard.set(recent, forKey: "organizeRecent")
    }

    // MARK: Options

    private var usesCourse: Bool { options.primary == .course || options.secondary == .course }
    private var usesRules: Bool { options.primary == .rules || options.secondary == .rules }

    private var optionsTile: some View {
        Tile {
            TileLabel(text: "Sort by")
            PillPicker(selection: $options.primary, options: GroupBy.allCases.map { ($0.rawValue, $0) })
            HStack(alignment: .top, spacing: 8) {
                Text("then by").font(F.body).foregroundStyle(C.text2).padding(.top, 5)
                DeckDropdown(selection: $options.secondary,
                             options: [("None", GroupBy?.none)] + GroupBy.allCases.filter { $0 != options.primary }.map { ($0.rawValue, Optional($0)) })
            }
            if usesCourse {
                if let courses {
                    Text(courses.isEmpty
                         ? "No courses yet. Add your classes in Plan → Timetable or connect Moodle in Plan → Deadlines, then preview again."
                         : "Uses your course names from Timetable and Moodle (\(courses.count) \(courses.count == 1 ? "course" : "courses")).")
                        .font(F.label).foregroundStyle(courses.isEmpty ? C.warn : C.text2).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Finding your courses…").font(F.label).foregroundStyle(C.text2)
                }
            }
            if usesRules && activeRules.isEmpty {
                Text("Add a rule under My rules first.").font(F.label).foregroundStyle(C.warn)
            }
            Rectangle().fill(C.line).frame(height: 0.5)
            Toggle(isOn: $options.cleanNames) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean up file names").font(F.body)
                    Text("You'll see every new name in the preview first.").font(F.label).foregroundStyle(C.text2)
                }
            }
            Rectangle().fill(C.line).frame(height: 0.5)
            Toggle(isOn: $options.includeSubfolders) { Text("Include files in subfolders").font(F.body) }
        }
        .toggleStyle(.trailingSwitch)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: My rules

    private var activeRules: [OrganizeRule] {
        rules.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty && !$0.folder.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var rulesTile: some View {
        Tile {
            Button { showRules.toggle() } label: {
                HStack(spacing: 8) {
                    TileLabel(text: "My rules")
                    if !rules.isEmpty { Text("\(rules.count)").font(F.mono(11)).foregroundStyle(C.text2) }
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(C.text2)
                        .rotationEffect(.degrees(showRules ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showRules ? "Hide my rules" : "Show my rules")
            if showRules {
                Text("Checked from top to bottom. The first rule that fits a file wins.").font(F.label).foregroundStyle(C.text2)
                if rules.isEmpty {
                    EmptyState(text: "No rules yet.", action: "Add a rule") { addRule() }
                } else {
                    ForEach($rules) { $rule in
                        RuleRow(rule: $rule,
                                first: rule.id == rules.first?.id, last: rule.id == rules.last?.id,
                                move: { moveRule(rule.id, by: $0) },
                                remove: { rules.removeAll { $0.id == rule.id } })
                    }
                    Button("Add a rule") { addRule() }.buttonStyle(.pill)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.2), value: showRules)
    }

    private func addRule() { rules.append(OrganizeRule(field: .nameContains, value: "", folder: "")) }

    private func moveRule(_ id: UUID, by d: Int) {
        guard let i = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(i + d) else { return }
        rules.swapAt(i, i + d)
    }

    static func loadRules() -> [OrganizeRule] {
        guard let data = UserDefaults.standard.data(forKey: "organizeRules") else { return [] }
        return (try? JSONDecoder().decode([OrganizeRule].self, from: data)) ?? []
    }

    // MARK: Preview, organize, undo

    private var actions: some View {
        HStack(spacing: 12) {
            Button(working ? "Looking…" : "Preview") { Task { await preview() } }
                .buttonStyle(.pill)
                .disabled(folder == nil || working)
            if folder == nil { Text("Pick a folder first.").font(F.label).foregroundStyle(C.text2) }
            Spacer()
            if let lastRecord, justDone == nil {
                Button("Undo last organize · \(Self.when(lastRecord.date))") { undo(lastRecord) }
                    .buttonStyle(.pill)
                    .help("Puts \(Self.files(lastRecord.moves.count)) back where they were in \(lastRecord.folder.lastPathComponent).")
            }
        }
    }

    private func preview() async {
        guard let folder else { return }
        working = true; problem = nil; message = nil; justDone = nil; moves = nil; findings = nil
        if courses == nil || usesCourse { courses = await Organizer.knownCourses() }
        async let plan = Organizer.plan(folder: folder, options: options, rules: activeRules, courses: courses ?? [])
        async let clean = Organizer.cleanup(in: folder, includeSubfolders: options.includeSubfolders)
        let (m, f) = await (plan, clean)
        let all = f.oldInstallers + f.duplicates.flatMap { $0 } + f.bigForgotten
        sizes = await Task.detached(priority: .userInitiated) {
            Dictionary(all.map { ($0, Self.size($0)) }, uniquingKeysWith: { a, _ in a })
        }.value
        moves = m; findings = f; working = false
    }

    private func organize(_ picked: [PlannedMove]) {
        do {
            let record = try Organizer.apply(picked)
            justDone = record
            moves = nil
            Store.log("Organized \(Self.files(record.moves.count)) in \(record.folder.lastPathComponent)")
        } catch {
            problem = "A file couldn't be moved, so everything was put back as it was. \(error.localizedDescription)"
            moves = nil
        }
        lastRecord = Organizer.lastRecord
        recount()
    }

    private func undo(_ record: UndoRecord) {
        do {
            try Organizer.undo(record)
            message = "Put \(Self.files(record.moves.count)) back where they were."
            problem = nil
        } catch {
            problem = "Couldn't put everything back. \(error.localizedDescription) Try Undo again for the rest."
        }
        justDone = nil; moves = nil; findings = nil
        lastRecord = Organizer.lastRecord // the engine forgets a fully undone record and keeps any files it couldn't move back
        recount()
    }

    private func recount() {
        guard let folder else { return }
        let deep = options.includeSubfolders
        Task { fileCount = await Task.detached { Self.countFiles(in: folder, deep: deep) }.value }
    }

    private func doneTile(_ record: UndoRecord) -> some View {
        Tile {
            HStack(spacing: 10) {
                Dot(color: C.lime)
                Text("Done. \(Self.files(record.moves.count)) organized.").font(F.ui(14, medium: true)).foregroundStyle(C.lime)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(record.folder) }.buttonStyle(.pill)
                Button("Undo") { undo(record) }.buttonStyle(.pill)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Clean-up

    private func trash(_ urls: [URL]) {
        var gone = Set<URL>(), freed: Int64 = 0
        for u in urls where (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil {
            gone.insert(u); freed += sizes[u] ?? 0
        }
        if var f = findings {
            f.oldInstallers.removeAll { gone.contains($0) }
            f.bigForgotten.removeAll { gone.contains($0) }
            f.duplicates = f.duplicates.map { $0.filter { !gone.contains($0) } }.filter { $0.count > 1 }
            findings = f
        }
        moves?.removeAll { gone.contains($0.source) }
        trashing = []
        if gone.count == urls.count {
            message = "Moved \(Self.files(gone.count)) to the Trash · \(bytes(freed)) freed."
            problem = nil
        } else {
            problem = "Moved \(gone.count) of \(urls.count) to the Trash. The rest may be open or locked."
        }
        if freed > 0 { Store.log("Moved clutter to the Trash", saved: freed) }
    }

    // MARK: Helpers

    static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

    static func when(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "Today \(clock(d))"
            : Calendar.current.isDateInYesterday(d) ? "Yesterday \(clock(d))"
            : d.formatted(.dateTime.day().month(.abbreviated)) + " \(clock(d))"
    }

    nonisolated static func size(_ u: URL) -> Int64 {
        Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    nonisolated static func countFiles(in folder: URL, deep: Bool) -> Int {
        let fm = FileManager.default
        func isFile(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        guard deep else {
            return (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles))?.filter(isFile).count ?? 0
        }
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var n = 0
        while let u = e.nextObject() as? URL { if isFile(u) { n += 1 } }
        return n
    }
}

/// "If [field] [value] → put in [folder]" with move up/down and remove.
struct RuleRow: View {
    @Binding var rule: OrganizeRule
    let first: Bool
    let last: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    private var hint: String {
        switch rule.field {
        case .nameContains: "a word, like lab"
        case .extensionIs: "pdf"
        case .fromSiteContains: "moodle"
        case .olderThanDays: "180"
        case .largerThanMB: "100"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("If").font(F.body).foregroundStyle(C.text2).padding(.top, 7)
            DeckDropdown(selection: $rule.field, options: OrganizeRule.Field.allCases.map { ($0.rawValue, $0) })
                .padding(.top, 2).frame(width: 150, alignment: .leading) // same width every row, so the fields line up
            TextField(hint, text: $rule.value).deckField().frame(minWidth: 70)
                .accessibilityLabel("Value for \(rule.field.rawValue.lowercased())")
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(C.text2).padding(.top, 10)
            Text("put in").font(F.body).foregroundStyle(C.text2).padding(.top, 7)
            TextField("Folder name", text: $rule.folder).deckField().frame(minWidth: 90)
                .accessibilityLabel("Folder to put matching files in")
            icon("chevron.up", "Move rule up") { move(-1) }.disabled(first)
            icon("chevron.down", "Move rule down") { move(1) }.disabled(last)
            icon("xmark", "Remove rule") { remove() }
        }
    }

    private func icon(_ name: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: name).font(.system(size: 10, weight: .semibold)).foregroundStyle(C.text2)
                .frame(width: 22, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A Deck-coloured checkbox (the stock one is system blue).
struct CheckBox: View {
    @Binding var on: Bool
    let label: String
    var body: some View {
        Button { on.toggle() } label: {
            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 14))
                .foregroundStyle(on ? C.lime : C.text2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "Selected" : "Not selected")
    }
}

/// The planned moves grouped by the folder they'll land in.
struct OrganizePreview: View {
    let folder: URL
    @Binding var moves: [PlannedMove]

    private var groups: [(dir: URL, indices: [Int])] {
        Dictionary(grouping: moves.indices) { moves[$0].destination.deletingLastPathComponent().standardizedFileURL }
            .map { ($0.key, $0.value) }
            .sorted { $0.dir.path.localizedStandardCompare($1.dir.path) == .orderedAscending }
    }

    private func title(_ dir: URL) -> String {
        let base = folder.standardizedFileURL.path
        guard dir.path != base else { return "Stays in \(folder.lastPathComponent), new name" }
        return dir.path.hasPrefix(base + "/") ? String(dir.path.dropFirst(base.count + 1)) : dir.path
    }

    var body: some View {
        if moves.isEmpty {
            Tile { EmptyState(text: "Everything here is already in order. Nothing to move.") }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groups, id: \.dir) { g in
                    Tile {
                        let on = g.indices.filter { moves[$0].include }.count
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(C.text2)
                            Text(title(g.dir)).font(F.ui(14, medium: true)).lineLimit(1).truncationMode(.middle)
                            Text(on == g.indices.count ? "\(on)" : "\(on) of \(g.indices.count)").font(F.mono(11)).foregroundStyle(C.text2)
                            Spacer()
                            Button(on == g.indices.count ? "Select none" : "Select all") {
                                let value = on != g.indices.count
                                for i in g.indices { moves[i].include = value }
                            }
                            .buttonStyle(.pill)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(g.indices.enumerated()), id: \.element) { n, i in
                                MoveRow(move: $moves[i], last: n == g.indices.count - 1)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct MoveRow: View {
    @Binding var move: PlannedMove
    let last: Bool

    var body: some View {
        let old = move.source.lastPathComponent, new = move.destination.lastPathComponent
        Row(divider: !last) {
            CheckBox(on: $move.include, label: "Include \(old)")
            Image(nsImage: NSWorkspace.shared.icon(forFile: move.source.path)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(old).font(F.body).foregroundStyle(old == new ? C.text : C.text2).lineLimit(1).truncationMode(.middle)
                    if old != new {
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(C.text2).accessibilityLabel("renamed to")
                        Text(new).font(F.body).lineLimit(1).truncationMode(.middle)
                    }
                }
                if !move.reason.isEmpty { Text(move.reason).font(F.label).foregroundStyle(C.text2).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .opacity(move.include ? 1 : 0.55)
    }
}

/// Old installers, duplicates and big forgotten files found while previewing.
struct CleanupView: View {
    let findings: CleanupFindings
    let sizes: [URL: Int64]
    let trash: ([URL]) -> Void
    let makeSmaller: (URL) -> Void
    @State private var skipped: Set<URL> = []

    private func total(_ urls: [URL]) -> String { bytes(urls.reduce(0) { $0 + (sizes[$1] ?? 0) }) }

    var body: some View {
        let extras = findings.duplicates.flatMap { $0.dropFirst() }
        VStack(alignment: .leading, spacing: 12) {
            if findings.oldInstallers.isEmpty && extras.isEmpty && findings.bigForgotten.isEmpty {
                Tile {
                    TileLabel(text: "Clean-up ideas")
                    EmptyState(text: "No old installers, duplicates or big forgotten files here.")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !findings.oldInstallers.isEmpty {
                let picked = findings.oldInstallers.filter { !skipped.contains($0) }
                Tile {
                    TileLabel(text: "Installers you've already used")
                    Text("The app is already installed, so these aren't needed any more.").font(F.label).foregroundStyle(C.text2)
                    VStack(spacing: 0) {
                        ForEach(Array(findings.oldInstallers.enumerated()), id: \.element) { i, u in
                            Row(divider: i < findings.oldInstallers.count - 1) {
                                CheckBox(on: Binding(get: { !skipped.contains(u) }, set: { if $0 { skipped.remove(u) } else { skipped.insert(u) } }),
                                         label: "Trash \(u.lastPathComponent)")
                                fileLabel(u)
                            }
                        }
                    }
                    Button("Move \(picked.count) to the Trash · \(total(picked))") { trash(picked) }
                        .buttonStyle(.pill).disabled(picked.isEmpty)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !extras.isEmpty {
                Tile {
                    TileLabel(text: "Duplicates")
                    Text("The same file more than once. Deck keeps the newest copy and trashes the rest.").font(F.label).foregroundStyle(C.text2)
                    VStack(spacing: 0) {
                        ForEach(Array(findings.duplicates.enumerated()), id: \.offset) { i, group in
                            Row(divider: i < findings.duplicates.count - 1) {
                                fileLabel(group[0], note: "\(group.count - 1) extra \(group.count == 2 ? "copy" : "copies") · \(total(Array(group.dropFirst())))")
                            }
                        }
                    }
                    Button("Keep the newest, trash \(extras.count) \(extras.count == 1 ? "copy" : "copies") · \(total(extras))") { trash(extras) }
                        .buttonStyle(.pill)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !findings.bigForgotten.isEmpty {
                Tile {
                    TileLabel(text: "Big and untouched for 6 months")
                    VStack(spacing: 0) {
                        ForEach(Array(findings.bigForgotten.enumerated()), id: \.element) { i, u in
                            Row(divider: i < findings.bigForgotten.count - 1) {
                                fileLabel(u)
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.pill)
                                Button("Make smaller") { makeSmaller(u) }.buttonStyle(.pill)
                                Button("Move to Trash") { trash([u]) }.buttonStyle(.pill)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func fileLabel(_ u: URL, note: String? = nil) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 20, height: 20)
        VStack(alignment: .leading, spacing: 2) {
            Text(u.lastPathComponent).font(F.body).lineLimit(1).truncationMode(.middle)
            if let note { Text(note).font(F.label).foregroundStyle(C.text2) }
        }
        Spacer(minLength: 8)
        if note == nil { Text(bytes(sizes[u] ?? 0)).font(F.mono(11)).foregroundStyle(C.text2) }
    }
}
