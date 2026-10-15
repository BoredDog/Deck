import Foundation

// Fan control as root. The Apple silicon sequence follows exelban/stats (MIT), SMC/smc.swift:
// write the mode key to 1 directly (newer chips); if the SMC refuses, set "Ftst"=1, wait for thermalmonitord
// to let go, then retry the mode write; then write the target. Automatic is mode 0 and target 0; "Ftst" goes back to 0
// once every fan is automatic. Call these from one serial queue only.
enum FanControl {
    private static let smc = SMC()
    /// Exists while Deck has forced a fan, so a helper that crashed mid-way knows to hand the fans back on start.
    /// It lives in /var/run, which is cleared on reboot, as is the SMC.
    private static let marker = "/var/run/com.nav.deck.fans"
    static var touched: Bool { FileManager.default.fileExists(atPath: marker) }

    private static var count: Int { Int(smc?.value("FNum") ?? 0) }

    /// Forces fan `i` to `rpm`, clamped to the fan's own min…max read just now.
    static func set(_ i: Int, rpm: Int) -> Bool {
        guard let smc, i >= 0, i < count,
              let lo = smc.value("F\(i)Mn"), let hi = smc.value("F\(i)Mx"), hi > lo else { return false }
        FileManager.default.createFile(atPath: marker, contents: nil)
        guard unlock(i, smc), let tg = smc.read("F\(i)Tg"),
              let bytes = SMC.encode(Double(FanMath.clamp(rpm, min: lo, max: hi)), type: tg.type) else { return false }
        return retry(10, every: 0.05) { smc.write("F\(i)Tg", bytes) }
    }

    /// Hands fan `i` back to macOS.
    static func auto(_ i: Int) -> Bool {
        guard let smc, i >= 0, i < count else { return false }
        let ok = release(i, smc)
        if (0..<count).allSatisfy({ smc.read(FanMath.modeKey($0, smc: smc))?.bytes.first == 0 }) { _ = unlockOff(smc) }
        return ok
    }

    /// Every fan back to automatic. Runs on helper start (after a crash) and when the last client goes away.
    @discardableResult static func resetAll() -> Bool {
        guard let smc else { return false }
        var ok = true
        for i in 0..<count where !release(i, smc) { ok = false }
        if !unlockOff(smc) { ok = false }
        if ok { try? FileManager.default.removeItem(atPath: marker) }
        return ok
    }

    private static func unlock(_ i: Int, _ smc: SMC) -> Bool {
        let mode = FanMath.modeKey(i, smc: smc)
        if smc.read(mode)?.bytes.first == 1 || smc.write(mode, [1]) { return true }
        guard let ftst = smc.read("Ftst") else { return false }   // no Ftst and the direct write failed: give up
        if ftst.bytes.first != 1 {
            guard retry(100, every: 0.05, { smc.write("Ftst", [1]) }) else { return false }
            Thread.sleep(forTimeInterval: 3)   // thermalmonitord needs a moment to yield
        }
        return retry(300, every: 0.1) { smc.write(mode, [1]) }
    }

    private static func release(_ i: Int, _ smc: SMC) -> Bool {
        let mode = FanMath.modeKey(i, smc: smc)
        guard smc.read(mode)?.bytes.first != 0 else { return true }
        guard retry(10, every: 0.05, { smc.write(mode, [0]) }) else { return false }
        if let tg = smc.read("F\(i)Tg"), let zero = SMC.encode(0, type: tg.type) { _ = retry(10, every: 0.05) { smc.write("F\(i)Tg", zero) } }
        return true
    }

    private static func unlockOff(_ smc: SMC) -> Bool {
        guard let ftst = smc.read("Ftst"), ftst.bytes.first != 0 else { return true }
        return retry(10, every: 0.05) { smc.write("Ftst", [0]) }
    }

    private static func retry(_ times: Int, every seconds: TimeInterval, _ attempt: () -> Bool) -> Bool {
        for n in 0..<times {
            if attempt() { return true }
            if n < times - 1 { Thread.sleep(forTimeInterval: seconds) }
        }
        return false
    }
}
