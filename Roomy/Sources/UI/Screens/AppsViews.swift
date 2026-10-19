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

