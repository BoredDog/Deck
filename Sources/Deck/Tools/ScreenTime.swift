import AppKit

/// Seconds per app per day. App names and bundle ids only: never window titles or web addresses.
struct UsageLog: Codable, Equatable {
    var days: [String: [String: Double]] = [:]   // "2026-10-16" → bundle id → seconds
    var names: [String: String] = [:]            // bundle id → app name

    static func key(_ d: Date, cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Credits `app` for the time from `start` to `end`, split at midnight so each day gets its own share.
    mutating func add(_ app: String, from start: Date, to end: Date, cal: Calendar = .current) {
        var t = start
        while t < end {
            let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: t))!
            let stop = min(end, midnight)
            days[Self.key(t, cal: cal), default: [:]][app, default: 0] += stop.timeIntervalSince(t)
            t = stop
        }
    }

    func total(_ d: Date, cal: Calendar = .current) -> Double { days[Self.key(d, cal: cal)]?.values.reduce(0, +) ?? 0 }

    func top(_ d: Date, cal: Calendar = .current) -> [(id: String, seconds: Double)] {
        (days[Self.key(d, cal: cal)] ?? [:]).map { (id: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    /// Drops days older than `keep` days.
    mutating func prune(keep: Int = 30, now: Date = .now, cal: Calendar = .current) {
        let oldest = Self.key(cal.date(byAdding: .day, value: -(keep - 1), to: now)!, cal: cal)
        days = days.filter { $0.key >= oldest }   // "yyyy-MM-dd" sorts like dates
        let used = Set(days.values.flatMap(\.keys))
        names = names.filter { used.contains($0.key) }
    }
}

/// The counting rules, kept apart from AppKit so they can be tested: time counts only while an app is in front
/// and nothing has paused it (screen off, locked, idle).
struct UsageClock {
    enum Pause: Hashable { case screenOff, locked, idle }
    static let idleLimit: TimeInterval = 120

    var log = UsageLog()
    private(set) var app: String?
    private(set) var paused: Set<Pause> = []
    private var since: Date?

    var counting: Bool { app != nil && paused.isEmpty }

    mutating func front(_ id: String?, name: String?, at t: Date) {
        change(at: t) { $0.app = id; if let id, let name { $0.log.names[id] = name } }
    }

    mutating func pause(_ p: Pause, at t: Date) { change(at: t) { $0.paused.insert(p) } }
    mutating func resume(_ p: Pause, at t: Date) { change(at: t) { $0.paused.remove(p) } }

    /// Called about once a minute with the seconds since the last keypress or mouse move.
    /// Idle time is cut back to the last input, so a long pause never counts.
    mutating func idleCheck(secondsIdle: TimeInterval, now: Date) {
        let lastInput = now.addingTimeInterval(-secondsIdle)
        if secondsIdle > Self.idleLimit { if !paused.contains(.idle) { pause(.idle, at: lastInput) } }
        else if paused.contains(.idle) { resume(.idle, at: lastInput) }
        else { flush(at: lastInput) }   // book only up to the last input, so a stretch that turns idle is never counted
    }

    /// Books the running stretch into the log (before saving) without stopping it.
    mutating func flush(at t: Date) { change(at: t) { _ in } }

    private mutating func change(at t: Date, _ body: (inout UsageClock) -> Void) {
        if let app, let since, t > since { log.add(app, from: since, to: t) }
        body(&self)
        if !counting { since = nil } else if since == nil || t > since! { since = t }
    }
}

/// Watches which app is in front. Event-driven; the only timer is a once-a-minute idle check.
@MainActor final class ScreenTime: ObservableObject {
    static let shared = ScreenTime()
    static let key = "trackAppUse"
    @Published private(set) var log = UsageLog()
    private var clock = UsageClock()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var file: URL { Vault.folder.appendingPathComponent("screen-time.json") }

    var isOn: Bool { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(UsageLog.self, from: data) { log = saved }
        clock.log = log
    }

    func startIfOn() { if isOn { start() } }

    func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key)
        on ? start() : stop()
    }

    /// Brings the shown numbers up to this moment (the screen is open, so you're here).
    func refresh() {
        guard !observers.isEmpty else { return }
        clock.flush(at: .now)
        save()
    }

    func deleteHistory() {
        clock.log = UsageLog()
        log = clock.log
        try? FileManager.default.removeItem(at: file)
    }

    func start() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter, dist = DistributedNotificationCenter.default()
        func on(_ c: NotificationCenter, _ name: Notification.Name, _ run: @escaping @MainActor (Notification) -> Void) {
            observers.append((c, c.addObserver(forName: name, object: nil, queue: .main) { n in MainActor.assumeIsolated { run(n) } }))
        }
        on(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] n in
            self?.front(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        for (name, p, paused) in [(NSWorkspace.screensDidSleepNotification, UsageClock.Pause.screenOff, true),
                                  (NSWorkspace.willSleepNotification, .screenOff, true),
                                  (NSWorkspace.screensDidWakeNotification, .screenOff, false),
                                  (NSWorkspace.didWakeNotification, .screenOff, false),
                                  (NSWorkspace.sessionDidResignActiveNotification, .locked, true),
                                  (NSWorkspace.sessionDidBecomeActiveNotification, .locked, false)] {
            on(ws, name) { [weak self] _ in self?.set(p, paused) }
        }
        on(dist, .init("com.apple.screenIsLocked")) { [weak self] _ in self?.set(.locked, true) }
        on(dist, .init("com.apple.screenIsUnlocked")) { [weak self] _ in self?.set(.locked, false) }
        on(.default, NSApplication.willTerminateNotification) { [weak self] _ in self?.clock.flush(at: .now); self?.save() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { ScreenTime.shared.tick() }
        }
        timer?.tolerance = 10
        front(NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        clock.flush(at: .now)
        clock.front(nil, name: nil, at: .now)
        save()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        timer?.invalidate()
        timer = nil
    }

    private func front(_ app: NSRunningApplication?) {
        // The lock screen and screen saver aren't you using the Mac.
        let id = app?.bundleIdentifier.flatMap { ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"].contains($0) ? nil : $0 }
        clock.front(id, name: app?.localizedName, at: .now)
    }

    private func set(_ p: UsageClock.Pause, _ paused: Bool) {
        paused ? clock.pause(p, at: .now) : clock.resume(p, at: .now)
        if paused { save() }
    }

    private func tick() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        clock.idleCheck(secondsIdle: idle, now: .now)
        save()
    }

    private func save() {
        clock.log.prune()
        guard clock.log != log else { return }
        log = clock.log
        if let data = try? JSONEncoder().encode(log) { try? data.write(to: file, options: .atomic) }
    }
}
