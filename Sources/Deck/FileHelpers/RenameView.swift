import SwiftUI

/// Plain-words rename rules. Applies to the name only; the file type ending is kept.
struct RenameRule: Equatable {
    enum Case: String, CaseIterable { case keep = "Keep as is", lower = "lowercase", upper = "UPPERCASE", title = "Title Case" }
    var find = ""
    var replace = ""
    var before = ""
    var after = ""
    var numbered = ""     // "Photo" → "Photo 1", "Photo 2"…
    var startAt = 1
    var letterCase = Case.keep

    func apply(_ names: [String]) -> [String] {
        names.enumerated().map { i, full in
            let url = URL(fileURLWithPath: full)
            let ext = url.pathExtension
            var name = ext.isEmpty ? full : url.deletingPathExtension().lastPathComponent
            if !numbered.isEmpty { name = "\(numbered) \(startAt + i)" }
            if !find.isEmpty { name = name.replacingOccurrences(of: find, with: replace) }
            name = before + name + after
            switch letterCase {
            case .keep: break
            case .lower: name = name.lowercased()
            case .upper: name = name.uppercased()
            case .title: name = name.capitalized
            }
            return ext.isEmpty ? name : "\(name).\(ext)"
        }
    }
}

struct RenameView: View {
    @State private var files: [URL] = []
    @State private var rule = RenameRule()
    @State private var undo: [(from: URL, to: URL)] = []
    @State private var message = ""

    private var newNames: [String] { rule.apply(files.map(\.lastPathComponent)) }

    /// Plain reason the rename can't happen yet, or nil.
    private var blocker: String? {
        let names = newNames
        if Set(names.map { $0.lowercased() }).count != names.count { return "Two files would end up with the same name." }
        if names.contains(where: { $0.isEmpty || $0.hasPrefix(".") || $0.contains("/") || $0.contains(":") }) { return "A name is empty or has / or : in it." }
        for (url, name) in zip(files, names) where name != url.lastPathComponent {
            let dest = url.deletingLastPathComponent().appendingPathComponent(name)
            if name.lowercased() != url.lastPathComponent.lowercased() && FileManager.default.fileExists(atPath: dest.path) {
                return "\(name) already exists in that folder."
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropZone(prompt: "Drop the files to rename", allowFolders: false) { files += $0; message = "" }
            if !files.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Tile {
                        TileLabel(text: "How to rename")
                        field("Find", $rule.find)
                        field("Replace with", $rule.replace)
                        field("Add before", $rule.before)
                        field("Add after", $rule.after)
                        field("Number them, like Photo", $rule.numbered)
                        if !rule.numbered.isEmpty { Stepper("Start at \(rule.startAt)", value: $rule.startAt, in: 0...100_000).font(F.body) }
                        Picker("Letters", selection: $rule.letterCase) {
                            ForEach(RenameRule.Case.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .font(F.body)
                    }
                    .frame(width: 300)
                    Tile {
                        TileLabel(text: "Preview")
                        ForEach(Array(zip(files, newNames).enumerated()), id: \.offset) { i, pair in
                            Row(divider: i < files.count - 1) {
                                Text(pair.0.lastPathComponent).font(F.body).foregroundStyle(C.text2).lineLimit(1)
                                Image(systemName: "arrow.right").foregroundStyle(C.muted)
                                Text(pair.1).font(F.body).lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                }
                HStack {
                    Button("Rename \(files.count) file\(files.count == 1 ? "" : "s")") { rename() }
                        .buttonStyle(.primary).disabled(blocker != nil || newNames == files.map(\.lastPathComponent))
                    if !undo.isEmpty { Button("Undo") { revert() }.buttonStyle(.pill) }
                    Button("Clear list") { files = [] }.buttonStyle(.pill)
                    Text(blocker ?? message).font(F.label).foregroundStyle(blocker == nil ? C.text2 : C.warn)
                }
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        TextField(label, text: text).textFieldStyle(.roundedBorder).font(F.body)
    }

    private func rename() {
        var done: [(URL, URL)] = []
        for (url, name) in zip(files, newNames) where name != url.lastPathComponent {
            let dest = url.deletingLastPathComponent().appendingPathComponent(name)
            if (try? FileManager.default.moveItem(at: url, to: dest)) != nil { done.append((url, dest)) }
        }
        undo = done
        files = files.map { u in done.first { $0.0 == u }?.1 ?? u }
        rule = RenameRule()
        message = "Renamed \(done.count) file\(done.count == 1 ? "" : "s")"
    }

    private func revert() {
        for (from, to) in undo.reversed() { try? FileManager.default.moveItem(at: to, to: from) }
        files = files.map { u in undo.first { $0.to == u }?.from ?? u }
        undo = []
        message = "Put the old names back"
    }
}
