import SwiftUI
import AVFoundation
import CoreAudio
import Accelerate

/// System-wide equalizer with a volume per app.
/// Sound path: one process tap per app you turned down + one tap for everything else (all muted at the source)
/// → private aggregate device on the current speakers → our IO callback → AVAudioEngine (real-time manual rendering):
/// one source per tap with its own volume → mixer → 10-band EQ → the aggregate's output.
/// Follows the default output device: plugging in headphones or AirPods rebuilds the chain on the new device.
@MainActor final class Equalizer: ObservableObject {
    static let shared = Equalizer()
    nonisolated static let bands: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let presets: [(String, [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Vocal", [-2, -2, -1, 0, 2, 4, 4, 2, 0, -1]),
        ("Podcast", [-8, -6, -2, 0, 1, 2, 3, 2, 0, -2]),
        ("Treble", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
    ]

    /// An app with sound, keyed by bundle id. Helper processes (browser tabs, WebKit) count toward their app.
    struct App: Identifiable, Hashable { let id: String; let name: String; let icon: NSImage?; let objects: [AudioObjectID] }

    /// A preset you brought in (from FineTune), shown after the built-in ones.
    struct Preset: Codable, Equatable { var name: String; var gains: [Float] }

    @Published var on = false
    @Published var problem: String?
    @Published var apps: [App] = []
    /// Buffers of real (non-silent) sound Deck has heard since switching on: a "listening" indicator.
    @Published private(set) var buffersSeen = 0
    @Published private(set) var userPresets: [Preset] = UserDefaults.standard.data(forKey: "eqUserPresets")
        .flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(userPresets), forKey: "eqUserPresets") }
    }
    /// Built-in presets, then imported ones.
    var allPresets: [(String, [Float])] { Self.presets + userPresets.map { ($0.name, $0.gains) } }
    @Published var gains: [Float] = UserDefaults.standard.array(forKey: "eqGains") as? [Float] ?? Array(repeating: 0, count: 10) {
        didSet { UserDefaults.standard.set(gains, forKey: "eqGains"); apply() }
    }
    /// App volume 0...1 by app id; missing means 100%.
    @Published private(set) var volumes = UserDefaults.standard.dictionary(forKey: "eqVolumes") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(volumes, forKey: "eqVolumes") }
    }

    private(set) var chain: TapChain?
    private var chainApps: [App] = []      // apps with their own tap, in tap order
    private var chainOutput: String?       // UID of the speakers the chain plays on
    private var pendingCheck: DispatchWorkItem?
    private var watchdog: Timer?
    private var lastCounts = (callbacks: 0, heard: 0)
    private var stuckSeconds = 0              // seconds an app played while Deck heard nothing

    private init() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
                MainActor.assumeIsolated { Equalizer.shared.devicesChanged() }
            }
        }
        // A new app or helper process (a new browser tab) started making sound: give turned-down apps their tap
        // even when the Focus screen isn't open.
        var procs = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &procs, .main) { _, _ in
            MainActor.assumeIsolated { if Equalizer.shared.on { Equalizer.shared.refreshApps() } }
        }
    }

    func setOn(_ value: Bool) {
        guard value != on else { return }
        if value, !Permission.wasExplained(.audioCapture) {
            Task { if await Permission.explain(.audioCapture) { setOn(true) } }
            return
        }
        if value { start() } else { stop() }
    }

    func preset(_ g: [Float]) { gains = g }

    func volume(_ app: App) -> Double { volumes[app.id] ?? 1 }

    func setVolume(_ app: App, _ v: Double) {
        volumes[app.id] = v >= 1 ? nil : v
        if let i = chainApps.firstIndex(where: { $0.id == app.id }) { chain?.setVolume(i, Float(v)) }
        else if on && v < 1 { restart() }   // first time this app is turned down: give it its own tap
    }

    /// Apps playing sound right now, plus any you turned down that are still open.
    func refreshApps() {
        var found: [String: (name: String, icon: NSImage?, objects: [AudioObjectID], playing: Bool)] = [:]
        for obj in Self.processes() {
            guard let pid = Self.prop(obj, kAudioProcessPropertyPID, as: pid_t.self),
                  let owner = Self.appPID(for: pid, responsible: Self.responsiblePID, parent: Self.parentPID,
                                          isApp: { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }),
                  owner != getpid(), let app = NSRunningApplication(processIdentifier: owner), let name = app.localizedName
            else { continue }
            let id = app.bundleIdentifier ?? "pid \(owner)"
            let playing = Self.prop(obj, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1
            var entry = found[id] ?? (name, app.icon, [], false)
            entry.objects.append(obj)
            entry.playing = entry.playing || playing
            found[id] = entry
        }
        apps = found.filter { $0.value.playing || volumes[$0.key] != nil }
            .map { App(id: $0.key, name: $0.value.name, icon: $0.value.icon, objects: $0.value.objects) }
            .sorted { $0.name < $1.name }
        // A turned-down app started playing, or started a new helper process (a new browser tab): give it its tap.
        let untapped = apps.contains { a in
            volumes[a.id] != nil && !(chainApps.first { $0.id == a.id }.map { Set(a.objects).isSubset(of: $0.objects) } ?? false)
        }
        if on && untapped { restart() }
    }

    func start() {
        refreshApps()
        let output = Self.defaultOutput()
        let chosen = apps.filter { volumes[$0.id] != nil }
        do {
            guard let output, let uid = Self.uid(output) else { throw CAError(status: -1) }
            let c = try TapChain(outputUID: uid, apps: chosen.map(\.objects))
            for (i, a) in chosen.enumerated() { c.setVolume(i, Float(volume(a))) }
            chain = c
            chainApps = chosen
            chainOutput = uid
            on = true
            problem = nil
            apply()
            lastCounts = (0, 0)
            stuckSeconds = 0
            buffersSeen = 0
            watchdog?.invalidate()
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { Equalizer.shared.checkSound() }
            }
            checkSound()
        } catch {
            problem = Self.audioCaptureDenied() ? Self.permissionProblem
                : "Deck couldn't start the equalizer on your speakers. Turn it off and on again."
            on = false
        }
    }

    private func stop() {
        watchdog?.invalidate()
        watchdog = nil
        chain?.stop()
        chain = nil
        problem = nil
        chainApps = []
        chainOutput = nil
        on = false
    }

    private func restart() { stop(); start() }

    // MARK: status

    nonisolated static let permissionProblem = "macOS hasn't let Deck hear your Mac's sound. Turn on Deck in System Settings › Privacy & Security › Screen & System Audio Recording."
    nonisolated static let fineTuneProblem = "Quit FineTune first; two equalizers fight over the sound."
    /// Opens the pane where Deck's audio permission lives.
    nonisolated static let permissionPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    /// Once a second while on: is sound actually flowing through Deck?
    private func checkSound() {
        guard let chain else { return }
        let me = getpid()
        let playing = Self.processes().contains {
            Self.prop($0, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1 && Self.prop($0, kAudioProcessPropertyPID, as: pid_t.self) != me
        }
        let counts = (callbacks: chain.callbacks, heard: chain.heard)
        stuckSeconds = playing && counts.heard == lastCounts.heard ? stuckSeconds + 1 : 0
        let p = Self.diagnose(fineTune: !NSRunningApplication.runningApplications(withBundleIdentifier: "com.finetuneapp.FineTune").isEmpty,
                              denied: Self.audioCaptureDenied(), stuckSeconds: stuckSeconds,
                              callbacksMoved: counts.callbacks != lastCounts.callbacks)
        lastCounts = counts
        if buffersSeen != counts.heard { buffersSeen = counts.heard }
        if problem != p { problem = p }
    }

    /// What to tell the user. Taps only run while some app plays, so "no buffers" only counts while something plays.
    nonisolated static func diagnose(fineTune: Bool, denied: Bool, stuckSeconds: Int, callbacksMoved: Bool) -> String? {
        if fineTune { return fineTuneProblem }
        if denied { return permissionProblem }
        guard stuckSeconds >= 2 else { return nil }
        // Buffers arrive but are pure silence: that's how macOS answers when Deck may not listen.
        return callbacksMoved ? permissionProblem : "Deck's equalizer isn't getting any sound. Turn it off and on again."
    }

    /// The user said no to "Screen & System Audio Recording" (TCC SPI, as in insidegui/AudioCap). False when unknown.
    nonisolated static func audioCaptureDenied() -> Bool {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(tcc, "TCCAccessPreflight") else { return false }
        return unsafeBitCast(sym, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) == 1
    }

    // MARK: FineTune import

    nonisolated static let fineTuneSettings = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/FineTune/settings.json")
    static var fineTuneAvailable: Bool { FileManager.default.fileExists(atPath: fineTuneSettings.path) }

    struct FineTuneSetup: Equatable {
        var gains: [Float]?                 // the EQ to use as Deck's one EQ
        var gainsFrom: String?              // bundle id it came from
        var presets: [Preset]               // FineTune's own presets
        var appEQs: [String: [Float]]       // bundle id → that app's EQ in FineTune
        var volumes: [String: Double]       // bundle id → 0…1, only apps below 100%
    }

    /// Reads FineTune's settings.json (v12: appEQSettings, userEQPresets, appVolumes, appMutes). FineTune has one EQ
    /// per app and Deck one in all, so Deck takes the EQ of an app in `preferring` (playing now), else the first by id.
    nonisolated static func parseFineTune(_ data: Data, preferring: [String] = []) throws -> FineTuneSetup {
        struct EQ: Decodable { var bandGains: [Float]?; var isEnabled: Bool? }
        struct UserPreset: Decodable { var name: String; var settings: EQ }
        struct File: Decodable {
            var appEQSettings: [String: EQ]?; var userEQPresets: [UserPreset]?
            var appVolumes: [String: Double]?; var appMutes: [String: Bool]?
        }
        let f = try JSONDecoder().decode(File.self, from: data)
        // FineTune's bands are 31.25, 62.5, 125 … 16k Hz: the same ten as Deck's, so they map one to one.
        func ten(_ g: [Float]?) -> [Float] {
            let g = (g ?? []).prefix(10).map { $0.isFinite ? min(12, max(-12, $0)) : 0 }
            return g + Array(repeating: 0, count: 10 - g.count)
        }
        let appEQs = (f.appEQSettings ?? [:]).filter { $0.value.isEnabled ?? true }
            .mapValues { ten($0.bandGains) }.filter { $0.value.contains { $0 != 0 } }
        let pick = preferring.first { appEQs[$0] != nil } ?? appEQs.keys.sorted().first
        var volumes = (f.appVolumes ?? [:]).filter { $0.value < 1 }.mapValues { max(0, $0) }
        for (id, muted) in f.appMutes ?? [:] where muted { volumes[id] = 0 }
        return FineTuneSetup(gains: pick.flatMap { appEQs[$0] }, gainsFrom: pick,
                             presets: (f.userEQPresets ?? []).map { Preset(name: $0.name, gains: ten($0.settings.bandGains)) },
                             appEQs: appEQs, volumes: volumes)
    }

    /// Brings in your FineTune EQ, presets and app volumes. Only reads FineTune's files.
    func importFineTune() -> String {
        guard let data = try? Data(contentsOf: Self.fineTuneSettings),
              let setup = try? Self.parseFineTune(data, preferring: apps.map(\.id)) else { return "Couldn't read FineTune's settings." }
        func appName(_ id: String) -> String {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) }?
                .replacingOccurrences(of: ".app", with: "") ?? id
        }
        // Each app's EQ becomes a preset named after the app, so the ones Deck didn't pick aren't lost.
        let builtIn = Set(Self.presets.map(\.0))
        let fresh = (setup.presets + setup.appEQs.keys.sorted().map { Preset(name: appName($0), gains: setup.appEQs[$0]!) })
            .filter { !builtIn.contains($0.name) }
        userPresets = userPresets.filter { old in !fresh.contains { $0.name == old.name } } + fresh
        if let g = setup.gains { gains = g }
        for (id, v) in setup.volumes { volumes[id] = v }
        if on && !setup.volumes.isEmpty { restart() }
        var parts: [String] = []
        if let from = setup.gainsFrom { parts.append("your FineTune EQ (from \(appName(from)))") }
        func count(_ n: Int, _ what: String) -> String { n == 0 ? "no \(what)s" : n == 1 ? "1 \(what)" : "\(n) \(what)s" }
        parts.append(count(fresh.count, "preset"))
        parts.append(count(setup.volumes.count, "app volume"))
        return "Imported " + parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    private func apply() {
        guard let eq = chain?.eq else { return }
        for (i, g) in gains.enumerated() where i < eq.bands.count { eq.bands[i].gain = g }
        eq.globalGain = -max(0, gains.max() ?? 0)   // headroom so boosts don't clip
    }

    // MARK: following the output device

    enum DeviceAction: Equatable { case keep, rebuild, stop }

    /// What to do after a device change, given the speakers we play on, the current default output and all device UIDs.
    nonisolated static func deviceAction(playingOn: String?, defaultOutput: String?, devices: Set<String>) -> DeviceAction {
        guard let playingOn else { return .keep }
        guard let defaultOutput, devices.contains(defaultOutput) else { return .stop }
        return playingOn == defaultOutput && devices.contains(playingOn) ? .keep : .rebuild
    }

    /// Device lists change in bursts (AirPods connect in several steps), so wait for them to settle.
    private func devicesChanged() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let eq = Equalizer.shared
                guard eq.on else { return }
                let uids = Set(Self.devices().compactMap(Self.uid))
                switch Self.deviceAction(playingOn: eq.chainOutput, defaultOutput: Self.defaultOutput().flatMap(Self.uid), devices: uids) {
                case .keep: break
                case .rebuild: eq.restart()
                case .stop: eq.stop(); eq.problem = "No speakers or headphones found. Turn the equalizer on again once they're back."
                }
            }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Core Audio property helpers

    nonisolated static func prop<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.load(as: T.self)
    }

    nonisolated static func list(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    nonisolated static func processes() -> [AudioObjectID] { list(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) }
    nonisolated static func devices() -> [AudioObjectID] { list(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) }

    /// Where music and videos play (not the alert-sound device).
    nonisolated static func defaultOutput() -> AudioObjectID? {
        prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    nonisolated static func uid(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    /// The app that owns a sound-making process: itself, the app responsible for it (WebKit helpers), or the nearest
    /// parent app (Chrome, Spotify and Electron helpers disclaim responsibility, so only their parent leads to the app).
    nonisolated static func appPID(for pid: pid_t, responsible: (pid_t) -> pid_t, parent: (pid_t) -> pid_t?,
                                   isApp: (pid_t) -> Bool) -> pid_t? {
        if isApp(pid) { return pid }
        if case let owner = responsible(pid), isApp(owner) { return owner }
        var p = pid, seen: Set<pid_t> = []
        while p > 1, seen.insert(p).inserted {
            if isApp(p) { return p }
            guard let next = parent(p) else { return nil }
            p = next
        }
        return nil
    }

    nonisolated static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size, mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        return sysctl(&mib, 4, &info, &size, nil, 0) == 0 && size > 0 ? info.kp_eproc.e_ppid : nil
    }

    /// The app a helper process works for (Activity Monitor does the same). Falls back to the process itself.
    nonisolated static func responsiblePID(_ pid: pid_t) -> pid_t {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return pid }
        let owner = unsafeBitCast(sym, to: Fn.self)(pid)
        return owner > 0 ? owner : pid
    }
}

private struct CAError: Error { let status: OSStatus }
private func check(_ s: OSStatus) throws { if s != noErr { throw CAError(status: s) } }

/// Owns the taps, the aggregate device, the IO callback and the EQ engine.
/// Tap + private aggregate setup and reading the tap's stream format are adapted from insidegui/AudioCap
/// (BSD-2-Clause, Copyright (c) 2024 Guilherme Rambo).
final class TapChain: @unchecked Sendable {
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private var sources: [AVAudioSourceNode] = []
    private var taps: [AudioObjectID] = []
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var input: UnsafePointer<AudioBufferList>?   // only touched on the audio thread
    private var scratch: AVAudioPCMBuffer!
    /// Written on the audio thread, read on main; a torn read only delays the status by a second.
    /// `heard`: callbacks whose tap input wasn't pure silence (macOS sends silence when Deck may not listen).
    private(set) var callbacks = 0, heard = 0
    var inPeak: Float = 0, outPeak: Float = 0   // loudest sample in / out since last reset

    /// `apps`: process objects per turned-down app. Everything else (minus Deck) goes through one more tap.
    init(outputUID: String, apps: [[AudioObjectID]]) throws {
        do { try build(outputUID: outputUID, apps: apps) } catch { teardown(); throw error }
    }

    func setVolume(_ index: Int, _ v: Float) { if sources.indices.contains(index) { sources[index].volume = v } }

    func stop() { teardown() }

    private func build(outputUID: String, apps: [[AudioObjectID]]) throws {
        // 1. Taps. Without Deck's own process object a global tap would hear our output and feed back.
        guard let me = Self.processObject(getpid()) else { throw CAError(status: -1) }
        let descs = apps.map { CATapDescription(stereoMixdownOfProcesses: $0) }
            + [CATapDescription(stereoGlobalTapButExcludeProcesses: [me] + apps.flatMap { $0 })]
        for d in descs {
            d.uuid = UUID()
            d.muteBehavior = .mutedWhenTapped   // sound comes back by itself if Deck stops reading
            d.isPrivate = true
            d.name = "Deck equalizer"
            var id = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateProcessTap(d, &id))
            taps.append(id)
            // We read raw float samples, so the tap must deliver 32-bit float PCM.
            guard let f = Equalizer.prop(id, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self),
                  f.mFormatID == kAudioFormatLinearPCM, f.mFormatFlags & kAudioFormatFlagIsFloat != 0, f.mBitsPerChannel == 32
            else { throw CAError(status: -2) }
        }

        // 2. Private aggregate device: the speakers + all taps as inputs.
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Deck EQ",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: descs.map { [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: $0.uuid.uuidString] },
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &deviceID))

        // 3. Engine, rendered by hand from the IO callback: one source per tap → mixer → EQ.
        let rate = Equalizer.prop(deviceID, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        for (i, b) in eq.bands.enumerated() {
            b.frequency = Equalizer.bands[i]
            b.bandwidth = 1
            b.filterType = i == 0 ? .lowShelf : i == 9 ? .highShelf : .parametric
            b.bypass = false
        }
        try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 8192)
        engine.attach(mixer)
        engine.attach(eq)
        let n = descs.count
        for i in 0..<n {
            let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, abl in
                self.copyTap(i, of: n, into: UnsafeMutableAudioBufferListPointer(abl), frames: Int(frames))
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: mixer, fromBus: 0, toBus: i, format: format)
            sources.append(source)
        }
        engine.connect(mixer, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        try engine.start()

        // 4. IO callback: taps in → engine → speakers out.
        let render = engine.manualRenderingBlock
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { [unowned self] _, inData, _, outData, _ in
            let out = UnsafeMutableAudioBufferListPointer(outData)
            guard let first = out.first(where: { $0.mNumberChannels > 0 }) else { return }
            let frames = min(Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels)), Int(self.scratch.frameCapacity))
            self.input = inData
            var err: OSStatus = noErr
            self.scratch.frameLength = AVAudioFrameCount(frames)
            _ = render(AVAudioFrameCount(frames), self.scratch.mutableAudioBufferList, &err)
            self.input = nil
            Self.write(self.scratch, to: out, frames: frames)
            self.callbacks += 1
            let inP = Self.peak(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)).suffix(n))
            if inP > 0 { self.heard += 1 }
            self.inPeak = max(self.inPeak, inP)
            self.outPeak = max(self.outPeak, Self.peak(out))
        })
        if let procID { Self.useOnlyTapInputs(deviceID, procID, taps: n) }
        try check(AudioDeviceStart(deviceID, procID))
    }

    private func teardown() {
        if let procID { AudioDeviceStop(deviceID, procID); AudioDeviceDestroyIOProcID(deviceID, procID) }
        procID = nil
        engine.stop()
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        taps.forEach { AudioHardwareDestroyProcessTap($0) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        taps = []
    }

    /// Headsets and AirPods add microphone streams before the tap streams. Turning those off for our callback keeps
    /// the mic (and the orange dot, and AirPods' low-quality call mode) out of it. Taps are the last `taps` streams.
    private static func useOnlyTapInputs(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID, taps: Int) {
        let streams = Equalizer.list(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
        guard streams > taps,
              let countAt = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams),
              let flagsAt = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let size = flagsAt + streams * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(streams), toByteOffset: countAt, as: UInt32.self)
        for i in 0..<streams { raw.storeBytes(of: UInt32(i >= streams - taps ? 1 : 0), toByteOffset: flagsAt + 4 * i, as: UInt32.self) }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(size), raw)
    }

    /// Source pull: copy tap `i` (one interleaved float stream; hardware inputs come first) into the engine's 2 channels.
    private func copyTap(_ i: Int, of n: Int, into dst: UnsafeMutableAudioBufferListPointer, frames: Int) {
        for b in dst { memset(b.mData, 0, Int(b.mDataByteSize)) }
        guard let input else { return }
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let index = src.count - n + i
        guard index >= 0, index < src.count, let data = src[index].mData?.assumingMemoryBound(to: Float.self),
              src[index].mNumberChannels > 0 else { return }
        let ch = Int(src[index].mNumberChannels)
        let count = min(frames, Int(src[index].mDataByteSize) / (4 * ch))
        for c in 0..<min(dst.count, 2) {
            guard let d = dst[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let sc = min(c, ch - 1)
            for f in 0..<count { d[f] = data[f * ch + sc] }
        }
    }

    /// Engine output (L, R) → device output: left and right into the first two channels across its streams.
    /// A mono device gets the average; extra channels stay silent.
    private static func write(_ buf: AVAudioPCMBuffer, to out: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard let chans = buf.floatChannelData else { return }
        let total = out.reduce(0) { $0 + Int($1.mNumberChannels) }
        var firstChannel = 0
        for b in out {
            let ch = Int(b.mNumberChannels)
            defer { firstChannel += ch }
            guard let d = b.mData?.assumingMemoryBound(to: Float.self), ch > 0 else { continue }
            memset(d, 0, Int(b.mDataByteSize))
            let n = min(frames, Int(b.mDataByteSize) / (4 * ch))
            for c in 0..<ch where firstChannel + c < 2 {
                let k = firstChannel + c
                for f in 0..<n { d[f * ch + c] = total == 1 ? (chans[0][f] + chans[1][f]) * 0.5 : chans[k][f] }
            }
        }
    }

    private static func peak(_ abl: some Sequence<AudioBuffer>) -> Float {
        var m: Float = 0
        for b in abl {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            var p: Float = 0
            vDSP_maxmgv(d, 1, &p, vDSP_Length(Int(b.mDataByteSize) / 4))
            m = max(m, p)
        }
        return m
    }

    private static func processObject(_ pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid, obj = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return s == noErr && obj != kAudioObjectUnknown ? obj : nil
    }
}
