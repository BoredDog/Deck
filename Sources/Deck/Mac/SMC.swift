import Foundation
import IOKit

// Shared by Deck and DeckHelper: Sources/DeckHelper/SMC.swift is a symlink to this file. Foundation + IOKit only.
// The AppleSMC user-client calls are adapted from exelban/stats (MIT), SMC/smc.swift, © 2021 Serhiy Mytrovtsiy.

/// Talks to the System Management Controller, which knows fan speeds and temperatures. Reading needs no root.
final class SMC {
    /// Mirrors the kernel's SMCKeyData_t byte for byte (80 bytes).
    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
    private enum Op: UInt8 { case readBytes = 5, writeBytes = 6, readIndex = 8, readKeyInfo = 9 }

    struct Value { var type: String; var bytes: [UInt8] }

    private var conn: io_connect_t = 0
    private let lock = NSLock()

    /// Nil when there's no AppleSMC (shouldn't happen on a real Mac).
    init?() {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard device != 0 else { return nil }
        defer { IOObjectRelease(device) }
        guard IOServiceOpen(device, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(conn) }

    func read(_ key: String) -> Value? {
        guard let code = Self.code(key) else { return nil }
        lock.lock(); defer { lock.unlock() }
        var input = KeyData(), output = KeyData()
        input.key = code
        input.data8 = Op.readKeyInfo.rawValue
        guard call(&input, &output), output.result == 0, output.keyInfo.dataSize > 0 else { return nil }
        let info = output.keyInfo
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Op.readBytes.rawValue
        guard call(&input, &output), output.result == 0 else { return nil }
        let all = withUnsafeBytes(of: output.bytes) { Array($0) }
        return Value(type: Self.string(info.dataType), bytes: Array(all.prefix(Int(min(info.dataSize, 32)))))
    }

    /// Writes raw bytes; the SMC itself refuses unless the caller is root.
    func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let code = Self.code(key), bytes.count <= 32 else { return false }
        lock.lock(); defer { lock.unlock() }
        var input = KeyData(), output = KeyData()
        input.key = code
        input.data8 = Op.writeBytes.rawValue
        input.keyInfo.dataSize = UInt32(bytes.count)
        withUnsafeMutableBytes(of: &input.bytes) { $0.copyBytes(from: bytes) }
        // IOKit can succeed while the SMC firmware still rejects the write, so check its result too.
        return call(&input, &output) && output.result == 0
    }

    func value(_ key: String) -> Double? { read(key).flatMap { Self.decode(type: $0.type, bytes: $0.bytes) } }

    /// Every key the SMC knows (a couple of thousand on Apple silicon). Slow-ish: call once and keep the list.
    func allKeys() -> [String] {
        guard let n = value("#KEY") else { return [] }
        lock.lock(); defer { lock.unlock() }
        return (0..<UInt32(n)).compactMap { i in
            var input = KeyData(), output = KeyData()
            input.data8 = Op.readIndex.rawValue
            input.data32 = i
            return call(&input, &output) && output.result == 0 ? Self.string(output.key) : nil
        }
    }

    private func call(_ input: inout KeyData, _ output: inout KeyData) -> Bool {
        var size = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &size) == kIOReturnSuccess
    }

    // MARK: pure helpers (tested)

    static func code(_ key: String) -> UInt32? {
        let u = Array(key.utf8)
        return u.count == 4 ? u.reduce(0) { $0 << 8 | UInt32($1) } : nil
    }

    static func string(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(code >> $0 & 0xff) }, as: UTF8.self)
    }

    /// SMC bytes → number. "flt " is little-endian; the fixed-point and integer types are big-endian.
    static func decode(type: String, bytes b: [UInt8]) -> Double? {
        func be(_ n: Int) -> UInt32? { b.count >= n ? b.prefix(n).reduce(0) { $0 << 8 | UInt32($1) } : nil }
        switch type {
        case "flt ": return b.count >= 4 ? Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)) : nil
        case "ui8 ": return be(1).map(Double.init)
        case "ui16": return be(2).map(Double.init)
        case "ui32": return be(4).map(Double.init)
        case "fpe2": return be(2).map { Double($0) / 4 }
        case "sp78": return be(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        default: return nil
        }
    }

    /// Number → SMC bytes for the key's existing type. Nil for types fans don't use.
    static func encode(_ v: Double, type: String) -> [UInt8]? {
        switch type {
        case "flt ": return withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { Array($0) }
        case "fpe2": let n = UInt16(max(0, min(16383, v.rounded())) * 4); return [UInt8(n >> 8), UInt8(n & 0xff)]
        case "ui8 ": return [UInt8(max(0, min(255, v.rounded())))]
        default: return nil
        }
    }
}

/// Fan math shared by the app (presets) and the helper (validation).
enum FanMath {
    /// The helper never sets a speed outside what the fan reports it can do.
    static func clamp(_ rpm: Int, min lo: Double, max hi: Double) -> Int {
        Int(Swift.max(lo, Swift.min(hi, Double(rpm))).rounded())
    }

    /// "Cooler": the minimum plus 40% of the range.
    static func cooler(min lo: Double, max hi: Double) -> Int { Int((lo + 0.4 * (hi - lo)).rounded()) }

    /// Fanless Macs (MacBook Air) report FNum 0 or no FNum at all.
    static func hasFans(_ fnum: Double?) -> Bool { (fnum ?? 0) >= 1 }

    /// On Apple silicon the mode key is "F0md" on some chips and "F0Md" on others; this picks the one that exists.
    static func modeKey(_ i: Int, smc: SMC) -> String {
        smc.read("F\(i)md") != nil ? "F\(i)md" : "F\(i)Md"
    }
}
