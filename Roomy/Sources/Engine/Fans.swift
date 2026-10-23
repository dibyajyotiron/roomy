import Foundation
import AppKit

/// Fan speeds, read straight from the SMC, and three presets like Mole's: Auto (macOS decides), Cool and Max.
/// Changing speed needs root, so it goes through roomy-fan, a two-command helper you install once. Roomy always hands
/// the fans back to macOS when it quits.
@MainActor @Observable
final class Fans {
    enum Preset: String, CaseIterable, Identifiable {
        case auto = "Auto", cool = "Cool", max = "Max"
        var id: String { rawValue }
        /// Share of the way from minimum to maximum speed; nil lets macOS decide.
        var fraction: Int? { switch self { case .auto: nil; case .cool: 60; case .max: 100 } }
    }

    static let helperPath = "/Library/PrivilegedHelperTools/app.roomy.fan"
    /// The Roomy build allowed to set speeds (its cdhash), root-owned, written when you allow fan control.
    static let allowPath = "/Library/PrivilegedHelperTools/app.roomy.fan.client"
    static var bundledHelper: String { Bundle.main.bundlePath + "/Contents/MacOS/roomy-fan" }

    var fans: [SMC.Fan] = []
    var preset: Preset = .auto
    var busy = false
    var problem: String?
    var helper: HelperState = .missing
    enum HelperState { case missing, outdated, ready }

    private let smc = SMC()

    var hasFans: Bool { !fans.isEmpty }
    var rpm: Double { fans.map(\.rpm).max() ?? 0 }
    var share: Double {
        guard let f = fans.max(by: { $0.rpm < $1.rpm }), f.max > 0 else { return 0 }
        return f.rpm / f.max
    }
    /// The fans are held by something other than Roomy (another fan app, or a preset from a session that crashed).
    var heldElsewhere: Bool { preset == .auto && fans.contains(where: \.manual) }

    init() {
        refresh()
        checkHelper()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { self.releaseOnQuit() }
        }
    }

    func refresh() { fans = smc.fans() }

    func checkHelper() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: Self.helperPath),
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o4000 != 0 else { helper = .missing; return }
        // Ready only when it's this build's helper and it lets this exact build set speeds; after an update it's allowed again once.
        let allowed = (try? String(contentsOfFile: Self.allowPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowOwner = (try? fm.attributesOfItem(atPath: Self.allowPath))?[.ownerAccountID] as? NSNumber
        helper = fm.contentsEqual(atPath: Self.helperPath, andPath: Self.bundledHelper) && allowOwner?.intValue == 0
            && allowed != nil && allowed == CodeIdentity.ownCDHash() ? .ready : .outdated
    }

    func apply(_ p: Preset) async {
        guard helper == .ready, !busy else { return }
        busy = true; problem = nil
        let previous = preset
        preset = p
        let r = await Shell.run(Self.helperPath, p.fraction.map { ["set", String($0)] } ?? ["auto"], timeout: 45)
        busy = false
        if !r.ok {
            preset = previous
            problem = p == .auto ? "macOS didn't take the fans back. They return to Auto after a restart." : "The fans didn't accept the new speed. They stay on \(previous.rawValue)."
        }
        refresh()
    }

    /// Installs roomy-fan as root (macOS asks for an administrator's password). The only thing it can do is set fan speed.
    func installHelper() async {
        busy = true; problem = nil
        guard let me = CodeIdentity.ownCDHash(), CodeIdentity.isHash(me) else { busy = false; problem = "Roomy's signature couldn't be read, so fan control can't be allowed."; return }
        let src = Self.bundledHelper.replacingOccurrences(of: "'", with: "'\\''")
        // The helper, and the one Roomy build it takes speeds from (hex only, so the command can't carry anything else).
        let cmd = "mkdir -p /Library/PrivilegedHelperTools && /usr/bin/install -o root -g wheel -m 4755 '\(src)' '\(Self.helperPath)'"
            + " && /usr/bin/printf '%s\\n' '\(me)' > '\(Self.allowPath)' && /usr/sbin/chown root:wheel '\(Self.allowPath)' && /bin/chmod 644 '\(Self.allowPath)'"
        let ok = await Self.asAdmin(cmd, prompt: "Roomy wants to install a small helper that can only change your Mac's fan speed.")
        busy = false
        checkHelper()
        if !ok && helper != .ready { problem = "Fan control wasn't installed." }
    }

    func removeHelper() async {
        if preset != .auto { await apply(.auto) }
        busy = true
        _ = await Self.asAdmin("/bin/rm -f '\(Self.helperPath)' '\(Self.allowPath)'", prompt: "Roomy wants to remove its fan helper.")
        busy = false
        checkHelper()
    }

    private func releaseOnQuit() {
        guard preset != .auto, helper == .ready else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.helperPath)
        p.arguments = ["auto"]
        try? p.run()
        p.waitUntilExit()
    }

    private static func asAdmin(_ shell: String, prompt: String) async -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        return await MainActor.run {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            return error == nil
        }
    }
}
