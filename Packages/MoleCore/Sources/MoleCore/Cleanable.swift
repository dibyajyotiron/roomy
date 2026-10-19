// SPDX-License-Identifier: GPL-3.0-or-later
// Ported from Mole (github.com/tw93/mole @ b9361703158c):
//   cmd/analyze/cleanable.go isCleanableDir, hasValidCacheDirTag, isHandledByMoClean,
//   moCleanHandledPathFragments, projectDependencyDirs

import Foundation

public enum Cleanable {
    public static let cacheDirTagFileName = "CACHEDIR.TAG"
    public static let cacheDirTagSignature = "Signature: 8a477f597d28d172789f06886806bc55"

    /// Paths the regular cleanup already handles, so the disk explorer doesn't offer them twice.
    public static let handledByCleanFragments = [
        "/Library/Caches/", "/Library/Logs/", "/Library/Saved Application State/", "/.Trash/",
        "/Library/DiagnosticReports/",
    ]

    /// Project dependency and build folders that tools rebuild.
    public static let projectDependencyDirs: Set<String> = [
        // JavaScript
        "node_modules", "bower_components", ".yarn", ".pnpm-store",
        // Python
        "venv", ".venv", "virtualenv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".tox", ".eggs", "htmlcov", ".ipynb_checkpoints",
        // Ruby / PHP
        "vendor", ".bundle",
        // Java / Kotlin
        ".gradle", "out",
        // Build outputs
        "build", "dist", "target", ".next", ".nuxt", ".output", ".parcel-cache", ".turbo", ".vite", ".nx",
        "coverage", ".coverage", ".nyc_output",
        // Frontend frameworks
        ".angular", ".svelte-kit", ".astro", ".docusaurus",
        // Apple / mobile
        "DerivedData", "Pods", ".build", "Carthage", ".dart_tool",
        // Infrastructure
        ".terraform",
    ]

    /// True for a folder that's safe to remove by hand and isn't already covered by cleanup:
    /// a tagged cache directory or a project dependency/build folder.
    public static func isCleanableDir(_ path: String) -> Bool {
        if path.isEmpty || isHandledByClean(path) { return false }
        if hasValidCacheDirTag(path) { return true }
        return projectDependencyDirs.contains((path as NSString).lastPathComponent)
    }

    public static func isHandledByClean(_ path: String) -> Bool {
        handledByCleanFragments.contains { path.contains($0) }
    }

    /// A CACHEDIR.TAG (bford.info/cachedir) marks the whole tree as regenerable cache.
    public static func hasValidCacheDirTag(_ path: String) -> Bool {
        let tag = path + "/" + cacheDirTagFileName
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: tag, isDirectory: &isDir), !isDir.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: tag),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: tag) else { return false }
        defer { try? handle.close() }
        let want = Data(cacheDirTagSignature.utf8)
        return (try? handle.read(upToCount: want.count)) == want
    }
}
