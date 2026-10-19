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
        case .systemJunk: ["systemJunk"]; case .userCache: ["userCache"]
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
    var launchItems: [LaunchItem] = []
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
    /// Your Trash, measured at scan time. Checkup shows it but never empties it.
    var trashBytes: Int64?

    func category(_ key: String) -> CleanCategory? { categories.first { $0.key == key } }
}

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case idle, scanning, done }

    var snap = Snapshot()
    var route: Route = .care
    var phase: Phase = .idle
    var running: Set<String> = []
    var finished: [String] = []
    var selection: Set<String> = []
    var lensCache: [String: [LensNode]] = [:]
    var toast: String?
    let monitor = Monitor()

    private static let ud = UserDefaults.standard
    var themeID = ud.string(forKey: "theme") ?? "plum" { didSet { Self.ud.set(themeID, forKey: "theme"); Theme.currentAccent = theme.accent ?? .accentColor } }
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
    func refreshAccess() { guard !Demo.on else { return }; let g = FullDiskAccess.granted; if g != hasFullDiskAccess { hasFullDiskAccess = g } }

    var theme: Theme { Theme.all.first { $0.id == themeID } ?? Theme.all[0] }

    private let file = Paths.support.appendingPathComponent("snapshot.json")

    init() {
        Theme.currentAccent = theme.accent ?? .accentColor
        MoleWhitelist.restore()   // in case Roomy quit in the middle of a clean
        if let demo = Demo.snapshot {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: demo)), let s = try? JSONDecoder().decode(Snapshot.self, from: d) { snap = s }
            hasFullDiskAccess = true
            snap.scannedAt = Date().addingTimeInterval(-40)
            phase = .done; finished = Self.steps.map(\.id); awaitingClean = true
        } else {
            if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Snapshot.self, from: d) { snap = s; phase = .idle }   // Checkup always opens on the untidy room; the last results stay in each module
            for i in snap.history.indices where snap.history[i].title == "Smart Care" { snap.history[i].title = "Checkup" }   // its name in 0.0.1
            snap.disk = ExtrasEngine.disk()
        }
        for i in snap.leftovers.indices where !AppsEngine.mayPreselect(snap.leftovers[i].path) { snap.leftovers[i].review = true }
        if snap.categories.isEmpty == false { preselect(); preselectAI() }
        MoleCheck.removeOldDownloads()
        AppUpdater.shared.start()
        // Testing aid: `-RoomyRoute lens` opens on that screen.
        if let r = UserDefaults.standard.string(forKey: "RoomyRoute").flatMap(Route.init(rawValue:)) { route = r }
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
        guard !Demo.on else { flash("This is a demo: scanning is off."); return }
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
        checkupSkip = []
        Task {
            snap.disk = ExtrasEngine.disk()
            snap.moleVersion = await Mole.version()
            async let cleanup: Void = step("cleanup") {
                let c = await CleanupEngine.scan()
                self.snap.categories = c.categories; self.snap.cacheHolders = c.cacheHolders; self.snap.moleTotal = c.moleTotal
                // The app check runs at the same time and may have finished first: keep what it found.
                let mole = Set(c.leftovers.map(\.path))
                self.snap.leftovers = (c.leftovers + self.snap.leftovers.filter { !mole.contains($0.path) }).filter { !Actions.isOffLimits(Paths.expand($0.path)) }
                self.snap.trashBytes = await diskSizes([HOME + "/.Trash"])[HOME + "/.Trash"]
                self.preselect()
            }
            async let apps: Void = step("apps") {
                let a = await AppsEngine.scan()
                self.snap.apps = a.apps
                let known = Set(self.snap.leftovers.map(\.path))
                // Never list what Roomy would refuse to remove (Docker's and OrbStack's live data, Library roots).
                self.snap.leftovers += a.leftovers.filter { !known.contains($0.path) && !Actions.isOffLimits(Paths.expand($0.path)) }
                for i in a.leftovers where !known.contains(i.path) { if i.review || !AppsEngine.mayPreselect(i.path) { self.selection.remove(i.path) } else { self.selection.insert(i.path) } }
                self.snap.languageFiles = await AppsEngine.languageFiles(a.apps)
                self.snap.universalBinaries = await AppsEngine.universalBinaries(a.apps)
                self.snap.launchItems = ExtrasEngine.launchItems()
                self.snap.outdated = await ExtrasEngine.outdatedCasks()
            }
            async let ai: Void = step("ai") { self.snap.aiCare = await AICareEngine.scan(); self.preselectAI() }
            async let dev: Void = step("dev") {
                self.snap.artifacts = await Mole.purgePreview()
                self.snap.installers = await Mole.installerPreview()
            }
            async let health: Void = step("health") {
                self.snap.protection = await ExtrasEngine.protection()
                let m = await Mole.optimizePreview()
                self.snap.maintenance = m.tasks; self.snap.diagnosis = m.diagnosis
                self.snap.touchID = await Mole.touchIDEnabled()
            }
            async let dups: Void = step("dups") {
                self.snap.duplicates = await ExtrasEngine.duplicates()
                let p = await ExtrasEngine.similarPhotos()
                self.snap.photos = p.groups; self.snap.photosChecked = p.checked
            }
            _ = await (cleanup, apps)
            await step("lens") {
                let ctx = self.lensContext()
                let (root, large) = await DiskMapEngine.root(disk: self.snap.disk, ctx: ctx)
                self.snap.lens = root
                self.lensCache = [:]
                await self.step("large") { self.snap.largeFiles = await CleanupEngine.largeFiles(moleLarge: large) }
                self.snap.storage = await StorageEngine.scan(disk: self.snap.disk, lens: root, apps: self.snap.apps)
            }
            _ = await (ai, dev, health, dups)
            snap.scannedAt = Date()
            awaitingClean = checkupBytes > 0
            phase = .done
            save()
        }
    }

    private func step(_ id: String, _ work: @escaping @MainActor () async -> Void) async {
        await work()
        withAnimation(.snappy) { running.remove(id); finished.append(id) }
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

    /// Everything Mole found: its clean removes all of it, with its own checks.
    var moleItems: [CleanItem] { snap.categories.flatMap(\.items).filter { $0.byMole == true } + snap.leftovers.filter { $0.byMole == true } }
    /// Mole's findings you unticked in Checkup's review. Mole keeps them for that clean.
    var checkupSkip: Set<String> = []
    /// True while any clean runs; every Clean button waits for it.
    var isCleaning = false
    /// The last Checkup clean, shown on Checkup until the next scan.
    var lastResult: HistoryEntry?
    var moleSelected: [CleanItem] { moleItems.filter { !checkupSkip.contains($0.path) } }
    /// What Mole's clean will remove: Mole's own total, or the ticked items once you've unticked some.
    var moleCleanable: Int64 { checkupSkip.isEmpty ? (snap.moleTotal ?? moleItems.reduce(0) { $0 + $1.bytes }) : moleSelected.reduce(0) { $0 + $1.bytes } }

    /// Roomy's own findings that Checkup removes (AI tool caches and old versions), minus anything inside a
    /// folder Mole already covers, so nothing is counted or removed twice.
    var checkupItems: [CleanItem] {
        let roots = moleItems.map { Paths.expand($0.path) }
        return snap.aiCare.clear.filter { selection.contains("ai:" + $0.path) }
            .filter { i in let p = Paths.expand(i.path); return !roots.contains { p == $0 || p.hasPrefix($0 + "/") } }
            .map { CleanItem(path: $0.path, name: $0.name, bytes: $0.bytes) }
    }
    var checkupBytes: Int64 { moleCleanable + checkupItems.reduce(0) { $0 + $1.bytes } }

    /// Checkup's clean: Mole removes what Mole found, Roomy moves its own findings to the Trash.
    @discardableResult
    func smartClean() async -> Actions.Report {
        // One clean at a time: two Mole runs at once interleave in its log, so neither total could be trusted.
        guard !isCleaning else { return Actions.Report(simulated: safeMode) }
        if !safeMode, await Mole.cleanRunning() {
            flash("Another clean is already running. Try again when it's done.")
            return Actions.Report(simulated: false)
        }
        isCleaning = true
        defer { isCleaning = false }
        let roomy = checkupItems.map { Actions.Target(path: $0.path, bytes: $0.bytes) }
        if safeMode {
            var rep = await Actions.perform(roomy, simulate: true)
            rep.removed += moleCleanable
            let entry = HistoryEntry(date: Date(), title: "Checkup", bytes: rep.removed, items: rep.count + moleSelected.count, simulated: true)
            snap.history.insert(entry, at: 0)
            lastResult = entry
            save()
            flash("Safe mode: nothing was removed. It would have freed \(Fmt.bytes(rep.removed)).")
            return rep
        }
        let run = await Mole.runClean(keeping: moleItems.map(\.path).filter { checkupSkip.contains($0) })
        var rep = await Actions.perform(roomy, simulate: false)
        let freed = run.freed, trashed = rep.removed
        // Temp folders of macOS's own background services refuse removal by design; that's protection, not failure.
        let sealed = run.failed.filter { ($0.path.hasPrefix("/var/folders/") || $0.path.hasPrefix("/private/var/folders/")) && $0.reason.lowercased().contains("permission") }
        let realFailures = run.failed.filter { f in !sealed.contains { $0.path == f.path } }
        rep.failures = realFailures.map { "\(Paths.short($0.path)) — \($0.reason)" } + rep.failures
        if !run.ran && run.removed.isEmpty && !moleItems.isEmpty { rep.failures.insert("The clean didn't run, so nothing was removed. Scan again and retry.", at: 0) }
        withAnimation(.smooth) {
            // Mole's findings are gone or were protected by Mole; the next scan shows anything left.
            let kept = checkupSkip
            for i in snap.categories.indices { snap.categories[i].items.removeAll { $0.byMole == true && !kept.contains($0.path) } }
            snap.leftovers.removeAll { $0.byMole == true }
            snap.moleTotal = 0
            let gone = Set(roomy.map(\.path)).subtracting(rep.failedPaths)
            snap.aiCare.clear.removeAll { gone.contains($0.path) }
            selection.subtract(gone.map { "ai:" + $0 })
        }
        snap.disk = ExtrasEngine.disk()
        let removedLines = run.removed.map { "\(Paths.short($0.path))" + ($0.bytes > 0 ? " — \(Fmt.bytes($0.bytes))" : "") } + rep.done
        let entry = HistoryEntry(date: Date(), title: "Checkup", bytes: freed + trashed, items: run.removed.count + rep.count, simulated: false,
                                 failures: rep.failures.isEmpty ? nil : rep.failures, trashed: trashed > 0 ? trashed : nil, removed: Array(removedLines.prefix(500)))
        snap.history.insert(entry, at: 0)
        lastResult = entry
        save()
        let fails = rep.failures.isEmpty ? "" : " \(rep.failures.count) couldn't be removed; see History."
        flash("Freed \(Fmt.bytes(freed))" + (trashed > 0 ? ", and moved \(Fmt.bytes(trashed)) to the Trash." : ".") + fails)
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
        _ = await Mole.run(["optimize"], timeout: 1200, dryRun: false)
        let m = await Mole.optimizePreview()
        snap.maintenance = m.tasks; snap.diagnosis = m.diagnosis
        snap.history.insert(HistoryEntry(date: Date(), title: "Maintenance", bytes: 0, items: m.tasks.count, simulated: false), at: 0)
        save()
        flash("Maintenance done. Anything still marked needs an administrator or your attention.")
    }

    @discardableResult
    func clean(_ title: String, targets all: [Actions.Target], after: (() -> Void)? = nil) async -> Actions.Report {
        guard !isCleaning else { return Actions.Report(simulated: safeMode) }
        isCleaning = true
        defer { isCleaning = false }
        // Mole's findings are removed only by Mole's clean (Checkup), never path by path here.
        let mole = Set(moleItems.map(\.path))
        let targets = all.filter { !mole.contains($0.path) }
        let rep = await Actions.perform(targets, simulate: safeMode)
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
        flash(rep.simulated ? "Safe mode: nothing was removed. It would have freed \(Fmt.bytes(rep.removed))."
                            : rep.failures.isEmpty ? "Moved \(Fmt.bytes(rep.removed)) to the Trash. Empty the Trash to free the space." : "Moved \(Fmt.bytes(rep.removed)) to the Trash. \(rep.failures.count) item\(rep.failures.count == 1 ? "" : "s") couldn't be removed; see History.")
        return rep
    }

    func flash(_ s: String) {
        withAnimation(.snappy) { toast = s }
        Task { try? await Task.sleep(for: .seconds(3.2)); withAnimation(.smooth) { if toast == s { toast = nil } } }
    }
}
