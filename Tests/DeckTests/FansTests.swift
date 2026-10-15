import XCTest
@testable import Deck

final class FansTests: XCTestCase {
    func testDecode() {
        // flt is little-endian: 1199.0 and 7199.0 as read from this Mac's F0Mn / F0Mx.
        XCTAssertEqual(SMC.decode(type: "flt ", bytes: [0, 224, 149, 68]), 1199)
        XCTAssertEqual(SMC.decode(type: "flt ", bytes: [0, 248, 224, 69]), 7199)
        XCTAssertEqual(SMC.decode(type: "fpe2", bytes: [0x1c, 0x20]), 1800)       // 1800 << 2 = 0x1c20
        XCTAssertEqual(SMC.decode(type: "ui8 ", bytes: [2]), 2)
        XCTAssertEqual(SMC.decode(type: "ui16", bytes: [0x01, 0x02]), 258)
        XCTAssertEqual(SMC.decode(type: "ui32", bytes: [0, 0, 1, 0]), 256)
        XCTAssertEqual(SMC.decode(type: "sp78", bytes: [0x2a, 0x80]), 42.5)
        XCTAssertEqual(SMC.decode(type: "sp78", bytes: [0xff, 0x00]), -1)
        XCTAssertNil(SMC.decode(type: "flt ", bytes: [1, 2]))
        XCTAssertNil(SMC.decode(type: "ioft", bytes: [0, 0, 0, 0]))
    }

    func testEncodeRoundTrip() {
        for type in ["flt ", "fpe2", "ui8 "] {
            let b = SMC.encode(200, type: type)!
            XCTAssertEqual(SMC.decode(type: type, bytes: b), 200, type)
        }
        XCTAssertEqual(SMC.encode(1800, type: "fpe2"), [0x1c, 0x20])
        XCTAssertNil(SMC.encode(1, type: "sp78"))
        XCTAssertEqual(SMC.string(SMC.code("F0Ac")!), "F0Ac")
        XCTAssertNil(SMC.code("F0A"))
    }

    func testClampAndPresets() {
        XCTAssertEqual(FanMath.clamp(500, min: 1199, max: 7199), 1199)
        XCTAssertEqual(FanMath.clamp(9000, min: 1199, max: 7199), 7199)
        XCTAssertEqual(FanMath.clamp(3000, min: 1199, max: 7199), 3000)
        XCTAssertEqual(FanMath.cooler(min: 1199, max: 7199), 3599)   // 1199 + 0.4 × 6000
        XCTAssertEqual(Fan(id: 0, rpm: 4199, min: 1199, max: 7199).level, 0.5)
    }

    func testFanless() {
        XCTAssertFalse(FanMath.hasFans(nil))
        XCTAssertFalse(FanMath.hasFans(0))
        XCTAssertTrue(FanMath.hasFans(1))
    }

    func testTemperatureGroups() {
        let g = Fans.groups(["Tp01": 80, "Te05": 60, "Tg0f": 50, "TB0T": 36, "TB1T": 38, "Ts1P": 31,
                             "Tz11": 0, "TVM3": -0.01, "Ts0P": 72, "TW0P": 44, "TCMz": 94])
        XCTAssertEqual(g, [Temperature(name: "Processor", celsius: 70), Temperature(name: "Graphics", celsius: 50),
                           Temperature(name: "Battery", celsius: 37), Temperature(name: "Case", celsius: 31)])
        XCTAssertEqual(Fans.groups([:]), [])
    }

    /// Reads (never writes) the real SMC on this Mac.
    func testLiveRead() throws {
        let smc = try XCTUnwrap(SMC())
        let n = smc.value("FNum") ?? 0
        XCTAssertGreaterThanOrEqual(n, 0)
        print("FNum", n, "F0Ac", smc.value("F0Ac") as Any, "F0Mn", smc.value("F0Mn") as Any, "F0Mx", smc.value("F0Mx") as Any)
        let temps = Fans.groups(Dictionary(uniqueKeysWithValues: smc.allKeys().filter { Fans.group(for: $0) != nil }.compactMap { k in smc.value(k).map { (k, $0) } }))
        print("Temps", temps.map { "\($0.name) \(Int($0.celsius))°C" })
    }
}
