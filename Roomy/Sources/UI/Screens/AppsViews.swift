import SwiftUI
import Pow

struct UninstallerView: View {
    @Environment(AppModel.self) var model
    @State private var selected: String?
    @State private var query = ""
    @State private var sort = 0
    @State private var loading = false
    @State private var confirm = false
    @State private var picked: Set<String> = []

    var apps: [AppRecord] {
        let l = model.snap.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case 1: return l.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case 2: return l.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        default: return l.sorted { $0.bytes + $0.relatedBytes > $1.bytes + $1.relatedBytes }
        }
    }
    var current: AppRecord? { model.snap.apps.first { $0.path == selected } ?? apps.first }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Uninstaller", subtitle: "Remove an app with everything it left in your Library. Apple apps can't be removed.", value: model.snap.apps.isEmpty ? nil : "\(model.snap.apps.count)", valueCaption: "apps")
            if model.snap.apps.isEmpty { NotScannedYet(); Spacer() } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 8) {
                        Picker("Sort", selection: $sort) { Text("Size").tag(0); Text("Last used").tag(1); Text("Name").tag(2) }
                            .pickerStyle(.segmented).labelsHidden()
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(apps) { a in appRow(a) }
                            }
                        }
                    }
                    .frame(width: 300)
                    if let a = current { detail(a).id(a.path).transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.16)), removal: .identity)) }
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search apps")
        .task(id: current?.path) {
            guard let a = current, !a.previewedByMole, !a.apple else { return }
            loading = true
            await model.loadUninstallPreview(a)
            loading = false
        }
        .onChange(of: current?.path) { picked = [] }
    }

    func appRow(_ a: AppRecord) -> some View {
        let on = current?.path == a.path
        return Button { withAnimation(.snappy) { selected = a.path } } label: {
            HStack(spacing: 10) {
                FileIcon(path: a.path, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(a.lastUsed.map { "Used \(Fmt.ago($0).lowercased())" } ?? "Never opened").font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Text(Fmt.bytes(a.bytes + a.relatedBytes)).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink2)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Palette.accent.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func detail(_ a: AppRecord) -> some View {
        let files = a.related
        let chosen = files.filter { !picked.contains($0.path) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                FileIcon(path: a.path, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.name).font(.system(size: 20, weight: .bold))
                    Text([a.version.isEmpty ? nil : "Version \(a.version)", a.appStore ? "App Store" : nil, a.lastUsed.map { "Used \(Fmt.ago($0).lowercased())" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Palette.ink2)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(Fmt.bytes(a.bytes + chosen.reduce(0) { $0 + $1.bytes })).font(.system(size: 22, weight: .bold)).monospacedDigit().contentTransition(.numericText())
                    Text("app + \(chosen.count) related files").font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
            }
            .padding(18)
            RowDivider()
            if a.apple {
                Notice(symbol: "lock.fill", tint: Palette.ink3, text: "Comes with macOS. macOS reinstalls it, so Roomy doesn't remove Apple apps.").padding(16)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ItemRow(path: a.path, title: a.name + ".app", subtitle: Paths.short(a.path), bytes: a.bytes, mode: .locked("Always removed"))
                        ForEach(files) { f in
                            RowDivider()
                            ItemRow(path: f.path, title: f.name, subtitle: "\(f.note ?? "") · \(Paths.short(f.path))", bytes: f.bytes, on: !picked.contains(f.path)) {
                                if picked.contains(f.path) { picked.remove(f.path) } else { picked.insert(f.path) }
                            }
                        }
                        if loading { HStack { ProgressView().controlSize(.small); Text("Checking exactly what an uninstall would remove…").font(.system(size: 12)).foregroundStyle(Palette.ink3) }.padding(14) }
                        if !a.personalKept.isEmpty {
                            Notice(symbol: "person.crop.circle.badge.checkmark", tint: Palette.ok, text: "Kept on purpose: " + a.personalKept.joined(separator: ", ")).padding(14)
                        }
                    }
                }
                RowDivider()
                HStack {
                    Text(a.previewedByMole ? "Checked with a dry run of the uninstall" : "Matched by bundle ID").font(.system(size: 11)).foregroundStyle(Palette.ink3)
                    Spacer()
                    Button("Uninstall \(a.name)") { confirm = true }.buttonStyle(.glassProminent).controlSize(.large)
                }
                .padding(14)
            }
        }
        .glass(14)
        .confirmationDialog("Uninstall \(a.name)?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) {
                let targets = [Actions.Target(path: a.path, bytes: a.bytes)] + chosen.map { Actions.Target(path: $0.path, bytes: $0.bytes) }
                Task {
                    let rep = await model.clean("Uninstalled \(a.name)", targets: targets, allowApps: true)
                    if !rep.simulated && rep.failures.isEmpty { withAnimation { model.snap.apps.removeAll { $0.path == a.path } } }
                }
            }
        } message: {
            Text("The app and \(chosen.count) related files go to the Trash. If \(a.name) is open, quit it first.")
        }
    }
}

struct UpdatesView: View {
    @Environment(AppModel.self) var model
    @State private var state: [String: Status] = [:]
    @State private var confirmQuit: OutdatedCask?
    enum Status: Equatable { case updating, updated, needsPassword, failed(String) }

    func app(_ c: OutdatedCask) -> AppRecord? {
        model.snap.apps.first { $0.name.lowercased().replacingOccurrences(of: " ", with: "-") == c.name.lowercased() }
    }
    func running(_ c: OutdatedCask) -> NSRunningApplication? {
        guard let p = app(c)?.path else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == p }
    }
    var pending: [OutdatedCask] { model.snap.outdated.filter { state[$0.name] != .updated && state[$0.name] != .updating } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Updates", subtitle: "Apps installed with Homebrew that have a newer version. Roomy updates them for you; your settings stay.") {
                if pending.count > 1 {
                    Button("Update All") { Task { for c in pending where running(c) == nil { await update(c) } } }
                        .buttonStyle(.glassProminent)
                        .help("Updates every app that isn't open. Open apps wait for you to quit them.")
                }
            }
            ScrollView {
                MoleEngineCard().padding(.horizontal, 28).padding(.bottom, 14)
                if model.snap.outdated.isEmpty {
                    EmptyState(symbol: "checkmark.seal", title: "Your apps are up to date", text: "Apps from the App Store update in the App Store. Others update themselves.")
                } else {
                    ListCard { ForEach(Array(model.snap.outdated.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { RowDivider() }
                        row(c)
                    } }
                    .padding(.horizontal, 28)
                }
            }
        }
        .confirmationDialog("Quit \(confirmQuit.flatMap { app($0)?.name } ?? "the app") to update it?", isPresented: Binding(get: { confirmQuit != nil }, set: { if !$0 { confirmQuit = nil } }), presenting: confirmQuit) { c in
            Button("Quit and Update") {
                running(c)?.terminate()
                Task { try? await Task.sleep(for: .seconds(2)); await update(c) }
            }
        } message: { _ in Text("It reopens with your windows and settings once it's updated.") }
    }

    func row(_ c: OutdatedCask) -> some View {
        let a = app(c), st = state[c.name]
        return HStack(spacing: 12) {
            if let a { FileIcon(path: a.path, size: 30) } else { Image(systemName: "shippingbox").frame(width: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Text(a?.name ?? c.name).font(.system(size: 13, weight: .medium))
                Group {
                    switch st {
                    case .updated: Text("Updated to \(c.current)").foregroundStyle(Palette.ok)
                    case .needsPassword: Text("Its installer needs your password").foregroundStyle(Palette.warn)
                    case .failed(let m): Text(m.isEmpty ? "The update didn't finish" : m).foregroundStyle(Palette.bad).lineLimit(1)
                    default: Text("\(c.installed) → \(c.current)").foregroundStyle(Palette.ink3).monospacedDigit()
                    }
                }
                .font(.system(size: 11))
            }
            Spacer()
            switch st {
            case .updating: ProgressView().controlSize(.small); Text("Updating…").font(.system(size: 12)).foregroundStyle(.secondary)
            case .updated: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
            case .needsPassword: Button("Update in Terminal…") { ExtrasEngine.upgradeInTerminal(c.name) }.help("Terminal opens so you can type your password for the installer.")
            default:
                Button(running(c) != nil ? "Quit and Update…" : "Update") {
                    if running(c) != nil { confirmQuit = c } else { Task { await update(c) } }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    func update(_ c: OutdatedCask) async {
        withAnimation(.snappy) { state[c.name] = .updating }
        let r = await ExtrasEngine.upgradeCask(c.name)
        withAnimation(.snappy) {
            switch r {
            case .updated: state[c.name] = .updated
            case .needsPassword: state[c.name] = .needsPassword
            case .failed(let m): state[c.name] = .failed(m)
            }
        }
        if case .updated = r { model.flash("\(app(c)?.name ?? c.name) is up to date.") }
    }
}

/// Which Mole Roomy cleans with. It's the copy inside Roomy and changes only with a Roomy update, once Roomy has been
/// tested with it.
struct MoleEngineCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "shippingbox").font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Cleaning engine · Mole \(Mole.activeVersion ?? "not installed")").font(.system(size: 13, weight: .medium))
                Text("Comes inside Roomy. A newer Mole arrives with a Roomy update, after Roomy has been tested with it.")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass(12)
    }
}

struct StartupView: View {
    @Environment(AppModel.self) var model
    @State private var disabled: Set<String> = []
    @State private var confirmRemove: LaunchItem?

    var items: [LaunchItem] { model.snap.launchItems.sorted { ($0.broken == nil ? 1 : 0, $0.allUsers ? 1 : 0, owner($0)) < ($1.broken == nil ? 1 : 0, $1.allUsers ? 1 : 0, owner($1)) } }

    /// The app a helper belongs to, by bundle-ID prefix ("com.google.keystone.agent" → Google Chrome), else its label.
    func owner(_ l: LaunchItem) -> String {
        let low = l.name.lowercased()
        let parts = low.split(separator: ".")
        let vendor = parts.count >= 2 ? parts.prefix(2).joined(separator: ".") : low
        if let a = model.snap.apps.first(where: { !$0.bundleID.isEmpty && low.hasPrefix($0.bundleID.lowercased()) }) ?? model.snap.apps.first(where: { $0.bundleID.lowercased().hasPrefix(vendor + ".") }) { return a.name }
        return l.name
    }
    func app(_ l: LaunchItem) -> AppRecord? { model.snap.apps.first { $0.name == owner(l) } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Startup Items", subtitle: "Helpers that start with your Mac. Turn off your own here; ones for all users are managed in Login Items.") {
                Button("Open Login Items") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }.buttonStyle(.glass)
            }
            if model.snap.scannedAt == nil { NotScannedYet(); Spacer() } else {
                ScrollView {
                    ListCard { ForEach(Array(items.enumerated()), id: \.element.id) { i, l in
                        if i > 0 { RowDivider() }
                        row(l)
                    } }
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
            }
        }
        .task { disabled = await LaunchControl.disabledLabels() }
        .confirmationDialog("Move \(confirmRemove?.name ?? "this helper") to the Trash?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), presenting: confirmRemove) { l in
            Button("Move to Trash", role: .destructive) {
                Task {
                    await LaunchControl.setEnabled(l, false)
                    await model.clean("Startup Items", targets: [Actions.Target(path: l.path, bytes: 0)]) { model.snap.launchItems.removeAll { $0.id == l.id } }
                }
            }
        } message: { l in Text(l.broken ?? "It stops starting with your Mac. You can put it back from the Trash.") }
    }

    func row(_ l: LaunchItem) -> some View {
        let off = disabled.contains(l.name)
        return HStack(spacing: 12) {
            if let a = app(l) { FileIcon(path: a.path, size: 26) } else { Image(systemName: l.allUsers ? "gearshape.2" : "gearshape").font(.system(size: 15)).foregroundStyle(Palette.ink3).frame(width: 26) }
            VStack(alignment: .leading, spacing: 2) {
                Text(owner(l)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(l.broken ?? (owner(l) == l.name ? l.path : l.name)).font(.system(size: 11)).foregroundStyle(l.broken == nil ? Palette.ink3 : Palette.warn).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if l.broken != nil { Tag(text: "Broken", color: Palette.warn).help("It tries to start a program that no longer exists.") }
            if l.allUsers {
                Tag(text: "All users").help("Turning this off needs an administrator: use Login Items.")
            } else if l.broken != nil {
                Button("Remove…") { confirmRemove = l }.buttonStyle(.glass).controlSize(.small)
            } else {
                Toggle("", isOn: Binding(get: { !off }, set: { on in
                    Task {
                        if model.safeMode { model.flash("Safe mode: nothing was changed."); return }
                        await LaunchControl.setEnabled(l, on)
                        disabled = await LaunchControl.disabledLabels()
                    }
                })).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help(off ? "Off: it won't start with your Mac" : "On: starts with your Mac")
            }
            Button { reveal(l.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 9).rowHover()
    }
}

/// Turning your own launch agents off and on with launchctl, the way Login Items does. No administrator needed.
enum LaunchControl {
    static var domain: String { "gui/\(getuid())" }

    static func disabledLabels() async -> Set<String> {
        let out = await Shell.run("/bin/launchctl", ["print-disabled", domain], timeout: 10).output
        var s = Set<String>()
        for line in out.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
            if let m = String(line).firstMatch(#"\"([^\"]+)\""#), let l = m[1] { s.insert(l) }
        }
        return s
    }

    static func setEnabled(_ l: LaunchItem, _ on: Bool) async {
        guard !l.allUsers else { return }
        let plist = Paths.expand(l.path)
        if on {
            _ = await Shell.run("/bin/launchctl", ["enable", "\(domain)/\(l.name)"], timeout: 10)
            _ = await Shell.run("/bin/launchctl", ["bootstrap", domain, plist], timeout: 10)
        } else {
            _ = await Shell.run("/bin/launchctl", ["disable", "\(domain)/\(l.name)"], timeout: 10)
            _ = await Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(l.name)"], timeout: 10)
        }
    }
}
