import SwiftUI
import AVFoundation
import CoreAudio

/// System-wide (or one app) equalizer.
/// Sound path: process tap (mutes the original) → private aggregate device → our IO callback
/// → AVAudioEngine in real-time manual rendering with a 10-band AVAudioUnitEQ → the aggregate's output (your speakers).
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

    struct App: Identifiable, Hashable { let id: AudioObjectID; let name: String }

    @Published var on = false
    @Published var problem: String?
    @Published var apps: [App] = []
    @Published var target: AudioObjectID?          // nil = all sound
    @Published var gains: [Float] = UserDefaults.standard.array(forKey: "eqGains") as? [Float] ?? Array(repeating: 0, count: 10) {
        didSet { UserDefaults.standard.set(gains, forKey: "eqGains"); apply() }
    }

    private var chain: AnyObject?   // the running TapChain (typed loosely so this class stays available on macOS 14.0)

    func setOn(_ value: Bool) {
        guard value != on else { return }
        if value { start() } else { stop() }
    }

    func choose(_ app: AudioObjectID?) {
        target = app
        if on { stop(); start() }
    }

    func preset(_ g: [Float]) { gains = g }

    func refreshApps() {
        apps = Self.processes().compactMap { (obj: AudioObjectID) -> App? in
            guard let pid = Self.prop(obj, kAudioProcessPropertyPID, as: pid_t.self), pid != getpid(),
                  let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName,
                  app.activationPolicy == .regular else { return nil }
            return App(id: obj, name: name)
        }
        .reduce(into: [App]()) { list, a in if !list.contains(where: { $0.name == a.name }) { list.append(a) } }
        .sorted { $0.name < $1.name }
    }

    private func start() {
        guard #available(macOS 14.2, *) else { problem = "The equalizer needs macOS 14.2 or newer."; return }
        do {
            let c = try TapChain(target: target)
            chain = c
            on = true
            problem = nil
            apply()
        } catch {
            problem = "Deck couldn't reach your Mac's sound. Check System Settings → Privacy & Security → Audio Recording."
            on = false
        }
    }

    private func stop() {
        if #available(macOS 14.2, *) { (chain as? TapChain)?.stop() }
        chain = nil
        on = false
    }

    private func apply() {
        guard #available(macOS 14.2, *), let eq = (chain as? TapChain)?.eq else { return }
        for (i, g) in gains.enumerated() where i < eq.bands.count { eq.bands[i].gain = g }
        eq.globalGain = -max(0, gains.max() ?? 0)   // headroom so boosts don't clip
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

    nonisolated static func processes() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}

private struct CAError: Error { let status: OSStatus }
private func check(_ s: OSStatus) throws { if s != noErr { throw CAError(status: s) } }

/// Owns the tap, the aggregate device, the IO callback and the EQ engine.
@available(macOS 14.2, *)
private final class TapChain: @unchecked Sendable {
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let engine = AVAudioEngine()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var input: UnsafePointer<AudioBufferList>?   // only touched on the audio thread
    private let scratch: AVAudioPCMBuffer

    init(target: AudioObjectID?) throws {
        // 1. Tap: everything except Deck itself, or just the chosen app. The original sound is muted.
        let me = Self.processObject(getpid())
        let desc = target.map { CATapDescription(stereoMixdownOfProcesses: [$0]) }
            ?? CATapDescription(stereoGlobalTapButExcludeProcesses: me.map { [$0] } ?? [])
        desc.uuid = UUID()
        desc.muteBehavior = .muted
        desc.isPrivate = true
        desc.name = "Deck equalizer"
        try check(AudioHardwareCreateProcessTap(desc, &tapID))

        // 2. Private aggregate device: current speakers + the tap as input.
        guard let out = Equalizer.prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self),
              let outUID = Self.uid(out) else { AudioHardwareDestroyProcessTap(tapID); throw CAError(status: -1) }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Deck EQ",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        do { try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &deviceID)) }
        catch { AudioHardwareDestroyProcessTap(tapID); throw error }

        // 3. EQ engine, rendered by hand from the IO callback.
        let rate = Equalizer.prop(deviceID, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        for (i, b) in eq.bands.enumerated() {
            b.frequency = Equalizer.bands[i]
            b.bandwidth = 1
            b.filterType = i == 0 ? .lowShelf : i == 9 ? .highShelf : .parametric
            b.bypass = false
        }
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, abl in
            self.copyInput(into: UnsafeMutableAudioBufferListPointer(abl), frames: Int(frames))
            return noErr
        }
        do {
            try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 8192)
            engine.attach(source)
            engine.attach(eq)
            engine.connect(source, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            try engine.start()
        } catch { teardown(); throw error }

        // 4. IO callback: tap in → EQ → speakers out.
        let render = engine.manualRenderingBlock
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { [unowned self] _, inData, _, outData, _ in
            let out = UnsafeMutableAudioBufferListPointer(outData)
            guard let first = out.first, first.mNumberChannels > 0 else { return }
            let frames = min(Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels)), Int(self.scratch.frameCapacity))
            self.input = inData
            var err: OSStatus = noErr
            self.scratch.frameLength = AVAudioFrameCount(frames)
            _ = render(AVAudioFrameCount(frames), self.scratch.mutableAudioBufferList, &err)
            self.input = nil
            Self.write(self.scratch, to: out, frames: frames)
        }
        do {
            try check(status)
            try check(AudioDeviceStart(deviceID, procID))
        } catch { teardown(); throw error }
    }

    func stop() { teardown() }

    private func teardown() {
        if let procID { AudioDeviceStop(deviceID, procID); AudioDeviceDestroyIOProcID(deviceID, procID) }
        procID = nil
        engine.stop()
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Source node pull: copy the tap's float samples (last input stream; interleaved or not) into the engine's 2 channels.
    private func copyInput(into dst: UnsafeMutableAudioBufferListPointer, frames: Int) {
        for i in 0..<dst.count { memset(dst[i].mData, 0, Int(dst[i].mDataByteSize)) }
        guard let input else { return }
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buf = src.last, let data = buf.mData?.assumingMemoryBound(to: Float.self), buf.mNumberChannels > 0 else { return }
        let ch = Int(buf.mNumberChannels)
        let n = min(frames, Int(buf.mDataByteSize) / (4 * ch))
        for c in 0..<min(dst.count, 2) {
            guard let d = dst[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let sc = min(c, ch - 1)
            for f in 0..<n { d[f] = data[f * ch + sc] }
        }
    }

    /// Engine output (2 separate channels) → device output (usually one interleaved stream).
    private static func write(_ buf: AVAudioPCMBuffer, to out: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard let chans = buf.floatChannelData else { return }
        for (i, b) in out.enumerated() {
            memset(b.mData, 0, Int(b.mDataByteSize))
            guard i == 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(b.mNumberChannels)
            for f in 0..<frames {
                for c in 0..<min(ch, 2) { d[f * ch + c] = chans[c][f] }
            }
        }
    }

    private static func processObject(_ pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid, obj = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return s == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    private static func uid(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

/// EQ tile: On switch, which sound, presets, 10 sliders.
struct EqualizerTile: View {
    @ObservedObject var eq: Equalizer
    @Environment(\.accent) private var accent

    var body: some View {
        Tile {
            HStack {
                TileLabel(text: "Equalizer")
                Spacer()
                Toggle("On", isOn: Binding(get: { eq.on }, set: { eq.setOn($0) })).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            if !eq.on && eq.problem == nil {
                Text("Shape the sound of your whole Mac. macOS will ask once to let Deck hear it.").font(F.label).foregroundStyle(C.text2)
            }
            if let p = eq.problem { Text(p).font(F.label).foregroundStyle(C.warn) }
            HStack(spacing: 6) {
                ForEach(Equalizer.presets, id: \.0) { name, g in
                    Button(name) { eq.preset(g) }.buttonStyle(.pill)
                }
                Spacer()
                Picker("", selection: Binding(get: { eq.target }, set: { eq.choose($0) })) {
                    Text("All sound").tag(AudioObjectID?.none)
                    ForEach(eq.apps) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden().frame(width: 150)
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 6) {
                        Text(String(format: "%+.0f", eq.gains[i])).font(F.mono(10)).foregroundStyle(C.text2)
                        Slider(value: Binding(get: { Double(eq.gains[i]) }, set: { eq.gains[i] = Float($0.rounded()) }), in: -12...12)
                            .tint(accent.accent)
                            .frame(width: 110).rotationEffect(.degrees(-90)).frame(width: 28, height: 110)
                        Text(Self.label(Equalizer.bands[i])).font(F.mono(10)).foregroundStyle(C.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { eq.refreshApps() }
    }

    private static func label(_ hz: Float) -> String { hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))" }
}
