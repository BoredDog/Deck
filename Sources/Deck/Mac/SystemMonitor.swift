import AppKit
import Darwin
import IOKit
import IOKit.ps

/// One app's share of the Mac. Helpers (e.g. a browser's renderers) are counted under their app.
struct AppUsage: Identifiable {
    let id: String          // the app's bundle path
    let name: String
    let cpu: Double         // share of one core, 0…n
    let memory: Int64
    let app: NSRunningApplication?
}

struct BatteryInfo {
    var level = 0.0         // 0…1
    var charging = false
    var cycles = 0
    var health = 0.0        // max capacity vs. new, 0…1
}

/// Live Mac stats. `cpu` and `memory` are 0…1.
@MainActor final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    static let historyLength = 60

    @Published var cpu = 0.0
    @Published var memory = 0.0
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var netDown: Int64 = 0      // bytes per second
    @Published var netUp: Int64 = 0
    @Published var battery: BatteryInfo?   // nil on Macs without one
    @Published var memoryTight = false     // macOS itself says memory is under pressure
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var netHistory: [Double] = []   // download bytes/s
    @Published var topCPU: [AppUsage] = []
    @Published var topMemory: [AppUsage] = []

    /// Plain words: "relaxed", "busy", "running low on memory".
    var mood: String {
        if memoryTight || memory > 0.92 { return "running low on memory" }
        if cpu > 0.7 { return "busy" }
        return "relaxed"
    }
    var moodLine: String { "Your Mac is \(mood)" }

    private var watchers = 0
    private var timer: Timer?
    private var lastTicks: [UInt32]?
    private var lastNet: (down: UInt32, up: UInt32, at: Date)?
    private var lastProc: [Int32: UInt64] = [:]
    private var lastProcAt = Date()

    /// Counted, so Home and the Mac screen can both ask for updates; polling stops when nobody is watching.
    func startPolling() {
        watchers += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { SystemMonitor.shared.sample() } }
    }

    func stopPolling() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    func sample() {
        cpu = readCPU() ?? cpu
        readMemory()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        }
        readNetwork()
        battery = Self.readBattery()
        readApps()
        Self.push(cpu, to: &cpuHistory)
        Self.push(memory, to: &memoryHistory)
        Self.push(Double(netDown), to: &netHistory)
    }

    static func push(_ v: Double, to a: inout [Double]) {
        a.append(v)
        if a.count > historyLength { a.removeFirst(a.count - historyLength) }
    }

    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3] // user, system, idle, nice
        defer { lastTicks = t }
        guard let last = lastTicks else { return nil }
        let d = zip(t, last).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? (total - d[2]) / total : nil
    }

    private func readMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if r == KERN_SUCCESS {
            // Same sum as Activity Monitor's "Memory Used": app memory + wired + compressed.
            let pages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
            memory = min(1, Double(pages * UInt64(vm_kernel_page_size)) / Double(ProcessInfo.processInfo.physicalMemory))
        }
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { memoryTight = level >= 2 }
    }

    private func readNetwork() {
        var down: UInt32 = 0, up: UInt32 = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return }
        defer { freeifaddrs(list) }
        var p = list
        while let a = p?.pointee {
            let name = String(cString: a.ifa_name)
            // Physical links only, so VPN tunnels don't count traffic twice.
            if a.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en") || name.hasPrefix("pdp_ip"),
               let data = a.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                down &+= data.ifi_ibytes
                up &+= data.ifi_obytes
            }
            p = a.ifa_next
        }
        let now = Date()
        if let last = lastNet {
            let dt = max(0.1, now.timeIntervalSince(last.at))
            // Counters are 32-bit; wrapping subtraction survives one rollover between samples.
            netDown = Int64(Double(down &- last.down) / dt)
            netUp = Int64(Double(up &- last.up) / dt)
        }
        lastNet = (down, up, now)
    }

    static func readBattery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { return nil }
        var b = BatteryInfo()
        let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0, max = d[kIOPSMaxCapacityKey] as? Int ?? 100
        b.level = max > 0 ? Double(cur) / Double(max) : 0
        b.charging = d[kIOPSIsChargingKey] as? Bool ?? false

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { IOObjectRelease(service) }
        func raw(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        let data = raw("BatteryData") as? [String: Any] ?? [:]
        // Newer macOS moves the mAh values into BatteryData; MaxCapacity is a percent on Apple silicon, so it isn't used.
        func prop(_ key: String) -> Int? { raw(key) as? Int ?? data[key] as? Int }
        b.cycles = prop("CycleCount") ?? 0
        if let design = prop("DesignCapacity"), design > 0, let full = prop("NominalChargeCapacity") ?? prop("AppleRawMaxCapacity") {
            b.health = min(1, Double(full) / Double(design))
        }
        return b
    }

    private func readApps() {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard n > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(n) / MemoryLayout<Int32>.size + 16)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size)) / Int32(MemoryLayout<Int32>.size)

        var mainApp: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications { if let path = app.bundleURL?.path { mainApp[path] = app } }

        let now = Date()
        let wall = now.timeIntervalSince(lastProcAt) * 1e9
        var cpuBy: [String: Double] = [:], memBy: [String: Int64] = [:]
        var times: [Int32: UInt64] = [:]
        for pid in pids.prefix(Int(max(0, got))) where pid > 0 {
            // Each process belongs to the outermost .app bundle it lives in, so helpers count toward their app.
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, let key = Self.outerApp(String(cString: buf)) else { continue }
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let t = (info.ri_user_time + info.ri_system_time) * UInt64(tb.numer) / UInt64(tb.denom)
            times[pid] = t
            if let last = lastProc[pid], t >= last, wall > 0 { cpuBy[key, default: 0] += Double(t - last) / wall }
            memBy[key, default: 0] += Int64(info.ri_phys_footprint)
        }
        lastProc = times
        lastProcAt = now

        func usage(_ key: String) -> AppUsage {
            let app = mainApp[key]
            let name = app?.localizedName ?? (key as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return AppUsage(id: key, name: name, cpu: cpuBy[key] ?? 0, memory: memBy[key] ?? 0, app: app)
        }
        topCPU = cpuBy.keys.map(usage).filter { $0.cpu > 0.005 }.sorted { $0.cpu > $1.cpu }.prefix(5).map { $0 }
        topMemory = memBy.keys.map(usage).sorted { $0.memory > $1.memory }.prefix(5).map { $0 }
    }

    /// "/Applications/Foo.app/Contents/Frameworks/Helper.app" → "/Applications/Foo.app".
    nonisolated static func outerApp(_ path: String) -> String? {
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }
}
