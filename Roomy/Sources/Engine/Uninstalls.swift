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

    /// The candidates that exist, with their real spelling (APFS ignores case, so ~/.config/OpenCode finds opencode).
    static func existing(_ app: App) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for c in candidates(app) {
            let parent = Paths.parent(c), want = Paths.name(c).lowercased()
            guard let real = Paths.children(parent).first(where: { Paths.name($0).lowercased() == want }), seen.insert(real.lowercased()).inserted else { continue }
            out.append(real)
        }
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
        let installedNames = Set(installed.map { AppsEngine.norm($0.name) })
        let paths = existing(app).filter { p in
            let low = p.lowercased(), home = HOME.lowercased()
            let xdg = [".config/", ".cache/", ".local/share/", ".local/state/"].contains { low.hasPrefix(home + "/" + $0) }
            if xdg && commandInstalled(Paths.name(p).lowercased()) { return false }
            // A folder named for the app that another installed app of the same name still uses.
            if !low.contains(app.id.lowercased()) && installedNames.contains(AppsEngine.norm((Paths.name(p) as NSString).deletingPathExtension)) { return false }
            return !Actions.isOffLimits(p) && !PathSafety.isCritical(p) && !Actions.safety.isProtected(p)
        }
        let sizes = await diskSizes(paths)
        return paths.compactMap { p in
            guard let b = sizes[p], b > 0 else { return nil }
            let dir = p.hasPrefix(HOME + "/Library/") ? String(p.dropFirst(HOME.count + 9).split(separator: "/").first ?? "") : "Home"
            let volatile = Self.volatile.contains(dir)
            let note = volatile ? "\(dir) · rebuilds if you install \(app.name) again"
                                : "\(dir == "Home" ? "Settings and data" : dir) · may hold \(app.name)'s settings or data, so you choose"
            return CleanItem(path: Paths.short(p), name: "\(app.name) (uninstalled)", bytes: b, note: note, review: !volatile)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Where macOS still knows an app with this ID, ignoring copies in the Trash.
    static func installedOutsideTrash(_ id: String) -> URL? {
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), !u.path.contains("/.Trash/") else { return nil }
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
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

    func start(onFound: @escaping ([CleanItem]) -> Void, onOpen: @escaping () -> Void) {
        guard sources.isEmpty, !Demo.on else { return }
        self.onFound = onFound; self.onOpen = onOpen
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
