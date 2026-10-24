import Foundation

/// What's filling memory and what would help, from readings only: no list of apps. Apps are grouped like the menu bar
/// (every process of an app together). Every figure is a measurement; "frees about" is the app's footprint, which is
/// what macOS returns when it quits (its compressed and swapped parts included).
struct MemoryAdvice: Equatable {
    struct IdleApp: Equatable, Identifiable {
        var id: String { name }
        var name: String
        var path: String
        var footprint: Int64
        var compressed: Int64
        /// How long it hasn't been in front. When it hasn't been since Roomy started watching, that's only a lower bound.
        var idleFor: TimeInterval
        var atLeast = false
        /// "Idle 2 h", or "Idle 45 min+" when Roomy can't know it was in front before it started watching.
        var idleLabel: String { "Idle \(MemoryAdvice.span(idleFor))" + (atLeast ? "+" : "") }
    }
    struct PushedOut: Equatable, Identifiable {
        var id: String { name }
        var name: String
        var path: String?
        var footprint: Int64
        var compressed: Int64
    }

    /// One or two sentences: why memory is where it is.
    var summary: String
    /// Full or tight: swap in use, or a fifth of memory compressed, or macOS reporting pressure.
    var tight: Bool
    /// macOS's own pressure level says memory is short (yellow or red in Activity Monitor), not just full.
    var pressured = false
    /// What open apps hold together (their footprints), against the Mac's memory.
    var wanted: Int64 = 0
    /// Open, not in front, not used for a while and nearly idle: quitting them is the quickest relief.
    var idle: [IdleApp]
    var idleTotal: Int64 { idle.reduce(0) { $0 + $1.footprint } }
    /// Apps whose memory macOS has mostly squeezed or moved to the SSD: they hold it without using it.
    var pushedOut: [PushedOut]
    /// Plain suggestions for the biggest kinds of use (web pages, very large apps).
    var tips: [String]

    struct Running: Equatable { var name: String; var path: String; var regular: Bool }

    static let idleAfter: TimeInterval = 20 * 60

    static func make(memory m: MemoryReading, apps: [Monitor.AppUsage], rows: [ProcessRow], running: [Running], frontmost: String?,
                     lastActive: [String: Date], watchingSince: Date, recentCPU: [String: Double], now: Date = Date(),
                     ownPath: String = Bundle.main.bundlePath) -> MemoryAdvice {
        let gb = 1_000_000_000.0
        let tight = m.pressureLevel >= 2 || m.swapUsed > 1_000_000_000 || m.compressed > m.total / 5
        let wanted = apps.reduce(Int64(0)) { $0 + $1.mem }
        var summary: String
        if tight {
            var parts: [String] = []
            if m.compressed > 0 { parts.append("\(Fmt.bytes(m.compressed)) of your memory is holding compressed data") }
            if m.swapUsed > 0 { parts.append("\(Fmt.bytes(m.swapUsed)) has been moved to your SSD") }
            summary = "Memory is tight: " + (parts.isEmpty ? "macOS is under pressure" : parts.joined(separator: " and ")) + ". "
            summary += wanted > m.total ? "Open apps want about \(Fmt.bytes(wanted)) on a \(Fmt.bytes(m.total)) Mac, so macOS squeezes what they aren't using."
                                        : "Quitting apps you aren't using gives macOS room again."
        } else {
            summary = "Memory is fine: macOS has room, and what's compressed or cached is ordinary."
        }

        // Idle apps: proper apps (with a window in the Dock), not in front, not switched to for 20 minutes while Roomy
        // watched, and nearly no CPU over the last five minutes. Unknown is never called idle.
        let watched = now.timeIntervalSince(watchingSince)
        var idle: [IdleApp] = []
        for a in apps {
            guard let path = a.path, path != ownPath, a.mem >= 150_000_000,
                  let r = running.first(where: { $0.path == path }), r.regular, path != frontmost,
                  !path.hasPrefix("/System/"), (recentCPU[a.name] ?? 100) < 2 else { continue }
            let known = lastActive[path].map { now.timeIntervalSince($0) }
            let idleFor = known ?? watched
            guard idleFor >= idleAfter else { continue }
            idle.append(IdleApp(name: a.name, path: path, footprint: a.mem, compressed: a.compressed, idleFor: idleFor, atLeast: known == nil))
        }
        idle.sort { $0.footprint > $1.footprint }

        let pushedOut = apps.filter { $0.compressed >= 500_000_000 && Double($0.compressed) >= Double($0.mem) * 0.4 }
            .sorted { $0.compressed > $1.compressed }.prefix(4)
            .map { PushedOut(name: $0.name, path: $0.path, footprint: $0.mem, compressed: $0.compressed) }

        var tips: [String] = []
        // Web pages: Safari's and Chrome's per-site processes. Processes aren't tabs (a site can have several, and
        // helpers share the name), so the tip names sites by what they hold, never a tab count.
        let pages = rows.filter { $0.name.hasSuffix("Web Content") || $0.name.contains("(Renderer)") && $0.name.lowercased().contains("chrome") }
        let pageMem = pages.reduce(Int64(0)) { $0 + $1.memory }
        if Double(pageMem) >= 1.5 * gb {
            // Safari names each page's process after its site ("YouTube Web Content"); the generic ones name no site.
            var bySite: [String: Int64] = [:]
            for p in pages where p.name.hasSuffix(" Web Content") {
                let site = String(p.name.dropLast(" Web Content".count))
                if !site.isEmpty, site != "Safari" { bySite[site, default: 0] += p.memory }
            }
            if let top = bySite.max(by: { $0.value < $1.value }), Double(top.value) >= Double(pageMem) * 0.4 {
                tips.append("Web pages hold \(Fmt.bytes(pageMem)), \(Fmt.bytes(top.value)) of it \(top.key). Close tabs you're done with.")
            } else {
                tips.append("Web pages hold \(Fmt.bytes(pageMem)). Close tabs you're done with.")
            }
        }
        // Very large apps: usually a virtual machine, a container runtime or a big project.
        for a in apps where Double(a.mem) >= 4 * gb && a.path != ownPath {
            tips.append("\(a.name) holds \(Fmt.bytes(a.mem)). If it runs containers or virtual machines, lower its memory limit in its settings.")
        }
        if m.swapUsed > 2_000_000_000 && tight {
            tips.append("Swap empties on its own as memory frees up; a restart clears it at once.")
        }
        return MemoryAdvice(summary: summary, tight: tight, pressured: m.pressureLevel >= 2, wanted: wanted, idle: idle, pushedOut: Array(pushedOut), tips: tips)
    }

    static func span(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 60 { return "\(max(1, m)) min" }
        let h = m / 60
        return h < 48 ? "\(h) h" : "\(h / 24) days"
    }
}
