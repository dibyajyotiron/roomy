// SPDX-License-Identifier: GPL-3.0-or-later
// Checks for MoleCore. Unit checks run on temp fixtures; `--parity` also compares results with
// the installed `mo` (Mole) on real folders. Nothing here deletes anything outside the temp dir.

import Darwin
import Foundation
import MoleCore

var passed = 0, failed = 0
func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { passed += 1; print("  ✓ \(name)") } else { failed += 1; print("  ✗ \(name) \(detail())") }
}
func suite(_ name: String, _ body: () throws -> Void) {
    print(name)
    do { try body() } catch { failed += 1; print("  ✗ threw \(error)") }
}

let fm = FileManager.default
let tmp = NSTemporaryDirectory() + "molecore-checks-\(getpid())"
try? fm.removeItem(atPath: tmp)
try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: tmp) }

func write(_ path: String, bytes: Int) throws {
    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in for i in stride(from: 0, to: bytes, by: 4096) { raw[i] = UInt8(truncatingIfNeeded: i / 4096 + 1) } }
    try data.write(to: URL(fileURLWithPath: path))
}
func lsize(_ p: String) -> Int64 { var st = stat(); lstat(p, &st); return FileSizer.actualSize(st) }
func shell(_ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try? p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Disk usage

suite("DiskUsage") {
    let d = tmp + "/disk"
    try write(d + "/a.bin", bytes: 1_000_000)
    let one = lsize(d + "/a.bin")
    check(one == 1_000_000, "regular file counts its logical size when fully allocated", "\(one)")

    // Hard link: counted once, like du
    link(d + "/a.bin", d + "/a-link.bin")
    var r = DirectorySizer().measure(d)
    check(r.bytes == one && r.deduplicated == 1, "hard link counted once", "bytes=\(r.bytes) dup=\(r.deduplicated)")

    // APFS clone sharing every block: counted once
    let c = tmp + "/clones"
    try write(c + "/src.bin", bytes: 2_000_000)
    let cloned = clonefile(c + "/src.bin", c + "/clone.bin", 0) == 0
    if cloned, let id = CloneIdentity.read(path: c + "/clone.bin") {
        check(id.sharesAllBlocks, "fresh clone reports shares-all-blocks")
        r = DirectorySizer().measure(c)
        check(r.bytes == lsize(c + "/src.bin") && r.deduplicated == 1, "unedited clone counted once", "bytes=\(r.bytes) dup=\(r.deduplicated)")
        // Edit the clone: it now owns blocks and counts in full
        let fh = FileHandle(forWritingAtPath: c + "/clone.bin")!
        try fh.seek(toOffset: 0); fh.write(Data(repeating: 0xAB, count: 8192)); try fh.close()
        r = DirectorySizer().measure(c)
        check(r.bytes == lsize(c + "/src.bin") + lsize(c + "/clone.bin") && r.deduplicated == 0,
              "edited clone counted in full", "bytes=\(r.bytes)")
    } else {
        check(false, "APFS clones supported in temp dir", "clonefile failed: \(errno)")
    }

    // Sparse file: counts allocated blocks, not its logical length
    let sp = tmp + "/sparse.bin"
    fm.createFile(atPath: sp, contents: nil)
    let fd = open(sp, O_WRONLY); ftruncate(fd, 500_000_000); close(fd)
    check(lsize(sp) < 1_000_000, "sparse file counts allocated blocks only", "\(lsize(sp))")

    // Symlink: only the link itself, never the target
    let s = tmp + "/links"
    try fm.createDirectory(atPath: s, withIntermediateDirectories: true)
    symlink(d + "/a.bin", s + "/to-a")
    r = DirectorySizer().measure(s)
    check(r.bytes < 100_000, "symlink isn't followed", "\(r.bytes)")

    // Mount-like folders are skipped as children but measured when asked for directly
    let m = tmp + "/mounts"
    try write(m + "/OrbStack/disk.img", bytes: 3_000_000)
    try write(m + "/keep.bin", bytes: 100_000)
    r = DirectorySizer().measure(m)
    check(r.bytes == lsize(m + "/keep.bin"), "default skip dirs aren't descended into", "\(r.bytes)")
    check(DirectorySizer().measure(m + "/OrbStack").bytes == lsize(m + "/OrbStack/disk.img"), "a skip dir measured directly is counted")

    // Siblings share one dedupe set: a file linked into two children counts once overall
    let sib = tmp + "/siblings"
    try write(sib + "/x/f.bin", bytes: 400_000)
    try fm.createDirectory(atPath: sib + "/y", withIntermediateDirectories: true)
    link(sib + "/x/f.bin", sib + "/y/f.bin")
    let kids = DirectorySizer().children(of: sib)
    check(kids.map(\.result.bytes).reduce(0, +) == lsize(sib + "/x/f.bin"), "hard link across siblings counted once")
    check(DirectorySizer().measure(tmp + "/does-not-exist").status == .unavailable, "missing path is unavailable")

    // Folded folders (node_modules, .venv…) are sized like du: clones inside count in full
    let f = tmp + "/fold"
    try write(f + "/node_modules/pkg/a.bin", bytes: 1_500_000)
    _ = clonefile(f + "/node_modules/pkg/a.bin", f + "/node_modules/pkg/b.bin", 0)
    try write(f + "/src/x.bin", bytes: 1_500_000)
    _ = clonefile(f + "/src/x.bin", f + "/src/y.bin", 0)
    let a = lsize(f + "/node_modules/pkg/a.bin"), x = lsize(f + "/src/x.bin")
    let kids2 = Dictionary(uniqueKeysWithValues: DirectorySizer().children(of: f).map { ($0.name, $0.result.bytes) })
    check((kids2["node_modules"] ?? 0) >= 2 * a, "folded node_modules counts clones in full, like du", "\(kids2["node_modules"] ?? -1)")
    check(kids2["src"] == x, "unfolded folder counts the clone once", "\(kids2["src"] ?? -1)")
    check(DirectorySizer(foldsLikeMole: false).children(of: f).first { $0.name == "node_modules" }?.result.bytes == a,
          "with folding off, clones count once everywhere")
    check(DirectorySizer.shouldFold(name: "a", path: NSHomeDirectory() + "/.npm/_cacache/a"), "npm cache layout folds")
    // duSize matches the real du -skPx
    for p in [f + "/node_modules", tmp + "/disk", tmp + "/clones"] {
        let duOut = shell(["du", "-skPx", p]).split(separator: "\t").first.flatMap { Int64($0) } ?? -1
        check(DirectorySizer.duSize(p).bytes == duOut * 1024, "duSize matches du -skPx for \((p as NSString).lastPathComponent)",
              "ours \(DirectorySizer.duSize(p).bytes) du \(duOut * 1024)")
    }
}

// MARK: - Path safety

suite("PathSafety") {
    let home = NSHomeDirectory()
    let safety = PathSafety()
    for bad in ["", "relative/path", "/a/../etc", "/a/\u{0}b"] {
        check((try? PathSafety.validate(bad)) == nil, "rejects \(bad.debugDescription)")
    }
    check((try? PathSafety.validate(home + "/Downloads/x.dmg")) != nil, "accepts a normal absolute path")
    for p in ["/", "/System", "/System/Library/CoreServices", "/usr/bin", "/Applications", "/Applications/Safari.app/Contents",
              "/Library/Keychains/x", "/private/var/db/x", "/opt/homebrew", "/Users"] {
        check(safety.isProtected(p), "protects \(p)")
    }
    check(safety.isProtected(home), "protects your home folder itself")
    if let other = (try? fm.contentsOfDirectory(atPath: "/Users"))?.first(where: { $0 != "Shared" && !$0.hasPrefix(".") }) {
        check(safety.isProtected("/Users/" + other), "protects account root /Users/\(other)")
    }
    check(!safety.isProtected(home + "/Library/Caches/com.example"), "allows a cache inside your home")
    check(!safety.isProtected(home + "/Downloads/old.dmg"), "allows a download")
    check(safety.isProtected(home + "/Library/Containers/com.docker.docker/Data/vms"), "protects Docker Desktop's VM state")
    check(safety.isProtected(home + "/.orbstack/data"), "protects OrbStack state")
    check(safety.isProtected(home + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"), "protects OrbStack group container")
    check(safety.isProtected("/private/var/folders/ab/cd/C/com.crowdstrike.falcon.Agent"), "protects EDR agent caches")
    check(!safety.isProtected("/private/var/folders/ab/cd/C/com.example.app"), "allows other per-user Darwin caches")
    // A symlink pointing into a protected tree is refused as a Trash target
    let trap = tmp + "/to-system"
    symlink("/System/Library", trap)
    check((try? safety.validateTrashTarget(trap)) == nil, "refuses a symlink that resolves into /System")
    check((try? safety.validateTrashTarget(tmp + "/disk/a.bin")) != nil, "accepts an ordinary temp file")
}

// MARK: - Cleanable

suite("Cleanable") {
    let p = tmp + "/proj"
    try fm.createDirectory(atPath: p + "/node_modules", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: p + "/src", withIntermediateDirectories: true)
    check(Cleanable.isCleanableDir(p + "/node_modules"), "node_modules is cleanable")
    check(!Cleanable.isCleanableDir(p + "/src"), "source folders aren't")
    check(!Cleanable.isCleanableDir(NSHomeDirectory() + "/Library/Caches/x/node_modules"), "skips paths regular cleanup handles")
    try fm.createDirectory(atPath: p + "/tagged", withIntermediateDirectories: true)
    try (Cleanable.cacheDirTagSignature + "\n# made by a tool\n").write(toFile: p + "/tagged/CACHEDIR.TAG", atomically: true, encoding: .utf8)
    check(Cleanable.isCleanableDir(p + "/tagged"), "valid CACHEDIR.TAG marks a cache")
    try fm.createDirectory(atPath: p + "/fake", withIntermediateDirectories: true)
    try "Signature: nope".write(toFile: p + "/fake/CACHEDIR.TAG", atomically: true, encoding: .utf8)
    check(!Cleanable.isCleanableDir(p + "/fake"), "wrong signature isn't trusted")
}

// MARK: - Byte format

suite("ByteFormat") {
    let cases: [(Int64, String)] = [(2_800_000_000, "2.80GB"), (1_005_000_000, "1.01GB"), (44_500_000, "44.5MB"),
                                    (14_499, "14KB"), (999, "999B"), (0, "0B")]
    for (n, want) in cases { check(ByteFormat.human(n) == want, "\(n) → \(want)", "got \(ByteFormat.human(n))") }
}

// MARK: - Parity with the installed Mole

func sh(_ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    var env = ProcessInfo.processInfo.environment; env["MOLE_DRY_RUN"] = "1"; env["NO_COLOR"] = "1"; p.environment = env
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try? p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

if CommandLine.arguments.contains("--parity") {
    suite("Parity with mo analyze") {
        let home = NSHomeDirectory()
        let folders = ["/.nvm", "/.rustup", "/.vscode", "/Documents", "/Desktop"].map { home + $0 }.filter { fm.fileExists(atPath: $0) }
        for folder in folders {
            let json = sh(["mo", "analyze", "--json", folder])
            guard let start = json.firstIndex(of: "{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) as? [String: Any],
                  let entries = obj["entries"] as? [[String: Any]] else {
                check(false, "mo analyze \(folder)", "no JSON"); continue
            }
            let moTotal = (obj["total_size"] as? Int64) ?? entries.compactMap { $0["size"] as? Int64 }.reduce(0, +)
            let ours = DirectorySizer().children(of: folder)
            let oursTotal = ours.map(\.result.bytes).reduce(0, +)
            let diff = Double(abs(oursTotal - moTotal)) / Double(max(moTotal, 1)) * 100
            check(diff <= 1.0, "\(folder.replacingOccurrences(of: home, with: "~")) total \(ByteFormat.human(oursTotal)) vs mo \(ByteFormat.human(moTotal))",
                  String(format: "diff %.2f%%", diff))
            // The three largest rows should match one by one
            let byName = Dictionary(ours.map { ($0.path, $0.result.bytes) }, uniquingKeysWith: { a, _ in a })
            for e in entries.sorted(by: { ($0["size"] as? Int64 ?? 0) > ($1["size"] as? Int64 ?? 0) }).prefix(3) {
                guard let path = e["path"] as? String, let size = e["size"] as? Int64, let mine = byName[path] else { continue }
                let d = Double(abs(mine - size)) / Double(max(size, 1)) * 100
                check(d <= 1.0 || abs(mine - size) < 1_000_000, "  row \((path as NSString).lastPathComponent) \(ByteFormat.human(mine)) vs \(ByteFormat.human(size))",
                      String(format: "diff %.2f%%", d))
            }
        }
    }
    suite("Parity with Mole's bytes_to_human") {
        let base = sh(["sh", "-c", "ls -d /opt/homebrew/Cellar/mole/*/libexec/lib/core/base.sh 2>/dev/null | tail -1"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { check(true, "Mole's shell library not found, skipped"); return }
        for n: Int64 in [0, 999, 14_499, 44_500_000, 1_005_000_000, 2_800_000_000, 123_456_789_012] {
            let theirs = sh(["bash", "-c", "source \"$0\" >/dev/null 2>&1; bytes_to_human \(n)", base]).trimmingCharacters(in: .whitespacesAndNewlines)
            check(theirs == ByteFormat.human(n), "\(n): \(ByteFormat.human(n)) vs mo \(theirs)")
        }
    }
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
