import XCTest
import CoreAudio
@testable import Deck

final class EqualizerTests: XCTestCase {

    // MARK: which app a sound-making process belongs to

    func testAppPIDMapping() {
        let apps: Set<pid_t> = [100, 200, 300]
        let parents: [pid_t: pid_t] = [101: 100, 201: 1, 301: 300, 302: 301, 400: 1]
        let responsible: [pid_t: pid_t] = [201: 200, 300: 200]   // WebKit helper → Safari; Chromium helpers point at themselves
        func map(_ p: pid_t) -> pid_t? {
            Equalizer.appPID(for: p, responsible: { responsible[$0] ?? $0 }, parent: { parents[$0] }, isApp: apps.contains)
        }
        XCTAssertEqual(map(100), 100)        // the app itself
        XCTAssertEqual(map(201), 200)        // responsible app
        XCTAssertEqual(map(101), 100)        // helper child of the app
        XCTAssertEqual(map(302), 300)        // grandchild
        XCTAssertEqual(map(300), 300)        // an app started from another app's terminal stays itself
        XCTAssertNil(map(400))               // daemon
        XCTAssertNil(Equalizer.appPID(for: 5, responsible: { $0 }, parent: { $0 == 5 ? 6 : 5 }, isApp: { _ in false }))   // loop
    }

    func testParentPIDOfThisProcess() {
        XCTAssertEqual(Equalizer.parentPID(getpid()), getppid())
    }

    // MARK: status

    func testDiagnose() {
        XCTAssertEqual(Equalizer.diagnose(fineTune: true, denied: true, stuckSeconds: 9, callbacksMoved: true), Equalizer.fineTuneProblem)
        XCTAssertEqual(Equalizer.diagnose(fineTune: false, denied: true, stuckSeconds: 0, callbacksMoved: false), Equalizer.permissionProblem)
        XCTAssertNil(Equalizer.diagnose(fineTune: false, denied: false, stuckSeconds: 1, callbacksMoved: true))
        XCTAssertEqual(Equalizer.diagnose(fineTune: false, denied: false, stuckSeconds: 2, callbacksMoved: true), Equalizer.permissionProblem)
        XCTAssertEqual(Equalizer.diagnose(fineTune: false, denied: false, stuckSeconds: 2, callbacksMoved: false),
                       "Deck's equalizer isn't getting any sound. Turn it off and on again.")
    }

    // MARK: FineTune import

    /// Same shape as FineTune's settings.json (version 12), made-up values.
    let fineTuneFixture = """
    {"version":12,"appSettings":{"defaultNewAppVolume":1,"loudnessEqualizationEnabled":false},"pinnedApps":[],
     "appEQSettings":{
       "com.example.music":{"bandGains":[3,2.5,1,0,0,0,0,0,1,2],"isEnabled":true},
       "com.example.browser":{"bandGains":[-1,0,0,0,0,0,0,0,0,20],"isEnabled":true},
       "com.example.off":{"bandGains":[9,9,9,9,9,9,9,9,9,9],"isEnabled":false},
       "com.example.flat":{"bandGains":[0,0,0,0,0,0,0,0,0,0],"isEnabled":true},
       "com.example.short":{"bandGains":[4,4]}},
     "appVolumes":{"com.example.music":1,"com.example.chat":0.4},
     "appMutes":{"com.example.ads":true,"com.example.music":false},
     "appBoosts":{"com.example.chat":2},
     "userEQPresets":[{"id":"5B0E2E1C-0000-4000-8000-000000000001","name":"Late night","createdAt":780000000,
                       "settings":{"bandGains":[-3,-2,0,0,0,0,0,0,-2,-4],"isEnabled":true}}],
     "favoriteAutoEQProfiles":[],"deviceAutoEQ":{}}
    """

    func testParseFineTune() throws {
        let s = try Equalizer.parseFineTune(Data(fineTuneFixture.utf8))
        XCTAssertEqual(s.gainsFrom, "com.example.browser")                  // first by id when nothing is playing
        XCTAssertEqual(s.gains, [-1, 0, 0, 0, 0, 0, 0, 0, 0, 12])           // clamped to ±12
        XCTAssertEqual(Set(s.appEQs.keys), ["com.example.music", "com.example.browser", "com.example.short"])  // off and flat skipped
        XCTAssertEqual(s.appEQs["com.example.short"], [4, 4, 0, 0, 0, 0, 0, 0, 0, 0])   // padded to 10 bands
        XCTAssertEqual(s.presets, [Equalizer.Preset(name: "Late night", gains: [-3, -2, 0, 0, 0, 0, 0, 0, -2, -4])])
        XCTAssertEqual(s.volumes, ["com.example.chat": 0.4, "com.example.ads": 0])

        let playing = try Equalizer.parseFineTune(Data(fineTuneFixture.utf8), preferring: ["com.example.none", "com.example.music"])
        XCTAssertEqual(playing.gainsFrom, "com.example.music")
        XCTAssertEqual(playing.gains, [3, 2.5, 1, 0, 0, 0, 0, 0, 1, 2])
    }

    func testParseFineTuneEmptyAndBroken() throws {
        let empty = try Equalizer.parseFineTune(Data(#"{"version":12}"#.utf8))
        XCTAssertNil(empty.gains)
        XCTAssertEqual(empty.presets, [])
        XCTAssertEqual(empty.volumes, [:])
        XCTAssertThrowsError(try Equalizer.parseFineTune(Data("not json".utf8)))
    }

    // MARK: live check (DECK_LIVE=1, with something playing; needs audio-capture permission for the app running the tests)

    @MainActor func testLiveEQChangesTheSound() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DECK_LIVE"] == nil)
        let eq = Equalizer.shared
        let saved = eq.gains
        defer { eq.setOn(false); eq.gains = saved }
        eq.start()
        let chain = try XCTUnwrap(eq.chain, eq.problem ?? "no chain")
        var peaks: [Float: (Float, Float)] = [:]
        for g: Float in [0, -12] {
            eq.gains = Array(repeating: g, count: 10)
            try await Task.sleep(for: .seconds(0.3))
            chain.inPeak = 0; chain.outPeak = 0
            try await Task.sleep(for: .seconds(2.5))
            peaks[g] = (chain.inPeak, chain.outPeak)
        }
        print("live: callbacks \(chain.callbacks) heard \(chain.heard) peaks \(peaks) problem \(eq.problem ?? "-")")
        XCTAssertGreaterThan(chain.heard, 0, "Nothing heard: play something and grant audio capture")
        XCTAssertLessThan(peaks[-12]!.1, peaks[-12]!.0 * 0.5, "-12 dB everywhere should at least halve the output")
    }
}
