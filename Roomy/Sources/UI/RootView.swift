import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            // No painted background: the window's own material runs under the glass toolbar and sidebar.
            GeometryReader { geo in
                Detail(route: model.route)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .id("\(model.route.rawValue)·\(model.themeID)")
                    // Like Apple's own sidebar apps: the old screen leaves at once (no ghosting of two layouts),
                    // the new one settles in with a short fade.
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.16)), removal: .identity))
            }
            // Content runs under the toolbar, so each module's artwork sits behind the toolbar glass.
            .ignoresSafeArea(edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .overlay(alignment: .bottom) { ToastView() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshAccess() }
            .toolbar {
                if AppModel.scanPart(for: model.route) != nil {
                    ToolbarItem(placement: .primaryAction) { RescanButton(route: model.route) }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(model.phase == .scanning ? "Scanning…" : "Scan") { model.route = .care; model.scanAll() }
                        .help(model.awaitingClean ? "Clean what the last scan found first" : "Scan your Mac with a Checkup")
                        .disabled(!model.canScan)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button { model.route = .storage } label: { Label("Storage", systemImage: "internaldrive") }
                        .help("What's using your disk")
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 660)
        .onAppear { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
    }
}

/// Scans again just what the screen shows (Storage, Leftovers, AI Cleanup…), leaving the rest of the last scan alone.
struct RescanButton: View {
    @Environment(AppModel.self) var model
    var route: Route
    var body: some View {
        let busy = model.isRescanning(route)
        Button { model.rescan(route) } label: {
            if busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Rescanning…") }
            } else {
                Label("Rescan", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
            }
        }
        .disabled(!model.canRescan(route))
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help(model.phase == .scanning ? "A Checkup scan is running" : model.isCleaning ? "Wait for the clean to finish" : "Scan \(route.title) again (⇧⌘R)")
    }
}

struct Detail: View {
    var route: Route
    var body: some View {
        Group {
            switch route {
            case .care: CheckupView()
            case .systemJunk, .userCache, .developer, .mail, .trash, .systemData: CategoryScreen(route: route)
            case .artifacts: ArtifactsView()
            case .aiCare: AICareView()
            case .uninstaller: UninstallerView()
            case .updates: UpdatesView()
            case .leftovers: LeftoversView()
            case .startup: StartupView()
            case .slimming: SlimmingView()
            case .lens: AdvancedGate(kind: .lens) { DiskMapView() }
            case .large: AdvancedGate(kind: .large) { LargeFilesView() }
            case .dups: DuplicatesView()
            case .photos: PhotosView()
            case .installers: InstallersView()
            case .protection: ProtectionView()
            case .status: ActivityView()
            case .maintenance: MaintenanceView()
            case .history: HistoryView()
            case .storage: StorageView()
            case .settings: SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The system Liquid Glass sidebar: plain symbols, native count badges, the disk at the bottom.
struct Sidebar: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(spacing: 0) {
        List(selection: Binding(get: { model.route }, set: { if let r = $0 { model.route = r } })) {
            ForEach(Route.sections, id: \.1) { section in
                if let title = section.0 {
                    Section(title) { ForEach(section.1) { SidebarRow(route: $0).tag($0) } }
                } else {
                    ForEach(section.1) { SidebarRow(route: $0).tag($0) }
                }
            }
        }
        .listStyle(.sidebar)
            VStack(spacing: 6) {
                UpdateButton()
                StorageWidget()
                HStack(spacing: 4) {
                    Button { model.route = .settings } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(model.route == .settings ? Color.primary.opacity(0.1) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 8)
        }
    }
}

/// Sits just above the disk once a new Roomy is out: a ringed download icon, like an app's badge on your profile photo.
/// One click downloads it (the ring fills), then Roomy quits, installs it and reopens.
struct UpdateButton: View {
    @State private var updater = AppUpdater.shared
    @State private var hover = false

    var body: some View {
        switch updater.state {
        case .available(let v): row(v, title: "Update available", detail: "Roomy \(v) · click to install", busy: false)
        case .downloading(let v): row(v, title: "Downloading…", detail: updater.progress.map { "Roomy \(v) · \(Int($0 * 100))%" } ?? "Roomy \(v)", busy: true)
        case .ready(let v): row(v, title: "Installing…", detail: "Roomy reopens in a moment", busy: true)
        default: EmptyView()
        }
    }

    func row(_ version: String, title: String, detail: String, busy: Bool) -> some View {
        Button { updater.update() } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(Palette.accent.opacity(busy ? 0.25 : 0.9), lineWidth: 1.5)
                    if busy {
                        Circle().trim(from: 0, to: max(0.04, updater.progress ?? 0.04))
                            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(0.75)
                            .animation(.smooth, value: updater.progress)
                    }
                    Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accent)
                        .symbolEffect(.bounce, options: .repeat(.periodic(delay: 2.5)), isActive: !busy)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover && !busy ? 0.1 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not .disabled: that greys the row out and makes a download look stuck. A click while busy does nothing.
        .onHover { hover = $0 }
        .help(busy ? "Updating Roomy to \(version)" : "Download Roomy \(version), then Roomy quits, installs it and reopens.")
        .accessibilityLabel(busy ? "Updating Roomy to \(version)" : "Update Roomy to \(version)")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// One sidebar row: its own view, so its badge re-reads the model whenever a scan or clean changes it.
struct SidebarRow: View {
    @Environment(AppModel.self) var model
    var route: Route
    var body: some View {
        Label(route.title, systemImage: route.symbol)
            .badge(badgeText.map { Text($0).monospacedDigit() })
    }

    var badgeText: String? {
        let s = model.snap
        if !route.categories.isEmpty {
            let b = route.categories.compactMap { s.category($0) }.reduce(0) { $0 + $1.bytes }
            return b > 0 ? Fmt.bytes(b) : nil
        }
        switch route {
        case .aiCare: let b = s.aiCare.cleanable; return b > 0 ? Fmt.bytes(b) : nil
        case .artifacts: let b = s.artifacts.reduce(0) { $0 + $1.bytes }; return b > 0 ? Fmt.bytes(b) : nil
        case .uninstaller: return s.apps.isEmpty ? nil : "\(s.apps.count)"
        case .updates: return s.outdated.isEmpty ? nil : "\(s.outdated.count)"
        case .leftovers: let b = s.leftovers.filter { !$0.review }.reduce(0) { $0 + $1.bytes }; return b > 0 ? Fmt.bytes(b) : nil
        case .slimming: let b = s.languageFiles.reduce(0) { $0 + $1.bytes }; return b > 0 ? Fmt.bytes(b) : nil
        case .large: let b = s.largeFiles.filter { !LargeFilesView.info($0).locked }.reduce(0) { $0 + $1.bytes }; return b > 0 ? Fmt.bytes(b) : nil
        case .dups: let b = s.duplicates.reduce(0) { $0 + $1.wasted }; return b > 0 ? Fmt.bytes(b) : nil
        case .photos: return s.photos.isEmpty ? nil : "\(s.photos.count)"
        case .installers: let b = s.installers.reduce(0) { $0 + $1.bytes }; return b > 0 ? Fmt.bytes(b) : nil
        case .protection: let off = s.protection.filter { $0.on == false }.count; return off > 0 ? "\(off) off" : nil
        default: return nil
        }
    }
}

/// Disk usage in a small glass card, coloured like System Settings' bar. Click to see what's using it.
struct StorageWidget: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let d = model.snap.disk
        Button { model.route = .storage } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Text(Fmt.bytes(d.free)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text("free of \(Fmt.bytes(d.total))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                StorageBar(report: model.snap.storage, disk: d, height: 6, selected: nil)
                Text(d.name).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(model.route == .storage ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See what's using your disk")
    }
}

struct ToastView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if let t = model.toast {
            Text(t).font(.system(size: 13)).padding(.horizontal, 18).padding(.vertical, 11)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 92)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
