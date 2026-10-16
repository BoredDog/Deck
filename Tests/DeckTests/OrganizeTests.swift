import XCTest
@testable import Deck

final class OrganizeTests: XCTestCase {
    var dir: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("org-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        Organizer.undoFile = dir.appendingPathComponent(".undo.json")
        UserDefaults.standard.removeObject(forKey: "courseNames")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
        UserDefaults.standard.removeObject(forKey: "courseNames")
    }

    @discardableResult
    func make(_ path: String, _ text: String = "x", created: Date? = nil, modified: Date? = nil) -> URL {
        let url = dir.appendingPathComponent(path)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
        var attrs: [FileAttributeKey: Any] = [:]
        if let created { attrs[.creationDate] = created }
        if let modified { attrs[.modificationDate] = modified }
        if !attrs.isEmpty { try! fm.setAttributes(attrs, ofItemAtPath: url.path) }
        return url
    }

    func plan(_ o: OrganizeOptions = OrganizeOptions(), rules: [OrganizeRule] = [], courses: [String] = []) async -> [String: String] {
        let moves = await Organizer.plan(folder: dir, options: o, rules: rules, courses: courses)
        // Paths may come back as /var/… or /private/var/…; compare from the temp folder's own name on.
        let rel = { (u: URL) in String(u.path.components(separatedBy: self.dir.lastPathComponent + "/").last!) }
        return Dictionary(uniqueKeysWithValues: moves.map { (rel($0.source), rel($0.destination)) })
    }

    func opts(_ p: GroupBy, _ s: GroupBy? = nil, clean: Bool = false, deep: Bool = false) -> OrganizeOptions {
        OrganizeOptions(primary: p, secondary: s, cleanNames: clean, includeSubfolders: deep)
    }

    func setWhereFrom(_ url: URL, _ links: [String]) {
        let data = try! PropertyListSerialization.data(fromPropertyList: links, format: .binary, options: 0)
        let r = data.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, data.count, 0, 0) }
        XCTAssertEqual(r, 0)
    }

    // MARK: grouping

    func testTypeGrouping() async {
        let files = ["a.pdf": "PDFs", "b.pptx": "Slides", "c.xlsx": "Spreadsheets", "c2.csv": "Spreadsheets", "d.png": "Images",
                     "Screenshot 2026-10-16 at 10.00.00.png": "Screenshots", "Screen Shot 2020-01-01.png": "Screenshots",
                     "e.mp4": "Videos", "f.mp3": "Audio", "g.docx": "Documents", "g2.txt": "Documents", "h.swift": "Code",
                     "h2.py": "Code", "i.zip": "Archives", "j.dmg": "Installers", "k.ttf": "Fonts", "l.xyz": "Other"]
        for f in files.keys { make(f) }
        let p = await plan(opts(.type))
        for (f, folder) in files { XCTAssertEqual(p[f], "\(folder)/\(f)", f) }
        let moves = await Organizer.plan(folder: dir, options: opts(.type), rules: [], courses: [])
        XCTAssertEqual(moves.first { $0.source.lastPathComponent == "a.pdf" }?.reason, "PDFs")
    }

    func testDateGrouping() async {
        let oct = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 3))!
        let mar = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2025, month: 3, day: 9))!
        make("a.pdf", created: oct)
        make("b.jpg", created: mar)
        let p = await plan(opts(.date))
        XCTAssertEqual(p["a.pdf"], "2026/10 October/a.pdf")
        XCTAssertEqual(p["b.jpg"], "2025/03 March/b.jpg")
        let both = await plan(opts(.type, .date))
        XCTAssertEqual(both["a.pdf"], "PDFs/2026/10 October/a.pdf")
        let moves = await Organizer.plan(folder: dir, options: opts(.type, .date), rules: [], courses: [])
        XCTAssertEqual(moves.first { $0.source.lastPathComponent == "a.pdf" }?.reason, "PDFs · October 2026")
    }

    func testCourseMatchingCodesNamesAndAbbreviations() async {
        CourseNames.set("Linear Algebra", for: "M26MA1.101")
        let courses = ["M26EC2.102", "M26MA1.101", "Physics"]
        make("EC2.102_Lec3.pdf")
        make("m26ec2102 tut.pdf")
        make("LinAlg_hw2.pdf")
        make("Lin Alg notes.pdf")
        make("linear-algebra-midterm.pdf")
        make("LA quiz.pdf")
        make("la la land.pdf")            // lower-case "la" is not initials
        make("Phys lab.pdf")
        make("physical therapy.pdf")      // not "Physics"
        make("holiday.jpg")
        let p = await plan(opts(.course), courses: courses)
        XCTAssertEqual(p["EC2.102_Lec3.pdf"], "M26EC2.102/EC2.102_Lec3.pdf", "no name given → the code is the folder")
        XCTAssertEqual(p["m26ec2102 tut.pdf"], "M26EC2.102/m26ec2102 tut.pdf")
        XCTAssertEqual(p["LinAlg_hw2.pdf"], "Linear Algebra/LinAlg_hw2.pdf")
        XCTAssertEqual(p["Lin Alg notes.pdf"], "Linear Algebra/Lin Alg notes.pdf")
        XCTAssertEqual(p["linear-algebra-midterm.pdf"], "Linear Algebra/linear-algebra-midterm.pdf")
        XCTAssertEqual(p["LA quiz.pdf"], "Linear Algebra/LA quiz.pdf")
        XCTAssertEqual(p["Phys lab.pdf"], "Physics/Phys lab.pdf")
        XCTAssertNil(p["la la land.pdf"])
        XCTAssertNil(p["physical therapy.pdf"])
        XCTAssertNil(p["holiday.jpg"], "unmatched files stay when grouping by course only")
    }

    func testCourseFromWhereFrom() async {
        CourseNames.set("Linear Algebra", for: "M26MA1.101")
        setWhereFrom(make("download.pdf"), ["https://moodle.example.edu/course/view.php?name=M26EC2.102", "https://moodle.example.edu/"])
        setWhereFrom(make("file.pdf"), ["https://moodle.example.edu/pluginfile.php/9/Linear%20Algebra/file.pdf"])
        setWhereFrom(make("other.pdf"), ["https://example.com/other.pdf"])
        let p = await plan(opts(.course), courses: ["M26EC2.102", "M26MA1.101"])
        XCTAssertEqual(p["download.pdf"], "M26EC2.102/download.pdf")
        XCTAssertEqual(p["file.pdf"], "Linear Algebra/file.pdf")
        XCTAssertNil(p["other.pdf"])
        XCTAssertEqual(Organizer.whereFroms(dir.appendingPathComponent("other.pdf")), ["https://example.com/other.pdf"])
    }

    func testCourseThenType() async {
        CourseNames.set("Linear Algebra", for: "M26MA1.101")
        make("LinAlg slides.pptx")
        make("holiday.jpg")
        let p = await plan(opts(.course, .type), courses: ["M26MA1.101"])
        XCTAssertEqual(p["LinAlg slides.pptx"], "Linear Algebra/Slides/LinAlg slides.pptx")
        XCTAssertEqual(p["holiday.jpg"], "Images/holiday.jpg", "no course → just the second grouping")
    }

    // MARK: rules

    func testRulesFirstMatchWinsThenGrouping() async {
        let rules = [OrganizeRule(field: .nameContains, value: "hw", folder: "Homework"),
                     OrganizeRule(field: .extensionIs, value: ".PDF, docx", folder: "Papers/Read"),
                     OrganizeRule(field: .largerThanMB, value: "0.0001", folder: "Big")]
        make("HW1.pdf")
        make("essay.docx")
        make("x.pdf")
        make("pic.png")
        make("large.bin", String(repeating: "x", count: 500))
        var p = await plan(opts(.type), rules: rules)
        XCTAssertEqual(p["HW1.pdf"], "Homework/HW1.pdf")
        XCTAssertEqual(p["essay.docx"], "Papers/Read/essay.docx")
        XCTAssertEqual(p["x.pdf"], "Papers/Read/x.pdf")
        XCTAssertEqual(p["large.bin"], "Big/large.bin")
        XCTAssertEqual(p["pic.png"], "Images/pic.png")
        p = await plan(opts(.rules), rules: rules)
        XCTAssertNil(p["pic.png"], "rules only: unmatched files stay")
        XCTAssertEqual(p["HW1.pdf"], "Homework/HW1.pdf")
    }

    func testOlderThanAndSiteRules() async {
        make("old.txt", created: Date(timeIntervalSinceNow: -40 * 86_400))
        make("new.txt")
        setWhereFrom(make("m.pdf"), ["https://moodle.iiit.ac.in/x"])
        let rules = [OrganizeRule(field: .olderThanDays, value: "30", folder: "Old"),
                     OrganizeRule(field: .fromSiteContains, value: "MOODLE", folder: "Moodle")]
        let p = await plan(opts(.rules), rules: rules)
        XCTAssertEqual(p["old.txt"], "Old/old.txt")
        XCTAssertNil(p["new.txt"])
        XCTAssertEqual(p["m.pdf"], "Moodle/m.pdf")
    }

    func testRuleFolderCannotEscape() async {
        make("a.txt")
        let p = await plan(opts(.rules), rules: [OrganizeRule(field: .nameContains, value: "a", folder: "../../evil/./x")])
        XCTAssertEqual(p["a.txt"], "evil/x/a.txt")
    }

    // MARK: safety

    func testNeverOverwrites() async {
        make("PDFs/a.pdf", "old")
        make("a.pdf", "new")
        make("Report (1).pdf")
        make("Report copy.pdf")
        make("Report.txt")
        let p = await plan(opts(.type, clean: true))
        XCTAssertEqual(p["a.pdf"], "PDFs/a 2.pdf")
        XCTAssertEqual(Set([p["Report (1).pdf"], p["Report copy.pdf"]]), ["PDFs/Report.pdf", "PDFs/Report 2.pdf"])
        XCTAssertEqual(p["Report.txt"], "Documents/Report.txt")
    }

    func testSkipsHiddenPackagesPartialsLinksAndCreatedFolders() async throws {
        make(".hidden.pdf")
        make("Thing.app/Contents/Info.plist")
        make("Lib.photoslibrary/db.pdf")
        make("movie.mp4.crdownload")
        make("x.part")
        make("y.download")
        make("z.aria2")
        let real = make("real.pdf")
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link.pdf"), withDestinationURL: real)
        try URL.writeBookmarkData(real.bookmarkData(options: .suitableForBookmarkFile), to: dir.appendingPathComponent("alias.pdf"))
        make("PDFs/already.pdf")
        make("2026/10 October/dated.pdf")
        make("Sub/deep.pdf")
        var p = await plan(opts(.type))
        XCTAssertEqual(Set(p.keys), ["real.pdf"])
        p = await plan(opts(.type, deep: true))
        XCTAssertEqual(Set(p.keys), ["real.pdf", "Sub/deep.pdf"], "files already in folders the plan makes stay put")
        XCTAssertEqual(p["Sub/deep.pdf"], "PDFs/deep.pdf")
    }

    func testCleanNamesRenameInPlaceWhenNotMoving() async {
        make("Report (1).pdf")
        make("hol.jpg")
        let p = await plan(opts(.rules, clean: true))
        XCTAssertEqual(p["Report (1).pdf"], "Report.pdf")
        XCTAssertNil(p["hol.jpg"])
    }

    // MARK: apply / undo

    @MainActor
    func testApplyAndUndoRoundTrip() async throws {
        make("Images/keep.txt")               // existing folder: must survive undo
        let a = make("a.pdf", "A"), b = make("b.png", "B"), c = make("Sub/c.mp3", "C")
        let moves = await Organizer.plan(folder: dir, options: opts(.type, deep: true), rules: [], courses: [])
        XCTAssertEqual(moves.count, 3)
        let record = try Organizer.apply(moves)
        XCTAssertEqual(record.moves.count, 3)
        XCTAssertEqual(record.folder.path, dir.path)
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("PDFs/a.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Images/b.png").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Audio/c.mp3").path))
        XCTAssertFalse(fm.fileExists(atPath: a.path))
        XCTAssertEqual(Organizer.lastRecord?.date, record.date)

        // Finder drops a .DS_Store in folders you open; still counts as empty.
        try Data().write(to: dir.appendingPathComponent("PDFs/.DS_Store"))
        try Organizer.undo(record)
        for (u, text) in [(a, "A"), (b, "B"), (c, "C")] { XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), text) }
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("PDFs").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("Audio").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Images/keep.txt").path))
        XCTAssertNil(Organizer.lastRecord)
    }

    @MainActor
    func testApplyRechecksAndUndoNeverOverwrites() async throws {
        let a = make("a.pdf", "A")
        let moves = await Organizer.plan(folder: dir, options: opts(.type), rules: [], courses: [])
        make("PDFs/a.pdf", "appeared")       // shows up between preview and apply
        let record = try Organizer.apply(moves)
        XCTAssertEqual(record.moves[0].to.lastPathComponent, "a 2.pdf")
        make("a.pdf", "also new")           // and the old spot gets taken before undo
        try Organizer.undo(record)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "also new")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a 2.pdf"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("PDFs/a.pdf"), encoding: .utf8), "appeared")
    }

    @MainActor
    func testApplyRollsBackOnFailure() async throws {
        let a = make("a.pdf"), b = make("b.png")
        let moves = await Organizer.plan(folder: dir, options: opts(.type), rules: [], courses: [])
        try fm.removeItem(at: b)               // second move will fail
        XCTAssertThrowsError(try Organizer.apply(moves))
        XCTAssertTrue(fm.fileExists(atPath: a.path), "first move rolled back")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("PDFs").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("Images").path))
        XCTAssertNil(Organizer.lastRecord)
    }

    @MainActor
    func testUnticked() async throws {
        let a = make("a.pdf"); make("b.png")
        var moves = await Organizer.plan(folder: dir, options: opts(.type), rules: [], courses: [])
        for i in moves.indices where moves[i].source.lastPathComponent == "a.pdf" { moves[i].include = false }
        let record = try Organizer.apply(moves)
        XCTAssertEqual(record.moves.map(\.from.lastPathComponent), ["b.png"])
        XCTAssertTrue(fm.fileExists(atPath: a.path))
    }

    @MainActor
    func testHistoryKeepsLastTen() async throws {
        for i in 0..<12 {
            make("f\(i).pdf")
            let moves = await Organizer.plan(folder: dir, options: opts(.rules, clean: true),
                                             rules: [OrganizeRule(field: .nameContains, value: "f\(i).", folder: "R\(i)")], courses: [])
            _ = try Organizer.apply(moves)
        }
        XCTAssertEqual(Organizer.history.count, 10)
        XCTAssertEqual(Organizer.lastRecord?.moves.first?.to.lastPathComponent, "f11.pdf")
    }

    // MARK: clean names

    func testCleanName() {
        let cases = [
            "Report (1).pdf": "Report.pdf",
            "Report (12).PDF": "Report.pdf",
            "Report copy.pdf": "Report.pdf",
            "Report copy 2.pdf": "Report.pdf",
            "Report - Copy.docx": "Report.docx",
            "Report (1) copy.pdf": "Report.pdf",
            "Report-1.pdf": "Report.pdf",
            "notes_1.txt": "notes.txt",
            "Lecture_1.pdf": "Lecture 1.pdf",
            "hw-1.pdf": "hw-1.pdf",
            "Report-11.pdf": "Report-11.pdf",
            "Essay_final_FINAL_v2.docx": "Essay final.docx",
            "Essay FINAL v2.docx": "Essay FINAL.docx",
            "Final exam v2.pdf": "Final exam v2.pdf",
            "my__lecture   notes.pdf": "my lecture notes.pdf",
            "IMG_20261016_103245.JPG": "Photo 2026-10-16 10.32.45.jpg",
            "PXL_20261016_103245123.jpg": "Photo 2026-10-16 10.32.45.jpg",
            "VID_20261016_103245.mp4": "Video 2026-10-16 10.32.45.mp4",
            "IMG_4823.HEIC": "Photo 4823.heic",
            "IMG_4823 (1).JPG": "Photo 4823.jpg",
            "README": "README",
            "Already clean.pdf": "Already clean.pdf",
            "(1).pdf": "(1).pdf",
            "___.pdf": "___.pdf",
            "archive.tar.GZ": "archive.tar.gz",
        ]
        for (input, want) in cases { XCTAssertEqual(Organizer.cleanName(input), want, input) }
    }

    // MARK: clean-up

    func testCleanupFindings() async throws {
        let apps = dir.appendingPathComponent("Apps")
        try fm.createDirectory(at: apps.appendingPathComponent("Spotify.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: apps.appendingPathComponent("Google Chrome.app"), withIntermediateDirectories: true)
        let folder = dir.appendingPathComponent("Downloads")
        let old = Date(timeIntervalSinceNow: -400 * 86_400)
        let spotify = make("Downloads/SpotifyInstaller.dmg", "1")
        let chrome = make("Downloads/googlechrome 131.0.dmg", "2")
        make("Downloads/Unknown.pkg", "3")
        let older = make("Downloads/dup a.txt", "same", modified: old)
        let newer = make("Downloads/dup b.txt", "same")

        let big = folder.appendingPathComponent("big.mov"), fresh = folder.appendingPathComponent("fresh.mov")
        for (u, size) in [(big, 200_000_000), (fresh, 201_000_000)] {
            fm.createFile(atPath: u.path, contents: nil)
            let h = try FileHandle(forWritingTo: u); try h.truncate(atOffset: UInt64(size)); try h.close()   // sparse
        }
        var v = URLResourceValues(); v.contentAccessDate = old; v.contentModificationDate = old
        var b = big; try b.setResourceValues(v)

        let f = await Organizer.cleanup(in: folder, includeSubfolders: false, appFolders: [apps])
        XCTAssertEqual(Set(f.oldInstallers.map(\.lastPathComponent)), [spotify.lastPathComponent, chrome.lastPathComponent])
        XCTAssertEqual(f.duplicates.map { $0.map(\.lastPathComponent) }, [[newer.lastPathComponent, older.lastPathComponent]])
        XCTAssertEqual(f.bigForgotten.map(\.lastPathComponent), ["big.mov"])
    }
}
