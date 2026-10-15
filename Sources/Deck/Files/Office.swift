import Foundation
import AppKit
import ZIPFoundation

/// Reads Office files (zipped XML) without LibreOffice.
enum OOXML {
    static func read(_ archive: Archive, _ path: String) throws -> Data {
        guard let e = archive[path] else { throw Engine.Failed(tool: "ooxml", detail: "missing \(path)") }
        var data = Data()
        _ = try archive.extract(e) { data.append($0) }
        return data
    }

    /// Calls `start` / `end` / `text` for each element; names have their "x:" prefix removed.
    final class Walker: NSObject, XMLParserDelegate {
        var start: (String, [String: String]) -> Void = { _, _ in }
        var end: (String) -> Void = { _ in }
        var text: (String) -> Void = { _ in }
        private static func local(_ n: String) -> String { n.split(separator: ":").last.map(String.init) ?? n }
        func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { start(Self.local(n), attributes) }
        func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) { end(Self.local(n)) }
        func parser(_ p: XMLParser, foundCharacters s: String) { text(s) }

        func run(_ data: Data) throws {
            let p = XMLParser(data: data)
            p.delegate = self
            p.shouldResolveExternalEntities = false
            guard p.parse() else { throw Engine.Failed(tool: "ooxml", detail: p.parserError?.localizedDescription ?? "bad xml") }
        }
    }

    /// The relationship id attribute ("r:id"), whatever its prefix.
    static func relID(_ attrs: [String: String]) -> String? { attrs.first { $0.key.hasSuffix(":id") }?.value }

    /// Relationship id → full path inside the zip.
    static func rels(_ archive: Archive, for part: String) throws -> [String: String] {
        let dir = (part as NSString).deletingLastPathComponent
        let relsPath = dir + "/_rels/" + (part as NSString).lastPathComponent + ".rels"
        var map: [String: String] = [:]
        let w = Walker()
        w.start = { name, a in
            guard name == "Relationship", let id = a["Id"], let target = a["Target"] else { return }
            map[id] = target.hasPrefix("/") ? String(target.dropFirst()) : ((dir + "/" + target) as NSString).standardizingPath
        }
        try w.run(read(archive, relsPath))
        return map
    }
}

enum XLSX {
    /// Sheet names and their paths, in workbook order.
    static func sheets(_ url: URL) throws -> [(name: String, path: String)] {
        let a = try Archive(url: url, accessMode: .read)
        let rels = try OOXML.rels(a, for: "xl/workbook.xml")
        var out: [(String, String)] = []
        let w = OOXML.Walker()
        w.start = { name, attrs in
            if name == "sheet", let id = OOXML.relID(attrs), let path = rels[id] { out.append((attrs["name"] ?? "Sheet \(out.count + 1)", path)) }
        }
        try w.run(OOXML.read(a, "xl/workbook.xml"))
        return out
    }

    /// One sheet as rows of cells: text (String), numbers (NSDecimalNumber, exact) and Bool.
    // shortcut: dates come out as Excel's day numbers (formatting lives in styles.xml); read styles if people ask.
    static func rows(_ url: URL, sheet: Int = 0) throws -> [[Any]] {
        let a = try Archive(url: url, accessMode: .read)
        let list = try sheets(url)
        guard sheet < list.count else { throw Engine.Failed(tool: "xlsx", detail: "no sheet") }

        var shared: [String] = []
        if a["xl/sharedStrings.xml"] != nil {
            var cur = "", inT = false, inPhonetic = false
            let w = OOXML.Walker()
            w.start = { n, _ in if n == "t" { inT = true } else if n == "rPh" { inPhonetic = true } }
            w.end = { n in
                if n == "t" { inT = false } else if n == "rPh" { inPhonetic = false } else if n == "si" { shared.append(cur); cur = "" }
            }
            w.text = { if inT && !inPhonetic { cur += $0 } }
            try w.run(OOXML.read(a, "xl/sharedStrings.xml"))
        }

        var rows: [[Any]] = [], row: [Any] = []
        var col = 0, type = "", text = "", collecting = false
        let w = OOXML.Walker()
        w.start = { n, attrs in
            switch n {
            case "row":
                // Keep empty rows in place so the layout matches what you see in Excel.
                if let r = attrs["r"].flatMap(Int.init) { while rows.count < r - 1 { rows.append([]) } }
                row = []
            case "c":
                col = attrs["r"].map(columnIndex) ?? row.count
                type = attrs["t"] ?? "n"
                text = ""
            case "v", "t": collecting = true
            default: break
            }
        }
        w.end = { n in
            switch n {
            case "v", "t": collecting = false
            case "c":
                let value: Any
                switch type {
                case "s": value = Int(text).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                case "b": value = text == "1"
                case "inlineStr", "str", "e": value = text
                default: value = text.isEmpty ? "" : NSDecimalNumber(string: text)
                }
                while row.count < col { row.append("") }
                row.append(value)
            case "row": rows.append(row)
            default: break
            }
        }
        w.text = { if collecting { text += $0 } }
        try w.run(OOXML.read(a, list[sheet].path))
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    /// "B3" → 1 (zero-based column).
    static func columnIndex(_ ref: String) -> Int {
        ref.prefix { $0.isLetter }.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    static func columnName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    private static let number = try! NSRegularExpression(pattern: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$"#)

    /// Writes a minimal, valid .xlsx with one sheet. Text that looks like a plain number becomes a number.
    static func write(_ rows: [[Any]], to url: URL) throws {
        var xml = ""
        for (r, row) in rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, v) in row.enumerated() {
                let ref = "\(columnName(c))\(r + 1)"
                if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                    xml += "<c r=\"\(ref)\" t=\"b\"><v>\(n.boolValue ? 1 : 0)</v></c>"
                } else if let n = v as? NSNumber {
                    xml += "<c r=\"\(ref)\"><v>\(n)</v></c>"
                } else {
                    let s = v is NSNull ? "" : "\(v)"
                    if s.isEmpty { continue }
                    if number.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                        xml += "<c r=\"\(ref)\"><v>\(s)</v></c>"
                    } else {
                        xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XMLJSON.escape(s))</t></is></c>"
                    }
                }
            }
            xml += "</row>"
        }
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
        let ct = "application/vnd.openxmlformats-officedocument.spreadsheetml"
        let parts: [(String, String)] = [
            ("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"\(ct).sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"\(ct).worksheet+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"\(ct).styles+xml\"/></Types>"),
            ("_rels/.rels", "<Relationships xmlns=\"\(pkg)\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"),
            ("xl/workbook.xml", "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"\(pkg)\"><Relationship Id=\"rId1\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/></Relationships>"),
            ("xl/styles.xml", "<styleSheet xmlns=\"\(main)\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"),
            ("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"\(main)\"><sheetData>\(xml)</sheetData></worksheet>"),
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (path, body) in parts {
            let data = Data((head + body).utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
    }
}

enum PPTX {
    /// All slide text, slide by slide, one paragraph per line.
    static func outline(_ url: URL) throws -> String {
        let a = try Archive(url: url, accessMode: .read)
        let rels = try OOXML.rels(a, for: "ppt/presentation.xml")
        var order: [String] = []
        let w = OOXML.Walker()
        w.start = { n, attrs in if n == "sldId", let id = OOXML.relID(attrs), let p = rels[id] { order.append(p) } }
        try w.run(OOXML.read(a, "ppt/presentation.xml"))

        return try order.enumerated().map { i, path in
            var paras: [String] = [], cur = "", inT = false
            let s = OOXML.Walker()
            s.start = { n, _ in if n == "t" { inT = true } else if n == "br" { cur += " " } }
            s.end = { n in
                if n == "t" { inT = false }
                if n == "p" { let t = cur.trimmingCharacters(in: .whitespaces); if !t.isEmpty { paras.append(t) }; cur = "" }
            }
            s.text = { if inT { cur += $0 } }
            try s.run(OOXML.read(a, path))
            return (["Slide \(i + 1)"] + paras.map { "  " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }
}

/// Pages, Numbers and Keynote export through the apps' own AppleScript. Only offered when the app is installed.
enum IWork {
    static let apps = ["pages": "Pages", "numbers": "Numbers", "key": "Keynote"]

    static func installed(_ ext: String) -> Bool {
        apps[ext].map { FileManager.default.fileExists(atPath: "/Applications/\($0).app") } ?? false
    }

    /// AppleScript export format for each output.
    static func format(_ inExt: String, _ outExt: String) -> String? {
        [
            "pages.docx": "Microsoft Word", "pages.pdf": "PDF",
            "numbers.xlsx": "Microsoft Excel", "numbers.csv": "CSV", "numbers.pdf": "PDF",
            "key.pptx": "Microsoft PowerPoint", "key.pdf": "PDF", "key.": "slide images with properties {image format:PNG}",
        ]["\(inExt).\(outExt)"]
    }

    static func export(_ src: URL, to out: URL, outExt: String) async throws {
        let inExt = src.pathExtension.lowercased()
        guard let app = apps[inExt], let fmt = format(inExt, outExt) else { throw Engine.Failed(tool: "iwork", detail: "unsupported") }
        let bundle = "com.apple.iWork.\(app)"
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
        // Start it in the background and hidden, so no window jumps in front of Deck.
        if !wasRunning { _ = try? await Engine.run("open", ["-g", "-j", "-b", bundle]) }
        // Paths go in as arguments, never pasted into the script text.
        let script = """
        on run argv
            tell application id "\(bundle)"
                set d to open (POSIX file (item 1 of argv))
                try
                    export d to (POSIX file (item 2 of argv)) as \(fmt)
                on error e
                    close d saving no
                    error e
                end try
                close d saving no
                \(wasRunning ? "" : "quit")
            end tell
        end run
        """
        try await Engine.run("osascript", ["-e", script, src.path, out.path])
    }
}
