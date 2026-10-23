import Foundation
import Darwin
import IOKit
import IOKit.ps
import AppKit

// MARK: - The whole Mac

/// One reading of the whole Mac, measured the way Activity Monitor measures it: processor ticks per core, the kernel's
/// own memory counters and pressure level, disk and network byte counters, the GPU's utilisation and the SMC's power.
struct SystemSample: Identifiable, Sendable {
    var id: Date { t }
    var t = Date()
    var user = 0.0, system = 0.0, idle = 100.0
    var perCore: [Double] = []
    var load = (0.0, 0.0, 0.0)
    var memory = MemoryReading()
    var diskRead = 0.0, diskWrite = 0.0, diskReadOps = 0.0, diskWriteOps = 0.0
    var netIn = 0.0, netOut = 0.0, packetsIn = 0.0, packetsOut = 0.0
    var gpu: Double?
    var power: Double?
    var cpu: Double { user + system }
}

struct MemoryReading: Sendable {
    var total: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var app: Int64 = 0, wired: Int64 = 0, compressed: Int64 = 0, cached: Int64 = 0, free: Int64 = 0
    var swapUsed: Int64 = 0, swapTotal: Int64 = 0
    /// The kernel's pressure level: 1 normal, 2 warning, 4 critical. Activity Monitor colours its graph by this.
    var pressureLevel = 1
    /// The share of memory the kernel considers available, which Activity Monitor's pressure graph plots inverted.
    var freePercent = 100
    /// Activity Monitor's "Memory Used": app memory, wired and compressed.
    var used: Int64 { app + wired + compressed }
    var pressurePercent: Double { Double(100 - freePercent) }
}

/// Takes system readings and turns counters into rates between calls.
final class SystemSampler: @unchecked Sendable {
    private var ticks: [[UInt32]] = []
    private var disk: (r: Int64, w: Int64, ro: Int64, wo: Int64)?
    private var net: (i: UInt64, o: UInt64, pi: UInt64, po: UInt64)?
    private var last: Date?
    private let smc = SMC()

    func sample() -> SystemSample {
        var s = SystemSample()
        let now = Date()
        let dt = last.map { now.timeIntervalSince($0) } ?? 0
        last = now

        // Processor: ticks per core since the last reading.
        let cores = Self.cpuTicks()
        if ticks.count == cores.count, !cores.isEmpty {
            var u = 0.0, sy = 0.0, id = 0.0
            s.perCore = zip(cores, ticks).map { c, p in
                let du = Double(c[0] &- p[0]) + Double(c[3] &- p[3]), ds = Double(c[1] &- p[1]), di = Double(c[2] &- p[2])
                u += du; sy += ds; id += di
                let tot = du + ds + di
                return tot > 0 ? (du + ds) / tot * 100 : 0
            }
            let tot = u + sy + id
            if tot > 0 { s.user = u / tot * 100; s.system = sy / tot * 100; s.idle = id / tot * 100 }
        }
        ticks = cores
        var l = [0.0, 0.0, 0.0]
        getloadavg(&l, 3)
        s.load = (l[0], l[1], l[2])

        s.memory = Self.memory()

        let d = Self.diskCounters()
        if let p = disk, dt > 0 {
            s.diskRead = Double(max(0, d.r - p.r)) / dt; s.diskWrite = Double(max(0, d.w - p.w)) / dt
            s.diskReadOps = Double(max(0, d.ro - p.ro)) / dt; s.diskWriteOps = Double(max(0, d.wo - p.wo)) / dt
        }
        disk = d

        let n = Self.netCounters()
        if let p = net, dt > 0 {
            s.netIn = Double(n.i &- p.i) / dt; s.netOut = Double(n.o &- p.o) / dt
            s.packetsIn = Double(n.pi &- p.pi) / dt; s.packetsOut = Double(n.po &- p.po) / dt
        }
        net = n

        s.gpu = Self.gpuUtilisation()
        s.power = smc.number("PSTR")
        return s
    }

    static func cpuTicks() -> [[UInt32]] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { i in
            let b = i * Int(CPU_STATE_MAX)
            // user, system, idle, nice
            return [UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]), UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                    UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]), UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])]
        }
    }

    static func memory() -> MemoryReading {
        var m = MemoryReading()
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let page = Int64(vm_kernel_page_size)
            m.app = (Int64(info.internal_page_count) - Int64(info.purgeable_count)) * page
            m.wired = Int64(info.wire_count) * page
            m.compressed = Int64(info.compressor_page_count) * page
            m.cached = (Int64(info.external_page_count) + Int64(info.purgeable_count)) * page
            m.free = max(0, Int64(info.free_count) - Int64(info.speculative_count)) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = Int64(swap.xsu_used); m.swapTotal = Int64(swap.xsu_total) }
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { m.pressureLevel = Int(level) }
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 { m.freePercent = Int(level) }
        return m
    }

    static func diskCounters() -> (r: Int64, w: Int64, ro: Int64, wo: Int64) {
        var r: Int64 = 0, w: Int64 = 0, ro: Int64 = 0, wo: Int64 = 0
        forEachService("IOBlockStorageDriver") { s in
            guard let st = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { return }
            r += (st["Bytes (Read)"] as? NSNumber)?.int64Value ?? 0
            w += (st["Bytes (Write)"] as? NSNumber)?.int64Value ?? 0
            ro += (st["Operations (Read)"] as? NSNumber)?.int64Value ?? 0
            wo += (st["Operations (Write)"] as? NSNumber)?.int64Value ?? 0
        }
        return (r, w, ro, wo)
    }

    /// 64-bit interface counters for every interface except loopback.
    static func netCounters() -> (i: UInt64, o: UInt64, pi: UInt64, po: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0, 0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0, 0, 0) }
        var i: UInt64 = 0, o: UInt64 = 0, pi: UInt64 = 0, po: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let h = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if Int32(h.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if h2.ifm_flags & IFF_LOOPBACK == 0 {
                        i &+= h2.ifm_data.ifi_ibytes; o &+= h2.ifm_data.ifi_obytes
                        pi &+= h2.ifm_data.ifi_ipackets; po &+= h2.ifm_data.ifi_opackets
                    }
                }
                guard h.ifm_msglen > 0 else { break }
                off += Int(h.ifm_msglen)
            }
        }
        return (i, o, pi, po)
    }

    static func gpuUtilisation() -> Double? {
        var u: Double?
        forEachService("IOAccelerator") { s in
            guard u == nil, let p = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let v = p["Device Utilization %"] as? NSNumber else { return }
            u = v.doubleValue
        }
        return u
    }

    static func forEachService(_ cls: String, _ body: (io_object_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var s = IOIteratorNext(it)
        while s != 0 { body(s); IOObjectRelease(s); s = IOIteratorNext(it) }
    }
}

// MARK: - Temperatures

/// The SMC's temperature sensors, grouped into the parts people know. Sensor names differ between chips, so groups
/// come from the key's prefix, which is stable across Apple silicon.
struct ThermalReading: Sendable {
    struct Group: Identifiable, Hashable { var id: String; var name: String; var average: Double; var hottest: Double; var count: Int; var explain: String }
    var groups: [Group] = []
    var hottest: Double = 0
    var state: ProcessInfo.ThermalState = .nominal
    var cpu: Double? { groups.first { $0.id == "cpu" }?.average }
}

final class ThermalSampler: @unchecked Sendable {
    private let smc = SMC()
    private lazy var keys: [String] = smc.allKeys().filter { k in
        ["Tp", "Te", "Tg", "Tm", "TM", "TH", "TB"].contains { k.hasPrefix($0) } && smc.read(k)?.type == "flt "
    }
    static let groups: [(id: String, name: String, prefixes: [String], explain: String)] = [
        ("cpu", "Processor", ["Tp", "Te"], "The CPU's cores. Apple silicon is designed to run hot under load; it slows itself down only near 105 °C."),
        ("gpu", "Graphics", ["Tg"], "The GPU cores. Games, video and AI models heat them most."),
        ("memory", "Memory", ["Tm", "TM"], "Sensors beside the memory chips."),
        ("ssd", "Storage", ["TH"], "The internal SSD. Long copies and swap warm it up; above about 70 °C it may slow down."),
        ("battery", "Battery", ["TB"], "The battery cells. Keeping them below about 35 °C helps them last longer."),
    ]

    func sample() -> ThermalReading {
        var r = ThermalReading(state: ProcessInfo.processInfo.thermalState)
        let values = keys.compactMap { k in smc.number(k).flatMap { (5...130).contains($0) ? (k, $0) : nil } }
        for g in Self.groups {
            let v = values.filter { k, _ in g.prefixes.contains { k.hasPrefix($0) } }.map(\.1)
            guard !v.isEmpty else { continue }
            r.groups.append(.init(id: g.id, name: g.name, average: v.reduce(0, +) / Double(v.count), hottest: v.max() ?? 0, count: v.count, explain: g.explain))
        }
        r.hottest = values.map(\.1).max() ?? 0
        return r
    }
}

// MARK: - Processes

/// One process, with Activity Monitor's columns.
struct ProcessRow: Identifiable, Hashable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var user: String
    /// Share of one core, so a busy process can pass 100% on a multi-core Mac (as in Activity Monitor).
    var cpu = 0.0
    var cpuTime = ""
    /// Physical footprint: the memory macOS charges to it, Activity Monitor's "Memory" column.
    var memory: Int64 = 0
    /// How much of that footprint macOS has compressed or moved to swap (top's CMPRS): memory it isn't actively using.
    var compressed: Int64 = 0
    /// macOS's energy impact score, the same number as Activity Monitor's Energy tab.
    var energy = 0.0
    var threads = 0
    var ports = 0
    var state = ""
    var netIn = 0.0, netOut = 0.0
    var diskRead: Double?, diskWrite: Double?
    var path: String?
    var appPath: String?
    var mine: Bool { user == NSUserName() }
}

/// Streams `top` (which sees every process, as Activity Monitor does) and `nettop` while someone is looking, and adds
/// per-process disk use for your own processes. Both tools ship with macOS.
final class ProcessFeed: @unchecked Sendable {
    private var top: Process?
    private var generation = 0
    private var netTotals: [Int32: (UInt64, UInt64)] = [:]
    private var netAt: Date?
    private var topBuffer = ""
    private let queue = DispatchQueue(label: "app.roomy.processfeed")
    private var netRates: [Int32: (Double, Double)] = [:]
    private var paths: [Int32: String] = [:]
    private var pathsAt = Date.distantPast
    private var disk: [Int32: (UInt64, UInt64, Date)] = [:]
    private var skipFirst = true
    var onUpdate: (([ProcessRow], Int, Int) -> Void)?
    /// Seconds between process samples. Activity Monitor's default is 5; 3 keeps the list lively for a fraction of the cost.
    static let interval = 3

    var running: Bool { top?.isRunning == true }

    func start() {
        guard top == nil else { return }
        skipFirst = true
        // Through a pseudo-terminal, so top hands over each sample as soon as it's written instead of in 4 KB chunks.
        top = launch("/usr/bin/script", ["-q", "/dev/null", "/usr/bin/top", "-l", "0", "-s", String(Self.interval), "-o", "cpu", "-n", "300",
                                         "-stats", "pid,command,cpu,mem,cmprs,power,threads,ports,user,state,time"]) { [weak self] s in self?.topChunk(s) }
        pollNetwork()
    }

    /// nettop streaming costs a whole core, so it's sampled once at a time (each sample takes a few seconds of waiting
    /// and almost no CPU) and the rates come from the difference between samples.
    private func pollNetwork() {
        let generation = self.generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            p.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation, self.top != nil else { return }
                self.netSample(String(decoding: data, as: UTF8.self))
                self.pollNetwork()
            }
        }
    }

    func stop() {
        top?.terminate()
        top = nil
        generation += 1
        queue.async { self.topBuffer = ""; self.netTotals = [:]; self.netAt = nil }
    }

    private func launch(_ exe: String, _ args: [String], _ handler: @escaping (String) -> Void) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice   // script(1) quits at once without a readable stdin
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            // End of file: the tool exited. Without removing the handler it would fire again and again, spinning a core.
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            self?.queue.async { handler(s) }
        }
        do { try p.run() } catch { return nil }
        return p
    }

    // nettop: one row per process, "name.pid,bytes_in,bytes_out,", counted since its connections opened.
    private func netSample(_ text: String) {
        let now = Date()
        var totals: [Int32: (UInt64, UInt64)] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let dot = f[0].lastIndex(of: "."), let pid = Int32(f[0][f[0].index(after: dot)...]),
                  let i = UInt64(f[1]), let o = UInt64(f[2]) else { continue }
            totals[pid] = (i, o)
        }
        if let then = netAt {
            let dt = max(0.5, now.timeIntervalSince(then))
            var rates: [Int32: (Double, Double)] = [:]
            for (pid, t) in totals {
                guard let p = netTotals[pid] else { continue }
                rates[pid] = (Double(t.0 > p.0 ? t.0 - p.0 : 0) / dt, Double(t.1 > p.1 ? t.1 - p.1 : 0) / dt)
            }
            netRates = rates
        }
        netTotals = totals
        netAt = now
    }

    // top: every sample starts with "Processes:"; the block before it is complete.
    private func topChunk(_ s: String) {
        topBuffer += s.replacingOccurrences(of: "\r", with: "")
        while let r = topBuffer.range(of: "Processes:", options: [], range: topBuffer.index(after: topBuffer.startIndex)..<topBuffer.endIndex) {
            let block = String(topBuffer[..<r.lowerBound])
            topBuffer = String(topBuffer[r.lowerBound...])
            parse(block)
        }
    }

    private func parse(_ block: String) {
        // The first sample has no CPU figures yet (they show as 0), but memory and the rest are real: show it now.
        skipFirst = false
        var procs = 0, threads = 0
        if let first = block.split(separator: "\n").first,
           let m = String(first).firstMatch(#"Processes:\s*(\d+) total.*?(\d+) threads"#) {
            procs = Int(m[1] ?? "") ?? 0; threads = Int(m[2] ?? "") ?? 0
        }
        refreshPaths()
        var rows: [ProcessRow] = []
        var inTable = false
        let me = NSUserName()
        for raw in block.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("PID") { inTable = true; continue }
            guard inTable else { continue }
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard t.count >= 11, let pid = Int32(t[0]) else { continue }
            let tail = Array(t.suffix(9))
            let command = t[1..<(t.count - 9)].joined(separator: " ")
            var row = ProcessRow(pid: pid, name: command, user: tail[6] == "(null)" ? "system" : tail[6])
            row.cpu = Double(tail[0]) ?? 0
            row.memory = Self.bytes(tail[1])
            row.compressed = Self.bytes(tail[2])
            row.energy = Double(tail[3]) ?? 0
            row.threads = Int(tail[4].split(separator: "/").first ?? "") ?? 0
            row.ports = Int(tail[5].trimmingCharacters(in: CharacterSet(charactersIn: "+-*"))) ?? 0
            row.state = tail[7]
            row.cpuTime = tail[8]
            if let n = netRates[pid] { row.netIn = n.0; row.netOut = n.1 }
            if let p = paths[pid] {
                row.path = p
                if let r = p.range(of: ".app/") { row.appPath = String(p[..<r.lowerBound]) + ".app" }
                if command.count >= 15 { row.name = Paths.name(p) }   // top cuts names at 16 characters
            }
            if row.user == me { (row.diskRead, row.diskWrite) = diskRates(pid) }
            rows.append(row)
        }
        let live = Set(rows.map(\.pid))
        disk = disk.filter { live.contains($0.key) }
        netRates = netRates.filter { live.contains($0.key) }
        let cb = onUpdate
        DispatchQueue.main.async { cb?(rows, procs, threads) }
    }

    /// Full executable paths for every process, from `ps` (it can see processes of every user). Refreshed every 10 s.
    private func refreshPaths() {
        guard Date().timeIntervalSince(pathsAt) > 10 else { return }
        pathsAt = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [Int32: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, let pid = Int32(parts[0]) { out[pid] = String(parts[1]) }
        }
        paths = out
    }

    private func diskRates(_ pid: Int32) -> (Double?, Double?) {
        var ri = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } } == 0
        guard ok else { return (nil, nil) }
        let now = Date()
        defer { disk[pid] = (ri.ri_diskio_bytesread, ri.ri_diskio_byteswritten, now) }
        guard let p = disk[pid] else { return (0, 0) }
        let dt = now.timeIntervalSince(p.2)
        guard dt > 0 else { return (0, 0) }
        return (Double(ri.ri_diskio_bytesread &- p.0) / dt, Double(ri.ri_diskio_byteswritten &- p.1) / dt)
    }

    static func bytes(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "+-*"))
        guard let unit = t.last, let n = Double(t.dropLast()) else { return Int64(t) ?? 0 }
        switch unit {
        case "K": return Int64(n * 1024)
        case "M": return Int64(n * 1024 * 1024)
        case "G": return Int64(n * 1024 * 1024 * 1024)
        case "B": return Int64(n)
        default: return Int64(Double(t) ?? 0)
        }
    }
}

// MARK: - Battery

/// What the battery has done since it was last full, read from macOS's power log (`pmset -g log`), which records the
/// charge every time the Mac switches between battery and power. It works for charges from before Roomy was open.
struct SinceFullCharge: Sendable, Equatable {
    var at: Date
    /// Percentage points used on battery since then, across any partial charges in between.
    var used: Int
    /// Time spent on battery since then.
    var onBattery: TimeInterval

    static func read(now percent: Int, onBattery nowOnBattery: Bool) async -> SinceFullCharge? {
        let r = await Shell.run("/bin/sh", ["-c", "/usr/bin/pmset -g log | /usr/bin/grep 'Using '"], timeout: 30)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var events: [(Date, Bool, Int)] = []
        for line in r.output.split(separator: "\n") {
            let s = String(line)
            guard s.count > 25, let d = f.date(from: String(s.prefix(25))),
                  let m = s.firstMatch(#"Using (AC|Batt) ?\(Charge: ?(\d+)"#), let kind = m[1], let c = m[2].flatMap({ Int($0) }) else { continue }
            if let last = events.last, last.1 == (kind == "Batt"), last.2 == c { continue }
            events.append((d, kind == "Batt", c))
        }
        guard let i = events.lastIndex(where: { $0.2 >= 100 }) else { return nil }
        let since = Array(events[i...])
        var used = 0, battery: TimeInterval = 0
        for (a, b) in zip(since, since.dropFirst()) {
            if a.1 { used += max(0, a.2 - b.2); battery += b.0.timeIntervalSince(a.0) }
        }
        if let last = since.last, nowOnBattery, last.1 {
            used += max(0, last.2 - percent)
            battery += Date().timeIntervalSince(last.0)
        }
        return SinceFullCharge(at: since[0].0, used: used, onBattery: battery)
    }
}

struct BatteryReading: Sendable {
    var present = false
    var percent = 0
    var charging = false
    var onAC = true
    var minutesLeft: Int?
    var cycles: Int?
    var health: String?
    /// How much charge the battery holds now against when it was new: what System Settings calls Maximum Capacity.
    var healthPercent: Int?

    static func read() -> BatteryReading {
        var b = BatteryReading()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return b }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            b.present = true
            b.percent = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            b.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            b.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let left = d[b.charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
            b.minutesLeft = left > 0 ? left : nil
            b.health = d["BatteryHealth"] as? String
        }
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if s != 0 {
            b.cycles = (IORegistryEntryCreateCFProperty(s, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            // NominalChargeCapacity ÷ DesignCapacity, the same figure System Settings shows.
            if let data = IORegistryEntryCreateCFProperty(s, "BatteryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let nominal = (data["NominalChargeCapacity"] as? NSNumber)?.doubleValue, let design = (data["DesignCapacity"] as? NSNumber)?.doubleValue, design > 0 {
                b.healthPercent = min(100, Int((nominal / design * 100).rounded()))
            }
            IOObjectRelease(s)
        }
        return b
    }
}
