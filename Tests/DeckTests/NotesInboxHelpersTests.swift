import XCTest
@testable import Deck

@MainActor final class NotesInboxHelpersTests: XCTestCase {
    func testDuplicateGroupingHashesOnlySameSize() {
        let u = (0..<5).map { URL(fileURLWithPath: "/f\($0)") }
        var hashed: [URL] = []
        let hashes = [u[0]: "a", u[1]: "a", u[2]: "b", u[3]: "a", u[4]: "a"]
        let groups = DuplicateFinder.groups([(u[0], 10), (u[1], 10), (u[2], 10), (u[3], 20), (u[4], 0)]) { url in
            hashed.append(url); return hashes[url]
        }
        XCTAssertEqual(groups.map(Set.init), [Set([u[0], u[1]])])
        XCTAssertFalse(hashed.contains(u[3]), "a file with a unique size is never read")
        XCTAssertFalse(hashed.contains(u[4]), "empty files are ignored")
    }

    func testRenamePreview() {
        var r = RenameRule()
        r.find = "IMG_"; r.replace = ""; r.before = "Trip "
        XCTAssertEqual(r.apply(["IMG_001.jpg", "notes"]), ["Trip 001.jpg", "Trip notes"])
        r = RenameRule(); r.numbered = "Photo"
        XCTAssertEqual(r.apply(["a.HEIC", "b.HEIC"]), ["Photo 1.HEIC", "Photo 2.HEIC"])
        r = RenameRule(); r.letterCase = .lower; r.after = "-Final"
        XCTAssertEqual(r.apply(["Report.PDF"]), ["report-final.PDF"])
    }

    func testClipboardSkipRules() {
        let ignore = ["1Password", "Passwords"]
        XCTAssertTrue(Clipboard.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], frontApp: "Notes", ignore: ignore))
        XCTAssertTrue(Clipboard.shouldSkip(types: ["org.nspasteboard.TransientType"], frontApp: nil, ignore: ignore))
        XCTAssertTrue(Clipboard.shouldSkip(types: ["com.agilebits.onepassword"], frontApp: nil, ignore: ignore))
        XCTAssertTrue(Clipboard.shouldSkip(types: ["public.utf8-plain-text"], frontApp: "passwords", ignore: ignore))
        XCTAssertFalse(Clipboard.shouldSkip(types: ["public.utf8-plain-text"], frontApp: "Safari", ignore: ignore))
    }

    func testTidyKinds() {
        let cases = ["JPG": "Images", "heic": "Images", "mov": "Videos", "mp4": "Videos", "mp3": "Audio", "pdf": "Documents",
                     "docx": "Documents", "txt": "Documents", "zip": "Archives", "7z": "Archives", "dmg": "Installers",
                     "pkg": "Installers", "qqq": "Other"]
        for (ext, folder) in cases { XCTAssertEqual(Tidy.folder(for: ext), folder, ext) }
    }

    func testFocusSummary() {
        XCTAssertEqual(Inbox.summary(kinds: ["download", "convert", "download", "download"]),
                       "While you focused: 3 downloads finished, 1 file converted")
    }
}
