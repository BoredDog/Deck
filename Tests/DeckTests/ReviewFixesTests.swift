import XCTest
import CryptoKit
@testable import Deck

@MainActor final class ReviewFixesTests: XCTestCase {
    private var dir: URL!
    private let realKey = Vault.keyProvider
    private let testKey = SymmetricKey(size: .bits256)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = testKey
        Vault.keyProvider = { key }   // never touch the real Keychain
    }

    override func tearDown() async throws {
        Vault.keyProvider = realKey
        try? FileManager.default.removeItem(at: dir)
    }

    private func files() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? [] }

    func testVaultFailsSafeWithoutKey() throws {
        let sealed = try Vault.seal("secret")
        XCTAssertEqual(Vault.openText(sealed), "secret")
        Vault.keyProvider = { nil }
        XCTAssertThrowsError(try Vault.seal("secret"))
        XCTAssertNil(Vault.openText(sealed))

        let note = dir.appendingPathComponent("Diary.decknote")
        try sealed.write(to: note)
        XCTAssertNil(NoteFiles.read(note), "an unreadable private note is not shown as empty")
        XCTAssertThrowsError(try NoteFiles.setPrivate(false, note), "an unreadable note is never converted")
        XCTAssertEqual(try Data(contentsOf: note), sealed)
        XCTAssertEqual(files(), ["Diary.decknote"])
        XCTAssertEqual(NoteFiles.read(dir.appendingPathComponent("missing.md")), "", "a note that doesn't exist yet is empty")
    }

    func testPrivateConversionKeepsOriginalWhenEncryptingFails() throws {
        let plain = dir.appendingPathComponent("Plan.md")
        try NoteFiles.write("my plan", to: plain)

        Vault.keyProvider = { nil }   // can't encrypt
        XCTAssertThrowsError(try NoteFiles.setPrivate(true, plain))
        XCTAssertEqual(files(), ["Plan.md"])

        Vault.keyProvider = { SymmetricKey(size: .bits256) }   // writes, but doesn't read back
        XCTAssertThrowsError(try NoteFiles.setPrivate(true, plain))
        XCTAssertEqual(files(), ["Plan.md"])
        XCTAssertEqual(NoteFiles.read(plain), "my plan")

        let key = testKey
        Vault.keyProvider = { key }
        let locked = try NoteFiles.setPrivate(true, plain)
        XCTAssertEqual(files(), ["Plan.decknote"])
        XCTAssertEqual(NoteFiles.read(locked), "my plan")
    }

    func testSecretsAreNotRemembered() {
        for secret in ["Tr0ub4dor&3", "hunter2Hunter", "aB3$kL9!mN", "correct-Horse-7", "ghp_9fA2kLm0Qx"] {
            XCTAssertTrue(Clipboard.looksLikeSecret(secret), secret)
        }
        for kept in ["hello", "Something", "password", "12345678", "Ab1!", "https://example.com/Some/Path?id=42",
                     "www.Example2.com/a?b=C", "/Users/nav/Documents/Report2.pdf", "Meet me at 5pm, OK?",
                     "Just a normal sentence.", String(repeating: "aB3$", count: 20)] {
            XCTAssertFalse(Clipboard.looksLikeSecret(kept), kept)
        }
    }

    func testImageCapDropsOldestImagesFirst() {
        let mb = 1_000_000
        let items = [Clipboard.Item(image: Data(count: 8 * mb)), Clipboard.Item(text: "hi"),
                     Clipboard.Item(image: Data(count: 8 * mb)), Clipboard.Item(image: Data(count: 8 * mb)),
                     Clipboard.Item(text: "old")]
        let kept = Clipboard.cappingImages(items, maxBytes: 20 * mb)
        XCTAssertEqual(kept.map(\.id), [items[0].id, items[1].id, items[2].id, items[4].id])
        XCTAssertEqual(Clipboard.cappingImages(items, maxBytes: 100 * mb).count, 5)
    }

    func testRenameStripsDotsAndSlashes() throws {
        XCTAssertEqual(NoteFiles.cleanName(".env"), "env")
        XCTAssertEqual(NoteFiles.cleanName("../secret"), "-secret")
        XCTAssertEqual(NoteFiles.cleanName("a:b/c"), "a-b-c")
        XCTAssertEqual(NoteFiles.cleanName("  . . Trip notes "), "Trip notes")
        XCTAssertEqual(NoteFiles.cleanName("..."), "")

        let note = dir.appendingPathComponent("Old.md")
        try NoteFiles.write("x", to: note)
        let renamed = NoteFiles.rename(note, to: ".hidden")
        XCTAssertEqual(renamed.lastPathComponent, "hidden.md")
        XCTAssertEqual(NoteFiles.rename(renamed, to: "..."), renamed, "a name of only dots is ignored")
    }

    func testFocusCreditsOnlyAwakeTime() {
        let t0 = Date(timeIntervalSince1970: 0)
        let end = t0 + 25 * 60
        // Asleep 10 minutes in: the session pauses with 15 minutes left.
        let left = FocusTimer.secondsLeft(end: end, now: t0 + 10 * 60)
        XCTAssertEqual(left, 15 * 60)
        XCTAssertEqual(FocusTimer.secondsLeft(end: end, now: t0 + 70 * 60), 0, "without pausing, the session would end asleep")
        // Woke after an hour, resumed 5 minutes later: the remaining 15 minutes start then.
        let resumed = t0 + 75 * 60
        let newEnd = resumed + Double(left)
        XCTAssertEqual(FocusTimer.secondsLeft(end: newEnd, now: resumed + 60), 14 * 60)
        XCTAssertEqual(FocusTimer.secondsLeft(end: newEnd, now: newEnd), 0)
        XCTAssertEqual(10 * 60 + left, 25 * 60, "awake focus time adds up to the session length")
    }

    func testInboxHoldsOnlyWhileFocusing() {
        let focusing = FocusTimer.isFocusing(running: true, phase: .focus, paused: false)
        XCTAssertTrue(Inbox.holds(urgent: false, focusing: focusing))
        XCTAssertFalse(Inbox.holds(urgent: true, focusing: focusing), "urgent things always come through")
        XCTAssertFalse(Inbox.holds(urgent: false, focusing: FocusTimer.isFocusing(running: true, phase: .rest, paused: false)), "break")
        XCTAssertFalse(Inbox.holds(urgent: false, focusing: FocusTimer.isFocusing(running: true, phase: .focus, paused: true)), "paused")
        XCTAssertFalse(Inbox.holds(urgent: false, focusing: FocusTimer.isFocusing(running: false, phase: .focus, paused: false)), "idle")
        XCTAssertEqual(Inbox.summary(kinds: ["focus"]), "While you focused: 1 focus session done")
    }

    func testHostsTempFileMustBeOurs() {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let base = tmp.hasSuffix("/") ? tmp : tmp + "/"
        XCTAssertTrue(Blocker.isOurTempFile(base + "deck-hosts-\(UUID().uuidString)/hosts"))
        XCTAssertFalse(Blocker.isOurTempFile(base + "deck-hosts-x/it's"))
        XCTAssertFalse(Blocker.isOurTempFile(base + "deck-hosts-x/../../etc/passwd"))
        XCTAssertFalse(Blocker.isOurTempFile("/etc/deck-hosts-x/hosts"))
        XCTAssertFalse(Blocker.isOurTempFile(base + "other/hosts"))
    }
}
