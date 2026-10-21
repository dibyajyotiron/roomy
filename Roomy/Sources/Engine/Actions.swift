import Foundation
import MoleCore

/// Selected native cleanup actions. Checkup delegates separately to Mole.
/// - Safe mode (the default) only records what would happen.
/// - Files go to the Trash, never straight to deletion, after MoleCore's path-safety checks.
/// - Things a tool manages are removed with that tool's own command (`docker builder prune`, `git worktree remove`…).
enum Actions {
    struct Target: Hashable {
        var path: String
        var bytes: Int64
        var command: [String]? = nil
        var directory: String? = nil
        var aiTool: String? = nil
        var requiresCleanWorktree = false
    }

    struct Report {
        var removed: Int64 = 0
        var count = 0
        /// Each failure as "path — reason".
        var failures: [String] = []
        var failedPaths: [String] = []
        /// Listed but already gone when the clean started (an earlier clean or the app removed it): done, not failed.
        var alreadyGone: [String] = []
        /// Each removal as "path — size", so History can show exactly what went.
        var done: [String] = []
        var simulated: Bool
        mutating func fail(_ path: String, _ reason: String) { failures.append("\(Paths.short(path)) — \(reason)"); failedPaths.append(path) }
    }

    static let safety = PathSafety()

    /// Folders Roomy must never remove as a whole. Mole's ledger lists some of these with "N items" meaning
    /// "items inside"; removing the folder itself would take everything in it. Container filesystems
    /// (OrbStack, Docker) belong to running containers and are never touched from the Mac side.
    static func isOffLimits(_ p: String) -> Bool {
        let roots = ["", "/Library", "/Library/Caches", "/Library/Logs", "/Library/Application Support", "/Library/Containers",
                     "/Library/Group Containers", "/Library/Preferences", "/Documents", "/Desktop", "/Downloads", "/Pictures",
                     "/Movies", "/Music", "/.config", "/.local", "/.cache", "/.npm"].map { HOME + $0 }
        let c = (p as NSString).standardizingPath
        if roots.contains(c) || c == "/" || c == "/Users" { return true }
        for inside in ["/OrbStack/", "/.orbstack/", "/Library/Containers/com.docker.docker/"] where c.hasPrefix(HOME + inside) || c == HOME + inside.dropLast() { return true }
        return false
    }

    /// Why Disk Map can't offer this path for the Trash, or nil when it can. Mirrors Mole's Analyze: anything may go
    /// to the Trash except the roots and trees its delete guard protects, plus the folders above and iCloud Drive.
    static func trashLock(_ path: String) -> String? {
        let p = Paths.expand(path)
        if isOffLimits(p) { return "A folder macOS or your apps rely on. Open it and choose what's inside instead." }
        if PathSafety.isCritical(p) || safety.isProtected(p) { return "Protected: removing it could break macOS, another account or a running app." }
        if p.hasPrefix(HOME + "/Library/Mobile Documents") { return "In iCloud Drive: removing it here removes it on your other devices too. Manage it in Finder." }
        if (p as NSString).deletingLastPathComponent == HOME + "/Library" { return "One of your Library's own folders. Open it and choose what's inside instead." }
        return nil
    }

    /// Inside an app bundle or an Applications folder: only an uninstall (or your own pick in Disk Map) may remove it.
    /// Anything else that points there is a bug, and removing it would break or delete an app.
    static func isAppPath(_ p: String) -> Bool {
        let c = (p as NSString).standardizingPath
        return c.hasSuffix(".app") || c.contains(".app/") || c.hasPrefix("/Applications/") || c.hasPrefix(HOME + "/Applications/")
            || c.hasPrefix("/System/")
    }

    static func perform(_ targets: [Target], simulate: Bool, allowApps: Bool = false) async -> Report {
        var rep = Report(simulated: simulate)
        if simulate {
            try? await Task.sleep(for: .milliseconds(700))
            rep.removed = targets.reduce(0) { $0 + $1.bytes }
            rep.count = targets.count
            return rep
        }
        for t in targets {
            if let tool = t.aiTool, let why = await AICareEngine.heldNow(tool) { rep.fail(t.path, why); continue }
            if t.requiresCleanWorktree, let why = GitInspection.cleanWorktreeProblem(await GitInspection.status(at: Paths.expand(t.path))) {
                rep.fail(t.path, why); continue
            }
            if !allowApps, t.command == nil, isAppPath(Paths.expand(t.path)) { rep.fail(t.path, "Only Uninstaller removes apps"); continue }
            if let cmd = t.command, let exe = cmd.first {
                let r: Shell.Result
                if exe == "git", let directory = t.directory {
                    r = await GitInspection.run(at: directory, Array(cmd.dropFirst()), timeout: 900)
                } else {
                    r = await Shell.run(exe, Array(cmd.dropFirst()), timeout: 900, directory: t.directory)
                }
                if r.ok { rep.removed += t.bytes; rep.count += 1; rep.done.append("\(Paths.short(t.path)) — \(Fmt.bytes(t.bytes))") } else { rep.fail(t.path, "\(exe) didn't finish: \(r.output.trimmed.suffix(120))") }
                continue
            }
            let p = Paths.expand(t.path)
            // Checked first: a list can be older than the disk, and a missing item is nothing to remove, not a failure.
            guard FileManager.default.fileExists(atPath: p) || (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil else {
                rep.alreadyGone.append(t.path); continue
            }
            guard !isOffLimits(p) else { rep.fail(t.path, "Roomy never removes this folder as a whole"); continue }
            do {
                try PathSafety.validate(p)
                try safety.validateTrashTarget(p)
                guard !safety.isProtected(p), !PathSafety.isCritical(p) else { rep.fail(t.path, "Protected by the safety rules"); continue }
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                rep.removed += t.bytes; rep.count += 1; rep.done.append("\(Paths.short(t.path)) — \(Fmt.bytes(t.bytes))")
            } catch {
                rep.fail(t.path, (error as NSError).localizedDescription)
            }
        }
        return rep
    }
}
