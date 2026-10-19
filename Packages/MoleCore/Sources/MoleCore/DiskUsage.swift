// SPDX-License-Identifier: GPL-3.0-or-later
// Ported from Mole (github.com/tw93/mole @ b9361703158c):
//   cmd/analyze/scanner.go   countableFileSize, getActualFileSize, scanChildren (symlink rule)
//   cmd/analyze/clone_darwin.go cloneIdentity
//   cmd/analyze/constants.go defaultSkipDirs, foldDirs
//   cmd/analyze/scanner.go   shouldFoldDirWithPath, getDirectorySizeFromDu (du -skPx)

import Darwin
import Foundation

/// An APFS file's clone identity, read with getattrlist.
public struct CloneIdentity: Equatable, Sendable {
    public let cloneID: UInt64
    /// True while the clone still shares every block with another file.
    public let sharesAllBlocks: Bool

    // Extended common attributes (sys/attr.h). With FSOPT_ATTR_CMN_EXTENDED they travel in the
    // fork group of the attribute list; asked for in commonattr, the kernel silently answers with
    // plain common attributes instead.
    static let attrCmnextCloneID: UInt32 = 0x0000_0100
    static let attrCmnextExtFlags: UInt32 = 0x0000_0200
    static let efSharesAllBlocks: UInt64 = 0x0000_0040
    static let fsoptNoFollow: UInt32 = 0x0000_0001
    static let fsoptAttrCmnExtended: UInt32 = 0x0000_0020

    /// Nil when the volume can't say (no clone tracking, network share) or the path can't be read;
    /// callers then size the file the plain way.
    public static func read(path: String) -> CloneIdentity? {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrCmnextCloneID | attrCmnextExtFlags
        // Reply: u32 length, then the clone id and the extended flags, both u64 (packed).
        var buf = [UInt8](repeating: 0, count: 20)
        let rc = buf.withUnsafeMutableBytes { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, fsoptNoFollow | fsoptAttrCmnExtended)
        }
        guard rc == 0, le32(buf, 0) >= UInt32(buf.count) else { return nil }
        return CloneIdentity(cloneID: le64(buf, 4), sharesAllBlocks: le64(buf, 12) & efSharesAllBlocks != 0)
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * UInt32($1)) }
    }

    private static func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }
    }
}

/// Tracks hard links and fully shared APFS clones already counted in one scan.
public final class SeenFiles: @unchecked Sendable {
    private struct Inode: Hashable { let dev: UInt32; let ino: UInt64 }
    private struct Clone: Hashable { let dev: UInt32; let id: UInt64 }
    private var inodes = Set<Inode>()
    private var clones = Set<Clone>()
    private let lock = NSLock()

    public init() {}

    func firstSighting(dev: UInt32, ino: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inodes.insert(Inode(dev: dev, ino: ino)).inserted
    }

    func firstSighting(dev: UInt32, cloneID: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return clones.insert(Clone(dev: dev, id: cloneID)).inserted
    }
}

public enum FileSizer {
    /// On-disk size Mole attributes to a file: allocated blocks, capped at the logical size
    /// (sparse files count their blocks, everything else its length).
    public static func actualSize(_ st: stat) -> Int64 {
        let allocated = Int64(st.st_blocks) * 512
        return allocated < Int64(st.st_size) ? allocated : Int64(st.st_size)
    }

    /// Size to count for a regular file. Hard links count once per scan, like `du`. An APFS clone
    /// that still shares every block with another file counts once per clone id; an edited clone
    /// owns blocks and counts in full, because macOS doesn't say how many it shares.
    /// Returns the size and whether this file was a zero-counted duplicate.
    public static func countableSize(path: String, stat st: stat, seen: SeenFiles?) -> (bytes: Int64, deduplicated: Bool) {
        let size = actualSize(st)
        guard let seen else { return (size, false) }
        let dev = UInt32(bitPattern: st.st_dev)
        if st.st_nlink > 1, !seen.firstSighting(dev: dev, ino: UInt64(st.st_ino)) {
            return (0, true)
        }
        if size == 0 { return (0, false) }
        if let clone = CloneIdentity.read(path: path), clone.sharesAllBlocks,
           !seen.firstSighting(dev: dev, cloneID: clone.cloneID) {
            return (0, true)
        }
        return (size, false)
    }
}

/// Measures folders the way `mo analyze` does.
public struct DirectorySizer: Sendable {
    public enum Status: String, Sendable { case complete, partial, unavailable }

    public struct Result: Sendable {
        public var bytes: Int64 = 0
        public var files: Int = 0
        public var deduplicated: Int = 0
        public var failures: Int = 0
        public var status: Status { failures == 0 ? .complete : (bytes > 0 ? .partial : .unavailable) }
    }

    /// Folder names Mole never descends into: network and VM mounts that would be measured
    /// elsewhere or hang the scan.
    public static let defaultSkipDirs: Set<String> = [
        "nfs", "PHD", "Permissions",
        "OrbStack", "Colima", "VMware Fusion", "VirtualBox VMs", "Rancher Desktop",
        ".lima", ".colima", ".orbstack",
    ]

    /// Folders Mole sizes with `du -skPx` instead of expanding them: dependency, build, cache and
    /// tool folders. Hard links dedupe only inside each one, and APFS clones count in full.
    public static let foldDirs: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", ".npm", "_npx", "_cacache", "_logs", "_locks", "_quick", "_libvips", "_prebuilds",
        "_update-notifier-last-checked", ".yarn", ".pnpm-store", ".next", ".nuxt", "bower_components", ".vite",
        ".turbo", ".parcel-cache", ".nx", ".rush", "tnpm", ".tnpm", ".bun", ".deno",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", "venv", ".venv", "virtualenv", ".tox",
        "site-packages", ".eggs", "*.egg-info", ".pyenv", ".poetry", ".pip", ".pipx",
        "vendor", ".bundle", "gems", ".rbenv", "target", ".gradle", ".m2", ".ivy2", "out", "pkg",
        "composer.phar", ".composer", ".cargo",
        "build", "dist", ".output", "coverage", ".coverage",
        ".idea", ".vscode", ".vs", ".fleet",
        ".cache", "__MACOSX", ".DS_Store", ".Trash", "Caches", ".Spotlight-V100", ".fseventsd",
        ".DocumentRevisions-V100", ".TemporaryItems", "$RECYCLE.BIN", ".temp", ".tmp", "_temp", "_tmp",
        ".Homebrew", ".rustup", ".sdkman", ".nvm",
        "Application Scripts", "Saved Application State", "Mobile Documents",
        ".docker", ".containerd",
        "Pods", "DerivedData", ".build", "xcuserdata", "Carthage", ".dart_tool",
        ".angular", ".svelte-kit", ".astro", ".solid",
        ".mysql", ".postgres", "mongodb",
        ".terraform", ".vagrant", "tmp", "temp",
    ]

    public var skipDirs: Set<String>
    /// Mole parity: size folded folders like `du`. Turn off to count clones once everywhere.
    public var foldsLikeMole: Bool

    public init(skipDirs: Set<String> = DirectorySizer.defaultSkipDirs, foldsLikeMole: Bool = true) {
        self.skipDirs = skipDirs
        self.foldsLikeMole = foldsLikeMole
    }

    /// Mole's shouldFoldDirWithPath: the fold list, plus npm's cache layout.
    public static func shouldFold(name: String, path: String) -> Bool {
        if foldDirs.contains(name) { return true }
        if path.contains("/.npm/") || path.contains("/.tnpm/") {
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if parent == ".npm" || parent == ".tnpm" || parent.hasPrefix("_") { return true }
            if name.count == 1 { return true }
        }
        return false
    }

    /// What `du -skPx` reports, in bytes: allocated blocks of everything under `path`, symlinks not
    /// followed, staying on one filesystem, each hard-linked inode once within this call.
    public static func duSize(_ path: String) -> Result {
        var r = Result()
        var root = stat()
        guard lstat(path, &root) == 0 else { r.failures = 1; return r }
        var inodes = Set<UInt64>()
        var blocks: Int64 = 0
        func visit(_ p: String) {
            var st = stat()
            guard lstat(p, &st) == 0 else { r.failures += 1; return }
            if st.st_nlink > 1, st.st_mode & S_IFMT != S_IFDIR, !inodes.insert(UInt64(st.st_ino)).inserted { return }
            blocks += Int64(st.st_blocks)
            if st.st_mode & S_IFMT != S_IFDIR { r.files += 1; return }
            if st.st_dev != root.st_dev { return }
            guard let dir = opendir(p) else { r.failures += 1; return }
            defer { closedir(dir) }
            while let ent = readdir(dir) {
                let name = DirectorySizer.entryName(ent)
                if name == "." || name == ".." { continue }
                visit(p + "/" + name)
            }
        }
        visit(path)
        // du -k rounds each total up to whole KiB; Mole multiplies that by 1024.
        r.bytes = ((blocks * 512 + 1023) / 1024) * 1024
        return r
    }

    static func entryName(_ ent: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: ent.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
        }
    }

    /// Total for a file or folder. Symlinks count only their own size and are never followed.
    public func measure(_ path: String, seen: SeenFiles = SeenFiles()) -> Result {
        var result = Result()
        walk(path, isRoot: true, seen: seen, into: &result)
        return result
    }

    private func walk(_ path: String, isRoot: Bool, seen: SeenFiles, into r: inout Result) {
        var st = stat()
        guard lstat(path, &st) == 0 else { r.failures += 1; return }
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK || type == S_IFREG {
            let (bytes, dup) = type == S_IFREG ? FileSizer.countableSize(path: path, stat: st, seen: seen)
                                               : (FileSizer.actualSize(st), false)
            r.bytes += bytes
            r.files += 1
            if dup { r.deduplicated += 1 }
            return
        }
        guard type == S_IFDIR else { return }
        let name = (path as NSString).lastPathComponent
        if !isRoot, skipDirs.contains(name) { return }
        if !isRoot, foldsLikeMole, DirectorySizer.shouldFold(name: name, path: path) {
            let folded = DirectorySizer.duSize(path)
            r.bytes += folded.bytes
            r.files += folded.files
            r.failures += folded.failures
            return
        }
        guard let dir = opendir(path) else { r.failures += 1; return }
        defer { closedir(dir) }
        while let ent = readdir(dir) {
            let child = DirectorySizer.entryName(ent)
            if child == "." || child == ".." { continue }
            walk(path == "/" ? "/" + child : path + "/" + child, isRoot: false, seen: seen, into: &r)
        }
    }

    /// Measures each direct child of `folder` (the rows a disk explorer shows), sharing one
    /// dedupe set across siblings so a file hard-linked into two children counts once.
    public func children(of folder: String) -> [(name: String, path: String, result: Result)] {
        let seen = SeenFiles()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.sorted().compactMap { name in
            let path = folder == "/" ? "/" + name : folder + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            if st.st_mode & S_IFMT == S_IFDIR {
                if skipDirs.contains(name) { return nil }
                if foldsLikeMole, DirectorySizer.shouldFold(name: name, path: path) { return (name, path, DirectorySizer.duSize(path)) }
            }
            return (name, path, measure(path, seen: seen))
        }
    }
}
