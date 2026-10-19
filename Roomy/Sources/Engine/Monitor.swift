import Foundation
import Darwin
import AppKit

/// Live readings for Activity and the menu bar, measured the way Activity Monitor measures them (see Activity.swift).
/// System readings run every 2 s while anyone is looking; the per-process feed runs only while Activity is open.
/// Mole's status adds the health score.
@MainActor @Observable
final class Monitor {
    struct AppUsage: Identifiable, Hashable { var id: String { name }; var name: String; var path: String?; var cpu: Double; var mem: Int64; var processes: Int }

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

    init() {
        feed.onUpdate = { [weak self] rows, procs, threads in
            MainActor.assumeIsolated { self?.receive(rows, procs, threads) }
        }
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
        if let usage { apps = usage }
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
            let key = r.appPath.map { (Paths.name($0) as NSString).deletingPathExtension } ?? r.name
            var a = grouped[key] ?? AppUsage(name: key, path: r.appPath, cpu: 0, mem: 0, processes: 0)
            a.cpu += r.cpu / ncpu; a.mem += r.memory; a.processes += 1
            grouped[key] = a
        }
        apps = grouped.values.sorted { $0.mem > $1.mem }.prefix(30).map { var x = $0; x.cpu = (x.cpu * 10).rounded() / 10; return x }
    }

    /// `ps` grouped by app bundle, CPU as a share of the whole Mac. Used while the process feed is off.
    nonisolated static func appUsage() async -> [AppUsage] {
        let r = await Shell.run("/bin/ps", ["-Ao", "pid=,pcpu=,rss=,comm="], timeout: 10)
        let ncpu = Double(ProcessInfo.processInfo.activeProcessorCount)
        var apps: [String: AppUsage] = [:]
        for line in r.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let cpu = Double(parts[1]), let rss = Int64(parts[2]) else { continue }
            let comm = String(parts[3])
            let m = comm.firstMatch(#"^(.*?/([^/]+)\.app)/"#)
            let key = m?[2] ?? Paths.name(comm)
            var a = apps[key] ?? AppUsage(name: key, path: m?[1], cpu: 0, mem: 0, processes: 0)
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
        guard p.mine, p.pid > 1 else { return false }
        if let app = NSRunningApplication(processIdentifier: p.pid) { return force ? app.forceTerminate() : app.terminate() }
        return kill(p.pid, force ? SIGKILL : SIGTERM) == 0
    }
}
