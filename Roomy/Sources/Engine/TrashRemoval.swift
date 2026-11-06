import Foundation
import Darwin

/// Empty only a real Trash directory, using descriptors so symlinked ancestors inside it are never followed.
enum TrashRemoval {
    struct Result { var removed = 0; var failed = 0 }

    static func empty(home: String) throws -> Result {
        let homeFD = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard homeFD >= 0 else { throw POSIXError(.EACCES) }
        defer { close(homeFD) }
        let trashFD = openat(homeFD, ".Trash", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard trashFD >= 0 else { throw POSIXError(.EACCES) }
        defer { close(trashFD) }
        var result = Result()
        for name in try children(trashFD) {
            do { try remove(name, in: trashFD); result.removed += 1 }
            catch { result.failed += 1 }
        }
        return result
    }

    private static func children(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw POSIXError(.EIO) }
        guard let dir = fdopendir(copy) else { close(copy); throw POSIXError(.EIO) }
        defer { closedir(dir) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw POSIXError(.EIO) }
        return names
    }

    private static func remove(_ name: String, in parent: Int32) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.EIO) }
        if info.st_mode & S_IFMT == S_IFDIR {
            var parentInfo = stat()
            guard fstat(parent, &parentInfo) == 0, info.st_dev == parentInfo.st_dev else { throw POSIXError(.EXDEV) }
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw POSIXError(.EACCES) }
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else {
                throw POSIXError(.EACCES)
            }
            for entry in try children(child) { try remove(entry, in: child) }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw POSIXError(.EIO) }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw POSIXError(.EIO) }
        }
    }
}
