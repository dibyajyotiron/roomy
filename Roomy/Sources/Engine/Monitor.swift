import Foundation
import Darwin
import AppKit

/// Live readings for Activity and the menu bar, measured the way Activity Monitor measures them (see Activity.swift).
/// System readings run every 2 s while anyone is looking; the per-process feed runs only while Activity is open.
/// Mole's status adds the health score.
@MainActor @Observable
final class Monitor {
    struct AppUsage: Identifiable, Hashable {
        var id: String { name }; var name: String; var path: String?; var cpu: Double; var mem: Int64; var processes: Int
        /// How much of `mem` macOS has compressed or swapped out (only while the process feed runs).
        var compressed: Int64 = 0
    }

    var sample = SystemSample()
    var history: [SystemSample] = []
    var thermal = ThermalReading()
    var tempHistory: [(Date, Double)] = []
    var battery = BatteryReading()
    var processes: [ProcessRow] = []
    var processCount = 0
    var threadCount = 0
    var apps: [AppUsage] = []
    var status: MoleStatus?
    var lastUpdate: Date?
    let fans = Fans()

    private let system = SystemSampler()
    private let thermals = ThermalSampler()
    private let feed = ProcessFeed()
    private var watchers = 0
    private var processWatchers = 0
    private var task: Task<Void, Never>?
    private var statusAt = Date.distantPast
    private var appNames: [Int32: (String?, String?)] = [:]
    private var appsAt = Date.distantPast
    static let historyLength = 90   // three minutes at 2 s

    var cpu: Double { sample.cpu }
    var memTotal: Int64 { sample.memory.total }
    var memUsed: Int64 { sample.memory.used }
    var memAvailable: Int64 { max(0, memTotal - memUsed) }
    var wired: Int64 { sample.memory.wired }
    var compressed: Int64 { sample.memory.compressed }
    /// macOS's own pressure level, as Activity Monitor colours it.
    var pressure: (label: String, level: Int) {
        guard lastUpdate != nil else { return ("Measuring", 0) }
        switch sample.memory.pressureLevel {
        case 4: return ("Pressure high", 2)
        case 2: return ("Pressure rising", 1)
        default: return ("Pressure normal", 0)
        }
    }

    /// When Roomy started watching, and when you last switched to each app (by bundle path) since then.
    let watchingSince = Date()
    @ObservationIgnored private(set) var lastActive: [String: Date] = [:]
    /// Each app's CPU (share of one core) averaged over roughly the last five minutes, by app name.
    @ObservationIgnored private(set) var recentCPU: [String: Double] = [:]
    @ObservationIgnored private var recentAt: Date?

    init() {
        feed.onUpdate = { [weak self] rows, procs, threads in
            MainActor.assumeIsolated { self?.receive(rows, procs, threads) }
        }
        if let p = NSWorkspace.shared.frontmostApplication?.bundleURL?.path { lastActive[p] = Date() }
        NotificationCenter.default.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared, queue: .main) { [weak self] n in
            let path = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path
            MainActor.assumeIsolated { if let path { self?.lastActive[path] = Date() } }
        }
    }

    /// What's filling memory and what would help (see MemoryAdvice), from the latest readings.
    var memoryAdvice: MemoryAdvice {
        let ws = NSWorkspace.shared
        let running = ws.runningApplications.compactMap { a in
            a.bundleURL.map { MemoryAdvice.Running(name: a.localizedName ?? "", path: $0.path, regular: a.activationPolicy == .regular) }
        }
        return MemoryAdvice.make(memory: sample.memory, apps: apps, rows: processes, running: running,
                                 frontmost: ws.frontmostApplication?.bundleURL?.path, lastActive: lastActive,
                                 watchingSince: watchingSince, recentCPU: recentCPU)
    }

    /// Folds the latest per-app CPU into a five-minute average, weighted by the time since the last reading.
    private func noteCPU(_ apps: [AppUsage]) {
        let now = Date(), ncpu = Double(ProcessInfo.processInfo.activeProcessorCount)
        let dt = recentAt.map { now.timeIntervalSince($0) } ?? 0
        recentAt = now
        let k = dt > 0 ? min(1, dt / 300) : 1
        var next: [String: Double] = [:]
        for a in apps { let c = a.cpu * ncpu; next[a.name] = recentCPU[a.name].map { $0 + (c - $0) * k } ?? c }
        recentCPU = next
    }

    func watch() {
        watchers += 1
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { task?.cancel(); task = nil }
    }

    /// The per-process feed (top and nettop) costs a little CPU, so it runs only while Activity is on screen.
    func watchProcesses() { processWatchers += 1; feed.start(); watch() }
    func unwatchProcesses() {
        processWatchers = max(0, processWatchers - 1)
        unwatch()
        // Kept alive a little, so going back to Activity shows live rows at once.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if let self, self.processWatchers == 0 { self.feed.stop() }
        }
    }

    func tick() async {
        // IOKit and SMC reads happen off the main thread (the first thermal read lists ~2,000 keys), one tick at a time.
        let (system, thermals) = (self.system, self.thermals)
        let (s, th, bat) = await Task.detached(priority: .utility) { (system.sample(), thermals.sample(), BatteryReading.read()) }.value
        let usage = feed.running ? nil : await Monitor.appUsage()
        let wantStatus = Date().timeIntervalSince(statusAt) > 15
        if wantStatus { statusAt = Date() }   // Mole's health score: every 15 s is plenty
        let status = wantStatus ? await Mole.status() : nil
        // Everything changes in one go, so views redraw once per tick, not once per reading.
        var h = history
        h.append(s)
        if h.count > Self.historyLength { h.removeFirst(h.count - Self.historyLength) }
        var temps = tempHistory
        if let c = th.cpu {
            temps.append((s.t, c))
            if temps.count > Self.historyLength { temps.removeFirst(temps.count - Self.historyLength) }
        }
        sample = s; history = h; thermal = th; tempHistory = temps; battery = bat
        if let usage { apps = usage; noteCPU(usage) }
        if let status { self.status = status }
        fans.refresh()
        lastUpdate = Date()
    }

    private func receive(_ rows: [ProcessRow], _ procs: Int, _ threads: Int) {
        var rows = rows
        // App names and bundles come from AppKit, on the main thread.
        if Date().timeIntervalSince(appsAt) > 10 {
            appsAt = Date()
            appNames = [:]
            for a in NSWorkspace.shared.runningApplications { appNames[a.processIdentifier] = (a.localizedName, a.bundleURL?.path) }
        }
        for i in rows.indices {
            if let a = appNames[rows[i].pid] {
                if let n = a.0 { rows[i].name = n }
                if let u = a.1 { rows[i].appPath = u }
            }
        }
        if Demo.on {
            rows = rows.filter { Demo.processes.contains($0.name) }
            for i in rows.indices where rows[i].mine { rows[i].user = "you" }
        }
        processes = rows
        processCount = procs; threadCount = threads
        var grouped: [String: AppUsage] = [:]
        let ncpu = Double(ProcessInfo.processInfo.activeProcessorCount)
        for r in rows {
            // Grouped exactly like Activity's Apps view: the outermost .app, under the name the app gives itself.
            let outer = ProcessRow.outerApp(r)
            let key = outer.map { ProcessRow.bundleInfo($0).name } ?? r.name
            var a = grouped[key] ?? AppUsage(name: key, path: outer ?? r.appPath, cpu: 0, mem: 0, processes: 0)
            a.cpu += r.cpu / ncpu; a.mem += r.memory; a.compressed += r.compressed; a.processes += 1
            grouped[key] = a
        }
        noteCPU(Array(grouped.values))
        apps = grouped.values.sorted { $0.mem > $1.mem }.prefix(30).map { var x = $0; x.cpu = (x.cpu * 10).rounded() / 10; return x }
    }

    /// `ps` grouped by app bundle, CPU as a share of the whole Mac. Used while the process feed is off.
    /// Memory is each process's footprint, the number Activity Monitor's Memory column shows, not its resident size:
    /// resident size leaves out compressed memory and memory mapped for a virtual machine (OrbStack's Linux VM read
    /// 1.8 GB resident against a 7 GB footprint).
    nonisolated static func appUsage() async -> [AppUsage] {
        let r = await Shell.run("/bin/ps", ["-Ao", "pid=,pcpu=,rss=,comm="], timeout: 10)
        let others = await SystemFootprints.shared.current()
        let ncpu = Double(ProcessInfo.processInfo.activeProcessorCount)
        var apps: [String: AppUsage] = [:]
        for line in r.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rssKB = Int64(parts[2]) else { continue }
            let rss = (footprint(pid) ?? others[pid] ?? rssKB * 1024) / 1024
            let comm = String(parts[3])
            let outer = ProcessRow.outerApp(ProcessRow(pid: pid, name: "", user: "", path: comm))
            let key = outer.map { ProcessRow.bundleInfo($0).name } ?? Paths.name(comm)
            var a = apps[key] ?? AppUsage(name: key, path: outer, cpu: 0, mem: 0, processes: 0)
            a.cpu += cpu / ncpu; a.mem += rss * 1024; a.processes += 1
            apps[key] = a
        }
        return apps.values.sorted { $0.mem > $1.mem }.prefix(30).map { var x = $0; x.cpu = (x.cpu * 10).rounded() / 10; return x }
    }

    /// Releases inactive memory with macOS's `purge`, which needs an administrator password.
    /// Returns the measured change in available memory, never an estimate.
    func freeMemory(simulate: Bool) async -> Int64 {
        let before = memAvailable
        if simulate {
            try? await Task.sleep(for: .seconds(1.2))
            return 0
        }
        _ = await Shell.run("/usr/bin/osascript", ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"], timeout: 120)
        await tick()
        return max(0, memAvailable - before)
    }

    /// Quits a process: politely for apps (they can save), with SIGTERM for others. `force` uses SIGKILL.
    /// Only your own processes; macOS's and other users' processes can't be quit from here.
    func quit(_ p: ProcessRow, force: Bool) -> Bool {
        // An app's row (negative id) quits the app itself, which takes its helpers with it.
        if p.isApp, p.mine, let app = NSRunningApplication(processIdentifier: p.shownPID) { return force ? app.forceTerminate() : app.terminate() }
        guard p.mine, p.pid > 1 else { return false }
        if let app = NSRunningApplication(processIdentifier: p.pid) { return force ? app.forceTerminate() : app.terminate() }
        return kill(p.pid, force ? SIGKILL : SIGTERM) == 0
    }
}

extension Monitor {
    /// A process's physical footprint (Activity Monitor's Memory column), for processes Roomy may inspect: yours.
    nonisolated static func footprint(_ pid: Int32) -> Int64? {
        var ri = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } } == 0
        return ok ? Int64(clamping: ri.ri_phys_footprint) : nil
    }
}

/// Footprints of processes Roomy isn't allowed to inspect (WindowServer and other system ones), read from `top`, which
/// may. A `top` snapshot costs most of a second of CPU, so it's taken at most every 30 seconds.
actor SystemFootprints {
    static let shared = SystemFootprints()
    private var cache: [Int32: Int64] = [:]
    private var at = Date.distantPast
    func current() async -> [Int32: Int64] {
        guard Date().timeIntervalSince(at) > 30 else { return cache }
        at = Date()
        let r = await Shell.run("/usr/bin/top", ["-l", "1", "-o", "mem", "-n", "80", "-stats", "pid,mem"], timeout: 15)
        var out: [Int32: Int64] = [:]
        var table = false
        for line in r.output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.first == "PID" { table = true; continue }
            guard table, cols.count >= 2, let pid = Int32(cols[0]) else { continue }
            out[pid] = ProcessFeed.bytes(String(cols[1]))
        }
        if !out.isEmpty { cache = out }
        return cache
    }
}
