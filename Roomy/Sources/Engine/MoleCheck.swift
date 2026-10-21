import Foundation

/// Roomy cleans with the copy of Mole bundled inside it, the version it was tested with. Mole never updates on its own:
/// a newer Mole reaches people only in a new Roomy release, after Roomy has been tested against it, because Roomy reads
/// Mole's output and a change there could make a scan or a clean go wrong.
enum MoleCheck {
    /// Where Roomy 0.0.x kept the Mole versions it downloaded. Nothing uses them any more.
    static let oldDownloads = Paths.support.appendingPathComponent("mole")

    /// Removes the Mole copies Roomy 0.0.x downloaded into its own folder, and the settings that went with them.
    static func removeOldDownloads() {
        try? FileManager.default.removeItem(at: oldDownloads)
        for k in ["moleLatest", "moleCheckedAt", "moleNote", "moleAutoUpdate", "moleRejected"] { UserDefaults.standard.removeObject(forKey: k) }
    }

    /// Everything Roomy reads from Mole, run against `mole`. Returns what didn't work, or nil.
    static func test(_ mole: String, version: String) async -> String? {
        guard await Mole.version(using: mole) == version else { return "it didn't report its version" }
        guard let s = await Mole.status(using: mole), s.cpu != nil || s.memory != nil else { return "its status didn't read" }
        guard await Mole.uninstallList(using: mole).isEmpty == false else { return "its app list didn't read" }
        let pv = await Mole.cleanPreview(using: mole)
        guard !pv.lines.isEmpty else { return "its clean preview didn't read" }
        if let problem = operationsLogProblem(mole) { return problem }
        return nil
    }

    /// Roomy reports what a clean removed from Mole's operations log, and dry runs don't write it, so the format is
    /// checked in Mole's source: a Mole that writes it differently is refused before it can ship ("Freed 0 B").
    static func operationsLogProblem(_ mole: String) -> String? {
        let dir = (URL(fileURLWithPath: mole).resolvingSymlinksInPath().path as NSString).deletingLastPathComponent
        let src = [dir + "/../libexec/lib/core/log.sh", dir + "/lib/core/log.sh"].lazy
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.first
        guard let src else { return "its operations log code wasn't found" }
        let needed = [#"[$timestamp] [$log_command] $action $path"#, #"session started at $timestamp"#,
                      #"session ended at $timestamp, $items items, $size_human"#]
        if let missing = needed.first(where: { !src.contains($0) }) { return "its operations log format changed (no \"\(missing)\")" }
        if src.contains("run=") && !src.contains(#"'%s run=%s'"#) { return "its operations log run tags changed" }
        // And Roomy's reader on both formats Mole has written.
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = f.string(from: Date().addingTimeInterval(60))
        let sample = """
        # ========== clean session started at \(now) ==========
        [\(now)] [clean] REMOVED /tmp/old-format (1.5MB)
        # ========== clean session ended at \(now), 1 items, 1.5MB ==========
        # ========== clean-dry-run run=9-9 session started at \(now) ==========
        [\(now)] [clean-dry-run run=9-9] REMOVED /tmp/dry (9MB)
        # ========== clean run=1-2 session started at \(now) ==========
        [\(now)] [clean run=1-2] REMOVED /tmp/new-format (2MB)
        [\(now)] [clean run=7-7] REMOVED /tmp/other-run (5MB)
        [\(now)] [clean run=1-2] FAILED /tmp/locked (permission denied)
        # ========== clean run=1-2 session ended at \(now), 1 items, 2.0MB ==========
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-oplog-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? sample.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        let r = Mole.readOperations(since: Date(), log: file.path)
        guard r.removed.map(\.path) == ["/tmp/new-format"], r.failed.map(\.path) == ["/tmp/locked"], r.freed == 2_000_000 else {
            return "Roomy's reader of the operations log failed its own check"
        }
        return nil
    }

    /// Testing aid, also run by release.sh: `Roomy -RoomyMoleSelfTest installed` runs Roomy's checks on the bundled
    /// Mole (or `-RoomyMoleSelfTest /path/to/mole` on another copy), prints the result and quits without a window.
    static func selfTest(_ what: String) -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            func say(_ s: String) { FileHandle.standardError.write(Data(("mole self-test: " + s + "\n").utf8)) }
            let p = what == "installed" ? Mole.path : what
            guard let p, let v = Mole.scriptVersion((try? String(contentsOfFile: p, encoding: .utf8)) ?? "") else { say("FAILED: no Mole found"); return }
            say("testing Mole \(v) at \(p)")
            say(await test(p, version: v).map { "FAILED: \($0)" } ?? "passed")
        }
        done.wait()
        exit(0)
    }
}
