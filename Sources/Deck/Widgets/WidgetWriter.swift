import AppKit
import Combine
import Security
import SwiftUI
import SwiftData
import WidgetKit

/// Keeps the Notification Center widgets fed: writes a WidgetSnapshot to the App Group folder when something changes
/// (tasks and focus right away, everything else at most every 30 s) and asks WidgetKit to reload.
/// Does nothing in builds without the App Group entitlement (swift run, scripts/bundle.sh).
@MainActor final class WidgetWriter {
    static let shared = WidgetWriter()
    private var bag: [AnyCancellable] = []
    private var pending: Task<Void, Never>?
    private var lastWrite = Date.distantPast
    private var lastReloaded: WidgetSnapshot?

    func start() {
        guard bag.isEmpty, Self.entitled else { return }
        let main = RunLoop.main   // @Published fires before the value changes; hop once so we read the new one
        Planner.shared.$todayTasks.removeDuplicates().receive(on: main).sink { _ in self.update(now: true) }.store(in: &bag)
        Planner.shared.$nextEvent.removeDuplicates().receive(on: main).sink { _ in self.update() }.store(in: &bag)
        Downloads.shared.$items.removeDuplicates().receive(on: main).sink { _ in self.update() }.store(in: &bag)
        // Focus sessions and "saved" activity land through SwiftData saves.
        NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: main).sink { _ in self.update(now: true) }.store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: main).sink { _ in self.update() }.store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: WidgetSnapshot.requestNotification).receive(on: main)
            .sink { _ in self.completeRequested() }.store(in: &bag)
        // Mac status isn't polled unless a screen shows it; sample it ourselves every 5 minutes.
        Timer.publish(every: 300, on: main, in: .common).autoconnect().sink { _ in
            SystemMonitor.shared.sample()
            self.update()
        }.store(in: &bag)
        SystemMonitor.shared.sample()
        completeRequested()
    }

    /// Writes now, or within 30 s of the last write (changes in between are folded into one write).
    func update(now: Bool = false) {
        if now {
            pending?.cancel()
            pending = nil
            write()
            return
        }
        guard pending == nil else { return }
        let wait = max(0, 30 - Date.now.timeIntervalSince(lastWrite))
        pending = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            pending = nil
            write()
        }
    }

    private func write() {
        let s = snapshot()
        lastWrite = .now
        try? s.save()
        // WidgetKit budgets reloads; skip them when only live gauges moved (widgets also refresh every 15 min).
        if Self.reloadKey(s) != lastReloaded.map(Self.reloadKey) {
            lastReloaded = s
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func snapshot() -> WidgetSnapshot {
        let ctx = Store.context
        let sessions = (try? ctx.fetch(FetchDescriptor<FocusSession>())) ?? []
        let saved = (try? ctx.fetch(FetchDescriptor<Activity>(predicate: #Predicate { $0.savedBytes > 0 }))) ?? []
        let p = Planner.shared, mon = SystemMonitor.shared
        var s = WidgetSnapshot()
        s.streakDays = FocusStats.streak(sessions)
        s.focusMinutesThisWeek = FocusStats.weekMinutes(sessions)
        s.nextEventTitle = p.nextEvent?.title
        s.nextEventStart = p.nextEvent?.start
        s.tasks = p.todayTasks.prefix(5).map { .init(id: $0.id, title: $0.title, due: $0.hasTime ? $0.due : nil, done: $0.done) }
        s.download = Downloads.shared.items.first { $0.status == "active" }.map { .init(name: $0.name, progress: $0.progress) }
        s.cpu = mon.cpu
        s.memory = mon.memory
        s.diskFree = mon.diskFree
        s.savedBytes = saved.reduce(0) { $0 + $1.savedBytes }
        s.accentHex = Self.hex(Accent.named(UserDefaults.standard.string(forKey: "theme") ?? "").accent)
        s.updated = .now
        return s
    }

    /// Completes the tasks ticked in a widget (the extension can't reach Reminders itself without its own permission).
    private func completeRequested() {
        guard let url = WidgetSnapshot.completeURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        // shortcut: a tick landing between this read and the remove is lost; ticks are seconds apart, fine for one user.
        try? FileManager.default.removeItem(at: url)
        for id in Set(text.split(separator: "\n").map(String.init)) {
            Planner.shared.complete(PlanTask(id: id, title: "", due: nil, done: false))
        }
    }

    private static func reloadKey(_ s: WidgetSnapshot) -> WidgetSnapshot {
        var k = s
        k.cpu = 0; k.memory = 0; k.diskFree = 0; k.updated = .distantPast
        k.download?.progress = ((s.download?.progress ?? 0) * 10).rounded() / 10
        return k
    }

    private static func hex(_ color: Color) -> UInt32 {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return 0x4fc9b8 }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }

    /// Only Xcode-signed builds carry the App Group; touching the folder without it makes macOS ask the user.
    private static var entitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String]
        else { return false }
        return groups.contains(WidgetSnapshot.group)
    }
}
