import Foundation
import MoleCore

let HOME = NSHomeDirectory()

enum Paths {
    /// `~/…` for display, like Finder's "Go to Folder".
    static func short(_ p: String) -> String { p.hasPrefix(HOME) ? "~" + p.dropFirst(HOME.count) : p }
    static func expand(_ p: String) -> String { p.hasPrefix("~") ? HOME + p.dropFirst() : p }
    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: expand(p)) }
    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: expand(p), isDirectory: &d) && d.boolValue
    }
    static func children(_ p: String) -> [String] {
        let e = expand(p)
        return ((try? FileManager.default.contentsOfDirectory(atPath: e)) ?? []).map { e + "/" + $0 }
    }
    static func name(_ p: String) -> String { (p as NSString).lastPathComponent }
    static func parent(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
    static func mtime(_ p: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: expand(p)))?[.modificationDate] as? Date
    }
    static let support: URL = {
        let folder = Bundle.main.bundleIdentifier == "app.roomy.v2" ? "Roomy v2" : "Roomy"
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(folder)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}

enum Fmt {
    /// Decimal units like Finder and System Settings: 1 GB = 1,000,000,000 bytes.
    static func bytes(_ b: Int64?) -> String {
        guard let b, b >= 0 else { return "—" }
        var v = Double(b)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return i >= 3 ? String(format: "%.1f %@", v, units[i]) : "\(Int(v.rounded())) \(units[i])"
    }

    static func split(_ b: Int64?) -> (String, String) {
        let parts = bytes(b).split(separator: " ")
        return (String(parts.first ?? "—"), parts.count > 1 ? String(parts[1]) : "")
    }

    struct Rate { var value: String; var unit: String; var joined: String { "\(value) \(unit)" } }
    /// A transfer rate in decimal units per second, like Activity Monitor: "12.4 MB/s".
    static func rate(_ bytesPerSecond: Double) -> Rate {
        var v = max(0, bytesPerSecond)
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return Rate(value: i >= 2 ? String(format: "%.1f", v) : "\(Int(v.rounded()))", unit: units[i])
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return "Never" }
        let days = Date().timeIntervalSince(d) / 86400
        switch days {
        case ..<1: return "Today"
        case ..<2: return "Yesterday"
        case ..<31: return "\(Int(days.rounded())) days ago"
        case ..<365: return "\(Int((days / 30).rounded())) months ago"
        default:
            let y = days / 365
            return y < 1.95 ? "Over a year ago" : "\(Int(y.rounded())) years ago"
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 1_000_000 ? String(format: "%.1f MB/s", bytesPerSecond / 1_000_000) : "\(Int((bytesPerSecond / 1000).rounded())) KB/s"
    }

    static func uptime(_ s: Int) -> String { "\(s / 86400)d \((s % 86400) / 3600)h" }
}

/// Size text like "1.2 GB" → bytes, as Mole and Docker print it.
func parseSize(_ text: String?) -> Int64? {
    guard let text, let m = text.firstMatch(#"([\d.]+)\s*(TB|GB|MB|KB|kB|B)\b"#), let n = Double(m[1] ?? "") else { return nil }
    let mult: Double = ["B": 1, "KB": 1e3, "kB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][m[2] ?? "B"] ?? 1
    return Int64(n * mult)
}

/// Bytes on disk like `du -skPx`, using the MoleCore port (hard links and clones counted once).
func diskSize(_ path: String) -> Int64 {
    let p = Paths.expand(path)
    guard FileManager.default.fileExists(atPath: p) else { return 0 }
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
    if !isDir.boolValue {
        var st = stat()
        return lstat(p, &st) == 0 ? FileSizer.actualSize(st) : 0
    }
    return DirectorySizer().measure(p).bytes
}

func diskSizes(_ paths: [String]) async -> [String: Int64] {
    await withTaskGroup(of: (String, Int64).self) { g in
        for p in paths { g.addTask { (p, diskSize(p)) } }
        var out: [String: Int64] = [:]
        for await (p, b) in g { out[p] = b }
        return out
    }
}
