import XCTest
@testable import Deck

final class AudioFocusTests: XCTestCase {

    // MARK: website blocker helper

    func testHelperDomainValidation() {
        for ok in ["youtube.com", "news.ycombinator.com", "a-b.co.uk", "x1.io"] { XCTAssertTrue(HostsFile.isValid(ok), ok) }
        for bad in ["", "localhost", ".com", "-a.com", "YouTube.com", "a b.com", "a;rm.com", "a/b.com", "a\n.com",
                    "evil.com\n0.0.0.0 apple.com", String(repeating: "a", count: 250) + ".com"] {
            XCTAssertFalse(HostsFile.isValid(bad), bad)
        }
    }

    func testHostsBlockInsertAndRemove() throws {
        let original = "127.0.0.1 localhost\n255.255.255.255 broadcasthost\n::1 localhost\n"
        let blocked = try XCTUnwrap(HostsFile.addingBlock(original, domains: ["youtube.com", "www.reddit.com"]))
        XCTAssertTrue(blocked.hasPrefix(original))
        for line in ["0.0.0.0 youtube.com", ":: youtube.com", "0.0.0.0 www.youtube.com", ":: www.youtube.com", "0.0.0.0 www.reddit.com"] {
            XCTAssertTrue(blocked.contains("\n\(line)\n"), line)
        }
        XCTAssertFalse(blocked.contains("www.www."))
        XCTAssertEqual(HostsFile.removingBlock(blocked), original)
        // Blocking again replaces the old block instead of stacking a second one.
        let twice = try XCTUnwrap(HostsFile.addingBlock(blocked, domains: ["x.com"]))
        XCTAssertEqual(twice.components(separatedBy: HostsFile.start).count, 2)
        XCTAssertFalse(twice.contains("youtube"))
        // Invalid input never produces a file.
        XCTAssertNil(HostsFile.addingBlock(original, domains: ["ok.com", "bad domain"]))
        XCTAssertNil(HostsFile.addingBlock(original, domains: []))
    }

    func testHostsRemoveKeepsUserLines() {
        let hosts = "1.2.3.4 mine\n\(HostsFile.start)\n0.0.0.0 a.com\n\(HostsFile.end)\n5.6.7.8 also-mine"
        XCTAssertEqual(HostsFile.removingBlock(hosts), "1.2.3.4 mine\n5.6.7.8 also-mine")
        // A broken block (no end marker) only loses its marker, never the user's lines after it.
        XCTAssertEqual(HostsFile.removingBlock("a\n\(HostsFile.start)\nb\n"), "a\nb\n")
        XCTAssertEqual(HostsFile.removingBlock("no block\n"), "no block\n")
    }

    // MARK: now playing (mediaremote-adapter stream lines)

    func testMediaRemoteStreamParsing() throws {
        let full = #"{"type":"data","diff":false,"payload":{"title":"Song","artist":"Band","bundleIdentifier":"org.mozilla.firefox","playing":true,"artworkData":"aGk="}}"#
        var state = try XCTUnwrap(NowPlaying.merge(line: full, into: [:]))
        XCTAssertEqual(NowPlaying.track(from: state),
                       NowPlaying.Track(title: "Song", artist: "Band", bundleID: "org.mozilla.firefox", playing: true, artwork: Data("hi".utf8)))
        // A diff updates some keys; null removes one.
        state = try XCTUnwrap(NowPlaying.merge(line: #"{"type":"data","diff":true,"payload":{"playing":false,"artist":null}}"#, into: state))
        let t = NowPlaying.track(from: state)
        XCTAssertEqual(t.title, "Song")
        XCTAssertNil(t.artist)
        XCTAssertFalse(t.playing)
        // A full payload replaces everything; an empty one means nothing is playing.
        state = try XCTUnwrap(NowPlaying.merge(line: #"{"type":"data","diff":false,"payload":{}}"#, into: state))
        XCTAssertNil(NowPlaying.track(from: state).title)
        // Web apps report the browser as the parent.
        let web = try XCTUnwrap(NowPlaying.merge(line: #"{"type":"data","diff":false,"payload":{"title":"x","bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari"}}"#, into: [:]))
        XCTAssertEqual(NowPlaying.track(from: web).bundleID, "com.apple.Safari")
        // Garbage and other line types are ignored.
        XCTAssertNil(NowPlaying.merge(line: "not json", into: state))
        XCTAssertNil(NowPlaying.merge(line: #"{"type":"error"}"#, into: state))
    }

    // MARK: habits

    func testHabitPastDayToggle() {
        let h = Habit(name: "Read")
        let cal = Calendar.current
        let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: .now)!
        h.toggle(threeDaysAgo)
        XCTAssertTrue(h.done(on: threeDaysAgo))
        XCTAssertFalse(h.done(on: .now))
        XCTAssertEqual(h.days, [cal.startOfDay(for: threeDaysAgo)])
        h.toggle(threeDaysAgo)
        XCTAssertFalse(h.done(on: threeDaysAgo))
        h.toggle(cal.date(byAdding: .day, value: 2, to: .now)!)
        XCTAssertTrue(h.days.isEmpty, "future days can't be ticked")
    }

    // MARK: equalizer device following

    func testDeviceAction() {
        let all: Set<String> = ["speakers", "airpods"]
        XCTAssertEqual(Equalizer.deviceAction(playingOn: nil, defaultOutput: "airpods", devices: all), .keep, "not running")
        XCTAssertEqual(Equalizer.deviceAction(playingOn: "speakers", defaultOutput: "speakers", devices: all), .keep)
        XCTAssertEqual(Equalizer.deviceAction(playingOn: "speakers", defaultOutput: "airpods", devices: all), .rebuild, "AirPods connected")
        XCTAssertEqual(Equalizer.deviceAction(playingOn: "airpods", defaultOutput: "speakers", devices: ["speakers"]), .rebuild, "AirPods gone")
        XCTAssertEqual(Equalizer.deviceAction(playingOn: "airpods", defaultOutput: nil, devices: []), .stop, "no output at all")
    }

    // MARK: background sounds

    func testRainAndCafeAreAudibleAndSafe() {
        for kind in [Sounds.Kind.rain, .cafe] {
            let gen = NoiseGen(kind, rate: 48_000)
            var peak: Float = 0, energy: Float = 0
            for _ in 0..<(48_000 * 3) {
                let x = gen.next()
                XCTAssertFalse(x.isNaN)
                peak = max(peak, abs(x)); energy += x * x
            }
            XCTAssertLessThan(peak, 1, "\(kind) clips")
            XCTAssertGreaterThan(energy / Float(48_000 * 3), 1e-4, "\(kind) is silent")
        }
    }
}
