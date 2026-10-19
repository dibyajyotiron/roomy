import Foundation
import AppKit

/// Caches Mole's rules don't cover, which Roomy can show are safe, and shows again at the moment of removal:
/// - App update downloads: Squirrel's `~/Library/Caches/<app>.ShipIt` and Sparkle's
///   `~/Library/Caches/<app>/org.sparkle-project.Sparkle`, the copies of updates an app already downloaded. Only when
///   the app isn't running, nothing is running from inside the folder, and nothing in it changed in the last day.
/// - Sandboxed apps' caches: what's inside `~/Library/Containers/<app>/Data/Library/Caches`, which macOS itself may
///   clear when space runs low. Third-party apps only, the app must still be installed (a removed app's container is
///   a leftover, handled by Leftovers), and it must not be running. Open apps' caches are listed as "Quit to include".
/// Nothing here follows a symlink out of its folder, touches Apple's own containers, or goes past the keep list.
enum RoomyRules {
    struct Found { var items: [CleanItem] = []; var held: [CleanItem] = [] }

    /// Smaller than this, a sandboxed cache isn't worth a row.
    static let minimum: Int64 = 512 * 1024
    static let caches = HOME + "/Library/Caches"
    static let containers = HOME + "/Library/Containers"

    /// What's running: bundle IDs with names, and every process's executable path.
    struct Running {
        var apps: [String: String] = [:]
        var paths: [String] = []
        func holds(_ bundleID: String) -> String? { apps[bundleID] }
        /// A process whose executable lives inside `folder` (an updater installing from its staging copy).
        func runsFrom(_ folder: String) -> Bool { paths.contains { $0.hasPrefix(folder + "/") } }
    }

    static func running() async -> Running {
        let apps = await MainActor.run {
            Dictionary(NSWorkspace.shared.runningApplications.compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } },
                       uniquingKeysWith: { a, _ in a })
        }
        let ps = await Shell.run("/bin/ps", ["-axo", "comm="], timeout: 20)
        return Running(apps: apps, paths: ps.output.split(separator: "\n").map { String($0).trimmed }.filter { $0.hasPrefix("/") })
    }

    // MARK: scan

    /// Everything these rules find now. `moleRoots` are paths Mole's own clean covers; anything overlapping one is
    /// left to Mole, so nothing is counted or removed twice.
    static func scan(skipping moleRoots: [String]) async -> Found {
        let now = await running()
        var out = Found()
        var candidates: [(path: String, name: String, note: String, bundle: String)] = []

        for entry in Paths.children(caches).map(Paths.name) {
            let path = caches + "/" + entry
            if entry.hasSuffix(".ShipIt") {
                let bundle = String(entry.dropLast(".ShipIt".count))
                candidates.append((path, "\(appName(bundle) ?? bundle) update download", "A copy of an update the app already downloaded (Squirrel).", bundle))
            }
            let sparkle = path + "/org.sparkle-project.Sparkle"
            if Paths.isDir(sparkle), entry != Bundle.main.bundleIdentifier {
                candidates.append((sparkle, "\(appName(entry) ?? entry) update download", "A copy of an update the app already downloaded (Sparkle).", entry))
            }
        }
        for bundle in Paths.children(containers).map(Paths.name) where isThirdParty(bundle) {
            guard appName(bundle) != nil else { continue }   // a removed app's container is a leftover
            let root = containers + "/" + bundle + "/Data/Library/Caches"
            guard isRealFolder(root, inside: containers + "/" + bundle) else { continue }
            for child in Paths.children(root).map(Paths.name) where !child.hasPrefix(".") {
                candidates.append((root + "/" + child, "\(appName(bundle) ?? bundle): \(child)", "Cache of a sandboxed app. macOS may clear it on its own when space runs low.", bundle))
            }
        }

        let roots = moleRoots.map(Paths.expand)
        let kept = keepList()
        candidates = candidates.filter { c in
            !roots.contains { r in c.path == r || c.path.hasPrefix(r + "/") || r.hasPrefix(c.path + "/") }
                && !kept.contains { fnmatch($0, c.path, 0) == 0 || c.path.hasPrefix($0 + "/") }
                && (isRealFolder(c.path, inside: (c.path as NSString).deletingLastPathComponent) || isRealFile(c.path))
        }
        let sizes = await sizesOf(candidates.map(\.path))

        for c in candidates {
            let bytes = sizes[c.path] ?? 0
            let isUpdate = !c.path.hasPrefix(containers)
            guard bytes >= (isUpdate ? 1 : minimum) else { continue }
            var item = CleanItem(path: c.path, name: c.name, bytes: bytes, note: c.note)
            item.app = c.bundle
            // Anything named like media, attachments or offline copies may be what you'd rather not download again:
            // listed, never ticked for you.
            if !isUpdate, Paths.name(c.path).lowercased().range(of: #"media|attach|offline|download|photo|video|gallery"#, options: .regularExpression) != nil {
                item.review = true
                item.note = "Cache of a sandboxed app that may hold media you'd download again. Never ticked for you."
            }
            if let why = heldNow(c.path, running: now) { item.held = why; out.held.append(item) } else { out.items.append(item) }
        }
        out.items.sort { $0.bytes > $1.bytes }
        out.held.sort { $0.bytes > $1.bytes }
        return out
    }

    // MARK: the checks, at scan time and again at removal

    /// Why this path must stay right now, or nil when it's safe to remove. Nil for paths these rules don't cover.
    static func heldNow(_ path: String, running now: Running) -> String? {
        guard let (bundle, isUpdate) = owner(of: path) else { return nil }
        let name = appName(bundle) ?? bundle
        if now.holds(bundle) != nil { return "Quit \(name) to include" }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.path, now.runsFrom(app) { return "Quit \(name) to include" }
        if isUpdate {
            if now.runsFrom(path) { return "An update is installing" }
            if let changed = newestChange(in: path), Date().timeIntervalSince(changed) < 86_400 { return "Downloaded in the last day" }
        }
        if !(isRealFolder(path, inside: (path as NSString).deletingLastPathComponent) || isRealFile(path)) { return "Not a plain folder" }
        return nil
    }

    /// The same check, for Actions just before a file goes to the Trash.
    static func heldNow(_ path: String) async -> String? {
        guard owner(of: path) != nil else { return nil }
        return heldNow(path, running: await running())
    }

    /// The app a path belongs to under these rules, and whether it's an update download.
    static func owner(of path: String) -> (String, Bool)? {
        let p = Paths.expand(path)
        if p.hasPrefix(caches + "/") {
            let rest = p.dropFirst(caches.count + 1).split(separator: "/").map(String.init)
            if rest.count == 1, rest[0].hasSuffix(".ShipIt") { return (String(rest[0].dropLast(".ShipIt".count)), true) }
            if rest.count == 2, rest[1] == "org.sparkle-project.Sparkle" { return (rest[0], true) }
            return nil
        }
        if p.hasPrefix(containers + "/") {
            let rest = p.dropFirst(containers.count + 1).split(separator: "/").map(String.init)
            if rest.count == 5, rest[1] == "Data", rest[2] == "Library", rest[3] == "Caches", isThirdParty(rest[0]) { return (rest[0], false) }
        }
        return nil
    }

    static func isThirdParty(_ bundle: String) -> Bool {
        !bundle.hasPrefix("com.apple.") && !bundle.hasPrefix("group.") && !bundle.contains("docker") && !bundle.contains("orbstack")
            && bundle != Bundle.main.bundleIdentifier
    }

    // MARK: helpers

    static func appName(_ bundle: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// A directory that is itself and whose real location is still inside `parent`: no symlink leads it elsewhere.
    static func isRealFolder(_ path: String, inside parent: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        let real = (path as NSString).resolvingSymlinksInPath, realParent = (parent as NSString).resolvingSymlinksInPath
        return real.hasPrefix(realParent + "/")
    }

    static func isRealFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// The most recent change anywhere inside, looking a few levels down (update folders are shallow).
    static func newestChange(in path: String) -> Date? {
        let fm = FileManager.default
        var newest = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
        guard let e = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.contentModificationDateKey],
                                    options: [.skipsPackageDescendants]) else { return newest }
        var seen = 0
        for case let url as URL in e {
            if e.level > 4 { e.skipDescendants(); continue }
            if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > (newest ?? .distantPast) { newest = d }
            seen += 1
            if seen > 5000 { break }
        }
        return newest
    }

    /// On-disk sizes, in one `du` run.
    static func sizesOf(_ paths: [String]) async -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }
        var out: [String: Int64] = [:]
        for chunk in stride(from: 0, to: paths.count, by: 200).map({ Array(paths[$0..<min($0 + 200, paths.count)]) }) {
            let r = await Shell.run("/usr/bin/du", ["-sk"] + chunk, timeout: 300)
            for line in r.output.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                if parts.count == 2, let k = Int64(parts[0].trimmingCharacters(in: .whitespaces)) { out[String(parts[1])] = k * 1024 }
            }
        }
        return out
    }

    /// Paths on Mole's keep list (the same list "Always keep" writes to), with `~` expanded.
    static func keepList() -> [String] {
        let text = (try? String(contentsOfFile: MoleWhitelist.file, encoding: .utf8)) ?? ""
        return (text.split(separator: "\n").map { String($0).trimmed } + MoleWhitelist.defaults())
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map(Paths.expand)
    }

    /// Testing aid: `Roomy -RoomyRulesProbe <out.json>` runs the real cleanup scan (Mole's preview, then these rules),
    /// writes what the rules found and held, plus Mole's total, as JSON, and quits. It only reads.
    static func probe(to out: String) {
        Task {
            let r = await CleanupEngine.scan()
            let user = r.categories.first { $0.key == "userCache" }
            func rows(_ items: [CleanItem]) -> [[String: Any]] { items.filter { $0.app != nil }.map { ["path": Paths.short($0.path), "bytes": $0.bytes, "app": $0.app ?? "", "held": $0.held ?? ""] } }
            let json: [String: Any] = ["moleTotal": r.moleTotal ?? 0, "found": rows(user?.items ?? []), "held": rows(user?.held ?? [])]
            if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: out)) }
            exit(0)
        }
    }
}
