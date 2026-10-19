import Foundation

/// The categories System Settings › Storage shows, each measured with a stated definition.
/// System Data is split into the parts that can be named; what macOS hides from apps is its own segment.
enum StorageEngine {
    static func apfsVolumes() async -> [String: Int64] {
        let out = await Shell.run("/usr/sbin/diskutil", ["apfs", "list"], timeout: 30).output
        var roles: [String: Int64] = [:], cur: String?
        for line in out.split(separator: "\n").map(String.init) {
            if let m = line.firstMatch(#"\(Role\):\s+\S+ \((\w+)\)"#) { cur = m[1] }
            if let m = line.firstMatch(#"Capacity Consumed:\s+(\d+) B"#), let c = cur, let b = Int64(m[1] ?? "") { roles[c, default: 0] += b; cur = nil }
        }
        return roles
    }

    static func scan(disk: DiskInfo, lens: LensNode?, apps: [AppRecord]) async -> StorageReport {
        let roots = Dictionary((lens?.children ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let home = roots["Home"]
        let homeKids = Dictionary((home?.children ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let roles = await apfsVolumes()
        var segs: [StorageSegment] = []

        // Applications
        let userApps = diskSize("~/Applications")
        var appKids = apps.prefix(40).map { a in
            StorageItem(name: a.name, path: a.path, bytes: a.bytes, cls: a.apple ? .system : .app,
                        why: a.apple ? "Comes with macOS." : a.appStore ? "From the App Store." : "Installed by you.",
                        action: a.apple ? nil : .uninstall(appPath: a.path))
        }
        // System Settings counts an app together with the data it keeps in Application Support. Checked on a real Mac:
        // bundles 25.0 GB + Application Support 28.2 GB = 53.2 GB against System Settings' 53.99 GB, while adding the
        // 5.8 GB of sandbox containers overshot. Containers therefore stay in System Data, as they do in System Settings.
        let bundles = (roots["Applications"]?.bytes ?? apps.reduce(0) { $0 + $1.bytes }) + userApps
        let libKids = Dictionary((homeKids["Library"]?.children ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let cloudDB = diskSize("~/Library/Application Support/CloudDocs")   // iCloud Drive's local database: System Settings counts it as iCloud
        let support = max(0, (libKids["Application Support"]?.bytes ?? diskSize("~/Library/Application Support")) - cloudDB)
        let sharedSupport = diskSize("/Library/Application Support")
        let rest = bundles - appKids.reduce(0) { $0 + ($1.bytes ?? 0) }
        if rest > 0 { appKids.append(StorageItem(name: "Other apps", path: "/Applications", bytes: rest, cls: .app, why: "Smaller apps and helper tools.")) }
        appKids.append(StorageItem(name: "Apps' data in Application Support", path: "~/Library/Application Support", bytes: support, cls: .appdata,
                                   why: "Each app's databases, downloads and settings. Remove an app with the Uninstaller to remove its data too.", action: .open(route: "uninstaller")))
        if sharedSupport > 0 {
            appKids.append(StorageItem(name: "Data shared by all accounts", path: "/Library/Application Support", bytes: sharedSupport, cls: .appdata,
                                       why: "Support files apps installed for every account on this Mac."))
        }
        let appTotal = bundles + support + sharedSupport
        segs.append(StorageSegment(key: "apps", name: "Applications", bytes: appTotal,
                                   what: "Your apps and the data each one keeps in Application Support: bundles in /Applications and ~/Applications plus their databases, downloads and settings.",
                                   versusApple: "Counted the way System Settings counts it: an app's data belongs to the app.",
                                   children: appKids.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }))

        // Documents
        var docs: [StorageItem] = []
        for n in ["Desktop", "Documents", "Downloads", "Movies", "Music"] {
            let b = homeKids[n]?.bytes ?? diskSize("~/" + n)
            if b > 0 { docs.append(StorageItem(name: n, path: "~/" + n, bytes: b, cls: .user, why: "Your files. Removing them moves them to the Trash.", action: .diskMap)) }
        }
        for c in home?.children ?? [] where !c.name.hasPrefix(".") && !["Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Applications"].contains(c.name) && c.cls == .user {
            docs.append(StorageItem(name: c.other ? "Other files in Home" : c.display, path: c.path, bytes: c.bytes, cls: .user,
                                    why: c.other ? "Smaller files and folders in your home folder." : "A folder you made in your home folder.", action: c.other ? nil : .diskMap))
        }
        // iCloud: System Settings' iCloud Drive is the iCloud Drive folder plus the app folders shown in it ("iCloud~…").
        // Apps' private iCloud data (team-ID containers, like a WhatsApp backup) counts under Documents there.
        let md = Paths.expand("~/Library/Mobile Documents")
        let mdKids = Paths.children(md).filter { !Paths.name($0).hasPrefix(".") }
        let mdSizes = await diskSizes(mdKids)
        var icloud: [StorageItem] = []
        for e in mdKids {
            guard let b = mdSizes[e], b >= 1_000_000 else { continue }
            let n = Paths.name(e), app = String(n.split(separator: "~").last ?? "")
            if n == "com~apple~CloudDocs" {
                icloud.append(StorageItem(name: "iCloud Drive folder", path: Paths.short(e), bytes: b, cls: .user,
                                          why: "Files in iCloud Drive that are downloaded to this Mac. Removing the download keeps them in iCloud.", action: .evict))
            } else if n.hasPrefix("iCloud~") {
                icloud.append(StorageItem(name: "\(app) folder in iCloud Drive", path: Paths.short(e), bytes: b, cls: .user, why: "Documents \(app) keeps in your iCloud Drive."))
            } else {
                docs.append(StorageItem(name: "\(app) iCloud data", path: Paths.short(e), bytes: b, cls: .appdata,
                                        why: "Data \(app) syncs with iCloud, like a chat backup. Manage it from \(app); System Settings counts it as Documents."))
            }
        }
        if cloudDB > 0 { icloud.append(StorageItem(name: "iCloud Drive's local database", path: "~/Library/Application Support/CloudDocs", bytes: cloudDB, cls: .system, why: "What iCloud keeps on this Mac to track your files and their sync state. macOS manages it.")) }
        // Sandboxed apps' containers: System Settings lists them under Documents › Containers.
        for (dir, label) in [("~/Library/Containers", "Sandboxed apps' containers"), ("~/Library/Daemon Containers", "System services' containers")] {
            let b = diskSize(dir)
            if b > 0 { docs.append(StorageItem(name: label, path: dir, bytes: b, cls: .appdata, why: "Private storage apps and services keep in their sandbox. System Settings counts it under Documents › Containers. Deleting it resets or breaks the app.")) }
        }
        let trash = diskSize("~/.Trash")
        if trash > 0 { docs.append(StorageItem(name: "Trash", path: "~/.Trash", bytes: trash, cls: .user, why: "Files in the Trash still use space until the Trash is emptied.")) }
        segs.append(StorageSegment(key: "docs", name: "Documents", bytes: docs.reduce(0) { $0 + ($1.bytes ?? 0) },
                                   what: "Your files: Desktop, Documents, Downloads, Movies, Music, folders you made in Home, the Trash, apps' private iCloud data and apps' sandbox containers.",
                                   versusApple: FullDiskAccess.granted ? "Counted the way System Settings counts Documents." : "Desktop, Documents and Downloads can only be measured with Full Disk Access, so this is lower than System Settings until it's allowed.",
                                   children: docs.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }))
        segs.append(StorageSegment(key: "icloud", name: "iCloud Drive", bytes: icloud.reduce(0) { $0 + ($1.bytes ?? 0) },
                                   what: "Files from iCloud Drive that are downloaded to this Mac.",
                                   versusApple: "Counted the way System Settings counts it: the iCloud Drive folder and the app folders in it.",
                                   children: icloud.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }))

        // Developer: what System Settings lists as Developer (Command Line Tools, SDKs, Xcode's data).
        let devSys = diskSize("/Library/Developer"), devUser = diskSize("~/Library/Developer")
        var dev: [StorageItem] = []
        if devSys > 0 { dev.append(StorageItem(name: "Command Line Tools and SDKs", path: "/Library/Developer", bytes: devSys, cls: .system, why: "Compilers and SDKs that Homebrew, Xcode and other tools use. Remove them with xcode-select if you no longer develop.")) }
        if devUser > 0 { dev.append(StorageItem(name: "Xcode data", path: "~/Library/Developer", bytes: devUser, cls: .appdata, why: "Simulators, build products and device support files.", action: .open(route: "developer"))) }
        if devSys + devUser > 0 {
            segs.append(StorageSegment(key: "developer", name: "Developer", bytes: devSys + devUser, what: "Developer tools and Xcode's data.", children: dev))
        }

        // Mail, Messages, Photos, Podcasts: private unless Roomy has Full Disk Access
        var hiddenApps: [String] = []
        for (key, name, path, what) in [("mail", "Mail", "~/Library/Mail", "Mail's messages and attachments."),
                                        ("messages", "Messages", "~/Library/Messages/Attachments", "Photos, videos and files people sent you in Messages."),
                                        ("photos", "Photos", "~/Pictures/Photos Library.photoslibrary", "Your Photos library."),
                                        ("podcasts", "Podcasts", "~/Library/Group Containers/243LU875E5.groups.com.apple.podcasts", "Downloaded episodes.")] where Paths.exists(path) {
            if (try? FileManager.default.contentsOfDirectory(atPath: Paths.expand(path))) != nil {
                let b = diskSize(path)
                segs.append(StorageSegment(key: key, name: name, bytes: b, what: what,
                                           children: [StorageItem(name: name, path: path, bytes: b, cls: .user, why: what, action: .openApp(name: name))]))
            } else {
                hiddenApps.append(name)
                segs.append(StorageSegment(key: key, name: name, bytes: nil, what: what + " macOS only shows its size to apps with Full Disk Access.", needsAccess: true))
            }
        }

        // Other Users & Shared
        var others: [StorageItem] = []
        for c in roots["Shared"]?.children ?? [] {
            for g in (c.name.hasPrefix("Virtual Machines") ? (c.children ?? [c]) : [c]) {
                let vm = g.name.hasSuffix(".vmwarevm") || g.name.hasSuffix(".pvm") || g.name.hasSuffix(".utm")
                others.append(StorageItem(name: g.display, path: g.path, bytes: g.bytes, cls: .user,
                                          why: vm ? "A virtual machine in the shared folder. Delete it from the app that made it if you no longer use it." : "Files in /Users/Shared, visible to every account.",
                                          action: vm ? .openApp(name: g.name.hasSuffix(".vmwarevm") ? "VMware Fusion" : "its app") : .diskMap))
            }
        }
        var hiddenUsers: [String] = []
        for u in Paths.children("/Users").map(Paths.name).sorted() where !["Shared", ".localized"].contains(u) && "/Users/\(u)" != HOME && !u.hasPrefix(".") && Paths.isDir("/Users/" + u) {
            let p = "/Users/" + u
            let r = await Shell.run("/usr/bin/dscl", [".", "-read", p, "RealName"], timeout: 10)
            let real = r.output.split(separator: "\n").dropFirst().first.map { String($0).trimmed }.flatMap { $0.isEmpty ? nil : $0 } ?? u
            let b = (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil ? diskSize(p) : 0
            if r.ok && b < 1_000_000 {
                hiddenUsers.append(real)
                others.append(StorageItem(name: "\(real)'s account", path: p, bytes: nil, cls: .system,
                                          why: "Another account on this Mac. macOS hides what's inside; only that person, or an admin, can see it."))
            } else if r.ok {
                others.append(StorageItem(name: "\(real)'s account", path: p, bytes: b, cls: .system,
                                          why: "Another account on this Mac. Only that person should remove their files: sign in as them, or remove the account in System Settings › Users & Groups."))
            } else if b > 1_000_000 {
                others.append(StorageItem(name: u, path: p, bytes: b, cls: .user, why: "A folder in /Users that isn't an account. Check it before removing.", action: .diskMap))
            }
        }
        segs.append(StorageSegment(key: "others", name: "Other Users & Shared", bytes: others.reduce(0) { $0 + ($1.bytes ?? 0) },
                                   what: "The shared folder, other accounts and anything else in /Users that isn't your home folder.",
                                   versusApple: "Apple includes the other accounts' sizes, which macOS doesn't show to apps.",
                                   children: others.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }))

        // macOS
        let mac = [StorageItem(name: "Sealed system volume", path: "/System", bytes: roles["System"] ?? 0, cls: .system, why: "macOS itself. It's read-only and signed by Apple; nothing can change it."),
                   StorageItem(name: "Preboot", path: "Preboot volume", bytes: roles["Preboot"] ?? 0, cls: .system, why: "What your Mac needs to start up, including the security policy."),
                   StorageItem(name: "Recovery", path: "Recovery volume", bytes: roles["Recovery"] ?? 0, cls: .system, why: "macOS Recovery, used to repair or reinstall macOS."),
                   StorageItem(name: "System extras and updates", path: "/System/Volumes/Data/System", bytes: diskSize("/System/Volumes/Data/System"), cls: .system,
                               why: "Rapid Security Responses, Safari and other parts of macOS that update separately.")]
        segs.append(StorageSegment(key: "macos", name: "macOS", bytes: mac.reduce(0) { $0 + ($1.bytes ?? 0) },
                                   what: "macOS itself. Every part is locked: the system is sealed and signed, and removing anything would stop your Mac from starting.",
                                   locked: true, children: mac))

        // System Data: named parts, then what's hidden
        var sd = [StorageItem(name: "Swap and sleep image", path: "VM volume", bytes: roles["VM"] ?? 0, cls: .system,
                              why: "Memory macOS writes to disk when RAM is full, plus the sleep image. macOS manages it; it shrinks after a restart.")]
        // Every folder in ~/Library, measured directly (the disk map doesn't always break ~/Library down, and anything
        // left unmeasured would wrongly land in "not visible"). Folders that belong to another category are skipped.
        let libPath = Paths.expand("~/Library")
        let skip: Set<String> = ["Mobile Documents", "Application Support", "Mail", "Developer", "Containers", "Daemon Containers"]
        let libDirs = Paths.children(libPath).filter { !skip.contains(Paths.name($0)) }
        let libSizes = await diskSizes(libDirs)
        let podcasts = segs.first { $0.key == "podcasts" }?.bytes ?? 0
        let explain: [String: (String, SafetyClass, String?)] = [
            "Caches": ("App caches. They rebuild themselves; clear them safely in User Cache.", .clean, "userCache"),
            "Containers": ("Private storage for App Store and other sandboxed apps. Deleting it resets or breaks the app.", .appdata, "uninstaller"),
            "Group Containers": ("Data apps share with their extensions and helpers. Virtual machine disks (OrbStack, Docker) often live here.", .appdata, nil),
            "Developer": ("Xcode, simulators and device support files. Clean them in Developer.", .appdata, "developer"),
            "Logs": ("Apps' log files. Old ones are cleared in System Junk.", .clean, "systemJunk"),
            "Messages": ("Messages' history database. Attachments are counted under Messages.", .user, nil),
        ]
        var smaller: Int64 = 0
        for d in libDirs {
            var b = libSizes[d] ?? 0
            let n = Paths.name(d)
            if n == "Group Containers" { b = max(0, b - podcasts) }   // Podcasts' downloads are counted under Podcasts
            if n == "Messages" { b = max(0, b - (segs.first { $0.key == "messages" }?.bytes ?? 0)) }   // attachments are counted under Messages
            guard b > 0 else { continue }
            if let e = explain[n], b >= 50_000_000 {
                sd.append(StorageItem(name: "~/Library/\(n)", path: "~/Library/" + n, bytes: b, cls: e.1, why: e.0, action: e.2.map { .open(route: $0) }))
            } else if b >= 500_000_000 {
                sd.append(StorageItem(name: "~/Library/\(n)", path: "~/Library/" + n, bytes: b, cls: .appdata, why: "A folder apps keep in your Library.", action: .diskMap))
            } else { smaller += b }
        }
        if smaller > 0 { sd.append(StorageItem(name: "~/Library, smaller folders", path: "~/Library", bytes: smaller, cls: .appdata, why: "Preferences, saved app states, keychains and other small folders.")) }
        let dots = (home?.children ?? []).filter { $0.name.hasPrefix(".") && $0.name != ".Trash" }
        if !dots.isEmpty {
            sd.append(StorageItem(name: "Developer and AI tool data in Home", path: "~/.*", bytes: dots.reduce(0) { $0 + $1.bytes }, cls: .appdata,
                                  why: "Hidden folders tools keep in your home folder, like ~/.codex, ~/.nvm and ~/.rustup. Apple counts them as System Data.",
                                  action: .open(route: "aiCare"),
                                  children: dots.map { StorageItem(name: $0.display, path: $0.path, bytes: $0.bytes, cls: $0.cls, why: $0.why) }))
        }
        if let hb = roots["homebrew"] {
            sd.append(StorageItem(name: "Homebrew", path: "/opt/homebrew", bytes: hb.bytes, cls: .appdata, why: "Command-line tools and their data. Clean old versions in Developer.", action: .open(route: "developer")))
        }
        let pv = diskSize("/private/var"), ul = diskSize("/usr/local")
        sd.append(StorageItem(name: "System caches, logs and databases", path: "/private/var", bytes: pv, cls: .system,
                              why: "macOS's own caches, logs and temporary files. Safe parts are cleared in System Junk.", action: .open(route: "systemJunk")))
        if ul > 0 { sd.append(StorageItem(name: "Shared command-line tools", path: "/usr/local", bytes: ul, cls: .system, why: "Tools installed outside Homebrew.")) }
        if let l = roots["Library"] { sd.append(StorageItem(name: "System Library", path: "/Library", bytes: max(0, l.bytes - sharedSupport - devSys), cls: .system, why: "Fonts, drivers and system support files every account uses.")) }
        let named = sd.reduce(0) { $0 + ($1.bytes ?? 0) }
        let known = segs.reduce(0) { $0 + ($1.bytes ?? 0) } + named
        let hidden = max(0, disk.used - known)
        let fda = FullDiskAccess.granted
        let snapshots = await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 15).output
            .split(separator: "\n").filter { $0.contains("com.apple.") }.count
        let accounts = hiddenUsers.map { "\($0)'s account" }
        if fda {
            // With Full Disk Access, what's left is space no app may read: other accounts, the index, admin-only folders.
            let parts = accounts + ["Spotlight's search index and file-system records", "system folders only an administrator can read"]
                + (snapshots > 0 ? ["\(snapshots) local Time Machine snapshot\(snapshots == 1 ? "" : "s")"] : [])
            sd.append(StorageItem(name: "Only macOS can see this", path: "", bytes: hidden, cls: .hidden,
                                  why: "Space no app can read, even with Full Disk Access: " + parts.joined(separator: ", ") + "."
                                      + (snapshots == 0 ? " There are no local Time Machine snapshots on this Mac." : " Snapshots are removed by macOS when space runs low.")))
        } else {
            let reasons = [hiddenApps.isEmpty ? nil : hiddenApps.joined(separator: ", ")] + accounts.map { Optional($0) }
                + ["sandboxed apps' data", "Spotlight's index", "file-system records"]
            sd.append(StorageItem(name: "Not visible without Full Disk Access", path: "", bytes: hidden, cls: .hidden,
                                  why: "Space macOS doesn't show to apps yet: " + reasons.compactMap { $0 }.joined(separator: ", ") + ". Allow Full Disk Access, then scan again.",
                                  action: .grantAccess))
        }
        segs.append(StorageSegment(key: "sysdata", name: "System Data", bytes: named + hidden,
                                   what: "Everything that isn't an app, a document or another category: developer tools and their data, caches, logs, swap, virtual machine disks and macOS's own files. System Settings shows it as one number; here each part is named, with where to clean it.",
                                   versusApple: "System Settings also parks space it hasn't finished calculating here, so its System Data can look bigger right after it opens.",
                                   children: sd.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }))
        return StorageReport(segments: segs, hiddenBytes: hidden, measuredWithAccess: fda)
    }
}
