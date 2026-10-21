import Foundation

@main
struct SecurityChecks {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-security-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "SecurityChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let cleanEnv = GitInspection.environment(from: ["HOME": root.path, "PATH": "/usr/bin:/bin", "GIT_DIR": "/wrong",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": "/unexpected",
            "BASH_ENV": "/unexpected", "ENV": "/unexpected", "BASH_FUNC_echo%%": "() { unexpected; }"])
        try expect(cleanEnv["GIT_DIR"] == nil && cleanEnv["GIT_CONFIG_COUNT"] == nil && cleanEnv["BASH_ENV"] == nil,
                   "Git overrides and shell startup scripts must not be inherited")
        try expect(cleanEnv["GIT_CONFIG_GLOBAL"] == "/dev/null" && cleanEnv["GIT_TERMINAL_PROMPT"] == "0",
                   "Git inspections must not load global configuration or prompt")
        let injectionMarker = root.appendingPathComponent("shell-injection")
        let payload = "fixture'; /usr/bin/touch \(injectionMarker.path); #\nnext line"
        let quoted = await Shell.run("/bin/sh", ["-c", "printf '%s' \(Shell.quote(payload))"])
        try expect(quoted.ok && quoted.output == payload && !fm.fileExists(atPath: injectionMarker.path), "A quoted shell argument must stay literal")
        try expect(Shell.validBrewToken("homebrew/cask/firefox") && !Shell.validBrewToken("--help") && !Shell.validBrewToken("x; touch marker") && !Shell.validBrewToken("../file"), "Only valid Homebrew cask tokens may reach the Terminal fallback")
        var result = await GitInspection.run(at: root.path, ["init", "--quiet"])
        try expect(result.ok, "Fixture repository could not be initialized")
        let tracked = root.appendingPathComponent("tracked.txt")
        try Data("original\n".utf8).write(to: tracked)
        result = await GitInspection.run(at: root.path, ["add", "--", "tracked.txt"])
        try expect(result.ok, "Fixture file could not be indexed")
        // A benign fixture hook would create a marker if a scan accidentally executed it.
        let marker = root.appendingPathComponent("hook-was-executed")
        let hook = root.appendingPathComponent("fsmonitor-hook")
        try Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexit 0\n".utf8).write(to: hook)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        result = await GitInspection.run(at: root.path, ["config", "core.fsmonitor", hook.path])
        try expect(result.ok, "Fixture fsmonitor configuration failed")
        _ = await GitInspection.status(at: root.path)
        try expect(!fm.fileExists(atPath: marker.path), "Read-only inspection executed the repository's fsmonitor hook")
        try Data("changed\n".utf8).write(to: tracked)
        result = await GitInspection.status(at: root.path)
        try expect(GitInspection.cleanWorktreeProblem(result) != nil, "Changed worktree must stay locked")
        result = await GitInspection.status(at: root.appendingPathComponent("missing").path)
        try expect(GitInspection.cleanWorktreeProblem(result) != nil, "Unknown worktree status must stay locked")
        try expect(GitInspection.cleanWorktreeProblem(.init(output: "", status: 124)) != nil, "Timeout must not mean clean")
        try expect(GitInspection.cleanWorktreeProblem(.init(output: "", status: 0)) == nil, "Verified clean status should be accepted")
        // Recovery touches only this private fixture, and never overwrites a user's newer keep list.
        let keep = root.appendingPathComponent("whitelist")
        let backup = root.appendingPathComponent("backup")
        let original = Data("# original\nkeep-me\n".utf8)
        try original.write(to: backup)
        try Data("# original\n# Roomy: kept for this clean only\nextra\n".utf8).write(to: keep)
        let recovered = MoleLegacySettings.recover(file: keep, backup: backup)
        try expect(recovered == nil && (try Data(contentsOf: keep)) == original && !fm.fileExists(atPath: backup.path), "Original keep list must be recovered exactly")
        try original.write(to: backup)
        let edited = Data("# user changed it\nnew-rule\n".utf8)
        try edited.write(to: keep)
        let conflict = MoleLegacySettings.recover(file: keep, backup: backup)
        try expect(conflict != nil && (try Data(contentsOf: keep)) == edited && fm.fileExists(atPath: backup.path), "External changes and recovery backup must be preserved")
        try fm.removeItem(at: keep)
        try fm.createSymbolicLink(at: keep, withDestinationURL: tracked)
        let refused = MoleLegacySettings.recover(file: keep, backup: backup)
        try expect(refused != nil && fm.fileExists(atPath: backup.path), "Recovery must reject a symlink keep list")
        try fm.removeItem(at: keep)
        try MoleLegacySettings.absentMark.write(to: backup)
        try Data("# old temporary file\n# Roomy: kept for this clean only\nextra\n".utf8).write(to: keep)
        let removed = MoleLegacySettings.recover(file: keep, backup: backup)
        try expect(removed == nil && !fm.fileExists(atPath: keep.path) && !fm.fileExists(atPath: backup.path), "Originally absent keep list must be restored to absent")
        // The Trash guard: Mole runs only while ~/.Trash is on the keep list, and the list comes back exactly.
        let tg = root.appendingPathComponent("trash-guard", isDirectory: true)
        try fm.createDirectory(at: tg, withIntermediateDirectories: false)
        let list = tg.appendingPathComponent("whitelist"), saved = tg.appendingPathComponent("support/mole-whitelist.backup")
        let trash = "/fixture-home/.Trash"
        let userList = Data("# mine\n/fixture-home/keep\n".utf8)
        try userList.write(to: list)
        var during = ""
        var guarded = await MoleTrashGuard.protecting(file: list, backup: saved, trash: trash, defaults: { "unused\n" }) {
            during = (try? String(contentsOf: list, encoding: .utf8)) ?? ""; return 1
        }
        try expect((try? guarded.get()) == 1 && MoleTrashGuard.protects(during, trash: trash) && during.contains("/fixture-home/keep") && during.contains("\n# Roomy:"),
                   "Mole must run with the Trash added to the user's own keep list, marked for recovery")
        try expect((try Data(contentsOf: list)) == userList && !fm.fileExists(atPath: saved.path), "The keep list must come back exactly, with no backup left")
        try fm.removeItem(at: list)
        let base = "x\ndeclare -a DEFAULT_WHITELIST_PATTERNS=(\n    \"$HOME/Library/Caches/JetBrains*\"\n    \"$FINDER_METADATA_SENTINEL\"\n)\n"
        guarded = await MoleTrashGuard.protecting(file: list, backup: saved, trash: trash, defaults: { try MoleTrashGuard.defaults(fromBaseScript: base, home: "/fixture-home") }) {
            during = (try? String(contentsOf: list, encoding: .utf8)) ?? ""; return 2
        }
        try expect((try? guarded.get()) == 2 && during.contains("/fixture-home/Library/Caches/JetBrains*") && during.contains("FINDER_METADATA") && MoleTrashGuard.protects(during, trash: trash),
                   "Without a keep list, Mole's own defaults must be kept alongside the Trash")
        try expect(!fm.fileExists(atPath: list.path) && !fm.fileExists(atPath: saved.path), "An absent keep list must be absent again afterwards")
        var ran = false
        guarded = await MoleTrashGuard.protecting(file: list, backup: saved, trash: trash, defaults: { throw MoleTrashGuard.Failure(reason: "no defaults") }) { ran = true; return 3 }
        try expect(!ran && (try? guarded.get()) == nil, "If Mole's defaults can't be read, Mole must not run")
        let elsewhere = tg.appendingPathComponent("someone-elses-file")
        try Data("untouched\n".utf8).write(to: elsewhere)
        try fm.createSymbolicLink(at: list, withDestinationURL: elsewhere)
        guarded = await MoleTrashGuard.protecting(file: list, backup: saved, trash: trash, defaults: { "unused\n" }) { ran = true; return 4 }
        try expect(!ran && (try? guarded.get()) == nil && (try String(contentsOf: elsewhere, encoding: .utf8)) == "untouched\n", "A symlinked keep list must stop the run untouched")
        try fm.removeItem(at: list)
        try userList.write(to: list)
        try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("older".utf8).write(to: saved)
        guarded = await MoleTrashGuard.protecting(file: list, backup: saved, trash: trash, defaults: { "unused\n" }) { ran = true; return 5 }
        try expect(!ran && (try Data(contentsOf: list)) == userList && (try Data(contentsOf: saved)) == Data("older".utf8), "A pending backup must stop the run and stay for recovery")
        try fm.removeItem(at: saved)
        let protected = Data("# mine\n/fixture-home/.Trash\n".utf8)
        try protected.write(to: list)
        guarded = await MoleTrashGuard.protecting(file: list, backup: saved, trash: trash, defaults: { "unused\n" }) { (try? Data(contentsOf: list)) == protected ? 6 : 0 }
        try expect((try? guarded.get()) == 6 && (try Data(contentsOf: list)) == protected && !fm.fileExists(atPath: saved.path), "A list that already keeps the Trash is left alone")
        print("SecurityChecks: \(checks) passed (temporary fixtures only)")
    }
}
