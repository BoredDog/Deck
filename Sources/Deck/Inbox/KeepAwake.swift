import SwiftUI
import IOKit.pwr_mgt

/// Stops the Mac from sleeping: until switched off, for a while, or until downloads finish.
@MainActor final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    enum Length: String, CaseIterable, Identifiable {
        case always = "Until I turn it off", hour = "1 hour", twoHours = "2 hours", downloads = "Until downloads finish"
        var id: String { rawValue }
        var short: String {
            switch self {
            case .always: "Until off"
            case .hour: "1 hour"
            case .twoHours: "2 hours"
            case .downloads: "Downloads done"
            }
        }
    }

    @Published var on = false { didSet { if on != oldValue { apply() } } }
    @Published var length = Length(rawValue: UserDefaults.standard.string(forKey: "keepAwakeLength") ?? "") ?? .always {
        didSet { UserDefaults.standard.set(length.rawValue, forKey: "keepAwakeLength"); if on { apply() } }
    }
    @AppStorage("keepScreenOn") var screenOn = false { didSet { if on { apply() } } }
    @Published private(set) var endsAt: Date?

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    private func apply() {
        release()
        guard on else { endsAt = nil; return }
        // The display assertion also keeps the system awake; the system one lets the screen dim.
        let type = screenOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Deck: keep awake" as CFString, &assertion) == kIOReturnSuccess else { on = false; return }
        endsAt = switch length {
        case .hour: .now.addingTimeInterval(3600)
        case .twoHours: .now.addingTimeInterval(7200)
        default: nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Task { @MainActor in KeepAwake.shared.check() } }
    }

    private func check() {
        if let endsAt, endsAt <= .now { on = false }
        if length == .downloads, !Downloads.shared.items.contains(where: { ["active", "waiting"].contains($0.status) }) { on = false }
    }

    private func release() {
        timer?.invalidate()
        timer = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
}

/// Keep-awake switch with how long, used in the menu bar panel and the quick panel.
struct KeepAwakeControls: View {
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Keep Mac awake", isOn: $awake.on).toggleStyle(.switch).font(F.body)
                Spacer()
                if let end = awake.endsAt {
                    Text("until \(clock(end))").font(F.mono(11)).foregroundStyle(C.text2)
                }
            }
            if awake.on {
                HStack(alignment: .top, spacing: 8) {
                    Text("For").font(F.label).foregroundStyle(C.text2).padding(.top, 6)
                    DeckDropdown(selection: $awake.length, options: KeepAwake.Length.allCases.map { ($0.rawValue, $0) })
                }
                Toggle("Keep the screen on too", isOn: $awake.screenOn).toggleStyle(.switch).font(F.label)
            }
        }
    }
}
