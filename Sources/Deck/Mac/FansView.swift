import SwiftUI
import ServiceManagement

/// Fan speeds, temperatures and (with the helper) fan control. Polls every 2 seconds only while on screen.
struct FansTile: View {
    @ObservedObject private var f = Fans.shared
    @State private var helper = Blocker.helper.status
    @Environment(\.accent) private var accent

    var body: some View {
        Tile {
            TileLabel(text: "Fans")
            if !f.hasFans {
                Text("This Mac has no fan — it stays quiet by design.").font(F.body).foregroundStyle(C.text2)
            } else {
                ForEach(f.fans) { fan in fanRow(fan) }
                if !f.temps.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(f.temps) { t in
                            Row(divider: t.id != f.temps.last?.id) {
                                Dot(color: t.celsius < 70 ? C.ok : t.celsius <= 90 ? C.warn : Color(hex: 0xf85149))
                                Text(t.name).font(F.ui(13))
                                Spacer()
                                Text("\(Int(t.celsius.rounded()))°C").font(F.mono(13))
                            }
                        }
                    }
                }
                helperRow
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { f.start(); helper = Blocker.helper.status }
        .onDisappear { f.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            helper = Blocker.helper.status   // back from System Settings
        }
    }

    private func fanRow(_ fan: Fan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Apple Silicon fans stop completely when the Mac is cool.
                if fan.rpm < 1 {
                    Text("Resting").font(F.big).tracking(-0.8)
                    Text("the fan is off while your Mac is cool").font(F.label).foregroundStyle(C.text2)
                } else {
                    Text("\(Int(fan.rpm.rounded()))").font(F.mono(32)).tracking(-0.8)
                    Text("rpm").font(F.mono(11)).foregroundStyle(C.text2)
                }
                Spacer()
                if f.fans.count > 1 { Text("Fan \(fan.id + 1)").font(F.label).foregroundStyle(C.text2) }
            }
            Bar4(value: fan.level, color: accent.accent)
            Text("\(Int(fan.min))–\(Int(fan.max)) rpm").font(F.mono(11)).foregroundStyle(C.muted)
            if helper == .enabled {
                let current = f.preset[fan.id] ?? .automatic
                HStack(spacing: 6) {
                    ForEach(FanPreset.allCases, id: \.self) { p in
                        Button(p.rawValue) { f.apply(p, to: fan) }
                            .buttonStyle(.pill)
                            .overlay(Capsule().strokeBorder(current == p ? accent.accent : .clear, lineWidth: 1))
                    }
                }
                if current == .custom {
                    let rpm = Binding(get: { f.custom[fan.id] ?? Double(FanMath.cooler(min: fan.min, max: fan.max)) },
                                      set: { f.custom[fan.id] = $0 })
                    HStack {
                        Slider(value: rpm, in: fan.min...fan.max) { editing in
                            if !editing { f.setCustom(rpm.wrappedValue, for: fan) }   // one helper call per drag
                        }
                        Text("\(Int(rpm.wrappedValue)) rpm").font(F.mono(11)).foregroundStyle(C.text2).frame(width: 72, alignment: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder private var helperRow: some View {
        switch helper {
        case .enabled:
            if f.failed { Text("The fan didn't change. Try again in a moment.").font(F.label).foregroundStyle(C.warn) }
        case .requiresApproval:
            Text("Turn on Deck in System Settings → General → Login Items to control the fan.").font(F.label).foregroundStyle(C.text2)
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.pill)
        default:
            Text("Fan control uses the same one-time helper as website blocking.").font(F.label).foregroundStyle(C.muted)
            Button("Set up") { Blocker.setUpHelper(); helper = Blocker.helper.status }.buttonStyle(.pill)
        }
    }
}
