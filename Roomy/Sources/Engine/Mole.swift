import Foundation

/// Adapter for Mole (github.com/tw93/mole, GPL-3.0), called as a separate program.
/// Every preview sets MOLE_DRY_RUN=1 on top of `--dry-run`, so scanning never changes anything.
enum Mole {
    /// Roomy ships its own tested copy of Mole inside the app, so nothing needs installing, and uses only that copy:
    /// Mole changes only with a Roomy release (see MoleCheck). A Mole installed with Homebrew is the fallback for
    /// development builds made without one.
    static let bundled = Bundle.main.resourcePath.map { $0 + "/mole/bin/mole" }
    struct Engine { var path: String; var version: String? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Engine??
    static var engine: Engine? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let e = resolve()
        cached = .some(e)
        return e
    }
    /// Looks again after an update switched copies.
    static func reload() { lock.lock(); cached = nil; lock.unlock() }
    static var path: String? { engine?.path }
    static var activeVersion: String? { engine?.version }
    static var available: Bool { path != nil }

    private static func resolve() -> Engine? {
        let fm = FileManager.default
        func version(_ p: String) -> String? { scriptVersion((try? String(contentsOfFile: p, encoding: .utf8)) ?? "") }
        if let p = bundled, fm.isExecutableFile(atPath: p) { return Engine(path: p, version: version(p)) }
        return Shell.which("mo").map { Engine(path: $0, version: version($0)) }
    }

    /// The `VERSION="1.61.0"` line of Mole's entry script.
    static func scriptVersion(_ script: String) -> String? {
        script.firstMatch(#"(?m)^VERSION="([0-9][0-9.]*)""#)?[1] ?? nil
    }
    static let config = HOME + "/.config/mole"

    static var env: [String: String] {
        var e = Shell.baseEnvironment
        e["MOLE_DRY_RUN"] = "1"; e["NO_COLOR"] = "1"; e["MO_NO_OPLOG"] = "1"
        // Checkup never empties the Trash: that would permanently delete things people put there.
        e["MOLE_SKIP_TRASH_CLEANUP"] = "1"
        return e
    }

    static func run(_ args: [String], timeout: TimeInterval = 900, input: String? = nil, dryRun: Bool = true, using: String? = nil) async -> String {
        guard let path = using ?? path else { return "" }
        var e = env
        if !dryRun { e.removeValue(forKey: "MOLE_DRY_RUN") }
        let r = await Shell.run(path, args, environment: e, timeout: timeout, input: input)
        return r.output.replacing(regex: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "").replacingOccurrences(of: "\r", with: "\n")
    }

    static func version(using: String? = nil) async -> String? {
        await run(["--version"], timeout: 20, using: using).firstMatch(#"Mole version ([\d.]+)"#)?[1] ?? nil
    }

    // MARK: clean

    struct Line { var section: String; var kind: String; var label: String; var detail: String; var bytes: Int64? }
    struct LedgerItem { var section: String; var path: String; var bytes: Int64?; var count: Int }
    struct CleanPreview { var lines: [Line] = []; var items: [LedgerItem] = []; var holders: [String] = []; var protected: [String] = []
        /// Mole's own total for everything its clean would remove (the ledger's "Potential cleanup").
        var total: Int64? }

    static func cleanPreview(using: String? = nil) async -> CleanPreview {
        let out = await run(["clean", "--dry-run"], timeout: 1200, using: using)
        var pv = CleanPreview()
        var section: String?
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(raw).trimmed
            if s.hasPrefix("↳") { pv.protected.append(String(s.dropFirst()).trimmed) }
            if s.hasPrefix("➤ ") { section = String(s.dropFirst(2)).trimmed; continue }
            // ✓ checked and clean, → would clean, ◎ skipped, ⊙ found but left for you to review (Mole 1.61+).
            guard let sec = section, let first = s.first, "✓→◎⊙".contains(first) else { continue }
            let body = String(s.dropFirst()).trimmed
            let parts = body.components(separatedBy: " · ")
            let label = parts[0].trimmed, detail = parts.dropFirst().joined(separator: " · ").trimmed
            let kind = first == "✓" ? "ok" : first == "→" ? "clean" : "hold"
            pv.lines.append(Line(section: sec, kind: kind, label: label, detail: detail,
                                 bytes: kind == "ok" ? nil : (detail.contains("dry") || kind == "hold" ? parseSize(detail) : nil)))
            if let m = detail.firstMatch(#"\(([^()]+?) running\)"#), let app = m[1] { pv.holders.append(app.trimmed) }
        }
        // Exact paths and sizes from Mole's preview ledger
        if let ledger = try? String(contentsOfFile: config + "/clean-list.txt", encoding: .utf8) {
            section = nil
            for raw in ledger.split(separator: "\n") {
                let s = String(raw).trimmed
                if let m = s.firstMatch(#"^# Potential cleanup:\s*(.+)$"#), let v = m[1] { pv.total = parseSize(v); continue }
                if let m = s.firstMatch("^=== (.+) ===$") { section = m[1]; continue }
                guard let sec = section, !s.isEmpty, !s.hasPrefix("#") else { continue }
                let parts = s.components(separatedBy: "  # ")
                let note = parts.count > 1 ? parts[1] : ""
                let count = Int(note.firstMatch(#"(\d+) items?"#)?[1] ?? "") ?? 1
                pv.items.append(LedgerItem(section: sec, path: parts[0].trimmed, bytes: parseSize(note), count: count))
            }
        }
        pv.holders = Array(Set(pv.holders)).sorted()
        return pv
    }

    static let aiPattern = "claude|codex|ollama|lm ?studio|lmstudio|cursor|copilot|gemini|antigravity|windsurf|chatgpt|openai"

    /// Mole's sections mapped onto Roomy's categories. Mole's verdicts are kept as they are.
    static func category(section: String, path: String, label: String) -> String {
        let p = path.lowercased(), t = "\(label) \(path)".lowercased()
        // By path, and by Mole's own label for lines it only reports ("Trash · skipped", "Mail Downloads · …").
        if p.contains("/.trash") || (p.isEmpty && label.lowercased().hasPrefix("trash")) { return "trashBins" }
        if t.contains("mail downloads") { return "mailAttachments" }
        if ["System", "Time Machine", "Device backups & firmware", "Apple Silicon updates", "System Data clues", "External volume"].contains(section) { return "systemData" }
        if section == "App leftovers" { return "leftovers" }
        if ["Developer tools", "Virtualization", "Project artifacts"].contains(section) {
            if t.contains(regex: aiPattern) { return "aiApps" }
            if t.contains(regex: "xcode|deriveddata|coresimulator|simulator") { return "xcodeJunk" }
            if t.contains("homebrew") { return "brewCache" }
            if t.contains(regex: #"\bnpm\b|\.npm|pnpm|yarn|corepack|npx"#) { return "nodeCache" }
            if t.contains("docker") { return "dockerCache" }
            return "devTools"
        }
        if t.contains(regex: aiPattern) && ["Applications", "Application Support"].contains(section) { return "aiApps" }
        if section == "User essentials" { return p.hasSuffix("/library/caches") || p.contains("/caches") ? "userCache" : "systemJunk" }
        if section == "App caches" { return p.contains("com.apple.") || p.contains("/geoservices") ? "systemJunk" : "userCache" }
        return "userCache"
    }

    struct Mapped { var items: [CleanItem] = []; var held: [CleanItem] = []; var checked: [String] = [] }

    static func categories(_ pv: CleanPreview) -> [String: Mapped] {
        var out: [String: Mapped] = [:]
        var bySection: [String: [Line]] = [:]
        for l in pv.lines { bySection[l.section, default: []].append(l) }
        // Every ledger line is shown, because Mole's clean removes all of it. A line with several items names the
        // folder they're in, not something to remove whole, so these are Mole's to remove, never Roomy's.
        // Mole's ledger can list a folder and, in another section, something inside it (~/Library/Caches/Google and
        // Chrome's cache within it). One clean removes both once, so the inner one isn't counted again.
        let outer = Set(pv.items.map { Paths.expand($0.path) })
        for it in pv.items {
            let full = Paths.expand(it.path)
            if outer.contains(where: { $0 != full && full.hasPrefix($0 + "/") }) { continue }
            let lab = bySection[it.section]?.first { l in
                guard l.kind == "clean", let lb = l.bytes, let ib = it.bytes else { return false }
                return abs(lb - ib) <= max(1500, Int64(Double(ib) * 0.02))
            }?.label
            let name = lab ?? (it.count > 1 ? "\(it.count) items in \(Paths.name(it.path))" : Paths.name(it.path))
            let key = category(section: it.section, path: it.path, label: name)
            let note = it.count > 1 ? "\(it.count) items inside this folder, chosen by Mole" : it.section
            out[key, default: Mapped()].items.append(CleanItem(path: Paths.short(it.path), name: name, bytes: it.bytes ?? 0, count: it.count,
                                                                note: note, byMole: true))
        }
        for l in pv.lines {
            let key = category(section: l.section, path: "", label: l.label)
            switch l.kind {
            case "ok": out[key, default: Mapped()].checked.append(l.label)
            case "hold": out[key, default: Mapped()].held.append(CleanItem(path: "mole:" + l.label, name: l.label, bytes: l.bytes ?? 0, review: true, held: l.detail))
            default: break
            }
        }
        return out
    }

    // MARK: the real clean

    struct CleanRun {
        var removed: [(path: String, bytes: Int64)] = []
        var failed: [(path: String, reason: String)] = []
        var ran = false
        /// Mole's own total for the session (some removals are logged in batches without a size).
        var total: Int64?
        var freed: Int64 { total ?? removed.reduce(0) { $0 + $1.bytes } }
    }

    /// Runs Mole's own user-level clean, the same pass its preview showed. Without a terminal Mole runs
    /// non-interactively and skips anything that needs an administrator. Its protections, keep list and in-use
    /// checks apply at the moment of removal, and every path it removes, skips or fails is read back from its
    /// operations log, so Roomy reports exactly what happened.
    /// Whether a `mo clean` (from Roomy, Mole's app or a Terminal) is running right now.
    static func cleanRunning() async -> Bool {
        await Shell.run("/usr/bin/pgrep", ["-if", "mole.*bin/clean.sh|mo clean"], timeout: 5).ok
    }

    /// Runs Mole's clean. `keeping` are paths you unticked in the review: Mole leaves them alone this time.
    static func runClean(keeping: [String] = []) async -> CleanRun {
        await MoleWhitelist.keeping(keeping) { await runCleanNow() }
    }

    private static func runCleanNow() async -> CleanRun {
        guard let path else { return CleanRun() }
        var e = Shell.baseEnvironment
        e["NO_COLOR"] = "1"
        e["MOLE_SKIP_TRASH_CLEANUP"] = "1"
        let started = Date().addingTimeInterval(-2)
        let r = await Shell.run(path, ["clean"], environment: e, timeout: 1800)
        var run = readOperations(since: started)
        run.ran = r.ok
        return run
    }

    /// Reads the newest clean session in Mole's operations log that started at or after `since`.
    static func readOperations(since: Date, log logPath: String = HOME + "/Library/Logs/mole/operations.log") -> CleanRun {
        var run = CleanRun()
        // Decoded leniently: one odd byte in a long log must not hide the whole session.
        guard let data = FileManager.default.contents(atPath: logPath) else { return run }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let start = lines.lastIndex(where: { l in
            guard let m = l.firstMatch(#"clean session started at (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)"#), let t = m[1], let d = stamp.date(from: t) else { return false }
            return d >= since
        }) else { return run }
        for l in lines[(start + 1)...] {
            if l.contains("session ended") {
                run.total = l.firstMatch(#",\s*([\d.]+\s*[KMGT]?B)\s*=*\s*$"#).flatMap { $0[1] }.flatMap { parseSize($0) }
                break
            }
            guard let m = l.firstMatch(#"^\[[^\]]+\] \[clean\] (REMOVED|FAILED) (.+?)(?: \(([^()]*)\))?$"#), let act = m[1], let p = m[2] else { continue }
            if act == "REMOVED" { run.removed.append((p, parseSize(m[3] ?? "") ?? 0)) } else { run.failed.append((p, m[3] ?? "error")) }
        }
        return run
    }

    // MARK: purge, installers, uninstall, optimize

    static func purgePreview() async -> [Artifact] {
        let out = await run(["purge", "--dry-run", "--debug"], timeout: 1200)
        return out.matches(#"Would remove:\s+\*\s+(.+?),\s*([\d.]+\s*[KMGT]?B),\s*(\d+) days old"#).compactMap { m in
            guard let p = m[1] else { return nil }
            return Artifact(path: Paths.short(p), kind: Paths.name(p), project: Paths.short(Paths.parent(p)), bytes: parseSize(m[2]) ?? 0, ageDays: Int(m[3] ?? "") ?? 0)
        }.sorted { $0.bytes > $1.bytes }
    }

    static func installerPreview() async -> [CleanItem] {
        let out = await run(["installer", "--dry-run", "--debug"], timeout: 600)
        return out.matches(#"Would remove:?\s+\*?\s*(/.+?\.(?:dmg|pkg|mpkg|iso|xip|zip)),\s*([\d.]+\s*[KMGT]?B)"#, options: .caseInsensitive).compactMap { m in
            guard let p = m[1] else { return nil }
            return CleanItem(path: Paths.short(p), name: Paths.name(p), bytes: parseSize(m[2]) ?? 0, note: "Installer")
        }
    }

    struct ListedApp: Decodable { var name: String?; var path: String; var uninstall_name: String? }

    static func uninstallList(using: String? = nil) async -> [ListedApp] {
        let out = await run(["uninstall", "--list"], timeout: 300, using: using)
        guard let a = out.firstIndex(of: "["), let b = out.lastIndex(of: "]") else { return [] }
        return (try? JSONDecoder().decode([ListedApp].self, from: Data(out[a...b].utf8))) ?? []
    }

    struct UninstallPreview { var files: [CleanItem]; var personalKept: [String] }

    /// Exact files Mole would move to the Trash for one app. Anything that isn't a dry run is refused.
    static func uninstallPreview(_ name: String) async -> UninstallPreview? {
        let out = await run(["uninstall", "--dry-run", "--debug", name], timeout: 240, input: "y\n")
        guard out.contains("DRY RUN MODE") else { return nil }
        let block = (out.components(separatedBy: "Files to be removed:").last ?? "").components(separatedBy: "➤ Remove").first ?? ""
        var seen = Set<String>(), files: [CleanItem] = []
        for raw in block.split(separator: "\n") {
            let s = String(raw).trimmed
            if let m = s.firstMatch(#"^✓\s+(.+?)(?:\s*,\s*([\d.]+\s*[KMGT]?B))?$"#), let p = m[1]?.trimmed, p.contains("/"), seen.insert(p).inserted {
                files.append(CleanItem(path: Paths.short(Paths.expand(p)), name: Paths.name(p), bytes: parseSize(m[2]) ?? diskSize(p), note: Paths.name(Paths.parent(p))))
            }
        }
        var kept: [String] = []
        if let r = out.range(of: "Personal data kept:") {
            for l in out[r.upperBound...].split(separator: "\n").prefix(12) {
                let t = String(l).trimmed
                if t.hasPrefix("~") || t.hasPrefix("/") { kept.append(t) } else if !t.isEmpty { break }
            }
        }
        return UninstallPreview(files: files.sorted { $0.bytes > $1.bytes }, personalKept: kept)
    }

    static func optimizePreview() async -> (tasks: [MaintenanceTask], diagnosis: [String]) {
        let out = await run(["optimize", "--dry-run"], timeout: 600)
        var tasks: [MaintenanceTask] = [], diag: [String] = [], inDiag = false
        for raw in out.split(separator: "\n") {
            let s = String(raw).trimmed
            if s == "PERFORMANCE DIAGNOSIS" { inDiag = true; continue }
            if s.hasPrefix("➤ ") { inDiag = false; tasks.append(MaintenanceTask(title: String(s.dropFirst(2)).trimmed, steps: [])); continue }
            guard let f = s.first else { continue }
            if inDiag, "◎☞✓".contains(f) { diag.append(String(s.dropFirst()).trimmed); continue }
            guard !tasks.isEmpty, "→◎○✓".contains(f) else { continue }
            let text = String(s.dropFirst()).trimmed
            var state = ["→": "Would run", "◎": "Needs you", "○": "Not applicable", "✓": "Already fine"][String(f)] ?? ""
            if f == "→", text.contains(regex: #"already|healthy|valid|clean\b|no legacy|not found|skipped"#) {
                state = text.contains(regex: "skipped") ? "Skipped" : "Already fine"
            }
            let over = text.contains(regex: "memory (released|optimi)|responsiveness improved|speed up|boost")
            tasks[tasks.count - 1].steps.append(.init(text: text, state: state, unverifiable: over))
        }
        return (tasks, diag)
    }

    // MARK: analyze, status, history

    struct Analysis: Decodable {
        struct Entry: Decodable { var name: String?; var path: String; var size: Int64; var is_dir: Bool? }
        var entries: [Entry]?
        var total_size: Int64?
        var large_files: [Entry]?
    }

    static func analyze(_ path: String) async -> Analysis? {
        let out = await run(["analyze", "--json", Paths.expand(path)], timeout: 900)
        guard let a = out.firstIndex(of: "{"), let b = out.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(Analysis.self, from: Data(out[a...b].utf8))
    }

    static func status(using: String? = nil) async -> MoleStatus? {
        let out = await run(["status", "--json"], timeout: 60, using: using)
        guard let a = out.firstIndex(of: "{"), let b = out.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(MoleStatus.self, from: Data(out[a...b].utf8))
    }

    static func touchIDEnabled() async -> Bool {
        let out = await run(["touchid", "status"], timeout: 30, dryRun: false).lowercased()
        return !out.contains("not configured") && out.contains("enabled")
    }

    static func whitelist() -> [String] {
        ((try? String(contentsOfFile: config + "/whitelist", encoding: .utf8)) ?? "")
            .split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

/// `mo status --json`. Every field is optional so a newer Mole never breaks decoding.
struct MoleStatus: Decodable {
    struct CPU: Decodable { var usage: Double?; var per_core: [Double]?; var load1: Double?; var load5: Double?; var load15: Double?
        var core_count: Int?; var p_core_count: Int?; var e_core_count: Int? }
    struct Memory: Decodable { var used: Int64?; var total: Int64?; var available: Int64?; var swap_used: Int64?; var swap_total: Int64?; var cached: Int64? }
    struct Battery: Decodable { var percent: Double?; var status: String?; var health: String?; var cycle_count: Int?; var capacity: Int? }
    struct Thermal: Decodable { var cpu_temp: Double?; var gpu_temp: Double?; var fan_speed: Int?; var system_power: Double?; var adapter_power: Double?; var battery_power: Double? }
    struct Net: Decodable { var name: String?; var rx_rate_mbs: Double?; var tx_rate_mbs: Double?; var ip: String? }
    struct Proxy: Decodable { var enabled: Bool?; var type: String? }
    struct Proc: Decodable { var pid: Int?; var name: String?; var command: String?; var cpu: Double?; var memory_bytes: Int64? }
    struct Hardware: Decodable { var model: String?; var cpu_model: String?; var total_ram: String?; var os_version: String?; var refresh_rate: String? }
    struct Watch: Decodable { var cpu_threshold: Double?; var window: String? }
    var cpu: CPU?
    var memory: Memory?
    var batteries: [Battery]?
    var thermal: Thermal?
    var network: [Net]?
    var proxy: Proxy?
    var top_processes: [Proc]?
    var hardware: Hardware?
    var health_score: Int?
    var health_score_msg: String?
    var uptime: String?
    var uptime_seconds: Int?
    var procs: Int?
    var process_watch: Watch?
}
