import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScreenHeader(icon: .settings, title: "Settings", subtitle: "Theme, safety and permissions.")
            Form {
                Section {
                    HStack(spacing: 12) {
                        ForEach(Theme.all) { t in
                            Button { withAnimation(.smooth(duration: 0.5)) { model.themeID = t.id } } label: {
                                VStack(spacing: 6) {
                                    ThemeSwatch(theme: t, selected: model.themeID == t.id)
                                    Text(t.name).font(.system(size: 11)).foregroundStyle(model.themeID == t.id ? .primary : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(t.name) theme")
                            .accessibilityAddTraits(model.themeID == t.id ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                } header: { Text("Theme") } footer: {
                    Text("Colours every area of the window, the round button and its glow, the accent and the walls of Checkup's room. By area gives each area its own colour. Follows light and dark mode.")
                }
                Section {
                    Toggle(isOn: $model.safeMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Safe mode")
                            Text("Cleaning only shows what would be removed. Turn it off when you're ready to let Roomy move files to the Trash.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    Button("Show the warning for Large & Old Files and Disk Map again") { model.ackLarge = false; model.ackLens = false }
                } header: { Text("Safety") } footer: {
                    Text("Roomy never removes anything that belongs to macOS, other accounts, apps that are open, Docker volumes or worktrees with uncommitted changes.")
                }
                Section("Permissions") {
                    LabeledContent("Full Disk Access") {
                        HStack {
                            Text(model.hasFullDiskAccess ? "Allowed" : "Not allowed").foregroundStyle(model.hasFullDiskAccess ? Palette.ok : Palette.warn)
                            Button("Open Privacy & Security") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
                        }
                    }
                    LabeledContent("Touch ID for admin tasks", value: model.snap.touchID ? "On" : "Off")
                    let fans = model.monitor.fans
                    if fans.helper != .missing {
                        LabeledContent("Fan control") {
                            HStack {
                                Text("Installed").foregroundStyle(.secondary)
                                Button("Remove") { Task { await fans.removeHelper() } }.disabled(fans.busy)
                            }
                        }
                    }
                }
                UpdatesSection()
                Section("About") {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Roomy").font(.headline)
                            Text("Make room on your Mac. Free software under GPL-3.0, cleaning with Mole (GPL-3.0) by tw93 and the fan code from Stats (MIT) by Serhiy Mytrovtsiy\((Mole.activeVersion ?? model.snap.moleVersion).map { ", version \($0)" } ?? ""). The living room's furniture, textures and lighting are CC0 scans from Poly Haven.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
        }
    }
}

/// The menu bar panel: health, storage, memory with Free Up, CPU and the busiest apps.
/// A tiny window in the theme: its ground (or, for By area, a band of each area's colour), the rail, the round
/// button half off the bottom edge and a strip of the room's wall.
struct ThemeSwatch: View {
    var theme: Theme
    var selected: Bool
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let dark = scheme == .dark
        let tint = theme.id == "area" ? Area.checkup.color(sat: 0.85, bri: 0.85) : (theme.accent ?? .accentColor)
        ZStack(alignment: .topLeading) {
            if theme.id == "area" {
                HStack(spacing: 0) {
                    ForEach([Area.checkup, .cleanup, .apps, .files, .health]) { a in a.color(sat: 0.9, bri: dark ? 0.32 : 0.9) }
                }
            } else {
                let h = Ground.hue(.checkup, theme)
                LinearGradient(colors: [h.color(sat: dark ? 0.95 : 0.16, bri: dark ? 0.2 : 0.99), h.color(sat: dark ? 0.85 : 0.4, bri: dark ? 0.45 : 0.95, shift: 14)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            VStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(.primary.opacity(0.35)).frame(width: 4, height: 4) } }
                .padding(.leading, 6).padding(.top, 9)
            theme.paint.frame(width: 30, height: 6).clipShape(Capsule()).offset(x: 24, y: 9)
            Circle().fill(tint).frame(width: 14, height: 14).shadow(color: tint.opacity(0.8), radius: 4)
                .position(x: 36, y: 48)
        }
        .frame(width: 72, height: 48)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? tint : Palette.hair, lineWidth: selected ? 2 : 1))
    }
}

/// Roomy's own version and its updates.
struct UpdatesSection: View {
    @State private var updater = AppUpdater.shared
    var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "–" }
    var body: some View {
        Section("Updates") {
            LabeledContent("Roomy \(version)") {
                switch updater.state {
                case .off: Button("Check Now") {}.disabled(true)
                case .checking: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
                case .available(let v): Button("Update to \(v)") { updater.update() }.buttonStyle(.glassProminent)
                case .downloading(let v), .ready(let v): HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Updating to \(v)…").foregroundStyle(.secondary) }
                case .failed: Button("Try Again") { updater.checkNow() }
                case .idle: Button("Check Now") { updater.checkNow() }
                }
            }
            if updater.state != .off {
                Toggle("Check for updates automatically, every 10 minutes", isOn: $updater.automatic)
                Text(note).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(Demo.on ? "The demo doesn't update itself. The installed Roomy checks every 10 minutes, and whenever you ask."
                             : "This build doesn't update itself (development builds carry no update key). Releases check every 10 minutes, and whenever you ask.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    var note: String {
        if case .failed(let m) = updater.state { return "The last check didn't finish: \(m)" }
        let when = updater.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? ""
        return "When a new version is out, an Update button appears in the toolbar. Click it and Roomy downloads the update, installs it and reopens. Updates are signed, so only Roomy's own releases install. " + when
    }
}
