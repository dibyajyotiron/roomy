import Foundation

/// Keeps your Trash out of every Mole scan and clean. Mole 1.61 empties ~/.Trash unless it's on Mole's keep list, and it
/// has no other switch, so for the length of one run Roomy adds that single line and then puts the list back exactly.
/// Fail-closed: if the line can't be written and read back, the list isn't a plain file, or an earlier backup is still
/// waiting, Mole doesn't run at all. Nothing else in the keep list changes, and an interrupted run's backup is
/// restored at next launch by MoleLegacySettings (it looks for the "\n# Roomy:" mark this writes).
/// Self-contained (paths are passed in) so the security checks can exercise it on temporary fixtures.
enum MoleTrashGuard {
    struct Failure: Error, Equatable { var reason: String }

    /// Whether the keep list already names the Trash.
    static func protects(_ text: String, trash: String) -> Bool {
        text.split(separator: "\n").contains { let t = $0.trimmingCharacters(in: .whitespaces); return t == trash || t == "~/.Trash" || t == "$HOME/.Trash" }
    }

    /// Mole's built-in keep list (DEFAULT_WHITELIST_PATTERNS in its base.sh), which a keep-list file replaces.
    static func defaults(fromBaseScript s: String, home: String) throws -> String {
        guard let r = s.range(of: "DEFAULT_WHITELIST_PATTERNS=("), let end = s[r.upperBound...].range(of: "\n)") else {
            throw Failure(reason: "Couldn't read Mole's built-in keep list, so Roomy can't protect your Trash. Nothing was cleaned.")
        }
        let lines = s[r.upperBound..<end.lowerBound].split(separator: "\n").compactMap { raw -> String? in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), t.hasSuffix("\""), t.count > 2 else { return nil }
            return String(t.dropFirst().dropLast()).replacingOccurrences(of: "$HOME", with: home).replacingOccurrences(of: "$FINDER_METADATA_SENTINEL", with: "FINDER_METADATA")
        }
        guard !lines.isEmpty else { throw Failure(reason: "Mole's built-in keep list was empty, so Roomy can't protect your Trash. Nothing was cleaned.") }
        return "# Mole's built-in protections, copied by Roomy so they keep working.\n" + lines.joined(separator: "\n") + "\n"
    }

    /// Runs `body` (one Mole scan or clean) with `trash` on the keep list at `file`. One run at a time edits it.
    static func protecting<T>(file: URL, backup: URL, trash: String, defaults: () throws -> String, _ body: () async -> T) async -> Result<T, Failure> {
        await MoleSettingsLock.shared.acquire()
        let r = await protectingNow(file: file, backup: backup, trash: trash, defaults: defaults, body)
        await MoleSettingsLock.shared.release()
        return r
    }

    private static func readRegular(_ url: URL) throws -> Data? {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw Failure(reason: "Mole's keep list isn't a plain file, so Roomy can't protect your Trash. Nothing was cleaned.")
        }
        return try Data(contentsOf: url)
    }

    private static func protectingNow<T>(file: URL, backup: URL, trash: String, defaults: () throws -> String, _ body: () async -> T) async -> Result<T, Failure> {
        let fm = FileManager.default
        do {
            let original = try readRegular(file)
            let text = original.map { String(decoding: $0, as: UTF8.self) }
            if let text, protects(text, trash: trash) { return .success(await body()) }
            guard !fm.fileExists(atPath: backup.path) else {
                throw Failure(reason: "An earlier keep-list backup hasn't been restored yet. Reopen Roomy, then clean again.")
            }
            let base = try text ?? defaults()
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (original ?? MoleLegacySettings.absentMark).write(to: backup, options: .atomic)
            let edited = Data((base + "\n# Roomy: keeps your Trash for this run only\n" + trash + "\n").utf8)
            try edited.write(to: file, options: .atomic)
            guard try readRegular(file) == edited else {
                restore(file: file, backup: backup, original)
                throw Failure(reason: "Couldn't confirm your Trash was protected. Nothing was cleaned.")
            }
            let result = await body()
            restore(file: file, backup: backup, original)
            return .success(result)
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(Failure(reason: "Couldn't protect your Trash (\(error.localizedDescription)). Nothing was cleaned."))
        }
    }

    /// Puts the keep list back exactly. On any problem the backup stays for launch-time recovery.
    private static func restore(file: URL, backup: URL, _ original: Data?) {
        let fm = FileManager.default
        do {
            if let original { try original.write(to: file, options: .atomic) } else if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            guard try readRegular(file) == original else { return }
            try fm.removeItem(at: backup)
        } catch {}
    }
}

/// Serialises edits to Mole's settings, so two runs never interleave a keep-list change and its restore.
actor MoleSettingsLock {
    static let shared = MoleSettingsLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
