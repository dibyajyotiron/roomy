import Foundation
import AppKit
import UserNotifications
import MoleCore

/// Leftovers of apps that were uninstalled, found the way Mole finds them: from the app's own name and bundle ID, never
/// from a list of known apps. Roomy remembers the apps it has seen. When one disappears (dragged to the Trash, removed
/// by an uninstaller or by Homebrew), the places that app's name and ID point to are checked, and what's there is a
/// leftover. While Roomy runs, the Trash and the Applications folders are watched so this happens the moment the app
/// goes; a scan catches anything removed while Roomy was closed.
enum LeftoverFinder {
    struct App: Codable, Hashable { var id: String; var name: String }

    /// Library folders whose contents rebuild or are only state, so a gone app's copies start selected.
    static let volatile = ["Caches", "Logs", "Saved Application State", "HTTPStorages", "WebKit", "Cookies"]

    /// Every place the app's name and bundle ID point to (Mole's find_app_files, user level).
    static func candidates(_ app: App) -> [String] {
        let L = HOME + "/Library/"
        var out: [String] = []
        if app.id.contains(regex: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+)+$"#) {
            let id = app.id
            out += ["Application Support/\(id)", "Caches/\(id)", "Logs/\(id)", "Preferences/\(id).plist", "Saved Application State/\(id).savedState",
                    "Containers/\(id)", "WebKit/\(id)", "HTTPStorages/\(id)", "HTTPStorages/\(id).binarycookies", "Cookies/\(id).binarycookies",
                    "Application Scripts/\(id)", "Autosave Information/\(id)"].map { L + $0 }
            out += Paths.children(L + "Preferences/ByHost").filter { Paths.name($0).lowercased().hasPrefix(id.lowercased() + ".") }
        }
        // The display name and its spellings: "Maestro Studio", "MaestroStudio", "Maestro-Studio", "Maestro_Studio",
        // and without a channel suffix ("Zed Nightly" → "Zed").
        var names = [app.name]
        if app.name.contains(" ") {
            names += [app.name.replacingOccurrences(of: " ", with: ""), app.name.replacingOccurrences(of: " ", with: "-"), app.name.replacingOccurrences(of: " ", with: "_")]
        }
        if let m = app.name.firstMatch(#"^(.+?)\s+(Nightly|Beta|Alpha|Dev|Canary|Preview|Insider|Edge|Stable|Release|RC|LTS|Developer Edition|Technology Preview)$"#), let base = m[1] {
            names.append(base)
        }
        for n in Set(names) where n.count >= 3 {
            out += ["Application Support/\(n)", "Caches/\(n)", "Logs/\(n)", "Preferences/\(n).plist", "Saved Application State/\(n).savedState"].map { L + $0 }
            // Where command-line style apps keep data. Never a top-level ~/.<name>: names like "Local" or "Docker"
            // would hit shared folders.
            for root in [".config", ".cache", ".local/share", ".local/state"] { out.append(HOME + "/" + root + "/" + n.lowercased()) }
        }
        return out
    }

    /// macOS's hidden per-user cache and temp folders (/private/var/folders/…/C and …/T), where apps and their helpers
    /// keep caches that Finder never shows.
    static let darwinDirs: [String] = [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap { name in
        let n = confstr(name, nil, 0)
        guard n > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: n)
        confstr(name, &buf, n)
        let p = (String(cString: buf) as NSString).resolvingSymlinksInPath
        return p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    /// Places named for the app's bundle ID or one of its helpers' (`<id>.helper`, `<id>.ShipIt`…), the way Mole
    /// finds them: Library folders, the hidden per-user caches, and the app's recent-documents list.
    static func related(_ app: App) -> [String] {
        let id = app.id.lowercased()
        guard app.id.contains(regex: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+)+$"#), id.split(separator: ".").count >= 2 else { return [] }
        let L = HOME + "/Library/"
        let dirs = ["Caches", "Logs", "HTTPStorages", "WebKit", "Saved Application State", "Preferences", "Containers",
                    "Application Scripts", "Cookies", "Application Support"].map { L + $0 } + darwinDirs
        var out: [String] = []
        for d in dirs {
            for c in Paths.children(d) {
                let stem = stem(Paths.name(c))
                if stem == id || stem.hasPrefix(id + ".") { out.append(c) }
            }
        }
        let recent = L + "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/"
        out += Paths.children(recent).filter { stem(Paths.name($0)) == id }
        return out
    }

    /// A Library entry's name without the endings macOS adds: "io.app.helper.plist" → "io.app.helper".
    static func stem(_ name: String) -> String {
        var n = name.lowercased()
        for ext in [".plist", ".savedstate", ".binarycookies", ".sfl4", ".sfl3", ".sfl2"] where n.hasSuffix(ext) { n.removeLast(ext.count) }
        return n
    }

    /// The candidates that exist, with their real spelling (APFS ignores case, so ~/.config/OpenCode finds opencode).
    static func existing(_ app: App) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for c in candidates(app) {
            let parent = Paths.parent(c), want = Paths.name(c).lowercased()
            guard let real = Paths.children(parent).first(where: { Paths.name($0).lowercased() == want }), seen.insert(real.lowercased()).inserted else { continue }
            out.append(real)
        }
        for r in related(app) where seen.insert(r.lowercased()).inserted { out.append(r) }
        return out
    }

    /// Folders a same-named command-line tool still uses stay: removing OpenCode.app must not take the opencode
    /// command's settings and sign-ins with it. A tool counts as installed when its command is in any usual place.
    static func commandInstalled(_ name: String) -> Bool {
        let dirs = Shell.searchPath.split(separator: ":").map(String.init)
            + ["/.local/bin", "/.cargo/bin", "/.bun/bin", "/go/bin", "/.deno/bin", "/.volta/bin", "/.npm-global/bin", "/bin", "/.\(name)/bin"].map { HOME + $0 }
            + Paths.children(HOME + "/.nvm/versions/node").map { $0 + "/bin" }
        return dirs.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
    }

    /// What `app` left behind, given the apps installed now. Nothing when the app (or one sharing its ID) is installed.
    static func leftovers(of app: App, installed: [App]) async -> [CleanItem] {
        let installedIDs = Set(installed.map { $0.id.lowercased() })
        guard !installedIDs.contains(app.id.lowercased()), installedOutsideTrash(app.id) == nil else { return [] }
        return await items(of: app, installed: installed)
    }

    /// What's on disk under the app's name and IDs, minus anything an installed app or command still uses.
    static func items(of app: App, installed: [App]) async -> [CleanItem] {
        let installedIDs = Set(installed.map { $0.id.lowercased() })
        let installedNames = Set(installed.map { AppsEngine.norm($0.name) })
        let paths = existing(app).filter { p in
            let low = p.lowercased(), home = HOME.lowercased()
            // Named for an installed app's ID (com.google.Chrome.canary when Chrome Canary is still here): that app's.
            let st = stem(Paths.name(p))
            if installedIDs.contains(where: { st == $0 || st.hasPrefix($0 + ".") }) { return false }
            let xdg = [".config/", ".cache/", ".local/share/", ".local/state/"].contains { low.hasPrefix(home + "/" + $0) }
            if xdg && commandInstalled(Paths.name(p).lowercased()) { return false }
            // A folder named for the app that another installed app of the same name still uses.
            if !low.contains(app.id.lowercased()) && installedNames.contains(AppsEngine.norm((Paths.name(p) as NSString).deletingPathExtension)) { return false }
            return !Actions.isOffLimits(p) && !PathSafety.isCritical(p) && !Actions.safety.isProtected(p)
        }
        let sizes = await diskSizes(paths)
        return paths.compactMap { p in
            // Empty folders count too: they're still clutter the app left (Mole lists them as well).
            let b = sizes[p] ?? 0
            guard Paths.exists(p) else { return nil }
            let hidden = darwinDirs.contains { p.hasPrefix($0 + "/") }
            let recent = p.contains("/com.apple.sharedfilelist/")
            let dir = hidden ? "Hidden caches" : recent ? "Recent documents list"
                : p.hasPrefix(HOME + "/Library/") ? String(p.dropFirst(HOME.count + 9).split(separator: "/").first ?? "") : "Home"
            let volatile = hidden || recent || Self.volatile.contains(dir)
            let note = volatile ? "\(dir) · rebuilds if you install \(app.name) again"
                                : "\(dir == "Home" ? "Settings and data" : dir) · may hold \(app.name)'s settings or data, so you choose"
            return CleanItem(path: Paths.short(p), name: "\(app.name) (uninstalled)", bytes: b, note: note, review: !volatile)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Testing aid: `Roomy -RoomyLeftoverProbe <bundle id>` prints what Roomy would list if that app were uninstalled,
    /// and whether it counts as installed now, then quits. It only reads; nothing is removed.
    nonisolated static func probe(_ id: String) -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            let name = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).first.map { ($0.lastPathComponent as NSString).deletingPathExtension } ?? id
            let app = App(id: id, name: name)
            func say(_ s: String) { FileHandle.standardError.write(Data(("leftover probe: " + s + "\n").utf8)) }
            say("\(name) (\(id)) installed now: \(installedOutsideTrash(id)?.path ?? "no")")
            let others = installedNow().filter { $0.id.lowercased() != id.lowercased() }
            for i in await items(of: app, installed: others) { say("\(Fmt.bytes(i.bytes))\t\(i.review ? "you choose" : "selected")\t\(i.path)\t\(i.note)") }
        }
        done.wait()
        exit(0)
    }

    /// A copy of the app that's still installed: one in an Applications folder (not in the Trash). Copies an app keeps
    /// inside its own data, like an updater's spare copy in Application Support, don't count as installed.
    static func installedOutsideTrash(_ id: String) -> URL? {
        let roots = ["/Applications/", HOME + "/Applications/"]
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).first { u in
            let p = u.resolvingSymlinksInPath().path
            return roots.contains { p.hasPrefix($0) } && !p.contains("/.Trash/") && FileManager.default.fileExists(atPath: p)
        }
    }

    /// The apps in /Applications and ~/Applications right now, by name and bundle ID.
    static func installedNow() -> [App] {
        AppsEngine.appBundles().compactMap { a in
            guard let info = NSDictionary(contentsOfFile: a + "/Contents/Info.plist") as? [String: Any], let id = info["CFBundleIdentifier"] as? String else { return nil }
            return App(id: id, name: (Paths.name(a) as NSString).deletingPathExtension)
        }
    }

    // MARK: memory

    private static let knownKey = "knownApps", goneKey = "uninstalledApps"

    /// Apps uninstalled whose leftovers haven't been dealt with yet.
    static var uninstalled: [App] {
        get { (UserDefaults.standard.data(forKey: goneKey)).flatMap { try? JSONDecoder().decode([App].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: goneKey) }
    }

    /// Compares the apps installed now with the ones seen before and returns the ones that went. Never reports
    /// Apple's apps or Roomy itself. The first call only remembers.
    static func noteInstalled(_ now: [App]) -> [App] {
        let d = UserDefaults.standard
        let before = (d.data(forKey: knownKey)).flatMap { try? JSONDecoder().decode([App].self, from: $0) }
        d.set(try? JSONEncoder().encode(now), forKey: knownKey)
        guard let before else { return [] }
        let ids = Set(now.map { $0.id.lowercased() })
        let gone = before.filter { !ids.contains($0.id.lowercased()) && !$0.id.hasPrefix("com.apple.") && !$0.id.hasPrefix("app.roomy") && installedOutsideTrash($0.id) == nil }
        if !gone.isEmpty { uninstalled = Array(Set(uninstalled + gone)) }
        return gone
    }

    /// Leftovers of every remembered uninstalled app. Apps with nothing left (or installed again) are forgotten.
    static func all(installed: [App]) async -> [CleanItem] {
        var keep: [App] = [], items: [CleanItem] = []
        for a in uninstalled {
            let l = await leftovers(of: a, installed: installed)
            if !l.isEmpty { keep.append(a); items += l }
        }
        uninstalled = keep
        return items
    }
}

/// Watches the Trash and the Applications folders while Roomy runs. When an app goes, its leftovers are found at once,
/// added to Leftovers, and a notification says how much it left behind.
@MainActor
final class UninstallWatcher: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UninstallWatcher()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?
    private var onFound: (([CleanItem]) -> Void)?
    private var onOpen: (() -> Void)?
    private var onReturned: (([LeftoverFinder.App]) -> Void)?

    func start(onFound: @escaping ([CleanItem]) -> Void, onReturned: @escaping ([LeftoverFinder.App]) -> Void, onOpen: @escaping () -> Void) {
        guard sources.isEmpty, !Demo.on else { return }
        self.onFound = onFound; self.onOpen = onOpen; self.onReturned = onReturned
        UNUserNotificationCenter.current().delegate = self
        _ = LeftoverFinder.noteInstalled(LeftoverFinder.installedNow())
        for dir in [HOME + "/.Trash", "/Applications", HOME + "/Applications"] {
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            s.setEventHandler { [weak self] in self?.changed() }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources.append(s)
        }
    }

    /// Waits for things to settle (an app update replaces the bundle in a moment), then compares.
    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            let now = LeftoverFinder.installedNow()
            let gone = LeftoverFinder.noteInstalled(now)
            // Put back from the Trash (or installed again): what it left isn't left over any more.
            let ids = Set(now.map { $0.id.lowercased() })
            let back = LeftoverFinder.uninstalled.filter { ids.contains($0.id.lowercased()) || LeftoverFinder.installedOutsideTrash($0.id) != nil }
            if !back.isEmpty {
                LeftoverFinder.uninstalled.removeAll { back.contains($0) }
                self?.onReturned?(back)
            }
            guard !gone.isEmpty else { return }
            for app in gone {
                let items = await LeftoverFinder.leftovers(of: app, installed: now)
                guard !items.isEmpty else { continue }
                self?.onFound?(items)
                self?.notify(app, bytes: items.reduce(0) { $0 + $1.bytes })
            }
        }
    }

    private func notify(_ app: LeftoverFinder.App, bytes: Int64) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = "\(app.name) left \(Fmt.bytes(bytes)) behind"
            n.body = "Its caches, settings and data are still on your Mac. Review them in Roomy's Leftovers."
            c.add(UNNotificationRequest(identifier: "leftovers." + app.id, content: n, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { onOpen?() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
