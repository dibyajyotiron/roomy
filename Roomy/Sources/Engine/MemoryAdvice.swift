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
        /// "Not used in 2 h", or "Not used since Roomy opened 45 min ago".
        var lastUsed: String
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
    var tight: Bool
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
            let since: String
            if let last = lastActive[path] {
                guard now.timeIntervalSince(last) >= idleAfter else { continue }
                since = "Not used in \(Self.span(now.timeIntervalSince(last)))"
            } else {
                guard watched >= idleAfter else { continue }
                since = "Not used since Roomy opened \(Self.span(watched)) ago"
            }
            idle.append(IdleApp(name: a.name, path: path, footprint: a.mem, compressed: a.compressed, lastUsed: since))
        }
        idle.sort { $0.footprint > $1.footprint }

        let pushedOut = apps.filter { $0.compressed >= 500_000_000 && Double($0.compressed) >= Double($0.mem) * 0.4 }
            .sorted { $0.compressed > $1.compressed }.prefix(4)
            .map { PushedOut(name: $0.name, path: $0.path, footprint: $0.mem, compressed: $0.compressed) }

        var tips: [String] = []
        // Web pages: Safari's and Chrome's per-site processes.
        let pages = rows.filter { $0.name.hasSuffix("Web Content") || $0.name.contains("(Renderer)") && $0.name.lowercased().contains("chrome") }
        let pageMem = pages.reduce(Int64(0)) { $0 + $1.memory }
        if Double(pageMem) >= 1.5 * gb {
            let named = pages.sorted { $0.memory > $1.memory }.prefix(3).map { "\($0.name.replacingOccurrences(of: " Web Content", with: "")) \(Fmt.bytes($0.memory))" }
            tips.append("Web pages use \(Fmt.bytes(pageMem)) across \(pages.count) tabs (\(named.joined(separator: ", "))). Closing tabs you aren't watching or reading frees it.")
        }
        // Very large apps: usually a virtual machine, a container runtime or a big project.
        for a in apps where Double(a.mem) >= 4 * gb && a.path != ownPath {
            let squeezed = a.compressed > 0 ? ", and macOS has squeezed \(Fmt.bytes(a.compressed)) of it" : ""
            tips.append("\(a.name) holds \(Fmt.bytes(a.mem))\(squeezed). If it runs virtual machines or containers, give it less memory in its settings, or quit it when you're done.")
        }
        if m.swapUsed > 2_000_000_000 && tight {
            tips.append("Swap shrinks on its own once memory frees up; a restart clears it at once.")
        }
        return MemoryAdvice(summary: summary, tight: tight, idle: idle, pushedOut: Array(pushedOut), tips: tips)
    }

    static func span(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 60 { return "\(max(1, m)) min" }
        let h = m / 60
        return h < 48 ? "\(h) h" : "\(h / 24) days"
    }
}
