import Foundation
import AppKit
import CoreServices
import Security

/// One thing that opens or runs when you log in, as System Settings › General › Login Items & Extensions lists it.
struct StartupItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case openAtLogin, loginItem, agent, daemon, backgroundTask }
    enum State: String, Codable {
        /// Allowed, and launchd has it.
        case on
        /// Switched off in System Settings (launchd doesn't have it).
        case off
        /// Switched off with `launchctl disable`, which System Settings doesn't show: it still reads On there.
        case offOutsideSettings
        /// Can't run: its file can't be read, or its program is gone.
        case broken
    }
    var id: String
    var name: String
    var kind: Kind
    var allUsers: Bool
    var state: State
    /// The app or developer System Settings lists it under.
    var owner: String
    /// The owning app, for its icon and to tell when it's gone.
    var ownerPath: String?
    /// Its launchd file, helper or app (`~`-shortened).
    var path: String?
    var label: String?
    /// Why it's broken, or the program it runs.
    var note: String?
    var appGone: Bool

    /// Only a file in your own LaunchAgents folder can go without an administrator.
    var removable: Bool { kind == .agent && !allUsers && (path?.hasPrefix("~/Library/LaunchAgents/") ?? false) }
    /// launchctl overrides in your own session can be undone without an administrator; System Settings never sees them.
    var canTurnBackOn: Bool { state == .offOutsideSettings && kind != .daemon && label != nil }
}

struct StartupReport: Codable {
    var items: [StartupItem] = []
    /// When macOS's own full list was last read (with an administrator's permission). Nil: read from launchd alone.
    var fullListAt: Date?
}

/// Reads what starts with your Mac. A scan never asks for a password: launchd's own state is what System Settings'
/// switches control, so "launchd has it" is On and "launchd doesn't" is Off. macOS's full list (`sfltool dumpbtm`)
/// also has apps' own background tasks and every developer's name, but needs an administrator, so it's read only
/// when you ask.
enum StartupEngine {
    static var guiDomain: String { "gui/\(getuid())" }

    // MARK: without a password

    static func scan(apps: [AppRecord]) async -> StartupReport {
        async let userLoaded = loadedLabels(guiDomain)
        async let systemLoaded = loadedLabels("system")
        async let userOff = overrides(guiDomain)
        async let systemOff = overrides("system")
        let (ul, sl, uo, so) = await (userLoaded, systemLoaded, userOff, systemOff)

        var items = openAtLogin(apps: apps)
        for (dir, allUsers, daemon) in [(HOME + "/Library/LaunchAgents", false, false), ("/Library/LaunchAgents", true, false), ("/Library/LaunchDaemons", true, true)] {
            for f in Paths.children(dir) where f.hasSuffix(".plist") {
                items.append(plistItem(f, allUsers: allUsers, daemon: daemon, loaded: daemon ? sl : ul, overrides: daemon ? so : uo, apps: apps))
            }
        }
        let known = Set(items.compactMap(\.label))
        items += embedded(apps: apps, userLoaded: ul, systemLoaded: sl, skipping: known)
        return StartupReport(items: items.sorted(by: order))
    }

    static func order(_ a: StartupItem, _ b: StartupItem) -> Bool {
        (a.owner.localizedLowercase, a.name.localizedLowercase) < (b.owner.localizedLowercase, b.name.localizedLowercase)
    }

    /// Labels launchd has in a domain (`launchctl print`), loaded whether or not they're running right now.
    static func loadedLabels(_ domain: String) async -> Set<String> {
        let out = await Shell.run("/bin/launchctl", ["print", domain], timeout: 20).output
        var labels = Set<String>(), inServices = false
        for line in out.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s == "services = {" { inServices = true; continue }
            if inServices && s == "}" { break }
            guard inServices else { continue }
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 3 { labels.insert(String(parts[2])) }
        }
        return labels
    }

    /// launchctl's own on/off overrides in a domain: true where something ran `launchctl disable`.
    static func overrides(_ domain: String) async -> [String: Bool] {
        let out = await Shell.run("/bin/launchctl", ["print-disabled", domain], timeout: 20).output
        var map: [String: Bool] = [:]
        for line in out.split(separator: "\n") {
            guard let m = String(line).firstMatch(#""([^"]+)"\s*=>\s*(\w+)"#), let label = m[1], let v = m[2] else { continue }
            map[label] = v == "disabled" || v == "true"
        }
        return map
    }

    /// Apps set to open at login. Read through the login items list, which needs no permission.
    static func openAtLogin(apps: [AppRecord]) -> [StartupItem] {
        guard let list = LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?.takeRetainedValue() else { return [] }
        var seed: UInt32 = 0
        let entries = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
        return entries.compactMap { e in
            let name = LSSharedFileListItemCopyDisplayName(e).takeRetainedValue() as String
            let path = (LSSharedFileListItemCopyResolvedURL(e, 0, nil)?.takeRetainedValue() as URL?)?.path
            let gone = path.map { !FileManager.default.fileExists(atPath: $0) } ?? true
            return StartupItem(id: "login:" + (path ?? name), name: name.replacingOccurrences(of: ".app", with: ""), kind: .openAtLogin, allUsers: false,
                               state: gone ? .broken : .on, owner: name.replacingOccurrences(of: ".app", with: ""), ownerPath: path, path: path.map(Paths.short),
                               label: nil, note: gone ? "The app is gone." : nil, appGone: gone)
        }
    }

    /// A launchd file in one of the LaunchAgents or LaunchDaemons folders.
    static func plistItem(_ f: String, allUsers: Bool, daemon: Bool, loaded: Set<String>, overrides: [String: Bool], apps: [AppRecord]) -> StartupItem {
        let file = (Paths.name(f) as NSString).deletingPathExtension
        let d = NSDictionary(contentsOfFile: f) as? [String: Any]
        let label = d?["Label"] as? String
        let program = (d?["Program"] as? String) ?? (d?["ProgramArguments"] as? [String])?.first
        let app = ownerApp(label ?? file, program: program, apps: apps)
        let developer = program.flatMap { $0.hasPrefix("/") ? developerName($0) : nil }
        var item = StartupItem(id: f, name: program.map { Paths.name($0) } ?? label ?? file, kind: daemon ? .daemon : .agent, allUsers: allUsers,
                               state: .on, owner: app?.name ?? developer ?? program.map { Paths.name($0) } ?? label ?? file,
                               ownerPath: app?.path, path: Paths.short(f), label: label, note: program.map(Paths.short), appGone: false)
        if d == nil || label == nil {
            item.state = .broken; item.note = "Its file can't be read, so macOS ignores it."
        } else if let p = program, p.hasPrefix("/"), !p.hasPrefix("/System/"), !p.hasPrefix("/usr/"), !p.hasPrefix("/bin/"), !p.hasPrefix("/sbin/"),
                  !FileManager.default.fileExists(atPath: p) {
            item.state = .broken; item.note = "Its program is gone: \(Paths.short(p))"
            item.appGone = p.contains(".app/")
        } else if let label, loaded.contains(label) {
            item.state = .on
        } else if let label, overrides[label] == true {
            item.state = .offOutsideSettings
        } else if (d?["Disabled"] as? Bool) == true {
            item.state = .off; item.note = "Its own file turns it off."
        } else {
            item.state = .off
        }
        return item
    }

    /// Helpers apps register for themselves (inside the app's Contents/Library). Listed only while launchd has them: an
    /// app can carry helpers it never registered, and launchd's leftover overrides don't say whether one is on the list.
    static func embedded(apps: [AppRecord], userLoaded: Set<String>, systemLoaded: Set<String>, skipping known: Set<String>) -> [StartupItem] {
        var out: [StartupItem] = []
        for app in apps {
            let lib = app.path + "/Contents/Library"
            for helper in Paths.children(lib + "/LoginItems") where helper.hasSuffix(".app") {
                guard let id = Bundle(path: helper)?.bundleIdentifier, !known.contains(id), userLoaded.contains(id) else { continue }
                out.append(StartupItem(id: helper, name: (Paths.name(helper) as NSString).deletingPathExtension, kind: .loginItem, allUsers: false,
                                       state: .on, owner: app.name, ownerPath: app.path, path: Paths.short(helper),
                                       label: id, note: nil, appGone: false))
            }
            for (folder, daemon) in [("LaunchAgents", false), ("LaunchDaemons", true)] {
                for f in Paths.children(lib + "/" + folder) where f.hasSuffix(".plist") {
                    guard let label = (NSDictionary(contentsOfFile: f) as? [String: Any])?["Label"] as? String, !known.contains(label) else { continue }
                    guard (daemon ? systemLoaded : userLoaded).contains(label) else { continue }
                    out.append(StartupItem(id: f, name: label, kind: daemon ? .daemon : .agent, allUsers: daemon, state: .on,
                                           owner: app.name, ownerPath: app.path, path: Paths.short(f), label: label, note: nil, appGone: false))
                }
            }
        }
        return out
    }

    /// The app a helper belongs to: the app its program lives in, else the app whose bundle ID its label starts with.
    static func ownerApp(_ label: String, program: String?, apps: [AppRecord]) -> AppRecord? {
        if let p = program, let a = apps.first(where: { p.hasPrefix($0.path + "/") }) { return a }
        let low = label.lowercased()
        if let a = apps.first(where: { !$0.bundleID.isEmpty && low.hasPrefix($0.bundleID.lowercased()) }) { return a }
        let parts = low.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let vendor = parts.prefix(2).joined(separator: ".") + "."
        // Only when exactly one app shares the vendor prefix: "com.google.keystone" isn't Chrome's if Google has two apps here.
        let matches = apps.filter { $0.bundleID.lowercased().hasPrefix(vendor) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The developer a program is signed by ("Developer ID Application: Google LLC (EQHXZ8M8AV)" → "Google LLC"),
    /// which is how System Settings names it.
    static func developerName(_ path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return nil }
        guard let r = summary.range(of: ": ") else { return nil }
        var name = String(summary[r.upperBound...])
        if let paren = name.range(of: " (", options: .backwards) { name = String(name[..<paren.lowerBound]) }
        return name.isEmpty ? nil : name
    }

    // MARK: macOS's full list, with an administrator's permission

    /// Runs `sfltool dumpbtm`, the list System Settings itself reads. macOS asks for an administrator's password in its
    /// own dialog. It only reads. Nil when the password was refused or the list couldn't be read.
    static func readFullList() async -> String? {
        let prompt = "Roomy wants to read macOS's list of login items and background items. It only reads; nothing changes."
        let script = "do shell script \"/usr/bin/sfltool dumpbtm\" with prompt \"\(prompt)\" with administrator privileges without altering line endings"
        let r = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 300)
        return r.ok && r.output.contains("Records for UID") ? r.output : nil
    }

    /// One record of `sfltool dumpbtm`.
    struct Record {
        var uid: String
        var fields: [String: String]
        var type: Int { fields["Type"].flatMap { $0.firstMatch(#"\(0x([0-9a-fA-F]+)\)"#)?[1] }.flatMap { Int($0, radix: 16) } ?? 0 }
        var disposition: String { fields["Disposition"] ?? "" }
        var allowed: Bool { !disposition.contains("disallowed") }
        var enabled: Bool { disposition.contains("[enabled") }
        var identifier: String { fields["Identifier"] ?? "" }
        var name: String? { fields["Name"].flatMap { $0 == "(null)" ? nil : $0 } }
    }

    static func parseRecords(_ text: String) -> [Record] {
        var out: [Record] = [], uid = "", current: [String: String]? = nil
        func flush() { if let c = current, c["Type"] != nil { out.append(Record(uid: uid, fields: c)) }; current = nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let m = line.firstMatch(#"Records for UID (-?\d+)"#), let u = m[1] { flush(); uid = u; continue }
            if line.range(of: #"^ #\d+:\s*$"#, options: .regularExpression) != nil { flush(); current = [:]; continue }
            guard current != nil, let m = line.firstMatch(#"^\s+([A-Za-z][A-Za-z ]*?):\s(.*)$"#), let k = m[1], let v = m[2] else { continue }
            if current?[k] == nil { current?[k] = v.trimmingCharacters(in: .whitespaces) }
        }
        flush()
        return out
    }

    /// The full list for you and for all users, merged with what the scan found without a password: the scan knows
    /// which files are broken and what launchctl turned off; the full list knows everything System Settings shows.
    static func merge(fullList text: String, into scan: StartupReport, apps: [AppRecord]) -> StartupReport {
        let me = String(getuid())
        let records = parseRecords(text).filter { $0.uid == me || $0.uid == "-2" }
        let byID = Dictionary(records.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [StartupItem] = [], matched = Set<String>()

        func resolve(_ url: String?, parent: Record?) -> String? {
            guard let url, url != "(null)" else { return nil }
            if url.hasPrefix("/") { return url.replacingOccurrences(of: "/Users/\(me)/", with: HOME + "/") }
            if let p = parent?.fields["URL"], p.hasPrefix("/") { return p + "/" + url }
            return nil
        }

        for r in records {
            let t = r.type
            let kind: StartupItem.Kind?
            if t == 0x2 { kind = r.enabled ? .openAtLogin : nil }   // an app: listed under Open at Login when it's on
            else if t == 0x4 { kind = .loginItem }
            else if t & 0x10 != 0 { kind = .daemon }                // daemon, legacy daemon
            else if t & 0x8 != 0 { kind = .agent }                  // agent, legacy agent
            else if t == 0x2000 || t == 0x1000 { kind = .backgroundTask }
            else { kind = nil }                                     // developers, and extensions (Quick Look, Spotlight, Dock tiles)
            guard let kind, r.enabled || kind == .openAtLogin else { continue }
            let parent = r.fields["Parent Identifier"].flatMap { byID[$0] }
            let path = resolve(r.fields["URL"], parent: kind == .openAtLogin ? nil : parent)
            let exe = r.fields["Executable Path"].map { $0.replacingOccurrences(of: "/Users/\(me)/", with: HOME + "/") }
            let ownerPath = kind == .openAtLogin ? path : parent.flatMap { resolve($0.fields["URL"], parent: nil) }
            let parentName = parent?.name ?? parent?.fields["Developer Name"].flatMap { $0 == "(null)" ? nil : $0 }
            let ownerName = parent?.identifier == "Unknown Developer" ? nil : parentName
            let name: String = {
                if kind == .backgroundTask { return "Background tasks" }
                return r.name ?? exe.map { Paths.name($0) } ?? r.identifier
            }()
            // What the scan saw of the same thing, matched by its file or label.
            let label = r.identifier.split(separator: ".", maxSplits: 1).last.map(String.init)
            let seen = scan.items.first { s in
                (path != nil && s.path.map(Paths.expand) == path) || (s.label != nil && s.label == label && s.kind == kind)
                    || (kind == .openAtLogin && s.kind == .openAtLogin && s.ownerPath == path)
            }
            if let seen { matched.insert(seen.id) }
            var state: StartupItem.State = r.allowed ? .on : .off
            if let seen, seen.state == .broken || seen.state == .offOutsideSettings { state = seen.state }
            let appGone = ownerPath.map { $0.hasSuffix(".app") && !FileManager.default.fileExists(atPath: $0) } ?? false
            items.append(StartupItem(id: seen?.id ?? "btm:" + r.identifier, name: name, kind: kind, allUsers: r.uid == "-2", state: appGone ? .broken : state,
                                     owner: kind == .openAtLogin ? name : (ownerName ?? seen?.owner ?? name), ownerPath: ownerPath ?? seen?.ownerPath,
                                     path: (path ?? seen?.path.map(Paths.expand)).map(Paths.short), label: seen?.label ?? label,
                                     note: appGone ? "Its app is gone." : (seen?.note ?? exe.map(Paths.short)), appGone: appGone || (seen?.appGone ?? false)))
        }
        // Files macOS ignores (unreadable, or for a program that's gone) aren't on its list, but they're worth removing.
        items += scan.items.filter { !matched.contains($0.id) && $0.state == .broken }
        return StartupReport(items: items.sorted(by: order), fullListAt: Date())
    }

    /// Testing aid: `Roomy -RoomyStartupProbe <out.json> [-RoomyStartupDump <sfltool output>]` writes what the scan finds
    /// without a password (and merged with a saved `sfltool dumpbtm`, if given), then quits. It only reads.
    static func probe(to out: String, fullList dump: String?) {
        Task {
            let apps = await AppsEngine.scan().apps
            let scan = await scan(apps: apps)
            var report = scan
            if let dump, let text = try? String(contentsOfFile: dump, encoding: .utf8) { report = merge(fullList: text, into: scan, apps: apps) }
            let rows = report.items.map { ["name": $0.name, "owner": $0.owner, "kind": $0.kind.rawValue, "state": $0.state.rawValue, "allUsers": $0.allUsers,
                                           "path": $0.path ?? "", "note": $0.note ?? "", "removable": $0.removable, "turnBackOn": $0.canTurnBackOn] as [String: Any] }
            if let d = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: out)) }
            if let d = try? JSONEncoder().encode(report) { try? d.write(to: URL(fileURLWithPath: out + ".report")) }
            exit(0)
        }
    }

    // MARK: actions that work without an administrator

    /// Undoes a `launchctl disable` in your own session and starts it again, so it matches System Settings' On.
    static func turnBackOn(_ item: StartupItem) async {
        guard item.canTurnBackOn, let label = item.label else { return }
        _ = await Shell.run("/bin/launchctl", ["enable", "\(guiDomain)/\(label)"], timeout: 10)
        if let p = item.path, p.hasSuffix(".plist") {
            _ = await Shell.run("/bin/launchctl", ["bootstrap", guiDomain, Paths.expand(p)], timeout: 10)
        }
    }

    /// Stops one of your own launch agents before its file goes to the Trash.
    static func stop(_ item: StartupItem) async {
        guard item.removable, let label = item.label else { return }
        _ = await Shell.run("/bin/launchctl", ["bootout", "\(guiDomain)/\(label)"], timeout: 10)
    }
}
