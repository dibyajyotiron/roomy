import SwiftUI

/// Startup Items, the way System Settings › General › Login Items & Extensions lists them: Open at Login, then Allow in
/// the Background grouped by app or developer, each with its real state. Only actions that work are offered: Remove
/// for your own launch agents, Turn Back On for what launchctl switched off behind System Settings' back, and System
/// Settings itself for everything else.
struct StartupView: View {
    @Environment(AppModel.self) var model
    @State private var confirmRemove: StartupItem?
    @State private var working: Set<String> = []

    var report: StartupReport? { model.snap.startup }
    var items: [StartupItem] { report?.items ?? [] }
    var openAtLogin: [StartupItem] { items.filter { $0.kind == .openAtLogin } }
    var attention: [StartupItem] { items.filter { $0.state == .broken || $0.state == .offOutsideSettings } }
    /// One row per app or developer, like System Settings.
    var groups: [(owner: String, items: [StartupItem])] {
        Dictionary(grouping: items.filter { $0.kind != .openAtLogin }, by: \.owner)
            .map { (owner: $0.key, items: $0.value) }
            .sorted { $0.owner.localizedLowercase < $1.owner.localizedLowercase }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Startup Items", subtitle: "What opens or runs when you log in, listed the way System Settings › Login Items lists it, with whether each is really on.",
                         value: report == nil ? nil : "\(items.filter { $0.state == .on }.count)", valueCaption: report == nil ? nil : "on at login") {
                Button("Open Login Items") { Self.openSettings() }.buttonStyle(.glass)
            }
            if report == nil { NotScannedYet(); Spacer() } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        source
                        if !attention.isEmpty {
                            SectionLabel(title: "Needs a look", note: "Broken helpers, and ones switched off in a way System Settings doesn't show.")
                            ListCard { ForEach(attention) { line($0, showOwner: true).padding(.horizontal, 14).padding(.vertical, 9).rowHover() } }
                        }
                        if !openAtLogin.isEmpty {
                            SectionLabel(title: "Open at Login", note: "Apps that open when you log in. Remove one in System Settings: select it and click −.")
                            ListCard { ForEach(openAtLogin) { appRow($0) } }
                        }
                        SectionLabel(title: "Allow in the Background", note: "Helpers that run without a window, listed by app or developer.")
                        ListCard { ForEach(groups, id: \.owner) { g in groupRow(g.owner, g.items) } }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
            }
        }
        .confirmationDialog("Move \(confirmRemove?.name ?? "this helper") to the Trash?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { item in
            Button("Move to Trash", role: .destructive) { remove(item) }
        } message: { item in
            Text((item.state == .broken ? (item.note ?? "It can't run.") + " " : "It stops starting when you log in. ") + "It goes to the Trash, so you can put it back.")
        }
    }

    // MARK: where the list came from

    var source: some View {
        HStack(spacing: 10) {
            Image(systemName: report?.fullListAt == nil ? "list.bullet" : "checkmark.seal").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                if let at = report?.fullListAt {
                    Text("macOS's full list, read \(at.formatted(.relative(presentation: .named)))").font(.system(size: 12, weight: .medium))
                    Text("The same list System Settings shows. Scanning again goes back to the list read without a password.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Read from launchd, without a password").font(.system(size: 12, weight: .medium))
                    Text("Apps' own background tasks and every developer's name are on macOS's full list, which needs an administrator.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.readingStartup {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for macOS…").font(.system(size: 11)).foregroundStyle(.secondary) }
            } else {
                Button(report?.fullListAt == nil ? "Read Full List…" : "Read Again…") { Task { await model.readFullStartupList() } }
                    .buttonStyle(.glass).controlSize(.small)
                    .help("macOS asks for an administrator's password in its own window. Roomy only reads the list; nothing changes.")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
    }

    // MARK: rows

    func appRow(_ item: StartupItem) -> some View {
        HStack(spacing: 12) {
            icon(item, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.note ?? item.path ?? "").font(.system(size: 11)).foregroundStyle(item.state == .broken ? Palette.warn : Palette.ink3).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            chip(item.state)
            Button("Manage…") { Self.openSettings() }.buttonStyle(.glass).controlSize(.small)
                .help("Login items are changed in System Settings: select it and click −.")
        }
        .padding(.horizontal, 14).padding(.vertical, 9).rowHover()
    }

    func groupRow(_ owner: String, _ members: [StartupItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                icon(members[0], size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(owner).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(summary(members)).font(.system(size: 11)).foregroundStyle(Palette.ink3).lineLimit(1)
                }
                Spacer()
                chip(groupState(members))
            }
            ForEach(members) { line($0, showOwner: false).padding(.leading, 44) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).rowHover()
    }

    /// One helper: its state, what it is, and only the actions that work for it.
    func line(_ item: StartupItem, showOwner: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(item.state)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(showOwner && item.owner != item.name ? "\(item.owner): \(item.name)" : item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(kind(item)).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                if let detail = detail(item) {
                    Text(detail).font(.system(size: 11)).foregroundStyle(item.state == .on || item.state == .off ? Palette.ink3 : Palette.warn)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if showOwner { chip(item.state) }
            if working.contains(item.id) { ProgressView().controlSize(.small) }
            else if item.canTurnBackOn {
                Button("Turn Back On") { turnBackOn(item) }.buttonStyle(.glass).controlSize(.small)
                    .help("It was switched off with launchctl, which System Settings doesn't show (it still says On there). This undoes that.")
            }
            if item.removable && !working.contains(item.id) {
                Button("Remove…") { confirmRemove = item }.buttonStyle(.glass).controlSize(.small)
            }
            if let p = item.path, Paths.exists(p) {
                Button { reveal(p) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
            }
        }
    }

    // MARK: pieces

    @ViewBuilder func icon(_ item: StartupItem, size: CGFloat) -> some View {
        if let p = item.ownerPath, p.hasSuffix(".app"), Paths.exists(p) { FileIcon(path: p, size: size) }
        else {
            Image(systemName: item.allUsers ? "gearshape.2" : "gearshape").font(.system(size: size * 0.5)).foregroundStyle(Palette.ink3).frame(width: size, height: size)
        }
    }

    func chip(_ s: StartupItem.State?) -> some View {
        switch s {
        case .on: Tag(text: "On", color: Palette.ok)
        case .off: Tag(text: "Off")
        case .offOutsideSettings: Tag(text: "Off outside Settings", color: Palette.warn)
        case .broken: Tag(text: "Broken", color: Palette.warn)
        case nil: Tag(text: "Some off")
        }
    }

    func color(_ s: StartupItem.State) -> Color {
        switch s { case .on: Palette.ok; case .off: Color.secondary.opacity(0.5); case .offOutsideSettings, .broken: Palette.warn }
    }

    /// The group's state when every member agrees; nil ("Some off") when they don't.
    func groupState(_ m: [StartupItem]) -> StartupItem.State? {
        if m.contains(where: { $0.state == .broken }) { return .broken }
        let states = Set(m.map(\.state))
        return states.count == 1 ? states.first : nil
    }

    func summary(_ m: [StartupItem]) -> String {
        var parts = ["\(m.count) item\(m.count == 1 ? "" : "s")"]
        if m.allSatisfy(\.allUsers) { parts.append("for all users") } else if m.contains(where: \.allUsers) { parts.append("some for all users") }
        if m.contains(where: \.appGone) { parts.append("its app is gone") }
        return parts.joined(separator: " · ")
    }

    func kind(_ item: StartupItem) -> String {
        switch item.kind {
        case .openAtLogin: "App"
        case .loginItem: "Login item"
        case .agent: item.allUsers ? "Agent, all users" : "Agent"
        case .daemon: "Daemon, all users"
        case .backgroundTask: "Runs in the background"
        }
    }

    func detail(_ item: StartupItem) -> String? {
        switch item.state {
        case .broken: item.note
        case .offOutsideSettings: "Turned off with launchctl. System Settings still shows it as on."
        case .off: item.note.map { $0.hasPrefix("Its own") ? $0 : "Off in System Settings · \($0)" } ?? "Off in System Settings"
        case .on: item.note ?? item.path
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    // MARK: actions

    func turnBackOn(_ item: StartupItem) {
        if model.safeMode { model.flash("Safe mode: nothing was changed."); return }
        working.insert(item.id)
        Task {
            await StartupEngine.turnBackOn(item)
            let loaded = await StartupEngine.loadedLabels(StartupEngine.guiDomain)
            working.remove(item.id)
            guard let label = item.label, let i = model.snap.startup?.items.firstIndex(where: { $0.id == item.id }) else { return }
            if loaded.contains(label) {
                withAnimation(.snappy) { model.snap.startup?.items[i].state = .on }
                model.flash("\(item.name) is on again.")
            } else {
                model.flash("\(item.name) is allowed again; it starts at your next login.")
                withAnimation(.snappy) { model.snap.startup?.items[i].state = .off }
            }
            model.save()
        }
    }

    func remove(_ item: StartupItem) {
        guard let p = item.path else { return }
        working.insert(item.id)
        Task {
            if !model.safeMode { await StartupEngine.stop(item) }
            await model.clean("Startup Items", targets: [Actions.Target(path: p, bytes: 0)]) {
                withAnimation(.snappy) { model.snap.startup?.items.removeAll { $0.id == item.id } }
            }
            working.remove(item.id)
        }
    }
}
