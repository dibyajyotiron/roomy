import Foundation
import AppKit
import CryptoKit
import CoreGraphics
import ImageIO

enum ExtrasEngine {
    static let skipDirs: Set<String> = ["node_modules", ".git", "venv", ".venv", "build", "dist", "DerivedData", "public", "assets"]
    static let skipSuffixes = [".app", ".photoslibrary", ".vmwarevm", ".xcassets"]

    static func files(in roots: [String], minSize: Int64, ext: Set<String>? = nil, limit: Int = .max) -> [(String, Int64, UInt64, Date)] {
        var out: [(String, Int64, UInt64, Date)] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        for r in roots where Paths.isDir(r) {
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: Paths.expand(r)), includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in e {
                if skipDirs.contains(u.lastPathComponent) || skipSuffixes.contains(where: u.lastPathComponent.hasSuffix) { e.skipDescendants(); continue }
                if let ext, !ext.contains(u.pathExtension.lowercased()) { continue }
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true,
                      let s = v.fileSize, Int64(s) >= minSize else { continue }
                var st = stat()
                let ino = lstat(u.path, &st) == 0 ? UInt64(st.st_ino) : 0
                out.append((u.path, Int64(s), ino, v.contentModificationDate ?? .distantPast))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Identical files, matched by size first and then by SHA-256. Hard links are one copy.
    static func duplicates() async -> [DuplicateGroup] {
        let all = files(in: ["~/Desktop", "~/Documents", "~/Downloads", "~/Pictures", "~/Movies", "~/Music"], minSize: 1_000_000)
        let bySize = Dictionary(grouping: all, by: { $0.1 }).values.filter { Set($0.map(\.2)).count > 1 && $0.count <= 30 }
        var groups: [DuplicateGroup] = []
        for cands in bySize {
            var uniq: [UInt64: (String, Date)] = [:]
            for f in cands { uniq[f.2] = uniq[f.2] ?? (f.0, f.3) }
            guard uniq.count > 1 else { continue }
            let hashes = await withTaskGroup(of: (String, Date, String?).self) { g in
                for (p, d) in uniq.values { g.addTask { (p, d, sha256(p)) } }
                var r: [(String, Date, String?)] = []
                for await x in g { r.append(x) }
                return r
            }
            for (h, list) in Dictionary(grouping: hashes.filter { $0.2 != nil }, by: { $0.2! }) where list.count > 1 {
                let sorted = list.sorted { $0.1 < $1.1 }
                groups.append(DuplicateGroup(hash: String(h.prefix(12)), name: Paths.name(sorted[0].0), bytes: cands[0].1, files: sorted.map(\.0)))
            }
        }
        return Array(groups.sorted { $0.wasted > $1.wasted }.prefix(120))
    }

    static func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Photos that look alike: an 8×8 average hash, grouped within a Hamming distance of 5.
    static func similarPhotos() async -> (checked: Int, groups: [PhotoGroup]) {
        let imgs = files(in: ["~/Pictures", "~/Desktop", "~/Downloads", "~/Documents"], minSize: 60_000,
                         ext: ["jpg", "jpeg", "png", "heic", "webp", "tiff"], limit: 800)
        let hashed = await withTaskGroup(of: (String, UInt64?).self) { g in
            for f in imgs { g.addTask { (f.0, aHash(f.0)) } }
            var r: [(String, UInt64)] = []
            for await (p, h) in g { if let h { r.append((p, h)) } }
            return r.sorted { $0.0 < $1.0 }
        }
        var used = Set<String>(), groups: [PhotoGroup] = []
        for (i, (p, h)) in hashed.enumerated() where !used.contains(p) {
            let grp = [p] + hashed[(i + 1)...].filter { !used.contains($0.0) && ($0.1 ^ h).nonzeroBitCount <= 5 }.map(\.0)
            if grp.count > 1 { used.formUnion(grp); groups.append(PhotoGroup(files: grp)) }
        }
        return (hashed.count, Array(groups.prefix(60)))
    }

    static func aHash(_ path: String) -> UInt64? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary)
        else { return nil }
        var px = [UInt8](repeating: 0, count: 64)
        guard let ctx = CGContext(data: &px, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let avg = px.reduce(0) { $0 + Int($1) } / 64
        return px.enumerated().reduce(UInt64(0)) { $1.element > avg ? $0 | (1 << UInt64($1.offset)) : $0 }
    }

    static func protection() async -> [ProtectionCheck] {
        func check(_ title: String, _ cmd: String, _ args: [String], _ ok: String, _ onText: String, _ offText: String, _ detail: String) async -> ProtectionCheck {
            let out = await Shell.run(cmd, args, timeout: 15).output.trimmed
            guard !out.isEmpty else { return ProtectionCheck(title: title, on: nil, summary: "Couldn't check", detail: detail) }
            let on = out.contains(regex: ok)
            return ProtectionCheck(title: title, on: on, summary: on ? onText : offText, detail: detail)
        }
        var items = [
            await check("Gatekeeper", "/usr/sbin/spctl", ["--status"], "assessments enabled", "Only trusted apps can open", "Any app can open", "Blocks apps that aren't signed by an identified developer."),
            await check("FileVault", "/usr/bin/fdesetup", ["status"], "FileVault is On", "Your disk is encrypted", "Your disk isn't encrypted", "Encrypts everything on the disk if your Mac is lost."),
            await check("Firewall", "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], "enabled|State = [12]", "Incoming connections are filtered", "Incoming connections aren't filtered", "Blocks unwanted incoming connections."),
            await check("System Integrity Protection", "/usr/bin/csrutil", ["status"], "enabled", "System files are protected", "System files can be modified", "Stops software from changing protected parts of macOS."),
        ]
        let xp = NSDictionary(contentsOfFile: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
        items.append(ProtectionCheck(title: "XProtect", on: xp != nil, summary: xp.map { "Malware definitions version \($0)" } ?? "Couldn't read definitions",
                                     detail: "Apple's built-in malware scanner, updated in the background."))
        return items
    }

    static func launchItems() -> [LaunchItem] {
        ["~/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"].flatMap { d in
            Paths.children(d).filter { $0.hasSuffix(".plist") }.map {
                LaunchItem(name: (Paths.name($0) as NSString).deletingPathExtension, path: Paths.short($0), allUsers: !$0.hasPrefix(HOME), broken: brokenReason($0))
            }
        }
    }

    /// A login item is broken when the program it launches is gone, usually because its app was deleted by dragging it
    /// to the Trash. Items that launch through a bundle identifier or a shell aren't judged.
    static func brokenReason(_ plist: String) -> String? {
        guard let d = NSDictionary(contentsOfFile: plist) as? [String: Any] else { return nil }
        let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
        guard let p = program, p.hasPrefix("/"), !p.hasPrefix("/bin/"), !p.hasPrefix("/usr/bin/"), !p.hasPrefix("/System/") else { return nil }
        return FileManager.default.fileExists(atPath: p) ? nil : "Its program is gone: \(Paths.short(p))"
    }

    static func outdatedCasks() async -> [OutdatedCask] {
        var env = Shell.baseEnvironment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"; env["HOMEBREW_NO_ANALYTICS"] = "1"
        let r = await Shell.run("brew", ["outdated", "--cask", "--greedy", "--json=v2"], environment: env, timeout: 120)
        guard r.ok, let o = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any], let casks = o["casks"] as? [[String: Any]] else { return [] }
        return casks.map { OutdatedCask(name: $0["name"] as? String ?? "", installed: ($0["installed_versions"] as? [String] ?? []).joined(separator: ", "),
                                        current: $0["current_version"] as? String ?? "") }
    }

    enum UpgradeResult { case updated, needsPassword, failed(String) }

    /// Updates one Homebrew app the way `brew upgrade --cask` does, without a Terminal. Installers that ask for an
    /// administrator password can't do that here, so they report it and the caller offers Terminal instead.
    static func upgradeCask(_ name: String) async -> UpgradeResult {
        var env = Shell.baseEnvironment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"; env["HOMEBREW_NO_ANALYTICS"] = "1"; env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["SUDO_ASKPASS"] = "/usr/bin/false"   // never hang on a password prompt nobody can see
        let r = await Shell.run("brew", ["upgrade", "--cask", name], environment: env, timeout: 1800)
        if r.ok { return .updated }
        let out = r.output.lowercased()
        if out.contains("sudo") || out.contains("password") || out.contains("a terminal is required") { return .needsPassword }
        let last = r.output.split(separator: "\n").last { $0.lowercased().contains("error") }.map(String.init) ?? r.output.split(separator: "\n").last.map(String.init) ?? ""
        return .failed(last.replacingOccurrences(of: "Error: ", with: "").trimmed)
    }

    /// Opens Terminal running the update, for installers that need your password.
    static func upgradeInTerminal(_ name: String) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("Roomy update \(name).command")
        try? "#!/bin/zsh\nbrew upgrade --cask \(name)\necho\necho 'Done. You can close this window.'\n".write(to: f, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        NSWorkspace.shared.open(f)
    }

    static func disk() -> DiskInfo {
        let u = URL(fileURLWithPath: "/System/Volumes/Data")
        let v = try? u.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey])
        let total = Int64(v?.volumeTotalCapacity ?? 0), free = Int64(v?.volumeAvailableCapacity ?? 0)
        let important = v?.volumeAvailableCapacityForImportantUsage ?? Int64(free)
        let name = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"
        return DiskInfo(name: name, total: total, used: total - free, free: free, purgeable: max(0, important - free))
    }
}
