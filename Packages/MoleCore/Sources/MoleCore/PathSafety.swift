// SPDX-License-Identifier: GPL-3.0-or-later
// Ported from Mole (github.com/tw93/mole @ b9361703158c):
//   cmd/analyze/delete.go validatePath, validateTrashTarget, isProtectedAnalyzeDeletePath,
//   isCriticalAnalyzeDeletePath, protectedAnalyzeHomeRoots, isPathWithinExistingRoot,
//   isSameExistingPath, isDirectChildOfExistingRoot, isEndpointSecurityCachePath

import Darwin
import Foundation

public enum PathSafetyError: Error, Equatable, CustomStringConvertible {
    case empty, notAbsolute(String), nullByte, traversal(String), protected(String)

    public var description: String {
        switch self {
        case .empty: return "path is empty"
        case .notAbsolute(let p): return "path must be absolute: \(p)"
        case .nullByte: return "path contains null bytes"
        case .traversal(let p): return "path contains traversal components: \(p)"
        case .protected(let p): return "protected path cannot be deleted: \(p)"
        }
    }
}

public struct PathSafety: Sendable {
    /// Home folders to protect. Defaults to $HOME and the account's home, each also resolved
    /// through symlinks, as Mole does.
    public var homeRoots: [String]

    public init(homeRoots: [String]? = nil) {
        self.homeRoots = homeRoots ?? PathSafety.defaultHomeRoots()
    }

    /// Mirror of ENDPOINT_SECURITY_BUNDLE_PREFIXES: deleting anything inside an EDR/MDM agent's
    /// per-user Darwin cache trips tamper detection (e.g. CrowdStrike), so it is never removable.
    public static let endpointSecurityBundlePrefixes = [
        "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.", "com.eset.", "com.jamf.",
        "com.jamfsoftware.", "com.paloaltonetworks.", "com.cisco.anyconnect", "com.cisco.secureclient",
        "com.alibaba.security.",
    ]

    static let criticalRoots = [
        "/", "/Applications", "/Applications/Finder.app", "/Applications/Safari.app", "/Library",
        "/Library/Apple", "/Library/Application Support", "/Library/Extensions", "/Library/Keychains",
        "/System", "/Users", "/Volumes", "/Network", "/cores", "/dev", "/etc", "/home", "/net", "/tmp",
        "/var", "/private", "/private/etc", "/private/tmp", "/private/var", "/private/var/audit",
        "/private/var/db", "/private/var/root", "/private/var/tmp", "/private/var/folders", "/bin",
        "/sbin", "/usr", "/opt", "/opt/homebrew",
    ]

    /// System-owned trees that are never a cleanup surface, even when a caller starts inside one.
    static let protectedTrees = [
        "/System", "/bin", "/sbin", "/usr", "/private/etc", "/private/var/audit", "/private/var/db",
        "/private/var/root", "/Library/Apple", "/Library/Extensions", "/Library/Keychains",
        "/Applications/Finder.app", "/Applications/Safari.app", "/dev",
    ]

    /// Checks a path is safe to hand to an external command.
    public static func validate(_ path: String) throws {
        if path.isEmpty { throw PathSafetyError.empty }
        if !path.hasPrefix("/") { throw PathSafetyError.notAbsolute(path) }
        if path.contains("\u{0}") { throw PathSafetyError.nullByte }
        if path.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            throw PathSafetyError.traversal(path)
        }
    }

    /// Throws unless `path` may be moved to the Trash: valid, and neither it nor its resolved
    /// target is protected.
    public func validateTrashTarget(_ path: String) throws {
        try PathSafety.validate(path)
        if isProtected(path) { throw PathSafetyError.protected(path) }
        let resolved = (path as NSString).resolvingSymlinksInPath
        if resolved != path, isProtected(resolved) { throw PathSafetyError.protected(path) }
    }

    public func isProtected(_ path: String) -> Bool {
        if path.isEmpty { return false }
        let clean = PathSafety.clean(path)
        // EDR protection depends only on the absolute path, so it runs before anything that needs HOME.
        if PathSafety.isEndpointSecurityCache(clean) { return true }
        if PathSafety.isCritical(clean) { return true }
        for home in homeRoots {
            if clean == home || PathSafety.isSameExisting(clean, home) { return true }
            let docker = home + "/Library/Containers/com.docker.docker"
            if clean == docker || clean.hasPrefix(docker + "/") || PathSafety.isWithinExisting(clean, root: docker) { return true }
            let orb = home + "/.orbstack"
            if clean == orb || clean.hasPrefix(orb + "/") || PathSafety.isWithinExisting(clean, root: orb) { return true }
            let groups = home + "/Library/Group Containers"
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: groups)) ?? []
            where entry.lowercased().hasSuffix("dev.orbstack") {
                if PathSafety.isWithinExisting(clean, root: groups + "/" + entry) { return true }
            }
            let lowerGroups = groups.lowercased() + "/", lowerClean = clean.lowercased()
            if lowerClean.hasPrefix(lowerGroups) {
                let container = lowerClean.dropFirst(lowerGroups.count).split(separator: "/").first.map(String.init) ?? ""
                if container.hasSuffix("dev.orbstack") { return true }
            }
        }
        return false
    }

    public static func isCritical(_ path: String) -> Bool {
        for root in criticalRoots where path == root || isSameExisting(path, root) { return true }
        // A direct child of /Users is another account's home: protect the root, not its contents.
        if isDirectChildOfExisting(path, root: "/Users") { return true }
        for root in protectedTrees where path.hasPrefix(root + "/") || isWithinExisting(path, root: root) { return true }
        return false
    }

    public static func isEndpointSecurityCache(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.hasPrefix("/private/var/folders/") || lower.hasPrefix("/var/folders/") else { return false }
        return endpointSecurityBundlePrefixes.contains { lower.contains($0) }
    }

    // MARK: helpers (same-file checks use device + inode, like os.SameFile)

    static func clean(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." { parts.append(part) }
        return "/" + parts.joined(separator: "/")
    }

    static func identity(_ path: String) -> (Int32, UInt64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return (st.st_dev, UInt64(st.st_ino))
    }

    static func isSameExisting(_ a: String, _ b: String) -> Bool {
        guard let x = identity(a), let y = identity(b) else { return false }
        return x == y
    }

    static func isWithinExisting(_ path: String, root: String) -> Bool {
        guard let rootID = identity(root) else { return false }
        var current = clean(path)
        while true {
            if let id = identity(current), id == rootID { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }

    static func isDirectChildOfExisting(_ path: String, root: String) -> Bool {
        let c = clean(path)
        let parent = (c as NSString).deletingLastPathComponent
        return c != clean(root) && parent != c && isSameExisting(parent, root)
    }

    static func defaultHomeRoots() -> [String] {
        var roots: [String] = []
        func add(_ home: String?) {
            guard let home, !home.isEmpty else { return }
            let c = clean(home)
            if !roots.contains(c) { roots.append(c) }
            let resolved = (c as NSString).resolvingSymlinksInPath
            if !roots.contains(resolved) { roots.append(resolved) }
        }
        add(ProcessInfo.processInfo.environment["HOME"])
        add(NSHomeDirectory())
        return roots
    }
}
