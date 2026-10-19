import Foundation
import AppKit
import CoreServices

enum AppsEngine {
    static let libDirs = ["Application Support", "Caches", "Containers", "Group Containers", "Preferences", "Saved Application State",
                          "HTTPStorages", "Logs", "WebKit", "Application Scripts", "LaunchAgents", "Cookies"]

    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func appBundles() -> [String] {
        var out: [String] = []
        for base in ["/Applications", HOME + "/Applications"] {
            for a in Paths.children(base) {
                if a.hasSuffix(".app") { out.append(a) }
                else if Paths.isDir(a), !Paths.name(a).hasPrefix(".") { out += Paths.children(a).filter { $0.hasSuffix(".app") } }
            }
        }
        return out
    }

    struct Output { var apps: [AppRecord]; var leftovers: [CleanItem] }

    static func scan() async -> Output {
        let bundles = appBundles()
        let entries = libDirs.flatMap { d in Paths.children(HOME + "/Library/" + d).map { (d, $0) } }
        var infos: [(path: String, info: [String: Any], id: String)] = []
        for a in bundles {
            let info = NSDictionary(contentsOfFile: a + "/Contents/Info.plist") as? [String: Any] ?? [:]
            infos.append((a, info, info["CFBundleIdentifier"] as? String ?? Paths.name(a)))
        }
        let sizes = await diskSizes(infos.map(\.path))
        var claimed = Set<String>()
        var apps: [AppRecord] = []
        for (a, info, ident) in infos {
            let lid = ident.lowercased(), nm = norm((Paths.name(a) as NSString).deletingPathExtension)
            var related: [(String, String)] = []
            for (d, c) in entries {
                let cn = Paths.name(c).lowercased()
                let base = cn.hasSuffix(".plist") ? String(cn.dropLast(6)) : cn
                if !lid.isEmpty && (base == lid || base.hasPrefix(lid + ".") || base.contains(lid)) || (nm.count > 3 && norm((Paths.name(c) as NSString).deletingPathExtension) == nm) {
                    related.append((d, c)); claimed.insert(c)
                }
            }
            let rs = await diskSizes(related.map(\.1))
            let rel = related.map { CleanItem(path: Paths.short($0.1), name: Paths.name($0.1), bytes: rs[$0.1] ?? 0, note: $0.0) }.sorted { $0.bytes > $1.bytes }
            apps.append(AppRecord(name: (Paths.name(a) as NSString).deletingPathExtension, bundleID: ident,
                                  version: info["CFBundleShortVersionString"] as? String ?? "", path: a, bytes: sizes[a] ?? 0,
                                  lastUsed: lastUsed(a), appStore: FileManager.default.fileExists(atPath: a + "/Contents/_MASReceipt"),
                                  apple: ident.hasPrefix("com.apple."), related: rel))
        }
        // Leftovers: reverse-DNS names in ~/Library that match no installed app
        let ids = Set(infos.map { $0.id.lowercased() }), names = Set(infos.map { norm((Paths.name($0.path) as NSString).deletingPathExtension) })
        var lefts: [(String, String, String)] = []
        // Same rules as Mole's orphan clean: leftovers in Caches, Logs and Saved Application State whose app is gone
        // (not in /Applications and unknown to macOS anywhere) and that haven't changed for 30 days start selected.
        // Data folders are listed for review only, and login items and scripts are left to Startup Items.
        // Safe places are Mole's orphan dirs plus PureMac's volatile web storage (HTTPStorages, WebKit).
        let safeDirs = Self.safeDirs
        // Login items are left to Startup Items, which flags broken ones.
        let neverList: Set<String> = ["LaunchAgents"]
        let month: TimeInterval = 30 * 86400
        // Apps you dragged to the Trash are gone as far as cleanup goes; their name makes the leftovers recognisable.
        var trashed: [String: String] = [:]
        for t in Paths.children(HOME + "/.Trash") where t.hasSuffix(".app") {
            if let i = NSDictionary(contentsOfFile: t + "/Contents/Info.plist") as? [String: Any], let id = i["CFBundleIdentifier"] as? String {
                trashed[id.lowercased()] = (Paths.name(t) as NSString).deletingPathExtension
            }
        }
        let shortTLDs: Set<String> = ["us", "io", "app", "so", "ai", "co", "net", "org", "com", "dev", "me", "tv", "fm", "cc", "to", "sh", "gg"]
        for (d, c) in entries where !claimed.contains(c) && !neverList.contains(d) {
            let n = Paths.name(c), name = n.hasSuffix(".plist") ? String(n.dropLast(6)) : n
            // The bundle ID inside the name: without a team-ID prefix (JQ525L2MZD.com.adobe…), "group." or a suffix.
            var core = name.replacing(regex: #"^[A-Z0-9]{10}\."#, with: "").lowercased()
            if core.hasPrefix("group.") { core = String(core.dropFirst(6)) }
            for suffix in [".savedstate", ".binarycookies", ".web"] where core.hasSuffix(suffix) { core = String(core.dropLast(suffix.count)) }
            let parts = core.split(separator: ".")
            // Never Roomy's own (its settings, demo mode), never Apple's: anything naming Apple, Shortcuts' old
            // "is.workflow" groups, system groups.
            if core.hasPrefix("app.roomy") { continue }
            if parts.contains("apple") || core.hasPrefix("apple") || core.hasPrefix(".") || core.hasPrefix("is.workflow") || name.lowercased().hasPrefix("systemgroup.") { continue }
            // Not an app's: developer tools, installer frameworks and SDKs whose owner can't be told from the name.
            if Self.notAppOwned.contains(where: { core.hasPrefix($0) }) { continue }
            // Group containers named for a family of apps are shared, so one installed member keeps them.
            if core.hasSuffix(".family") { continue }
            // Group containers are shared by a developer's apps: any installed app from the same developer keeps them.
            if d == "Group Containers", parts.count >= 2, ids.contains(where: { $0.hasPrefix("\(parts[0]).\(parts[1]).") }) { continue }
            // An installed app named in the ID (WhatsApp in net.whatsapp.family) still owns it.
            if parts.dropFirst().contains(where: { $0.count >= 4 && names.contains(norm(String($0))) }) { continue }
            // Reverse-DNS (com.vendor.app), or a two-part domain name like zoom.us or draw.io.
            let reverseDNS = parts.count >= 3 && core.contains(regex: #"^[a-z0-9-]+(\.[a-z0-9_-]+)+$"#, options: [])
            let domain = parts.count == 2 && shortTLDs.contains(String(parts[1])) && parts[0].count >= 3
            guard reverseDNS || domain else { continue }
            if ids.contains(where: { core == $0 || core.hasPrefix($0 + ".") || $0.hasPrefix(core) }) { continue }
            if names.contains(norm(String(parts.last ?? ""))) || domain && names.contains(norm(String(parts[0]))) { continue }
            // An app installed anywhere macOS knows about still owns its files (macOS ignores copies in the Trash).
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: core) != nil { continue }
            lefts.append((d, c, trashed[core].map { "\($0) (in your Trash)" } ?? name))
        }
        let ls = await diskSizes(lefts.map(\.1))
        let leftovers = lefts.compactMap { (d, c, n) -> CleanItem? in
            guard let b = ls[c], b > 0 else { return nil }
            let modified = (try? FileManager.default.attributesOfItem(atPath: c)[.modificationDate] as? Date) ?? Date()
            let idle = Date().timeIntervalSince(modified)
            let safe = safeDirs.contains(d) && idle >= month
            let age = "changed \(Fmt.ago(modified).lowercased())"
            let note = safe ? "\(d) · \(age) · rebuilds if the app comes back"
                            : safeDirs.contains(d) ? "\(d) · \(age) · changed in the last 30 days, so not selected"
                                                   : "\(d) · \(age) · may hold the app's data, so you choose"
            return CleanItem(path: Paths.short(c), name: n, bytes: b, note: note, review: !safe)
        }.sorted { ($0.review ? 1 : 0, -$0.bytes) < ($1.review ? 1 : 0, -$1.bytes) }
        return Output(apps: apps.sorted { $0.bytes > $1.bytes }, leftovers: Array(leftovers.prefix(150)))
    }

    /// Mole's and PureMac's orphan rule by place alone: only leftovers in these Library folders can ever start selected. Checked
    /// again whenever results load, so a list saved by an older version can't pre-select anything else.
    static func mayPreselect(_ path: String) -> Bool {
        safeDirs.contains { Paths.short(path).hasPrefix("~/Library/\($0)/") }
    }
    static let notAppOwned = ["org.swift.", "jetbrains.", "com.jetbrains.", "com.install4j.", "io.qt.", "com.segment.", "org.cups.", "com.google.keystone",
                              "com.microsoft.autoupdate", "org.sparkle-project.", "com.crashlytics", "org.python.", "org.nodejs."]
    static let safeDirs: Set<String> = ["Caches", "Logs", "Saved Application State", "HTTPStorages", "WebKit"]

    /// Mole's dry-run list of exactly what an uninstall would remove. Falls back to Roomy's own match.
    static func preview(_ app: AppRecord) async -> AppRecord {
        var a = app
        let listed = await Mole.uninstallList()
        guard let m = listed.first(where: { $0.path == app.path }), let name = m.uninstall_name ?? m.name,
              let pv = await Mole.uninstallPreview(name) else { return a }
        a.related = pv.files.filter { Paths.expand($0.path) != app.path }
        a.personalKept = pv.personalKept
        a.previewedByMole = true
        return a
    }

    static func languageFiles(_ apps: [AppRecord]) async -> [CleanItem] {
        let keep: Set<String> = ["en.lproj", "base.lproj", "en_us.lproj", "english.lproj"]
        var rows: [CleanItem] = []
        for a in apps where !a.apple {
            let lp = Paths.children(a.path + "/Contents/Resources").filter { $0.hasSuffix(".lproj") && !keep.contains(Paths.name($0).lowercased()) }
            guard !lp.isEmpty else { continue }
            let total = await diskSizes(lp).values.reduce(0, +)
            if total > 1_000_000 { rows.append(CleanItem(path: a.path, name: a.name, bytes: total, count: lp.count, note: "\(lp.count) languages you don't use", review: true)) }
        }
        return rows.sorted { $0.bytes > $1.bytes }
    }

    static func universalBinaries(_ apps: [AppRecord]) async -> [CleanItem] {
        var rows: [CleanItem] = []
        for a in apps where !a.apple && !a.appStore {
            let info = NSDictionary(contentsOfFile: a.path + "/Contents/Info.plist") as? [String: Any] ?? [:]
            guard let exe = info["CFBundleExecutable"] as? String else { continue }
            let r = await Shell.run("/usr/bin/lipo", ["-detailed_info", a.path + "/Contents/MacOS/" + exe], timeout: 10)
            guard r.ok, r.output.contains("x86_64"), r.output.contains("arm64"),
                  let m = r.output.firstMatch(#"architecture x86_64[\s\S]*?size (\d+)"#), let s = Int64(m[1] ?? "") else { continue }
            rows.append(CleanItem(path: a.path, name: a.name, bytes: s, note: "Intel code this Mac never runs", review: true))
        }
        return rows.sorted { $0.bytes > $1.bytes }
    }
}
