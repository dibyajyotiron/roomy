import Foundation
import SwiftUI

enum Route: String, CaseIterable, Identifiable, Codable {
    case care, systemJunk, userCache, developer, artifacts, aiCare, mail, trash, systemData
    case uninstaller, updates, leftovers, startup, slimming
    case lens, large, dups, photos, installers
    case protection, status, maintenance, history
    case storage, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .care: "Checkup"; case .systemJunk: "System Junk"; case .userCache: "User Cache"; case .developer: "Developer"
        case .artifacts: "Project Artifacts"; case .aiCare: "AI Cleanup & Care"; case .mail: "Mail Attachments"; case .trash: "Trash"; case .systemData: "System Data"
        case .uninstaller: "Uninstaller"; case .updates: "Updates"; case .leftovers: "Leftovers"; case .startup: "Startup Items"; case .slimming: "App Slimming"
        case .lens: "Disk Map"; case .large: "Large & Old Files"; case .dups: "Duplicates"; case .photos: "Similar Photos"; case .installers: "Installers"
        case .protection: "Protection"; case .status: "Activity"; case .maintenance: "Maintenance"; case .history: "History"
        case .storage: "Storage"; case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .care: "house"; case .systemJunk: "trash"; case .userCache: "square.stack.3d.up"; case .developer: "curlybraces"
        case .artifacts: "shippingbox"; case .aiCare: "cpu"; case .mail: "envelope"; case .trash: "trash.circle"; case .systemData: "internaldrive"
        case .uninstaller: "square.grid.2x2"; case .updates: "arrow.triangle.2.circlepath"; case .leftovers: "puzzlepiece.extension"
        case .startup: "power"; case .slimming: "scissors"
        case .lens: "circle.hexagongrid"; case .large: "doc.richtext"; case .dups: "doc.on.doc"; case .photos: "photo.on.rectangle.angled"
        case .installers: "shippingbox.and.arrow.backward"
        case .protection: "checkmark.shield"; case .status: "waveform.path.ecg"; case .maintenance: "wrench.and.screwdriver"
        case .history: "clock.arrow.circlepath"; case .storage: "internaldrive"; case .settings: "gearshape"
        }
    }

    /// Cleanup categories each screen lists.
    var categories: [String] {
        switch self {
        case .systemJunk: ["systemJunk"]; case .userCache: ["userCache", "aiApps"]
        case .developer: ["xcodeJunk", "brewCache", "nodeCache", "devTools", "dockerCache"]
        case .mail: ["mailAttachments"]; case .trash: ["trashBins"]; case .systemData: ["systemData"]
        default: []
        }
    }

    static let sections: [(String?, [Route])] = [
        (nil, [.care]),
        ("Cleanup", [.systemJunk, .userCache, .developer, .artifacts, .aiCare, .mail, .trash, .systemData]),
        ("Applications", [.uninstaller, .updates, .leftovers, .startup, .slimming]),
        ("Your Files", [.lens, .large, .dups, .photos, .installers]),
        ("Health", [.protection, .status, .maintenance, .history]),
    ]
}

/// Everything a scan finds. Saved to disk so Roomy opens with the last results.
struct Snapshot: Codable {
    var scannedAt: Date?
    var disk = DiskInfo()
    var categories: [CleanCategory] = []
    var cacheHolders: [String] = []
    var apps: [AppRecord] = []
    var leftovers: [CleanItem] = []
    var languageFiles: [CleanItem] = []
    var universalBinaries: [CleanItem] = []
    var largeFiles: [LargeFile] = []
    var lens: LensNode?
    var aiCare = AICare()
    var storage = StorageReport()
    var duplicates: [DuplicateGroup] = []
    var photos: [PhotoGroup] = []
    var photosChecked = 0
    var protection: [ProtectionCheck] = []
    /// What starts with your Mac. Optional so snapshots from before 0.2.1 still open.
    var startup: StartupReport?
    var outdated: [OutdatedCask] = []
    var artifacts: [Artifact] = []
    var installers: [CleanItem] = []
    var maintenance: [MaintenanceTask] = []
    var diagnosis: [String] = []
    var history: [HistoryEntry] = []
    var touchID = false
    var moleVersion: String?
    /// Mole's own total for its clean (its preview's "Potential cleanup").
    var moleTotal: Int64?
    /// Your Trash, measured at scan time. Normal Mole Clean may empty it.
    var trashBytes: Int64?

    func category(_ key: String) -> CleanCategory? { categories.first { $0.key == key } }
}

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case idle, scanning, done }

    var snap = Snapshot()
    var route: Route = .care { didSet { lastRoute[Area.of(route)] = route } }
    /// The module each area showed last, so the rail returns to it.
    var lastRoute: [Area: Route] = [:]
    var phase: Phase = .idle
    var running: Set<String> = []
    var finished: [String] = []
    var selection: Set<String> = []
    var lensCache: [String: [LensNode]] = [:]
    var toast: String?
    let monitor = Monitor()

    private static let ud = UserDefaults.standard
    var themeID = ud.string(forKey: "theme") ?? "plum" {
        didSet { Self.ud.set(themeID, forKey: "theme"); Theme.currentAccent = theme.accent ?? .accentColor; Theme.current = theme }
    }
    /// A module's Clean asked Checkup to clean what's in the bag as soon as it opens.
    var cleanRequested = false
    /// The action of the screen's footer, which the orb performs. Set by `FooterBar` while it's on screen.
    var footer: FooterSpec?
    @ObservationIgnored var footerAction: (() -> Void)?
    var storedSafeMode = ud.object(forKey: "safeMode") as? Bool ?? true { didSet { Self.ud.set(storedSafeMode, forKey: "safeMode") } }
    /// Safe mode only previews removals. A demo is always in Safe mode.
    var safeMode: Bool {
        get { storedSafeMode || Demo.on }
        set { storedSafeMode = newValue }
    }
    var ackLarge = ud.bool(forKey: "ackLarge") { didSet { Self.ud.set(ackLarge, forKey: "ackLarge") } }
    var ackLens = ud.bool(forKey: "ackLens") { didSet { Self.ud.set(ackLens, forKey: "ackLens") } }
    /// Full Disk Access lets Roomy look everywhere without macOS asking about each folder and each app's data.
    /// Re-checked whenever Roomy comes to the front, since it's granted in System Settings.
    var hasFullDiskAccess = FullDiskAccess.granted
    /// The person chose to scan without Full Disk Access and accepted macOS's per-folder questions.
    var scanWithoutAccess = ud.bool(forKey: "scanWithoutAccess") { didSet { Self.ud.set(scanWithoutAccess, forKey: "scanWithoutAccess") } }
    var needsAccessStep: Bool { !hasFullDiskAccess && !scanWithoutAccess }
    /// A scan finished and its trash is bagged by the bin. Scanning again waits until it's cleaned.
    var awaitingClean = false
    /// Scanning again is blocked until the found junk is cleaned, unless the findings are more than an hour old: then
    /// Clean must not run on them, and a fresh scan is the only way on.
    var canScan: Bool { phase != .scanning && (!awaitingClean || scanIsStale) }
    var scanIsStale: Bool { snap.scannedAt.map { Date().timeIntervalSince($0) > 3600 } ?? false }
    /// A scan was asked for but is waiting on the access step.
    var accessPrompted = false
    func refreshAccess() {
        guard !Demo.on else { return }
        let g = FullDiskAccess.granted; if g != hasFullDiskAccess { hasFullDiskAccess = g }
        pruneMissing()
    }

    /// Drops every listed item whose file is gone, whatever removed it: another screen's clean, Mole, the app itself or
    /// you in Finder. Runs after each clean and whenever Roomy comes to the front, so no list offers what isn't there.
    func pruneMissing() {
        guard !Demo.on else { return }
        let fm = FileManager.default
        func gone(_ path: String) -> Bool {
            guard path.hasPrefix("/") || path.hasPrefix("~") else { return false }   // docker:…, mole:… aren't files
            let p = Paths.expand(path)
            return !fm.fileExists(atPath: p) && (try? fm.destinationOfSymbolicLink(atPath: p)) == nil
        }
        func count(_ x: Snapshot) -> Int {
            x.categories.reduce(0) { $0 + $1.items.count } + x.aiCare.clear.count + x.aiCare.held.count + x.aiCare.review.count
                + x.aiCare.worktrees.count + x.aiCare.cliTools.count + x.aiCare.chats.reduce(0) { $0 + $1.files.count }
                + x.leftovers.count + x.largeFiles.count + x.installers.count + x.artifacts.count
        }
        var s = snap
        for i in s.categories.indices { s.categories[i].items.removeAll { gone($0.path) } }
        s.aiCare.clear.removeAll { gone($0.path) }
        s.aiCare.held.removeAll { gone($0.path) }
        s.aiCare.review.removeAll { gone($0.path) }
        s.aiCare.worktrees.removeAll { gone($0.path) }
        s.aiCare.cliTools.removeAll { gone($0.path) }
        for i in s.aiCare.chats.indices { s.aiCare.chats[i].files.removeAll { gone($0.path) } }
        s.aiCare.chats.removeAll { $0.files.isEmpty }
        s.leftovers.removeAll { gone($0.path) }
        s.largeFiles.removeAll { gone($0.path) }
        s.installers.removeAll { gone($0.path) }
        s.artifacts.removeAll { gone($0.path) }
        guard count(s) != count(snap) else { return }
        withAnimation(.smooth) { snap = s }
        save()
    }

    var theme: Theme { Theme.all.first { $0.id == themeID } ?? Theme.all[0] }

    private let file = Paths.support.appendingPathComponent("snapshot.json")

    init() {
        Theme.currentAccent = theme.accent ?? .accentColor
        Theme.current = theme
        let legacyProblems = MoleLegacySettings.recover(config: URL(fileURLWithPath: Mole.config), support: Paths.support)
        if let demo = Demo.snapshot {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: demo)), let s = try? JSONDecoder().decode(Snapshot.self, from: d) { snap = s }
            hasFullDiskAccess = true
            snap.scannedAt = nil
            phase = .idle; finished = []; awaitingClean = false   // the story starts on the untidy room
        } else {
            if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Snapshot.self, from: d) { snap = s; phase = .idle }   // Checkup always opens on the untidy room; the last results stay in each module
            for i in snap.history.indices where snap.history[i].title == "Smart Care" { snap.history[i].title = "Checkup" }   // its name in 0.0.1
            repairEmptyCleans()
            snap.disk = ExtrasEngine.disk()
        }
        for i in snap.categories.indices { snap.categories[i].items.removeAll { $0.byMole != true } }
        for i in snap.leftovers.indices where !AppsEngine.mayPreselect(snap.leftovers[i].path) { snap.leftovers[i].review = true }
        if snap.categories.isEmpty == false { preselect(); preselectAI() }
        if !Demo.on { scannedParts = partsInSnapshot() }
        MoleCheck.removeOldDownloads()
        if !legacyProblems.isEmpty { flash(legacyProblems.joined(separator: " ")) }
        AppUpdater.shared.start()
        UninstallWatcher.shared.start(onFound: { [weak self] items in self?.addLeftovers(items) },
                                      onReturned: { [weak self] apps in self?.dropLeftovers(of: apps) },
                                      onOpen: { [weak self] in self?.route = .leftovers; NSApp.activate(); self?.openMainWindow?() })
        // Testing aid: `-RoomyRoute lens` opens on that screen.
        if let r = UserDefaults.standard.string(forKey: "RoomyRoute").flatMap(Route.init(rawValue:)) { route = r }
        // Testing aid, demo only: `-RoomyAutoScan YES` plays the scan on launch, for screenshots.
        if Demo.on, UserDefaults.standard.bool(forKey: "RoomyAutoScan") {
            Task { try? await Task.sleep(for: .seconds(1.5)); scanAll() }
        }
    }

    /// Cleans recorded as "0 items" because Mole 1.61 changed its log format before Roomy could read it: the real
    /// numbers are still in Mole's log, so they're read again for History and the result shown in Checkup.
    func repairEmptyCleans() {
        for i in snap.history.indices {
            let h = snap.history[i]
            guard h.title == "Checkup", !h.simulated, h.items == 0, h.bytes == 0, (h.removed ?? []).isEmpty else { continue }
            let run = Mole.readOperations(since: h.date.addingTimeInterval(-3600))
            // Only the session that ended just before Roomy recorded this clean.
            guard let end = run.ended, end <= h.date.addingTimeInterval(5), end >= h.date.addingTimeInterval(-120), run.count > 0 else { continue }
            snap.history[i].bytes = run.freed
            snap.history[i].items = run.count
            snap.history[i].removed = Array(run.removed.map { Paths.short($0.path) + ($0.bytes > 0 ? " — \(Fmt.bytes($0.bytes))" : "") }.prefix(500))
            if lastResult?.id == h.id { lastResult = snap.history[i] }
        }
    }

    /// An app came back (put back from the Trash, or installed again): its files aren't leftovers any more.
    func dropLeftovers(of apps: [LeftoverFinder.App]) {
        let names = Set(apps.map { "\($0.name) (uninstalled)" })
        let gone = snap.leftovers.filter { names.contains($0.name) }.map(\.path)
        guard !gone.isEmpty else { return }
        snap.leftovers.removeAll { gone.contains($0.path) }
        selection.subtract(gone)
        save()
    }

    func save() {
        guard !Demo.on else { return }
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: file, options: .atomic) }
    }

    // MARK: scanning

    static let steps: [(id: String, title: String)] = [
        ("cleanup", "System junk and caches"), ("apps", "Applications and leftovers"), ("lens", "Disk map"),
        ("ai", "AI tools"), ("large", "Large and old files"), ("dev", "Project artifacts and installers"),
        ("health", "Protection and maintenance"), ("dups", "Duplicates and similar photos"),
    ]

    func scanAll() {
        guard !Demo.on else { demoScan(); return }
        engineMissing = !Mole.available
        guard canScan, !engineMissing else { route = .care; return }
        refreshAccess()
        // Without Full Disk Access, macOS would ask about every protected folder and app. Checkup shows the access step instead.
        guard !needsAccessStep else { route = .care; accessPrompted = true; return }
        accessPrompted = false
        phase = .scanning
        finished = []
        running = Set(Self.steps.map(\.id))
        snap.leftovers = []
        Task {
            snap.disk = ExtrasEngine.disk()
            snap.moleVersion = await Mole.version()
            async let cleanup: Void = step("cleanup") { await self.scanCleanup() }
            async let apps: Void = step("apps") { await self.scanApps() }
            async let ai: Void = step("ai") { await self.scanAI() }
            async let dev: Void = step("dev") { await self.scanDev() }
            async let health: Void = step("health") { await self.scanHealth() }
            async let dups: Void = step("dups") { await self.scanDups() }
            _ = await (cleanup, apps)
            await step("lens") { await self.scanDiskMap { found in await self.step("large") { await self.scanLarge(found) } } }
            _ = await (ai, dev, health, dups)
            snap.scannedAt = Date()
            awaitingClean = checkupBytes > 0
            phase = .done
            save()
        }
    }

    /// A demo's scan: the parts report one after another on the demo's own findings. Nothing on this Mac is read.
    func demoScan() {
        guard canScan else { return }
        phase = .scanning
        finished = []
        running = Set(Self.steps.map(\.id))
        Task {
            for (id, wait) in [("cleanup", 1.7), ("ai", 0.9), ("dev", 0.9), ("lens", 1.2), ("large", 0.8), ("dups", 0.9), ("apps", 1.3), ("health", 1.1)] {
                try? await Task.sleep(for: .seconds(wait))
                withAnimation(.snappy) { running.remove(id); finished.append(id); scannedParts.insert(Self.part(of: id)) }
            }
            snap.scannedAt = Date()
            awaitingClean = checkupBytes > 0
            phase = .done
        }
    }

    // MARK: the parts of a scan (each one can also run alone, from its screen's Rescan)

    func scanCleanup() async {
        let c = await CleanupEngine.scan()
        snap.categories = c.categories; snap.cacheHolders = c.cacheHolders; snap.moleTotal = c.moleTotal
        // The app check runs at the same time and may have finished first: keep what it found.
        let mole = Set(c.leftovers.map(\.path))
        // What this part found last time is replaced; what the app check found stays, if it's still there.
        let stale = foundByCleanup.subtracting(mole)
        snap.leftovers = (c.leftovers + snap.leftovers.filter { !mole.contains($0.path) && !stale.contains($0.path) && Paths.exists($0.path) })
            .filter { !Actions.isOffLimits(Paths.expand($0.path)) }
        foundByCleanup = mole
        snap.trashBytes = await diskSizes([HOME + "/.Trash"])[HOME + "/.Trash"]
        preselect()
    }

    func scanApps() async {
        let a = await AppsEngine.scan()
        snap.apps = a.apps
        // Apps uninstalled since Roomy last looked, and what their name and ID point to.
        let now = a.apps.map { LeftoverFinder.App(id: $0.bundleID, name: $0.name) }
        _ = LeftoverFinder.noteInstalled(now)
        let gone = await LeftoverFinder.all(installed: now)
        let goneAt = Set(gone.map(\.path))
        let found = gone + a.leftovers.filter { !goneAt.contains($0.path) }
        // What the app check found last time is replaced; Mole's findings (the cleanup part) stay, if they're still there.
        snap.leftovers = snap.leftovers.filter { !foundByApps.contains($0.path) && Paths.exists($0.path) }
        foundByApps = Set(found.map(\.path))
        let known = Set(snap.leftovers.map(\.path))
        // Never list what Roomy would refuse to remove (Docker's and OrbStack's live data, Library roots).
        snap.leftovers += found.filter { !known.contains($0.path) && !Actions.isOffLimits(Paths.expand($0.path)) }
        for i in found where !known.contains(i.path) { if i.review || !AppsEngine.mayPreselect(i.path) { selection.remove(i.path) } else { selection.insert(i.path) } }
        snap.languageFiles = await AppsEngine.languageFiles(a.apps)
        snap.universalBinaries = await AppsEngine.universalBinaries(a.apps)
        snap.startup = await StartupEngine.scan(apps: snap.apps)
        snap.outdated = await ExtrasEngine.outdatedCasks()
    }

    /// macOS's full list of login and background items, which needs an administrator's permission (macOS asks in its
    /// own dialog). Only when you ask; a scan never does.
    var readingStartup = false
    func readFullStartupList() async {
        guard !Demo.on else { flash("The demo doesn't read this Mac's list."); return }
        guard !readingStartup else { return }
        readingStartup = true
        defer { readingStartup = false }
        guard let text = await StartupEngine.readFullList() else { flash("macOS's full list wasn't read. Nothing changed."); return }
        let scan = await StartupEngine.scan(apps: snap.apps)
        withAnimation(.snappy) { snap.startup = StartupEngine.merge(fullList: text, into: scan, apps: snap.apps) }
        save()
    }

    func scanAI() async { snap.aiCare = await AICareEngine.scan(); preselectAI() }

    func scanDev() async {
        snap.artifacts = await Mole.purgePreview()
        snap.installers = await Mole.installerPreview()
    }

    func scanHealth() async {
        snap.protection = await ExtrasEngine.protection()
        let m = await Mole.optimizePreview()
        snap.maintenance = m.tasks; snap.diagnosis = m.diagnosis
        snap.touchID = await Mole.touchIDEnabled()
    }

    func scanDups() async {
        snap.duplicates = await ExtrasEngine.duplicates()
        let p = await ExtrasEngine.similarPhotos()
        snap.photos = p.groups; snap.photosChecked = p.checked
    }

    /// The disk map, then large files (from the same walk) and Storage's categories.
    func scanDiskMap(large: (([Mole.Analysis.Entry]) async -> Void)? = nil) async {
        snap.disk = ExtrasEngine.disk()
        let (root, found) = await DiskMapEngine.root(disk: snap.disk, ctx: lensContext())
        snap.lens = root
        lensCache = [:]
        if let large { await large(found) } else { await scanLarge(found) }
        snap.storage = await StorageEngine.scan(disk: snap.disk, lens: root, apps: snap.apps)
    }

    func scanLarge(_ moleLarge: [Mole.Analysis.Entry]) async { snap.largeFiles = await CleanupEngine.largeFiles(moleLarge: moleLarge) }

    /// The part of the scan a screen shows, or nil for screens that don't scan.
    static func scanPart(for r: Route) -> String? {
        switch r {
        case .systemJunk, .userCache, .developer, .mail, .trash, .systemData: "cleanup"
        case .uninstaller, .updates, .leftovers, .startup, .slimming: "apps"
        case .aiCare: "ai"
        case .artifacts, .installers: "dev"
        case .protection, .maintenance: "health"
        case .dups, .photos: "dups"
        case .lens, .large, .storage: "lens"
        default: nil
        }
    }

    /// The parts of a scan whose results are in: a module whose part isn't shows its title page instead of a list.
    /// A demo starts with none, so it opens on title pages like a first launch.
    var scannedParts: Set<String> = []
    /// The scan part a Checkup step belongs to ("large" is found by the disk map's walk).
    static func part(of step: String) -> String { step == "large" ? "lens" : step }

    /// Whether the scan part has run since Roomy opened, or its results came back from the last session.
    func hasScanned(_ part: String) -> Bool { scannedParts.contains(part) }

    /// What the last session left, by part.
    func partsInSnapshot() -> Set<String> {
        var out: Set<String> = []
        if !snap.categories.isEmpty { out.insert("cleanup") }
        if !snap.apps.isEmpty { out.insert("apps") }
        if snap.lens != nil { out.insert("lens") }
        if !snap.protection.isEmpty { out.insert("health") }
        if snap.scannedAt != nil { out.formUnion(["ai", "dev", "dups"]) }
        return out
    }

    /// Which leftovers each part found last, so a rescan replaces only its own.
    @ObservationIgnored private var foundByCleanup: Set<String> = []
    @ObservationIgnored private var foundByApps: Set<String> = []

    /// Parts being rescanned on their own right now.
    var rescanning: Set<String> = []
    func isRescanning(_ r: Route) -> Bool { Self.scanPart(for: r).map { rescanning.contains($0) } ?? false }
    func canRescan(_ r: Route) -> Bool {
        guard let part = Self.scanPart(for: r) else { return false }
        return phase != .scanning && !isCleaning && !rescanning.contains(part) && (Demo.on || Mole.available)
    }

    /// Scans again just what this screen shows, leaving the rest of the last scan as it was.
    func rescan(_ r: Route) {
        guard canRescan(r), let part = Self.scanPart(for: r) else { return }
        if Demo.on {
            // A demo pretends: the orb spins for a moment and nothing is read.
            rescanning.insert(part)
            Task {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.smooth) { rescanning.remove(part); scannedParts.insert(part) }
            }
            return
        }
        refreshAccess()
        rescanning.insert(part)
        Task {
            switch part {
            case "cleanup": await scanCleanup()
            case "apps": await scanApps()
            case "ai": await scanAI()
            case "dev": await scanDev()
            case "health": await scanHealth()
            case "dups": await scanDups()
            default: await scanDiskMap()
            }
            withAnimation(.smooth) { rescanning.remove(part); scannedParts.insert(part) }
            awaitingClean = awaitingClean && checkupBytes > 0
            save()
            flash("\(r.title) is up to date.")
        }
    }

    private func step(_ id: String, _ work: @escaping @MainActor () async -> Void) async {
        await work()
        withAnimation(.snappy) { running.remove(id); finished.append(id); scannedParts.insert(Self.part(of: id)) }
    }

    func lensContext() -> DiskMapEngine.Context {
        var ctx = DiskMapEngine.Context(apps: snap.apps)
        for c in snap.categories where c.safe && !["largeFiles"].contains(c.key) {
            for i in c.items where !i.path.hasPrefix("mole:") && !i.path.hasPrefix("docker:") { ctx.cleanPaths[i.path] = "Cleaned in \(c.title). \(c.note)" }
        }
        for a in snap.artifacts { ctx.cleanPaths[a.path] = "Project build output, \(a.ageDays) days since last change. Rebuilt next time you build." }
        ctx.leftovers = Set(snap.leftovers.map(\.path))
        return ctx
    }

    func lensChildren(_ n: LensNode) async -> [LensNode] {
        if let c = n.children, !c.isEmpty { return c }
        if Demo.on { return [] }   // a demo never reads the real disk
        if let c = lensCache[n.id] { return c }
        let kids = await DiskMapEngine.children(of: n, ctx: lensContext())
        lensCache[n.id] = kids
        return kids
    }

    func loadUninstallPreview(_ app: AppRecord) async {
        let a = await AppsEngine.preview(app)
        if let i = snap.apps.firstIndex(where: { $0.path == app.path }) { snap.apps[i] = a }
    }

    // MARK: selection

    func preselect() {
        for c in snap.categories where c.safe {
            for i in c.items where !i.review && i.held == nil && i.byMole != true { selection.insert(i.path) }
        }
        // Leftovers that meet Mole's safe-to-remove rules start selected; anything that needs review never stays selected
        // from an earlier scan.
        for i in snap.leftovers where i.review || i.byMole == true || !AppsEngine.mayPreselect(i.path) { selection.remove(i.path) }
        for i in snap.leftovers where !i.review && i.byMole != true && AppsEngine.mayPreselect(i.path) { selection.insert(i.path) }
    }

    func preselectAI() { for i in snap.aiCare.clear { selection.insert("ai:" + i.path) } }

    func toggle(_ id: String) { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }

    /// Mole's last dry-run findings. This is an estimate, not a fixed execution manifest.
    var moleItems: [CleanItem] {
        snap.categories.flatMap(\.items).filter { $0.byMole == true } + snap.leftovers.filter { $0.byMole == true }
    }
    var isCleaning = false
    var lastResult: HistoryEntry?
    var moleCleanable: Int64 { snap.moleTotal ?? moleItems.reduce(0) { $0 + $1.bytes } }
    var checkupBytes: Int64 { moleCleanable }

    /// Checkup delegates its entire cleanup to bundled Mole, with Mole's own settings and safeguards.
    @discardableResult
    func smartClean() async -> Actions.Report {
        guard !isCleaning else { return Actions.Report(simulated: safeMode) }
        isCleaning = true
        defer { isCleaning = false }
        if safeMode {
            var rep = Actions.Report(simulated: true)
            rep.removed = moleCleanable; rep.count = moleItems.count
            let entry = HistoryEntry(date: Date(), title: "Checkup", bytes: rep.removed, items: rep.count, simulated: true)
            snap.history.insert(entry, at: 0); lastResult = entry
            save()
            flash(Demo.on ? "This is a demo, so nothing was removed." : "Safe mode: nothing was removed. Mole's preview estimates \(Fmt.bytes(rep.removed)).")
            return rep
        }
        let run = await Mole.runClean()
        var rep = Actions.Report(simulated: false)
        rep.removed = run.freed; rep.count = run.count
        rep.failures = run.failed.map { "\(Paths.short($0.path)) — \($0.reason)" }
        if !run.ran { rep.failures.insert("Mole did not complete successfully. Review History and scan again.", at: 0) }
        if run.ran {
            for i in snap.categories.indices { snap.categories[i].items.removeAll { $0.byMole == true } }
            snap.leftovers.removeAll { $0.byMole == true }
            snap.moleTotal = 0
        }
        snap.disk = ExtrasEngine.disk()
        let entry = HistoryEntry(date: Date(), title: "Checkup", bytes: run.freed, items: run.count, simulated: false,
                                 failures: rep.failures.isEmpty ? nil : rep.failures,
                                 removed: Array(run.removed.prefix(500).map { "\(Paths.short($0.path))" + ($0.bytes > 0 ? " — \(Fmt.bytes($0.bytes))" : "") }))
        snap.history.insert(entry, at: 0); lastResult = entry
        save()
        // Mole's clean can take things other screens list (an old extension, a cache AI Cleanup shows too).
        pruneMissing()
        flash("Mole reports \(Fmt.bytes(run.freed)) freed." + (rep.failures.isEmpty ? "" : " Review History for skipped or failed operations."))
        return rep
    }

    // MARK: setup

    /// Roomy cleans with Mole (free, GPL-3.0), which ships inside the app. Without it (a build made without Mole) scans
    /// find nothing, so Checkup says how to get it instead.
    var engineMissing = !Mole.available && !Demo.on

    // MARK: actions

    /// Runs the maintenance tasks for real (Safe mode only previews), then reads what's left to do.
    func runMaintenance() async {
        guard !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }
        if safeMode {
            try? await Task.sleep(for: .seconds(1))
            flash("Safe mode: maintenance wasn't run. Turn Safe mode off in Settings to run it.")
            return
        }
        // Exactly Mole's own maintenance, with Mole's own defaults and your Mole keep list.
        _ = await Mole.run(["optimize"], timeout: 1200, dryRun: false)
        let m = await Mole.optimizePreview()
        snap.maintenance = m.tasks; snap.diagnosis = m.diagnosis
        snap.history.insert(HistoryEntry(date: Date(), title: "Maintenance", bytes: 0, items: m.tasks.count, simulated: false), at: 0)
        save()
        flash("Maintenance done. Anything still marked needs an administrator or your attention.")
    }

    @discardableResult
    func clean(_ title: String, targets all: [Actions.Target], allowApps: Bool = false, after: (() -> Void)? = nil) async -> Actions.Report {
        guard !isCleaning else { return Actions.Report(simulated: safeMode) }
        isCleaning = true
        defer { isCleaning = false }
        // Mole's findings are removed only by Mole's clean (Checkup), never path by path here.
        let mole = Set(moleItems.map(\.path))
        let targets = all.filter { !mole.contains($0.path) }
        let rep = await Actions.perform(targets, simulate: safeMode, allowApps: allowApps)
        snap.history.insert(HistoryEntry(date: Date(), title: title, bytes: rep.removed, items: rep.count, simulated: rep.simulated,
                                         failures: rep.failures.isEmpty ? nil : rep.failures, trashed: rep.simulated || rep.removed == 0 ? nil : rep.removed,
                                         removed: rep.simulated ? nil : Array(rep.done.prefix(500))), at: 0)
        // Safe mode removes nothing, so the lists stay exactly as they are.
        if !rep.simulated { withAnimation(.smooth) {
            // Only what was actually removed leaves the lists; failures stay visible.
            let gone = Set(targets.map(\.path)).subtracting(rep.failedPaths)
            for i in snap.categories.indices { snap.categories[i].items.removeAll { gone.contains($0.path) } }
            snap.aiCare.clear.removeAll { gone.contains($0.path) }
            snap.aiCare.review.removeAll { gone.contains($0.path) }
            snap.aiCare.worktrees.removeAll { gone.contains($0.path) }
            snap.aiCare.cliTools.removeAll { gone.contains($0.path) }
            for i in snap.aiCare.chats.indices { snap.aiCare.chats[i].files.removeAll { gone.contains($0.path) } }
            snap.aiCare.chats.removeAll { $0.files.isEmpty }
            snap.leftovers.removeAll { gone.contains($0.path) }
            snap.largeFiles.removeAll { gone.contains($0.path) }
            snap.installers.removeAll { gone.contains($0.path) }
            snap.artifacts.removeAll { gone.contains($0.path) }
            selection.subtract(gone)
            selection.subtract(gone.map { "ai:" + $0 })
            after?()
        } }
        if !rep.simulated { snap.disk = ExtrasEngine.disk() }
        save()
        if !rep.simulated { pruneMissing() }
        let already = rep.alreadyGone.isEmpty ? "" : " \(rep.alreadyGone.count) \(rep.alreadyGone.count == 1 ? "was" : "were") already removed by an earlier clean."
        if !rep.simulated, rep.count == 0, rep.failures.isEmpty, !rep.alreadyGone.isEmpty {
            flash("Nothing to remove: \(rep.alreadyGone.count == 1 ? "it was" : "they were") already removed by an earlier clean.")
            return rep
        }
        flash(rep.simulated ? "Safe mode: nothing was removed. It would have freed \(Fmt.bytes(rep.removed))."
                            : rep.failures.isEmpty ? "Moved \(Fmt.bytes(rep.removed)) to the Trash." + already + " Empty the Trash to free the space." : "Moved \(Fmt.bytes(rep.removed)) to the Trash." + already + " \(rep.failures.count) item\(rep.failures.count == 1 ? "" : "s") couldn't be removed; see History.")
        return rep
    }

    /// Set by the window, so a notification can bring it back after it was closed.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Leftovers the uninstall watcher found: added to Leftovers, caches and logs selected, data for you to choose.
    func addLeftovers(_ items: [CleanItem]) {
        let known = Set(snap.leftovers.map(\.path))
        let new = items.filter { !known.contains($0.path) }
        guard !new.isEmpty else { return }
        withAnimation(.smooth) { snap.leftovers = new + snap.leftovers }
        for i in new where !i.review && AppsEngine.mayPreselect(i.path) { selection.insert(i.path) }
        save()
    }

    /// The number beside a module in its area's list: what it found, or nil.
    func badge(for route: Route) -> String? {
        if let part = Self.scanPart(for: route), !hasScanned(part) { return nil }
        let s = snap
        if !route.categories.isEmpty {
            let b = route.categories.compactMap { s.category($0) }.reduce(0) { $0 + $1.bytes }
            return b > 0 ? Fmt.bytes(b) : nil
        }
        switch route {
        case .aiCare: let b = s.aiCare.cleanable; return b > 0 ? Fmt.bytes(b) : nil
        case .artifacts: let b = s.artifacts.reduce(0) { $0 + $1.bytes }; return b > 0 ? Fmt.bytes(b) : nil
        case .uninstaller: return s.apps.isEmpty ? nil : "\(s.apps.count)"
        case .updates: return s.outdated.isEmpty ? nil : "\(s.outdated.count)"
        case .leftovers: let b = s.leftovers.filter { !$0.review }.reduce(0) { $0 + $1.bytes }; return b > 0 ? Fmt.bytes(b) : nil
        case .slimming: let b = s.languageFiles.reduce(0) { $0 + $1.bytes }; return b > 0 ? Fmt.bytes(b) : nil
        case .large: let b = s.largeFiles.filter { !LargeFilesView.info($0).locked }.reduce(0) { $0 + $1.bytes }; return b > 0 ? Fmt.bytes(b) : nil
        case .dups: let b = s.duplicates.reduce(0) { $0 + $1.wasted }; return b > 0 ? Fmt.bytes(b) : nil
        case .photos: return s.photos.isEmpty ? nil : "\(s.photos.count)"
        case .installers: let b = s.installers.reduce(0) { $0 + $1.bytes }; return b > 0 ? Fmt.bytes(b) : nil
        case .protection: let off = s.protection.filter { $0.on == false }.count; return off > 0 ? "\(off) off" : nil
        default: return nil
        }
    }

    /// A dot on the rail: something in that area wants attention (updates, protections off, leftovers to clear).
    func areaHasNews(_ a: Area) -> Bool {
        switch a {
        case .apps: !snap.outdated.isEmpty || snap.leftovers.contains { !$0.review && $0.bytes > 0 }
        case .health: snap.protection.contains { $0.on == false }
        default: false
        }
    }

    func flash(_ s: String) {
        withAnimation(.snappy) { toast = s }
        Task { try? await Task.sleep(for: .seconds(3.2)); withAnimation(.smooth) { if toast == s { toast = nil } } }
    }
}
