import SwiftUI
import SwiftData
import AVFoundation
import UserNotifications

enum FocusModels { static let all: [any PersistentModel.Type] = [] }

/// Settings keys shared by the timer and the Focus screen.
enum FocusKey {
    static let minutes = "focusMinutes", breakMinutes = "breakMinutes"
    static let apps = "blockedApps", sites = "blockedSites"           // newline-separated
    static let noise = "noise", volume = "noiseVolume"
    static let breaksOn = "breaksOn", breaksEvery = "breaksEvery"
    static let dndOn = "dndOnShortcut", dndOff = "dndOffShortcut"
}

@MainActor final class FocusTimer: ObservableObject {
    enum Phase { case focus, rest }
    static let shared = FocusTimer()
    @Published var running = false
    @Published var paused = false
    @Published var phase = Phase.focus
    @Published var remaining = 25 * 60   // seconds
    @Published var total = 25 * 60
    var remainingText: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }
    var progress: Double { total > 0 ? 1 - Double(remaining) / Double(total) : 0 }
    /// True while focusing (not on a break, not paused): distractions are blocked.
    var focusing: Bool { running && phase == .focus && !paused }

    private var end = Date.now
    private var started = Date.now
    private var ticker: Timer?
    private var defaults: UserDefaults { .standard }
    private var focusMinutes: Int { defaults.integer(forKey: FocusKey.minutes).nonZero ?? 25 }

    private init() {
        total = focusMinutes * 60
        remaining = total
        Blocker.shared.cleanUpLeftovers()
        BreakReminders.shared.reschedule()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FocusTimer.shared.prepareForQuit() }
        }
    }

    /// Quitting mid-session: unblock websites, stop the sound and run the "focus ends" Shortcut.
    /// Safe to call more than once; FocusTimer also calls it itself on willTerminate.
    func prepareForQuit() {
        Blocker.shared.unblockSites()
        guard running, phase == .focus else { return }
        running = false
        Sounds.shared.stop()
        // Launched, not awaited: the Shortcut keeps running after Deck exits.
        if let name = defaults.string(forKey: FocusKey.dndOff)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            try? p.run()
        }
    }

    func start(minutes: Int = 25) {
        if running { stop() }
        phase = .focus
        started = .now
        begin(seconds: minutes * 60)
        Blocker.shared.blockSites()
        Sounds.shared.play()
        runShortcut(FocusKey.dndOn)
    }

    func pause() { paused = true; ticker?.invalidate() }

    func resume() {
        end = .now + Double(remaining)
        paused = false
        startTicker()
    }

    func stop() {
        let wasFocus = running && phase == .focus
        ticker?.invalidate()
        running = false
        paused = false
        phase = .focus
        setLength(focusMinutes)
        if wasFocus { endEffects() }
    }

    /// Changes the default session length; shown right away when idle.
    func setLength(_ minutes: Int) {
        defaults.set(minutes, forKey: FocusKey.minutes)
        if !running { total = minutes * 60; remaining = total }
    }

    private func begin(seconds: Int) {
        total = seconds
        remaining = seconds
        end = .now + Double(seconds)
        running = true
        paused = false
        startTicker()
    }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { FocusTimer.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)   // keeps ticking while a menu is open or the user scrolls
        ticker = t
    }

    private func tick() {
        remaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        if remaining == 0 { finish() }
    }

    private func finish() {
        ticker?.invalidate()
        if phase == .focus {
            let minutes = total / 60
            Store.context.insert(FocusSession(start: started, minutes: minutes))
            try? Store.context.save()
            Store.log("Focused for \(minutes) minutes", kind: "focus")
            endEffects()
            phase = .rest
            begin(seconds: (defaults.integer(forKey: FocusKey.breakMinutes).nonZero ?? 5) * 60)
        } else {
            running = false
            phase = .focus
            setLength(focusMinutes)
            Store.log("Break's over. Ready when you are.", kind: "break")
        }
    }

    private func endEffects() {
        Blocker.shared.unblockSites()
        Sounds.shared.stop()
        runShortcut(FocusKey.dndOff)
    }

    private func runShortcut(_ key: String) {
        guard let name = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        Task { try? await Engine.run("shortcuts", ["run", name]) }
    }
}

private extension Int { var nonZero: Int? { self == 0 ? nil : self } }

/// Sums of focus sessions, for the Focus screen and Home.
enum FocusStats {
    static func weekMinutes(_ sessions: [FocusSession]) -> Int {
        sessions.filter { $0.start >= Days.weekStart }.map(\.minutes).reduce(0, +)
    }

    /// Minutes per day this week, Monday (or the locale's first day) first.
    static func weekByDay(_ sessions: [FocusSession]) -> [Int] {
        var days = Array(repeating: 0, count: 7)
        for s in sessions where s.start >= Days.weekStart {
            let i = Calendar.current.dateComponents([.day], from: Days.weekStart, to: s.start).day ?? 0
            if i < 7 { days[i] += s.minutes }
        }
        return days
    }

    static func streak(_ sessions: [FocusSession]) -> Int { Days.streak(sessions.map(\.start)) }
}

// MARK: background sounds

/// Noise, rain and café sounds made live, so there are no files to download.
/// Not main-actor bound: the render block runs on the audio thread.
final class Sounds {
    enum Kind: String, CaseIterable { case off = "Off", white = "White", pink = "Pink", brown = "Brown", rain = "Rain", cafe = "Café" }
    static let shared = Sounds()
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?

    func play() {
        stop()
        let kind = Kind(rawValue: UserDefaults.standard.string(forKey: FocusKey.noise) ?? "") ?? .off
        guard kind != .off else { return }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let gen = NoiseGen(kind, rate: Float(rate > 0 ? rate : 44_100))
        let node = AVAudioSourceNode { _, _, frames, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(frames) { out[i] = gen.next() }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 44_100, channels: 1))
        engine.mainMixerNode.outputVolume = volume
        try? engine.start()
        self.node = node
    }

    func stop() {
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
    }

    var volume: Float { Float(UserDefaults.standard.object(forKey: FocusKey.volume) as? Double ?? 0.4) }
    func setVolume(_ v: Float) { engine.mainMixerNode.outputVolume = v }
}

final class NoiseGen {
    let kind: Sounds.Kind
    private let rate: Float
    private var seed: UInt32 = 0x9E37_79B9
    private var b: [Float] = Array(repeating: 0, count: 7)
    private var brown: Float = 0
    private var lp1: Float = 0, lp2: Float = 0     // rain bed / café murmur band
    private var hit: Float = 0, last: Float = 0     // rain droplet envelope, previous white sample
    private var talk: Float = 0, talkTarget: Float = 0, talkHold = 0
    private var clink: Float = 0, clinkPhase: Float = 0, clinkStep: Float = 0
    init(_ kind: Sounds.Kind, rate: Float = 44_100) { self.kind = kind; self.rate = rate }

    // xorshift: cheap and allocation-free, safe on the audio thread.
    private func white() -> Float {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }
    private func chance(perSecond n: Float) -> Bool { (white() + 1) * 0.5 < n / rate }
    /// One-pole low-pass coefficient for a cutoff in Hz.
    private func pole(_ hz: Float) -> Float { 1 - exp(-2 * .pi * hz / rate) }

    func next() -> Float {
        let w = white()
        switch kind {
        case .pink:   // Paul Kellet's filter
            b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520; b[3] = 0.86650 * b[3] + w * 0.3104856
            b[4] = 0.55000 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.0168980
            let p = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
            b[6] = w * 0.115926
            return p * 0.11
        case .brown:
            brown = (brown + 0.02 * w) / 1.02
            return brown * 3.5
        case .rain:
            // Steady hiss: noise band-passed to roughly 400 Hz–4 kHz.
            lp1 += pole(4000) * (w - lp1)
            lp2 += pole(400) * (lp1 - lp2)
            // Droplets: random short, bright ticks of varying loudness.
            if chance(perSecond: 30) { hit = max(hit, 0.2 + 0.4 * (white() + 1)) }
            hit *= 1 - pole(25)
            let tick = (w - last) * hit
            last = w
            return (lp1 - lp2) * 0.45 + tick * 0.25
        case .cafe:
            // Room tone.
            brown = (brown + 0.02 * w) / 1.02
            // Murmur: voice-range noise (250 Hz–1 kHz) swelling and fading like distant talk.
            lp1 += pole(1000) * (w - lp1)
            lp2 += pole(250) * (lp1 - lp2)
            talkHold -= 1
            if talkHold <= 0 { talkTarget = 0.3 + 0.35 * (white() + 1); talkHold = Int(rate * (0.15 + 0.1 * (white() + 1))) }
            talk += pole(4) * (talkTarget - talk)
            // An occasional cup or spoon clink: a quick, fading high tone.
            if chance(perSecond: 0.25) { clink = 0.05 + 0.04 * (white() + 1); clinkStep = 2 * .pi * (2500 + 1000 * (white() + 1)) / rate }
            clinkPhase += clinkStep
            if clinkPhase > 2 * .pi { clinkPhase -= 2 * .pi }
            clink *= 1 - pole(6)
            return brown * 2 + (lp1 - lp2) * talk * 1.6 + sin(clinkPhase) * clink
        default:
            return w * 0.3
        }
    }
}

// MARK: break reminders

@MainActor final class BreakReminders {
    static let shared = BreakReminders()
    private var timer: Timer?
    private var count = 0
    private let tips = ["Rest your eyes: look at something 20 feet away for 20 seconds.",
                        "Stand up and stretch for a minute.",
                        "Have a glass of water."]

    // UNUserNotificationCenter crashes when Deck runs outside an app bundle (e.g. `swift run`).
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func reschedule() {
        timer?.invalidate()
        let d = UserDefaults.standard
        guard d.bool(forKey: FocusKey.breaksOn) else { return }
        let minutes = d.integer(forKey: FocusKey.breaksEvery).nonZero ?? 20
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: true) { _ in
            MainActor.assumeIsolated { BreakReminders.shared.fire() }
        }
    }

    func askPermission() async {
        guard canNotify else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func fire() {
        guard canNotify, !Planner.shared.inEvent else { return }
        let c = UNMutableNotificationContent()
        c.title = "Time for a short break"
        c.body = tips[count % tips.count]
        count += 1
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
