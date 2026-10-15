import AppKit

struct Fan: Identifiable, Equatable {
    let id: Int
    var rpm, min, max: Double
    /// 0…1 of the way from min to max, for the bar.
    var level: Double { max > min ? (rpm - min) / (max - min) : 0 }
}

struct Temperature: Identifiable, Equatable {
    let name: String
    let celsius: Double
    var id: String { name }
}

enum FanPreset: String, CaseIterable { case automatic = "Automatic", cooler = "Cooler", max = "Max", custom = "Custom" }

/// Fan speeds and temperatures from the SMC (read here, no root), fan changes through DeckHelper (root).
@MainActor final class Fans: ObservableObject {
    static let shared = Fans()

    @Published var fans: [Fan] = []
    @Published var temps: [Temperature] = []
    @Published var hasFans = true
    @Published var preset: [Int: FanPreset] = [:]
    @Published var custom: [Int: Double] = [:]
    @Published var failed = false

    private let smc = SMC()
    private lazy var tempKeys: [String] = smc?.allKeys().filter { Self.group(for: $0) != nil } ?? []
    private var timer: Timer?
    private var helper: NSXPCConnection?
    private var forced = false

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Fans.shared.resetOnQuit() }
        }
    }

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { Fans.shared.sample() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func sample() {
        guard let smc else { hasFans = false; return }
        let n = smc.value("FNum")
        hasFans = FanMath.hasFans(n)
        fans = hasFans ? (0..<Int(n ?? 0)).compactMap { i in
            guard let lo = smc.value("F\(i)Mn"), let hi = smc.value("F\(i)Mx") else { return nil }
            return Fan(id: i, rpm: smc.value("F\(i)Ac") ?? 0, min: lo, max: hi)
        } : []
        var readings: [String: Double] = [:]
        for k in tempKeys { readings[k] = smc.value(k) }
        temps = Self.groups(readings)
    }

    // MARK: control (through the helper)

    func apply(_ p: FanPreset, to fan: Fan) {
        preset[fan.id] = p
        switch p {
        case .automatic: call { $0.setFanAuto(index: fan.id, reply: $1) }
        case .cooler: force(fan, FanMath.cooler(min: fan.min, max: fan.max))
        case .max: force(fan, Int(fan.max))
        case .custom: force(fan, Int(custom[fan.id] ?? Double(FanMath.cooler(min: fan.min, max: fan.max))))
        }
    }

    func setCustom(_ rpm: Double, for fan: Fan) {
        custom[fan.id] = rpm
        if preset[fan.id] == .custom { force(fan, Int(rpm)) }
    }

    private func force(_ fan: Fan, _ rpm: Int) {
        forced = true
        call { $0.setFan(index: fan.id, rpm: rpm, reply: $1) }
    }

    /// The helper also resets on its own once Deck's connection closes; this is the polite, immediate version.
    private func resetOnQuit() {
        guard forced, let c = helper,
              let proxy = c.synchronousRemoteObjectProxyWithErrorHandler({ _ in }) as? FanHelperProtocol else { return }
        proxy.resetAllFans { _ in }
    }

    /// Keeps one connection open while Deck controls a fan: the helper hands fans back when it closes.
    private func call(_ body: (FanHelperProtocol, @escaping (Bool) -> Void) -> Void) {
        if helper == nil {
            let c = NSXPCConnection(machServiceName: "com.nav.deck.helper", options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            c.invalidationHandler = { DispatchQueue.main.async { Fans.shared.helper = nil } }
            c.resume()
            helper = c
        }
        let done: (Bool) -> Void = { ok in DispatchQueue.main.async { Fans.shared.failed = !ok } }
        guard let proxy = helper?.remoteObjectProxyWithErrorHandler({ _ in done(false) }) as? FanHelperProtocol else { return done(false) }
        body(proxy, done)
    }

    // MARK: pure helpers (tested)

    /// Which plain group an SMC temperature key belongs to, by prefix (model-agnostic across M1…M4).
    /// shortcut: Intel CPU keys (TC0P…) aren't mapped, so Intel Macs show no "Processor" row; add them if Intel matters.
    nonisolated static func group(for key: String) -> String? {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return "Processor" }
        if key.hasPrefix("Tg") { return "Graphics" }
        if key.hasPrefix("TB") && key.hasSuffix("T") { return "Battery" }
        // Palm-rest and airflow sensors; most "Ts0x" keys sit next to the chip and read like it, so they're left out.
        if ["Ts1P", "TsOP", "TaLP", "TaRF"].contains(key) { return "Case" }
        return nil
    }

    /// Averages readings into plain groups. Zero, negative and absurd values are idle or unused sensors.
    nonisolated static func groups(_ readings: [String: Double]) -> [Temperature] {
        var sums: [String: (Double, Int)] = [:]
        for (k, v) in readings where v > 1 && v < 130 {
            guard let g = group(for: k) else { continue }
            sums[g, default: (0, 0)].0 += v
            sums[g, default: (0, 0)].1 += 1
        }
        return ["Processor", "Graphics", "Battery", "Case"].compactMap { g in sums[g].map { Temperature(name: g, celsius: $0.0 / Double($0.1)) } }
    }
}

/// The fan half of DeckHelperProtocol (Sources/DeckHelper/main.swift). XPC matches by selector, so these must match it.
@objc(FanHelperProtocol) protocol FanHelperProtocol {
    func setFan(index: Int, rpm: Int, reply: @escaping (Bool) -> Void)
    func setFanAuto(index: Int, reply: @escaping (Bool) -> Void)
    func resetAllFans(reply: @escaping (Bool) -> Void)
}
