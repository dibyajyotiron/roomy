import Foundation

/// Mole's keep list (~/.config/mole/whitelist). Checkup uses it so anything you untick in the review stays put:
/// those paths are added for that one clean and the file is put back exactly as it was afterwards.
///
/// One rule matters: when the file exists, Mole uses only what's in it and drops its own built-in protections
/// (Spotlight and font caches, iCloud Drive, model downloads…). So whenever Roomy creates the file it starts from
/// Mole's built-in list. If Roomy stops halfway, the leftover file only protects more, never less, and the next
/// launch restores it.
enum MoleWhitelist {
    static let file = Mole.config + "/whitelist"
    private static let backup = Paths.support.appendingPathComponent("mole-whitelist.backup").path
    private static let absentMark = "ROOMY-NO-WHITELIST-FILE"

    /// Mole's built-in protections, read from the installed Mole so they stay current; a copy is the fallback.
    static func defaults() -> [String] {
        var lines: [String] = []
        if let mo = Mole.path {
            let root = URL(fileURLWithPath: mo).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            if let s = try? String(contentsOf: root.appendingPathComponent("libexec/lib/core/base.sh"), encoding: .utf8),
               let r = s.range(of: "DEFAULT_WHITELIST_PATTERNS=("), let end = s[r.upperBound...].range(of: "\n)") {
                for raw in s[r.upperBound..<end.lowerBound].split(separator: "\n") {
                    let t = raw.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("\""), t.hasSuffix("\""), t.count > 2 else { continue }
                    lines.append(String(t.dropFirst().dropLast()).replacingOccurrences(of: "$HOME", with: HOME)
                        .replacingOccurrences(of: "$FINDER_METADATA_SENTINEL", with: "FINDER_METADATA"))
                }
            }
        }
        if !lines.isEmpty { return lines }
        return ["/Library/Caches/ms-playwright*", "/.cache/huggingface*", "/.m2/repository/*", "/.gradle/caches/*", "/.gradle/daemon/*",
                "/.ollama/models/*", "/Library/Caches/JetBrains*", "/Library/Application Support/JetBrains*", "/Library/Caches/com.apple.finder",
                "/Library/Mobile Documents*", "/Library/Caches/com.apple.FontRegistry*", "/Library/Caches/com.apple.spotlight*",
                "/Library/Caches/com.apple.Spotlight*", "/Library/Caches/CloudKit*"].map { HOME + $0 } + ["FINDER_METADATA"]
    }

    private static func baseText() -> String {
        if let d = FileManager.default.contents(atPath: file) { return String(decoding: d, as: UTF8.self) }
        return (["# Mole's built-in protections, copied by Roomy so they keep working alongside your own entries."] + defaults()).joined(separator: "\n") + "\n"
    }

    /// Runs `body` with `paths` protected, then restores the keep list.
    static func keeping<T>(_ paths: [String], _ body: () async -> T) async -> T {
        let extra = paths.map(Paths.expand).filter { $0.hasPrefix("/") && !$0.contains("..") }
        guard !extra.isEmpty else { return await body() }
        let original = FileManager.default.contents(atPath: file)
        try? FileManager.default.createDirectory(atPath: Mole.config, withIntermediateDirectories: true)
        try? (original ?? Data(absentMark.utf8)).write(to: URL(fileURLWithPath: backup), options: .atomic)
        let text = baseText().trimmingCharacters(in: .newlines) + "\n# Roomy: kept for this clean only\n" + extra.joined(separator: "\n") + "\n"
        try? text.write(toFile: file, atomically: true, encoding: .utf8)
        defer { restore() }
        return await body()
    }

    /// Puts the keep list back as it was before a clean. Also runs at launch, in case Roomy quit mid-clean.
    static func restore() {
        guard let saved = FileManager.default.contents(atPath: backup) else { return }
        if saved == Data(absentMark.utf8) { try? FileManager.default.removeItem(atPath: file) }
        else { try? saved.write(to: URL(fileURLWithPath: file), options: .atomic) }
        try? FileManager.default.removeItem(atPath: backup)
    }

    /// Adds a path to the keep list for good ("Always keep"), so neither Mole nor Roomy cleans it again.
    static func keepAlways(_ path: String) {
        let p = Paths.expand(path)
        guard p.hasPrefix("/"), !p.contains("..") else { return }
        var text = baseText()
        guard !text.split(separator: "\n").contains(where: { $0 == p }) else { return }
        if !text.hasSuffix("\n") { text += "\n" }
        text += p + "\n"
        try? FileManager.default.createDirectory(atPath: Mole.config, withIntermediateDirectories: true)
        try? text.write(toFile: file, atomically: true, encoding: .utf8)
    }
}
