import SwiftUI
import AppKit

/// "3h 12m", "45m", "<1m".
func usageTime(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    if m < 1 { return "<1m" }
    return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
}

/// Mac → Screen time: how long each app was in front, kept only on this Mac.
struct ScreenTimeView: View {
    @ObservedObject private var st = ScreenTime.shared
    @AppStorage(ScreenTime.key) private var on = true
    @State private var confirmDelete = false
    @Environment(\.accent) private var accent

    private let cal = Calendar.current
    private var today: Date { .now }
    private var yesterday: Date { cal.date(byAdding: .day, value: -1, to: .now)! }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Tile {
                    TileLabel(text: "Today")
                    BigNumber(text: usageTime(st.log.total(today)))
                    if st.log.total(today) > 0, st.log.total(today) < st.log.total(yesterday) {
                        Text("Less than yesterday so far.").font(F.label).foregroundStyle(C.text2)
                    }
                }
                week
            }
            .fixedSize(horizontal: false, vertical: true)
            topApps
            Tile {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Track app use").font(F.ui(13))
                        Text("Only app names and times, saved on this Mac. Never window titles or websites.").font(F.label).foregroundStyle(C.text2)
                    }
                    Spacer()
                    Toggle("Track app use", isOn: Binding(get: { on }, set: { on = $0; st.setOn($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if !on, !st.log.days.isEmpty {
                    Button("Delete history") { confirmDelete = true }.buttonStyle(.pill)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { st.refresh() }
        .confirmationDialog("Delete all screen time history?", isPresented: $confirmDelete) {
            Button("Delete history", role: .destructive) { st.deleteHistory() }
        }
    }

    /// Last 7 days, today on the right.
    private var week: some View {
        let days = (0..<7).reversed().map { cal.date(byAdding: .day, value: -$0, to: .now)! }
        let totals = days.map { st.log.total($0) }
        let peak = max(1, totals.max() ?? 1)
        return Tile {
            TileLabel(text: "This week")
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days.indices, id: \.self) { i in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(totals[i] > 0 ? accent.accent : C.line)
                            .frame(height: max(2, CGFloat(totals[i] / peak) * 56))
                        Text(days[i].formatted(.dateTime.weekday(.narrow))).font(F.mono(10)).foregroundStyle(C.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .help(usageTime(totals[i]))
                }
            }
            .frame(height: 76, alignment: .bottom)
        }
    }

    private var topApps: some View {
        let list = Array(st.log.top(today).prefix(8))
        let peak = max(1, list.first?.seconds ?? 1)
        return Tile {
            TileLabel(text: "Most used today")
            if list.isEmpty {
                Text(on ? "Nothing yet today." : "Tracking is off.").font(F.label).foregroundStyle(C.text2)
            }
            ForEach(list, id: \.id) { app in
                Row(divider: app.id != list.last?.id) {
                    icon(app.id)
                    Text(st.log.names[app.id] ?? app.id).font(F.ui(13)).lineLimit(1).frame(width: 160, alignment: .leading)
                    Bar4(value: app.seconds / peak, color: accent.accent)
                    Text(usageTime(app.seconds)).font(F.mono(11)).foregroundStyle(C.text2).frame(width: 64, alignment: .trailing)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func icon(_ id: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        return Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application))
            .resizable().frame(width: 18, height: 18)
    }
}
