import Foundation
import AppKit

enum CleanupEngine {
    static let titles: [(key: String, title: String, note: String)] = [
        ("systemJunk", "System Junk", "Logs, temporary files and system caches verified as safe to rebuild."),
        ("userCache", "User Cache", "App and browser caches. Caches of apps that are open right now are skipped."),
        ("aiApps", "AI Caches", "Caches from AI tools. The full picture is in AI Cleanup & Care."),
        ("mailAttachments", "Mail Attachments", "Attachments Mail downloaded. The messages stay in Mail."),
        ("trashBins", "Trash Bins", "Every Trash bin, including external drives."),
        ("xcodeJunk", "Xcode", "DerivedData, archives and simulator caches Xcode recreates."),
        ("brewCache", "Homebrew", "Downloaded bottles and old versions."),
        ("nodeCache", "Node", "npm, pnpm, Yarn and Corepack caches."),
        ("devTools", "Other Developer Caches", "Editor, language and tool caches."),
        ("dockerCache", "Docker", "Unused build cache and dangling image layers. Volumes and containers are never touched."),
        ("systemData", "System Data", "Local snapshots, Time Machine leftovers, device backups, firmware and update files."),
    ]

    struct Output { var categories: [CleanCategory]; var leftovers: [CleanItem]; var cacheHolders: [String]; var protected: [String]; var moleTotal: Int64? }

    /// The cleaning tool's own wording ("skipped (Xcode running)", "… · mo purge") said the way people say it.
    static func plainReason(_ detail: String) -> String {
        let d = detail.trimmed
        if let m = d.firstMatch(#"\(([^()]+?) running\)"#), let app = m[1] { return "Skipped while \(app.trimmed) is open" }
        if d.contains("docker system df") { return "Review it in Docker" }
        if d.contains("purge") { return (parseSize(d).map { "\(Fmt.bytes($0)) · " } ?? "") + "Review it in Project Artifacts" }
        if d.contains("whitelist") { return "On your keep list" }
        if d.contains("manual review") { return "Needs your review" }
        if d.contains("in use") || d.contains("open files") { return "In use right now" }
        if d.contains("preserved") { return "Kept: chats and sign-ins" }
        let c = d.replacing(regex: #"\bmo \w+"#, with: "").replacing(regex: #"\s+·\s*$"#, with: "").trimmed
        return c.prefix(1).uppercased() + c.dropFirst()
    }

    static func scan() async -> Output {
        let pv = await Mole.cleanPreview()
        var mapped = Mole.categories(pv)
        let left = mapped.removeValue(forKey: "leftovers")
        var cats: [CleanCategory] = titles.map { t in
            let m = mapped[t.key] ?? Mole.Mapped()
            return CleanCategory(key: t.key, title: t.title, note: t.note, safe: true,
                                 items: m.items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes },
                                 held: m.held.map { var h = $0; h.held = plainReason(h.held ?? ""); return h }, checkedEmpty: m.checked)
        }
        let fda = FullDiskAccess.granted
        for i in cats.indices where ["mailAttachments", "trashBins"].contains(cats[i].key) && cats[i].items.isEmpty && !fda {
            cats[i].blocked = "macOS only lets apps with Full Disk Access measure this."
        }
        var leftovers = (left?.items ?? []).map { var x = $0; x.note = "Left by an app that's gone"; return x }
        leftovers += (left?.held ?? []).flatMap { h -> [CleanItem] in
            (h.held ?? "").components(separatedBy: " · ").compactMap { part in
                guard let m = part.trimmed.firstMatch(#"(~?/\S+)\s+([\d.]+\s*[KMGT]?B)"#), let p = m[1] else { return nil }
                // Mole only hints at these and never removes them: a dot-folder can hold a tool's settings or data.
                return CleanItem(path: p, name: Paths.name(p), bytes: parseSize(m[2]) ?? 0,
                                 note: "Its tool looks uninstalled · may hold settings, so check first", review: true)
            }
        }
        return Output(categories: cats, leftovers: leftovers, cacheHolders: pv.holders, protected: pv.protected, moleTotal: pv.total)
    }

    /// Only files in your own folders can be selected. Anything else (Homebrew's databases, app data, dot folders)
    /// and any database store inside your folders is listed but locked: removing one file corrupts the whole store.
    static let userRoots = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { HOME + "/" + $0 } + ["/Users/Shared"]

    static func isUserFile(_ p: String, roots: [String] = userRoots) -> Bool {
        guard roots.contains(where: { p.hasPrefix($0 + "/") }) else { return false }
        let low = p.lowercased()
        let stores = ["/postgres", "/pgdata", "/mysql", "/mariadb", "/mongodb", "/redis", "/.git/", "/node_modules/", ".photoslibrary/", "/library/"]
        return !stores.contains { low.contains($0) }
    }

    /// Over 100 MB, or untouched for a year. Never pre-selected; app data is listed but locked.
    static func largeFiles(moleLarge: [Mole.Analysis.Entry]) async -> [LargeFile] {
        let roots = userRoots
        let r = await Shell.run("/usr/bin/find", roots.filter { Paths.isDir($0) } + ["-xdev", "-type", "f", "(", "-size", "+100M", "-o", "(", "-size", "+10M", "-atime", "+365", ")", ")",
                                                                                     "-not", "-path", "*/node_modules/*", "-not", "-path", "*/.git/*"], timeout: 600)
        var files: [String: LargeFile] = [:]
        var packages: [String: LargeFile] = [:]
        func add(_ p: String) {
            var st = stat()
            guard stat(p, &st) == 0 else { return }
            let atime = Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            let size = Int64(st.st_blocks) * 512
            if let m = p.firstMatch(#"^(.*?\.(vmwarevm|pvm|utm|photoslibrary|fcpbundle))/"#), let pkg = m[1] {
                var g = packages[pkg] ?? LargeFile(path: pkg, bytes: 0, lastOpened: atime, modified: mtime, isPackage: true)
                g.bytes += size
                g.lastOpened = max(g.lastOpened ?? atime, atime)
                packages[pkg] = g
            } else {
                files[p] = LargeFile(path: p, bytes: size, lastOpened: atime, modified: mtime, insideAppData: !isUserFile(p, roots: roots))
            }
        }
        for line in r.output.split(separator: "\n") { add(String(line)) }
        for e in moleLarge where files[e.path] == nil && !packages.keys.contains(where: { e.path.hasPrefix($0 + "/") }) { add(e.path) }
        return (Array(files.values) + Array(packages.values)).sorted { $0.bytes > $1.bytes }
    }
}

enum FullDiskAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static func openSettings() { NSWorkspace.shared.open(settingsURL) }

    /// The TCC database is only readable with Full Disk Access, which makes it a reliable probe.
    static var granted: Bool {
        FileManager.default.isReadableFile(atPath: HOME + "/Library/Application Support/com.apple.TCC/TCC.db")
            || (try? FileManager.default.contentsOfDirectory(atPath: HOME + "/Library/Mail")) != nil
    }
}
