import Foundation

/// Whole-disk map, measured with `mo analyze` (hard links and APFS clones counted once) and classified
/// so every item says whether it's macOS, an app, app data, safe to clean or your own files.
enum DiskMapEngine {
    static let minBytes: Int64 = 100_000_000

    static let depDirs: Set<String> = ["node_modules", "bower_components", ".pnpm-store", "venv", ".venv", "virtualenv", "__pycache__", ".pytest_cache",
        ".mypy_cache", ".ruff_cache", ".tox", "dist", "build", "target", ".next", ".nuxt", ".output", ".parcel-cache", ".turbo", ".vite", ".nx",
        "coverage", ".angular", ".svelte-kit", ".astro", "DerivedData", "Pods", ".build", "Carthage", ".dart_tool", ".gradle", ".terraform"]
    static let cacheNames: Set<String> = ["Caches", "Cache", "cache", ".cache", "Logs", "logs", "CachedData", "Code Cache", "GPUCache", "DawnCache",
        "Crashpad", "ShaderCache", "Service Worker", "tmp", "temp", ".npm", "_cacache", "DiagnosticReports", "Saved Application State"]
    static let systemRoots = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin"]

    static let known: [String: (String, String)] = [
        "~": ("Your home folder", "Everything that belongs to your user account."),
        "~/Library": ("Your Library", "Settings, caches and data for every app you use. Clean the caches inside, not the folder."),
        "~/Library/Caches": ("App caches", "Files apps rebuild on their own. Safe to clean while the app is closed."),
        "~/Library/Application Support": ("App data", "Databases, downloads and state apps need. Remove an app's folder by uninstalling the app."),
        "~/Library/Containers": ("Sandboxed app data", "Private storage for App Store apps. Deleting it resets or breaks the app."),
        "~/Library/Group Containers": ("Shared app data", "Data shared between an app and its extensions."),
        "~/Library/Developer": ("Developer data", "Xcode build products, simulators and device support files."),
        "~/Library/Mobile Documents": ("iCloud Drive", "Files synced with iCloud. Removing them here removes them on your other devices too."),
        "~/Library/Mail": ("Mail", "Your mailboxes and messages."), "~/Library/Messages": ("Messages", "Your message history and attachments."),
        "~/Library/Logs": ("Logs", "Diagnostic logs. Safe to clean."),
        "~/Desktop": ("Desktop", "Your files. Review before removing anything."), "~/Documents": ("Documents", "Your files. Review before removing anything."),
        "~/Downloads": ("Downloads", "Things you downloaded. Old installers and archives are usually safe to remove."),
        "~/Movies": ("Movies", "Your videos."), "~/Music": ("Music", "Your music library."), "~/Pictures": ("Pictures", "Your photos."),
        "~/.codex": ("Codex data", "Chats, history and tools for OpenAI Codex. Review it in AI Cleanup & Care."),
        "~/.claude": ("Claude Code data", "Projects, chats and settings for Claude Code."),
        "~/.lmstudio": ("LM Studio data", "Downloaded models and chats. Remove models from inside LM Studio."),
        "~/.ollama": ("Ollama data", "Downloaded models. Remove them with `ollama rm`."),
        "~/.nvm": ("Node versions (nvm)", "Installed Node.js versions. Remove old ones with `nvm uninstall`."),
        "~/.rustup": ("Rust toolchains", "Installed Rust toolchains. Remove old ones with `rustup toolchain uninstall`."),
        "~/.cargo": ("Cargo", "Rust packages and build cache."), "~/.vscode": ("VS Code extensions", "Installed extensions."),
        "~/.cache": ("Tool caches", "Caches from command-line tools. Usually safe to clean."), "~/.npm": ("npm cache", "Packages npm can fetch again."),
        "~/.docker": ("Docker settings", "Docker CLI configuration and contexts."), "~/.Trash": ("Trash", "Files you already deleted."),
        "/Applications": ("Applications", "Installed apps. Remove them with the Uninstaller so their leftovers go too."),
        "/Users/Shared": ("Shared folder", "Files every account on this Mac can see, such as virtual machines."),
        "/opt/homebrew": ("Homebrew", "Command-line tools and their data. Use `brew uninstall` or `brew cleanup`."),
        "/opt/homebrew/var": ("Homebrew service data", "Databases and service data such as PostgreSQL. Back up before removing anything."),
        "/opt/homebrew/Cellar": ("Homebrew packages", "Installed command-line tools. Remove them with `brew uninstall`."),
        "/Users/Shared/Virtual Machines.localized": ("Virtual machines", "Delete a VM from the app that made it, so its settings go too."),
        "/Library": ("System Library", "Shared settings, fonts and helpers for all accounts. Managed by macOS and your apps."),
    ]

    struct Context { var cleanPaths: [String: String] = [:]; var leftovers: Set<String> = []; var apps: [AppRecord] = [] }

    static func classify(_ path: String, name: String, parent: LensNode?, ctx: Context) -> (SafetyClass, String) {
        let sp = Paths.short(path)
        if parent?.cls == .system || (systemRoots.contains { path.hasPrefix($0) } && !path.hasPrefix("/Library/Caches")) {
            return (.system, "Part of macOS or shared system data. View only.")
        }
        if let w = ctx.cleanPaths[sp] { return (.clean, w) }
        if depDirs.contains(name) { return (.clean, "Rebuilt by its tool the next time you build or install.") }
        if cacheNames.contains(name) || (path + "/").contains("/Library/Caches/") || (path + "/").contains("/.cache/") {
            return (.clean, "Rebuilds itself when needed. Safe to clean.")
        }
        if ctx.leftovers.contains(sp) { return (.clean, "Left behind by an app that's no longer installed.") }
        if path.hasSuffix(".app") && (path.hasPrefix("/Applications/") || path.hasPrefix(HOME + "/Applications/")) {
            return (.app, "An installed app. Uninstall it to remove its data too.")
        }
        if sp == "/Applications" { return (.app, known[sp]!.1) }
        if let p = parent, p.cls == .appdata || p.cls == .app { return (.appdata, p.why) }
        if sp.hasPrefix("~/Library/Mobile Documents") { return (.user, known["~/Library/Mobile Documents"]!.1) }
        if sp.hasPrefix("~/Library") || (sp.hasPrefix("~/.") && sp.filter { $0 == "/" }.count == 1) || sp.hasPrefix("/opt/homebrew") {
            return (.appdata, known[sp]?.1 ?? "Belongs to an app or tool. Manage it from that app.")
        }
        return (.user, known[sp]?.1 ?? "Your files. Review before removing.")
    }

    static func owner(_ path: String, apps: [AppRecord]) -> String? {
        let low = path.lowercased()
        return apps.first { (!$0.bundleID.isEmpty && low.contains($0.bundleID.lowercased())) || ($0.name.count > 3 && low.contains("/" + $0.name.lowercased())) }?.name
    }

    static func node(_ e: Mole.Analysis.Entry, parent: LensNode?, ctx: Context) -> LensNode {
        let name = e.name ?? Paths.name(e.path)
        let (cls, why) = classify(e.path, name: name, parent: parent, ctx: ctx)
        let sp = Paths.short(e.path)
        let k = known[sp]
        return LensNode(name: name, title: k?.0, path: sp, bytes: e.size, cls: cls, why: (k != nil && cls != .clean) ? k!.1 : why,
                        owner: [.appdata, .clean].contains(cls) ? owner(e.path, apps: ctx.apps) : nil, isDir: e.is_dir ?? true)
    }

    /// Children of one folder, measured now. Small items are grouped into one "Smaller items" row.
    static func children(of n: LensNode, ctx: Context) async -> [LensNode] {
        guard let res = await Mole.analyze(n.path) else { return [] }
        var kids = (res.entries ?? []).filter { $0.size >= minBytes }.sorted { $0.size > $1.size }.prefix(18).map { node($0, parent: n, ctx: ctx) }
        let rest = n.bytes - kids.reduce(0) { $0 + $1.bytes }
        if !kids.isEmpty && rest > minBytes {
            kids.append(LensNode(name: "Smaller items", path: n.path, bytes: rest, cls: n.cls == .root ? .system : n.cls,
                                 why: "Everything under 100 MB in this folder, grouped.", isDir: false, other: true))
        }
        return kids
    }

    static func root(disk: DiskInfo, ctx: Context) async -> (LensNode, [Mole.Analysis.Entry]) {
        let roots = [(HOME, "Home"), ("/Applications", "Applications"), ("/Users/Shared", "Shared"), ("/opt/homebrew", "homebrew"), ("/Library", "Library")]
        var kids: [LensNode] = []
        var large: [Mole.Analysis.Entry] = []
        await withTaskGroup(of: (Int, LensNode?, [Mole.Analysis.Entry]).self) { g in
            for (i, (p, name)) in roots.enumerated() where Paths.isDir(p) {
                g.addTask {
                    guard let res = await Mole.analyze(p) else { return (i, nil, []) }
                    let size = res.total_size ?? (res.entries ?? []).reduce(0) { $0 + $1.size }
                    var n = node(.init(name: name, path: p, size: size, is_dir: true), parent: nil, ctx: ctx)
                    if p == HOME { n.cls = .user }
                    n.children = await children(of: n, ctx: ctx)
                    return (i, n, res.large_files ?? [])
                }
            }
            var tmp: [(Int, LensNode)] = []
            for await (i, n, l) in g { if let n { tmp.append((i, n)) }; large += l }
            kids = tmp.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let rest = disk.used - kids.reduce(0) { $0 + $1.bytes }
        if rest > 0 {
            kids.append(LensNode(name: "macOS & other", title: "macOS & other", path: "/", bytes: rest, cls: .system,
                                 why: "The macOS system volume, other accounts, local snapshots, virtual memory and purgeable space. macOS manages these.",
                                 isDir: false, other: true))
        }
        let root = LensNode(name: disk.name, title: disk.name, path: "/", bytes: disk.used, cls: .root,
                            why: "\(disk.name) · \(Fmt.bytes(disk.free)) free of \(Fmt.bytes(disk.total))", children: kids.sorted { $0.bytes > $1.bytes })
        return (root, large)
    }
}

extension DiskMapEngine {
    /// What "macOS & other" is made of, from the Storage scan: the system volumes, swap, macOS's own caches, other
    /// accounts and the space no app can read. View only; the folders among them can be opened.
    static func macOSParts(of n: LensNode, storage: StorageReport) -> [LensNode] {
        var out: [LensNode] = []
        func add(_ i: StorageItem, cls: SafetyClass = .system) {
            guard let b = i.bytes, b >= minBytes else { return }
            let folder = i.path.hasPrefix("/") && Paths.isDir(i.path) && !i.path.hasPrefix("/System")
            out.append(LensNode(name: i.name, title: i.name, path: folder ? i.path : "macos:" + i.name, bytes: b, cls: cls, why: i.why,
                                isDir: folder, other: !folder))
        }
        let seg = { (k: String) in storage.segments.first { $0.key == k }?.children ?? [] }
        seg("macos").forEach { add($0) }
        for i in seg("sysdata") where ["VM volume", "/private/var", "/usr/local", ""].contains(i.path) { add(i, cls: i.cls == .hidden ? .hidden : .system) }
        for i in seg("others") where i.cls == .system { add(i) }
        let rest = n.bytes - out.reduce(0) { $0 + $1.bytes }
        if rest >= minBytes {
            out.append(LensNode(name: "Not broken down", title: "Not broken down", path: "macos:rest", bytes: rest, cls: .system,
                                why: "Used space no folder accounts for: purgeable files macOS can free on its own, file-system records, and space measured differently by macOS.",
                                isDir: false, other: true))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }
}

extension SafetyClass {
    /// Only the disk root uses this; it never appears on an item.
    static let root = SafetyClass.hidden
}
