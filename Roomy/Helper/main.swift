// roomy-fan: the only part of Roomy that runs as root. You install it yourself from Activity or the menu bar (one
// administrator prompt) into /Library/PrivilegedHelperTools. It touches nothing but the fans:
//   roomy-fan auto          hand the fans back to macOS. Anyone may ask: it only ever undoes a manual speed.
//   roomy-fan set <0-100>   hold every fan at that share of the way from its minimum to its maximum speed. Only the
//                           exact Roomy build recorded when you allowed fan control may ask (see CodeIdentity).
//   roomy-fan watch <pid>   started by `set`: waits for that Roomy to exit, however it exits (quit, crash, force
//                           quit), then hands the fans back to macOS, so they never stay pinned without Roomy.
import Foundation

#if ROOMY_FAN_DRY
// Test build only (scripts/check-security.sh): no root, no SMC. Paths come from the environment and every fan change is
// written to a log instead, so the caller check and the watcher can be exercised on fixtures.
let env = ProcessInfo.processInfo.environment
let allowFile = env["ROOMY_FAN_ALLOW"] ?? "/nonexistent"
let helperPath = CommandLine.arguments[0]
let markDir = env["ROOMY_FAN_DIR"] ?? "/nonexistent"
func fanLog(_ line: String) -> Bool {
    let h = FileHandle(forWritingAtPath: markDir + "/fans.log") ?? { FileManager.default.createFile(atPath: markDir + "/fans.log", contents: nil); return FileHandle(forWritingAtPath: markDir + "/fans.log")! }()
    h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); h.closeFile(); return true
}
func fansAuto() -> Bool { fanLog("auto") }
func fansSet(_ pct: Int) -> Bool { fanLog("set \(pct)") }
func becomeRoot() -> Bool { true }
func ownerOK(_ attrs: [FileAttributeKey: Any]) -> Bool { true }
#else
let allowFile = "/Library/PrivilegedHelperTools/app.roomy.fan.client"
let helperPath = "/Library/PrivilegedHelperTools/app.roomy.fan"
let markDir = "/var/run"
func fansAuto() -> Bool { let smc = SMC(); return smc.isOpen && smc.automatic() }
func fansSet(_ pct: Int) -> Bool { let smc = SMC(); return smc.isOpen && smc.setFans(fraction: Double(pct) / 100) }
// The file is setuid root; make the real user root too, so the SMC accepts writes.
func becomeRoot() -> Bool { setuid(0) == 0 }
func ownerOK(_ attrs: [FileAttributeKey: Any]) -> Bool { (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0 }
#endif

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

/// The Roomy build allowed to set speeds: a root-owned file holding one cdhash, written when you allowed fan control.
func allowedCaller() -> String? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: allowFile),
          ownerOK(attrs),
          ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0,
          attrs[.type] as? FileAttributeType == .typeRegular,
          let s = try? String(contentsOfFile: allowFile, encoding: .utf8) else { return nil }
    let h = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return CodeIdentity.isHash(h) ? h : nil
}

/// Starts the watcher for Roomy process `pid`, once per Roomy process, detached into its own session.
func startWatcher(for pid: pid_t) -> Bool {
    let mark = markDir + "/app.roomy.fan.watch.\(pid)"
    if let s = try? String(contentsOfFile: mark, encoding: .utf8), let w = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), kill(w, 0) == 0, CodeIdentity.cdhash(pid: w) == CodeIdentity.ownCDHash() { return true }
    var ready: [Int32] = [0, 0]
    guard pipe(&ready) == 0 else { return false }
    defer { close(ready[0]); close(ready[1]) }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var files: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&files)
    for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
    // The child must authenticate its live parent before that short-lived parent exits.
    posix_spawn_file_actions_adddup2(&files, ready[1], 3)
    if ready[0] != 3 { posix_spawn_file_actions_addclose(&files, ready[0]) }
    var child: pid_t = 0
    let args = [helperPath, "watch", String(pid)]
    let argv = args.map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = [nil]
    #if ROOMY_FAN_DRY
    envp = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("ROOMY_FAN_") }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    #endif
    let spawned = posix_spawn(&child, helperPath, &files, &attr, argv, envp) == 0
    if spawned {
        try? String(child).write(toFile: mark, atomically: true, encoding: .utf8)
    }
    argv.forEach { free($0) }
    envp.forEach { free($0) }
    posix_spawn_file_actions_destroy(&files)
    posix_spawnattr_destroy(&attr)
    guard spawned else { return false }
    var event = pollfd(fd: ready[0], events: Int16(POLLIN), revents: 0)
    var byte: UInt8 = 0
    guard poll(&event, 1, 5000) > 0, read(ready[0], &byte, 1) == 1, byte == 1 else {
        kill(child, SIGTERM)
        try? FileManager.default.removeItem(atPath: mark)
        return false
    }
    return true
}

/// Blocks until process `pid` exits (returns at once if it's already gone).
func waitForExit(of pid: pid_t) {
    let kq = kqueue()
    guard kq >= 0 else { return }
    var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
    var event = kevent()
    while true {
        let n = kevent(kq, &change, 1, &event, 1, nil)
        if n > 0 || (n < 0 && errno != EINTR) { break }
    }
    close(kq)
}

let args = Array(CommandLine.arguments.dropFirst())
// The caller is checked before anything runs as root.
let caller = getppid()
switch (args.first, args.count) {
case ("auto", 1):
    break
case ("set", 2):
    guard let pct = Int(args[1]), (0...100).contains(pct) else { fail("usage: roomy-fan set <0-100>", 64) }
    guard let allowed = allowedCaller(), let who = CodeIdentity.cdhash(pid: caller), who == allowed else {
        fail("Only the Roomy you allowed fan control for can set a speed. Open Roomy and allow fan control again.", 13)
    }
case ("watch", 2):
    guard let pid = pid_t(args[1]), pid > 1 else { fail("usage: roomy-fan watch <pid>", 64) }
    // Only this helper can start its internal root watcher, never an arbitrary local process.
    guard CodeIdentity.cdhash(pid: caller) == CodeIdentity.ownCDHash() else { fail("Internal command", 13) }
    #if !ROOMY_FAN_DRY
    guard getuid() == 0 else { fail("Internal command", 13) }
    #endif
#if ROOMY_FAN_DRY
case ("whoami", 1):
    print(CodeIdentity.cdhash(pid: caller) ?? "none"); exit(0)
#endif
default:
    fail("usage: roomy-fan auto | set <0-100>", 64)
}

guard becomeRoot() else { fail("roomy-fan must be installed as root to control the fans", 77) }

if args[0] == "watch", let pid = pid_t(args[1]) {
    var ready: UInt8 = 1
    guard write(3, &ready, 1) == 1 else { exit(1) }
    close(3)
    // Wait for the set operation to finish before resetting, even if Roomy exits during startup.
    waitForExit(of: caller)
    waitForExit(of: pid)
    _ = fansAuto()
    try? FileManager.default.removeItem(atPath: markDir + "/app.roomy.fan.watch.\(pid)")
    exit(0)
}

if args[0] == "auto" { exit(fansAuto() ? 0 : 1) }
let pct = Int(args[1])!
// The watcher starts before the fans change, so there's never a moment they're pinned without one.
guard startWatcher(for: caller) else {
    _ = fansAuto()
    fail("Could not start the fan safety watcher; fans remain automatic", 1)
}
exit(fansSet(pct) ? 0 : 1)
