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
