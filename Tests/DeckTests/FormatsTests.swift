import XCTest
import ZIPFoundation
@testable import Deck

final class FormatsTests: XCTestCase {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("deck-fmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func ids(_ name: String) -> [String] { Converters.targets(for: URL(fileURLWithPath: "/x/" + name)).map(\.id) }
    private func target(_ name: String, _ id: String) -> Target? { Converters.targets(for: URL(fileURLWithPath: "/x/" + name)).first { $0.id == id } }

    func testRouting() throws {
        XCTAssertTrue(ids("a.gif").contains("anim.webp"))
        XCTAssertTrue(ids("a.gif").contains("anim.avif"))
        XCTAssertFalse(ids("a.png").contains("anim.webp"))
        XCTAssertEqual(target("a.png", "img.icns")?.ext, "icns")

        let mov = ids("a.mov")
        for id in ["video.screen", "video.edit", "video.dnxhd", "video.mp3", "video.frames", "video.loud", "video.speed50", "video.speed200",
                   "video.subs", "anim.webp", "anim.avif", "video.webm"] {
            XCTAssertTrue(mov.contains(id), id)
        }
        XCTAssertFalse(mov.contains("video.burn"), "only with a matching .srt")
        XCTAssertEqual(target("a.mov", "video.loud")?.ext, "mov")
        XCTAssertEqual(target("a.avi", "video.loud")?.ext, "mp4")
        XCTAssertFalse(ids("a.avi").contains("video.subs"))

        let wav = ids("a.wav")
        for id in ["audio.ringtone", "audio.wma", "audio.ac3", "audio.mp2", "audio.loud", "audio.speed150"] { XCTAssertTrue(wav.contains(id), id) }
        XCTAssertEqual(target("a.wav", "audio.ringtone")?.ext, "m4r")
        XCTAssertEqual(target("a.wav", "audio.loud")?.ext, "wav")
        XCTAssertEqual(target("a.ogg", "audio.loud")?.ext, "m4a")

        for f in ["a.xml", "a.toml", "a.yml", "a.yaml"] { XCTAssertTrue(ids(f).contains("data.json"), f) }
        XCTAssertFalse(ids("a.yml").contains("data.yaml"))
        XCTAssertFalse(ids("a.xml").contains("data.xml"))
        XCTAssertTrue(ids("a.json").contains("data.xml"))
        XCTAssertTrue(ids("a.csv").contains("data.xlsx"))
        XCTAssertTrue(ids("a.json").contains("data.xlsx"))

        XCTAssertEqual(ids("a.xlsx").prefix(2), ["xlsx.csv", "xlsx.json"])
        XCTAssertNil(target("a.xlsx", "xlsx.csv")?.addOn, "Excel → CSV works without the Office pack")
        XCTAssertTrue(ids("a.pptx").contains("pptx.outline"))
        XCTAssertEqual(target("a.pptx", "office.slides")?.addOn, "office")
        XCTAssertEqual(target("a.ppt", "office.pdf")?.addOn, "office")
        XCTAssertFalse(ids("a.ppt").contains("pptx.outline"))

        XCTAssertEqual(target("a.tex", "latex.pdf")?.addOn, "latex")
        XCTAssertNil(target("a.tex", "doc.pdf")?.addOn, "quick PDF needs nothing extra")
        XCTAssertNil(target("a.md", "latex.pdf"))

        XCTAssertEqual(target("a.ttf", "font.woff2")?.addOn, "fonts")
        XCTAssertNil(target("a.ttf", "font.desktop"), "TTF ↔ OTF isn't offered")
        XCTAssertNil(target("a.ttf", "font.otf"))
        XCTAssertNotNil(target("a.woff2", "font.desktop"))
        XCTAssertNil(target("a.woff2", "font.woff2"))

        for id in ["arc.tgz", "arc.txz", "arc.tzst"] { XCTAssertTrue(ids("a.txt").contains(id), id) }
        XCTAssertEqual(target("a.txt", "arc.tgz")?.ext, "tar.gz")

        XCTAssertEqual(ids("a.pages").contains("iwork.docx"), IWork.installed("pages"))
        XCTAssertEqual(ids("a.key").contains("iwork.images"), IWork.installed("key"))

        let pics = [URL(fileURLWithPath: "/x/a.jpg"), URL(fileURLWithPath: "/x/b.heic")]
        XCTAssertEqual(Converters.combineTargets(for: pics).map(\.id), ["combine.video", "combine.tiff"])
        XCTAssertTrue(Converters.combineTargets(for: [pics[0]]).isEmpty)
        XCTAssertTrue(Converters.combineTargets(for: [pics[0], URL(fileURLWithPath: "/x/c.mov")]).isEmpty)

        // A matching .srt next to the video turns on "With subtitles".
        let dir = try tmp()
        let video = dir.appendingPathComponent("Trip.mp4"), srt = dir.appendingPathComponent("Trip.srt")
        FileManager.default.createFile(atPath: video.path, contents: Data())
        FileManager.default.createFile(atPath: srt.path, contents: Data())
        XCTAssertEqual(Converters.targets(for: video).first?.id, "video.burn")
    }

    func testAddOns() {
        XCTAssertEqual(Setup.addOns.map(\.id), ["office", "latex", "fonts", "videolinks"])
        let latex = Setup.addOn("latex")
        XCTAssertTrue(latex.detail.contains("Downloads the LaTeX pieces it needs the first time you use it."))
        XCTAssertEqual(latex.formula, "tectonic")
        XCTAssertNil(latex.cask)
        XCTAssertEqual(Setup.addOn("office").cask, "libreoffice")
        XCTAssertEqual(Setup.addOn("videolinks").detail, "Only for videos you have the right to download.")
        XCTAssertEqual(Setup.installed(Setup.addOn("fonts")), Engine.has("fonttools"))
    }

    func testSmallParsers() {
        XCTAssertEqual(VideoEdit.seconds("1:05"), 65)
        XCTAssertEqual(VideoEdit.seconds("1:02:03.5"), 3723.5)
        XCTAssertEqual(VideoEdit.seconds("90"), 90)
        XCTAssertNil(VideoEdit.seconds("abc"))
        XCTAssertNil(VideoEdit.seconds("1:2:3:4"))
        XCTAssertEqual(VideoLink.percent("[download]  42.0% of   10.00MiB at  1.00MiB/s ETA 00:05"), 0.42)
        XCTAssertNil(VideoLink.percent("[youtube] abc: Downloading webpage"))
        XCTAssertEqual(XLSX.columnIndex("A1"), 0)
        XCTAssertEqual(XLSX.columnIndex("AB12"), 27)
        XCTAssertEqual(XLSX.columnName(27), "AB")
        XCTAssertEqual(XLSX.columnName(XLSX.columnIndex("ZZ9")), "ZZ")
    }

    func testXMLJSON() throws {
        let xml = """
        <?xml version="1.0"?>
        <library city="Pune">
          <book id="1"><title>Dune</title><tag>sf</tag><tag>classic</tag></book>
          <book id="2"><title>Emma &amp; co</title></book>
          <note>Open daily</note>
        </library>
        """
        let v = try XMLJSON.parse(Data(xml.utf8))
        let lib = try XCTUnwrap(v["library"] as? [String: Any])
        XCTAssertEqual(lib["@city"] as? String, "Pune")
        XCTAssertEqual(lib["note"] as? String, "Open daily")
        let books = try XCTUnwrap(lib["book"] as? [[String: Any]])
        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(books[0]["tag"] as? [String], ["sf", "classic"])
        XCTAssertEqual(books[1]["title"] as? String, "Emma & co")

        // JSON → XML → JSON keeps the data.
        let back = try XMLJSON.parse(Data(XMLJSON.xml(v).utf8))
        XCTAssertEqual(try json(back), try json(v))

        let fromJSON = XMLJSON.xml(["name": "Sam", "2nd key": [1, 2], "ok": true] as [String: Any])
        XCTAssertTrue(fromJSON.contains("<_2nd_key>1</_2nd_key>"))
        XCTAssertTrue(fromJSON.contains("<ok>true</ok>"))
        XCTAssertNoThrow(try XMLJSON.parse(Data(fromJSON.utf8)))
    }

    private func json(_ v: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]), as: UTF8.self)
    }

    func testTOML() throws {
        let text = #"""
        # Settings
        title = "Deck \"app\""
        path = 'C:\no\escape'
        count = 1_000
        hex = 0xff
        ratio = 0.5
        big = 1e3
        on = true
        when = 1979-05-27T07:32:00Z
        day = 1979-05-27 07:32:00
        list = [1, 2,
          3, ]  # trailing comma
        point = { x = 1, y = "two" }
        site."google.com" = true
        bio = """
        Hello \
          there"""

        [owner]
        name = "Nav"

        [owner.pets]
        cat = "Mo"

        [[fruit]]
        name = "apple"

        [[fruit]]
        name = "pear"
        [fruit.color]
        main = "green"
        """#
        let v = try TOML.parse(text)
        XCTAssertEqual(v["title"] as? String, "Deck \"app\"")
        XCTAssertEqual(v["path"] as? String, #"C:\no\escape"#)
        XCTAssertEqual(v["count"] as? Int, 1000)
        XCTAssertEqual(v["hex"] as? Int, 255)
        XCTAssertEqual(v["ratio"] as? Double, 0.5)
        XCTAssertEqual(v["big"] as? Double, 1000)
        XCTAssertEqual(v["on"] as? Bool, true)
        XCTAssertEqual(v["when"] as? String, "1979-05-27T07:32:00Z")
        XCTAssertEqual(v["day"] as? String, "1979-05-27 07:32:00")
        XCTAssertEqual(v["list"] as? [Int], [1, 2, 3])
        XCTAssertEqual((v["point"] as? [String: Any])?["y"] as? String, "two")
        XCTAssertEqual((v["site"] as? [String: Any])?["google.com"] as? Bool, true)
        XCTAssertEqual(v["bio"] as? String, "Hello there")
        XCTAssertEqual(((v["owner"] as? [String: Any])?["pets"] as? [String: Any])?["cat"] as? String, "Mo")
        let fruit = try XCTUnwrap(v["fruit"] as? [[String: Any]])
        XCTAssertEqual(fruit.map { $0["name"] as? String }, ["apple", "pear"])
        XCTAssertEqual((fruit[1]["color"] as? [String: Any])?["main"] as? String, "green")

        XCTAssertThrowsError(try TOML.parse("a = \n")) { XCTAssertEqual(($0 as? TOML.Bad)?.line, 1) }
        XCTAssertThrowsError(try TOML.parse("ok = 1\nbad = \"open\n"))
        XCTAssertEqual(try TOML.parse("x = 1\r\ny = 2\r\n")["y"] as? Int, 2)
    }

    func testDataFilesToJSON() throws {
        let dir = try tmp()
        let cases = [("a.yaml", "name: Sam\ntags: [a, b]\nage: 30\n"), ("b.toml", "name = \"Sam\"\ntags = [\"a\", \"b\"]\nage = 30\n")]
        for (name, text) in cases {
            let src = dir.appendingPathComponent(name)
            try text.write(to: src, atomically: true, encoding: .utf8)
            let out = try await_convert(src, "data.json")
            let v = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
            XCTAssertEqual(v["name"] as? String, "Sam", name)
            XCTAssertEqual(v["tags"] as? [String], ["a", "b"], name)
            XCTAssertEqual(v["age"] as? Int, 30, name)
        }
    }

    /// Data conversions are synchronous under the hood; this keeps the test short.
    private func await_convert(_ src: URL, _ id: String) throws -> URL {
        let t = try XCTUnwrap(Converters.targets(for: src).first { $0.id == id }, id)
        let out = FileManager.default.freeURL(in: src.deletingLastPathComponent(), name: src.deletingPathExtension().lastPathComponent, ext: t.ext)
        try DataConvert.convert(src, toExt: t.ext, out: out)
        return out
    }

    func testXLSXRoundTrip() async throws {
        let dir = try tmp()
        let csvText = "name,score,note,passed\nSam,3.5,\"Hi, there\",TRUE\nAlex,-12,007,FALSE\n,,,\nZoë,1000,\"say \"\"yo\"\"\",\n"
        let csv = dir.appendingPathComponent("scores.csv")
        try csvText.write(to: csv, atomically: true, encoding: .utf8)

        let xlsx = try await Converters.convert(csv, to: XCTUnwrap(Converters.targets(for: csv).first { $0.id == "data.xlsx" })) { _ in }
        XCTAssertEqual(xlsx.pathExtension, "xlsx")
        XCTAssertEqual(try XLSX.sheets(xlsx).map(\.name), ["Sheet1"])
        let rows = try XLSX.rows(xlsx)
        XCTAssertTrue(rows[1][1] is NSDecimalNumber, "numbers are stored as numbers")
        XCTAssertEqual(rows[2][2] as? String, "007", "leading zeros stay text")

        let back = try await Converters.convert(xlsx, to: XCTUnwrap(Converters.targets(for: xlsx).first { $0.id == "xlsx.csv" })) { _ in }
        XCTAssertEqual(try String(contentsOf: back, encoding: .utf8), csvText)

        let json = try await Converters.convert(xlsx, to: XCTUnwrap(Converters.targets(for: xlsx).first { $0.id == "xlsx.json" })) { _ in }
        let records = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]])
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0]["score"] as? Double, 3.5)
        XCTAssertEqual(records[2]["name"] as? String, "Zoë")

        // JSON → Excel too.
        let src = dir.appendingPathComponent("people.json")
        try #"[{"name":"Sam","age":30,"ok":true},{"name":"Alex","age":4.5}]"#.write(to: src, atomically: true, encoding: .utf8)
        let fromJSON = try await Converters.convert(src, to: XCTUnwrap(Converters.targets(for: src).first { $0.id == "data.xlsx" })) { _ in }
        let r = try XLSX.rows(fromJSON)
        XCTAssertEqual(r[0] as? [String], ["age", "name", "ok"])
        XCTAssertEqual(r[1][2] as? Bool, true)
        XCTAssertEqual("\(r[2][0])", "4.5")
    }

    func testXLSXSharedStringsAndSheets() throws {
        let dir = try tmp()
        let url = dir.appendingPathComponent("book.xlsx")
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        try zip(url, [
            ("xl/workbook.xml", "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheets><sheet name=\"Totals\" sheetId=\"1\" r:id=\"rId7\"/><sheet name=\"Raw\" sheetId=\"2\" r:id=\"rId8\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId7\" Target=\"/xl/worksheets/b.xml\"/><Relationship Id=\"rId8\" Target=\"worksheets/a.xml\"/></Relationships>"),
            ("xl/sharedStrings.xml", "<sst xmlns=\"\(main)\"><si><t>Item</t></si><si><r><t>Rich </t></r><r><t>text</t></r></si></sst>"),
            ("xl/worksheets/b.xml", "<worksheet xmlns=\"\(main)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"C1\" t=\"s\"><v>1</v></c></row><row r=\"3\"><c r=\"B3\"><f>1+1</f><v>2</v></c><c r=\"C3\" t=\"b\"><v>1</v></c></row></sheetData></worksheet>"),
            ("xl/worksheets/a.xml", "<worksheet xmlns=\"\(main)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>raw</t></is></c></row></sheetData></worksheet>"),
        ])
        XCTAssertEqual(try XLSX.sheets(url).map(\.name), ["Totals", "Raw"])
        XCTAssertEqual(DataConvert.csv(rows: try XLSX.rows(url)), "Item,,Rich text\n,,\n,2,TRUE\n")
        XCTAssertEqual(DataConvert.csv(rows: try XLSX.rows(url, sheet: 1)), "raw\n")
        XCTAssertTrue(Converters.targets(for: url).contains { $0.id == "xlsx.allcsv" })
    }

    func testPPTXOutline() throws {
        let dir = try tmp()
        let url = dir.appendingPathComponent("talk.pptx")
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main", p = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        func slide(_ paras: [[String]]) -> String {
            let body = paras.map { "<a:p>" + $0.map { "<a:r><a:t>\($0)</a:t></a:r>" }.joined() + "</a:p>" }.joined()
            return "<p:sld xmlns:a=\"\(a)\" xmlns:p=\"\(p)\"><p:cSld><p:spTree><p:sp><p:txBody>\(body)</p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
        }
        try zip(url, [
            // The deck shows slide2.xml first: order comes from the presentation, not the file names.
            ("ppt/presentation.xml", "<p:presentation xmlns:p=\"\(p)\" xmlns:r=\"\(r)\"><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId3\"/><p:sldId id=\"257\" r:id=\"rId2\"/></p:sldIdLst></p:presentation>"),
            ("ppt/_rels/presentation.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId2\" Target=\"slides/slide1.xml\"/><Relationship Id=\"rId3\" Target=\"slides/slide2.xml\"/></Relationships>"),
            ("ppt/slides/slide1.xml", slide([["Thanks"], [], ["Questions &amp; answers"]])),
            ("ppt/slides/slide2.xml", slide([["Deck ", "v1.1"], ["Fast", " and private"]])),
        ])
        XCTAssertEqual(try PPTX.outline(url), "Slide 1\n  Deck v1.1\n  Fast and private\n\nSlide 2\n  Thanks\n  Questions & answers\n")
    }

    private func zip(_ url: URL, _ parts: [(String, String)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, text) in parts {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
    }

    func testTarArchivesRoundTrip() async throws {
        let dir = try tmp()
        let folder = dir.appendingPathComponent("Stuff")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try String(repeating: "deck ", count: 1000).write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        for id in ["arc.tgz", "arc.txz", "arc.tzst"] {
            let tool = ["arc.txz": "xz", "arc.tzst": "zstd"][id]
            if let tool, !Engine.has(tool) { continue }
            let t = try XCTUnwrap(Converters.targets(for: folder).first { $0.id == id })
            let packed = try await Converters.convert(folder, to: t) { _ in }
            XCTAssertTrue(packed.lastPathComponent.hasPrefix("Stuff.tar."), id)
            let list = try await Engine.run("tar", ["-tf", packed.path] + (id == "arc.tzst" ? ["--use-compress-program", "zstd -d"] : []))
            XCTAssertTrue(list.contains("Stuff/a.txt"), id)
            let unpacked = try await Converters.convert(packed, to: XCTUnwrap(Converters.targets(for: packed).first { $0.id == "arc.extract" })) { _ in }
            XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("Stuff/a.txt"), encoding: .utf8).count, 5000, id)
        }
        // A single compressed file (not a tar) comes back as the file.
        let gz = dir.appendingPathComponent("note.txt.gz")
        try await Engine.run("gzip", ["-c", folder.appendingPathComponent("a.txt").path], stdoutTo: gz)
        let back = try await Converters.convert(gz, to: XCTUnwrap(Converters.targets(for: gz).first { $0.id == "arc.extract" })) { _ in }
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("note.txt"), encoding: .utf8).count, 5000)
    }

    func testRealConversions() async throws {
        guard Engine.has("ffmpeg"), Engine.has("magick") else { throw XCTSkip("helpers not installed") }
        let dir = try tmp()
        let ff = ["-hide_banner", "-loglevel", "error"]
        let wav = dir.appendingPathComponent("tone.wav")
        try await Engine.run("ffmpeg", ff + ["-f", "lavfi", "-i", "sine=frequency=440:duration=40", wav.path])
        let mov = dir.appendingPathComponent("clip.mov")
        try await Engine.run("ffmpeg", ff + ["-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=15", "-f", "lavfi", "-i", "sine=duration=2",
                                             "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", mov.path])
        try "1\n00:00:00,000 --> 00:00:01,500\nHello there\n".write(to: dir.appendingPathComponent("clip.srt"), atomically: true, encoding: .utf8)
        let gif = dir.appendingPathComponent("loop.gif")
        try await Engine.run("ffmpeg", ff + ["-f", "lavfi", "-i", "testsrc=duration=1:size=64x48:rate=10", gif.path])
        let png = dir.appendingPathComponent("pic.png"), png2 = dir.appendingPathComponent("pic2.png")
        try await Engine.run("ffmpeg", ff + ["-f", "lavfi", "-i", "testsrc=size=300x200", "-frames:v", "1", png.path])
        try await Engine.run("ffmpeg", ff + ["-f", "lavfi", "-i", "mandelbrot=size=200x300", "-frames:v", "1", png2.path])

        let cases: [(URL, String)] = [
            (wav, "audio.ringtone"), (wav, "audio.wma"), (wav, "audio.ac3"), (wav, "audio.mp2"), (wav, "audio.loud"), (wav, "audio.speed150"),
            (mov, "video.webm"), (mov, "video.screen"), (mov, "video.dnxhd"), (mov, "video.mp3"), (mov, "video.loud"), (mov, "video.speed200"),
            (mov, "video.burn"), (mov, "anim.webp"), (mov, "anim.avif"), (gif, "anim.webp"), (gif, "anim.avif"), (png, "img.icns"),
        ]
        for (src, id) in cases {
            let t = try XCTUnwrap(Converters.targets(for: src).first { $0.id == id }, id)
            let out = try await Converters.convert(src, to: t) { _ in }
            XCTAssertGreaterThan(FileManager.default.size(of: out), 0, id)
            XCTAssertEqual(out.pathExtension, t.ext, id)
            let length = await Converters.mediaDuration(out)
            if id == "audio.ringtone" { XCTAssertEqual(length, 30, accuracy: 0.2) }
            if id == "audio.speed150" { XCTAssertEqual(length, 40 / 1.5, accuracy: 0.3) }
            if id == "video.burn" {
                // Subtitles went in (drawn or as a track); taking them back out proves it for the track case.
                if !Converters.canBurnSubtitles {
                    let srt = try await Converters.convert(out, to: XCTUnwrap(Converters.targets(for: out).first { $0.id == "video.subs" })) { _ in }
                    XCTAssertTrue(try String(contentsOf: srt, encoding: .utf8).contains("Hello there"))
                }
            }
        }

        let animated = try await Engine.run("magick", ["identify", dir.appendingPathComponent("loop.webp").path])
        XCTAssertGreaterThan(animated.split(separator: "\n").count, 1, "animated WebP keeps every frame")

        // Rotate 90° and keep 0.5 s → 1.5 s.
        let edit = try await Converters.convert(mov, to: XCTUnwrap(target(for: mov, "video.edit")), edit: VideoEdit(rotate: 90, start: "0.5", end: "0:01.5")) { _ in }
        let dims = try await Engine.run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", edit.path])
        XCTAssertEqual(dims.trimmingCharacters(in: .whitespacesAndNewlines), "240,320")
        let editLength = await Converters.mediaDuration(edit)
        XCTAssertEqual(editLength, 1, accuracy: 0.15)

        let frames = try await Converters.convert(mov, to: XCTUnwrap(target(for: mov, "video.frames"))) { _ in }
        XCTAssertGreaterThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: frames.path).count, 2)

        let slideshow = try await Converters.combine([png, png2], to: Converters.combineTargets(for: [png, png2])[0]) { _ in }
        let showLength = await Converters.mediaDuration(slideshow)
        XCTAssertEqual(showLength, 6, accuracy: 0.2)
        let tiff = try await Converters.combine([png, png2], to: Converters.combineTargets(for: [png, png2])[1]) { _ in }
        let pages = try await Engine.run("magick", ["identify", tiff.path])
        XCTAssertEqual(pages.split(separator: "\n").count, 2)

        let icons = try await Engine.run("iconutil", ["-c", "iconset", "-o", dir.appendingPathComponent("check.iconset").path, dir.appendingPathComponent("pic.icns").path])
        _ = icons
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("check.iconset").path).count, 10)
    }

    private func target(for url: URL, _ id: String) -> Target? { Converters.targets(for: url).first { $0.id == id } }

    func testLaTeXToWebPage() async throws {
        guard Engine.has("pandoc") else { throw XCTSkip("pandoc not installed") }
        let dir = try tmp()
        let tex = dir.appendingPathComponent("notes.tex")
        try #"\documentclass{article}\begin{document}\section{Hi}Energy: $E = mc^2$\end{document}"#.write(to: tex, atomically: true, encoding: .utf8)
        let html = try await Converters.convert(tex, to: XCTUnwrap(target(for: tex, "doc.html"))) { _ in }
        XCTAssertTrue(try String(contentsOf: html, encoding: .utf8).contains("<math"), "math kept as MathML")
        let md = try await Converters.convert(tex, to: XCTUnwrap(target(for: tex, "doc.md"))) { _ in }
        XCTAssertTrue(try String(contentsOf: md, encoding: .utf8).contains("mc^2"))
    }
}
