import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        let area = Area.of(model.route)
        ZStack(alignment: .topLeading) {
            AreaGround(area: area, theme: model.theme)
            // Checkup's room runs under everything, rail included; every other area sits beside its list.
            if area == .checkup {
                // The room fades in rather than blurring: a blur over a live 3D view costs a second of frames.
                CheckupView().transition(.opacity.animation(.easeOut(duration: 0.3)))
            } else {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 80)
                    if area.routes.count > 1 {
                        AreaList(area: area).id(area).transition(.opacity.combined(with: .offset(x: -14)))
                    }
                    GeometryReader { geo in
                        Detail(route: model.route)
                            // Lists scroll on under the footer and the orb, and end clear of them.
                            .contentMargins(.bottom, 84, for: .scrollContent)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                            .id("\(model.route.rawValue)·\(model.themeID)")
                            .transition(swap)
                    }
                }
                .transition(swap)
            }
            IconRail().padding(.leading, 9).padding(.top, 64).padding(.bottom, 14)
        }
        .animation(.smooth(duration: 0.38), value: model.route)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                InWindowGlow(state: OrbPanel.shared.state)
                InWindowOrb(state: OrbPanel.shared.state)
            }
        }
        .ignoresSafeArea()
        .background(WindowReader { OrbPanel.shared.attach(to: $0) })
        .onAppear { syncOrb() }
        // Again on the next turn: a scan's last step can render on its own before the phase it ends with is set,
        // and the orb must not stay on "100%".
        .onChange(of: orbKey) { syncOrb(); Task { @MainActor in syncOrb() } }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .overlay(alignment: model.route == .care ? .top : .bottom) { ToastView() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshAccess() }
        .toolbar {
            ToolbarSpacer(.flexible)
            // The orb scans; once it has turned into the screen's clean-up action, Scan Again lives up here.
            if AppModel.scanPart(for: model.route) != nil, model.route != .care, model.footer?.route == model.route {
                ToolbarItem { RescanButton(route: model.route) }
            }
            ToolbarItem { UpdatePill() }
        }
        .frame(minWidth: 1000, minHeight: 660)
        .onAppear { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
    }

    /// Everything the orb shows on a module screen, so it updates only when one of these changes.
    var orbKey: String {
        let f = model.footer.map { "\($0.route.rawValue)\($0.title)\($0.enabled)" } ?? "-"
        return [model.route.rawValue, f, "\(model.isCleaning)", model.rescanning.sorted().joined(), "\(model.phase)", model.themeID, "\(model.finished.count)",
                "\(model.canRescan(model.route))"].joined(separator: "|")
    }

    /// The orb on every screen but Checkup (which drives its own): the screen's footer action when something is
    /// selected, otherwise a scan of what the screen shows; a spinner while either runs.
    func syncOrb() {
        let orb = OrbPanel.shared, s = orb.state, r = model.route
        // The orb never moves: centred on the window's bottom edge on every screen. Checkup sets its own words; until
        // it does, the orb already reads Scan there rather than the last screen's action.
        guard r != .care else { if model.phase == .idle { s.title = "Scan"; s.progress = nil; s.busy = false }; return }
        s.tint = Ground.tint(Area.of(r), model.theme)
        s.progress = nil; s.busy = false; s.enabled = true
        if model.phase == .scanning {
            let p = Double(model.finished.count) / Double(AppModel.steps.count)
            s.title = "\(Int(p * 100))%"; s.progress = p; s.help = "Scanning"
        } else if model.isCleaning || model.isRescanning(r) {
            s.busy = true; s.enabled = false; s.title = ""; s.help = "Working…"
        } else if let f = model.footer, f.route == r {
            // After a scan the orb is the screen's clean-up action; it waits, dimmed, until something is selected.
            s.title = f.title; s.help = f.enabled ? f.help : "Select what to \(f.title.lowercased()) first"; s.enabled = f.enabled
            s.action = { [model] in model.footerAction?() }
        } else if AppModel.scanPart(for: r) != nil {
            s.title = "Scan"; s.enabled = model.canRescan(r)
            s.help = model.phase == .scanning ? "A Checkup scan is running" : "Scan \(r.title) again (⇧⌘R)"
            s.action = { [model] in model.rescan(model.route) }
        } else {
            orb.show(false); return
        }
        orb.show(true)
    }

    /// Screens arrive out of a soft blur and leave quickly, so two layouts never ghost over each other.
    var swap: AnyTransition {
        reduceMotion ? .opacity
            : .asymmetric(insertion: AnyTransition(.blurReplace).combined(with: .scale(scale: 0.985)),
                          removal: .opacity.animation(.easeOut(duration: 0.12)))
    }
}

/// A new Roomy, as a small glass capsule in the toolbar. One click downloads it, then Roomy reopens updated.
struct UpdatePill: View {
    @State private var updater = AppUpdater.shared
    var body: some View {
        switch updater.state {
        case .available(let v):
            Button { updater.update() } label: { Label("Update to \(v)", systemImage: "arrow.down.circle") }
                .help("Download Roomy \(v), then Roomy quits, installs it and reopens.")
        case .downloading(let v), .ready(let v):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Updating to \(v)…") }
        default: EmptyView()
        }
    }
}

/// ⇧⌘R scans again what the screen shows; the orb does the same with a click.
struct RescanShortcut: View {
    @Environment(AppModel.self) var model
    var route: Route
    var body: some View {
        Button("") { model.rescan(route) }.keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.canRescan(route)).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
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
                Label("Scan Again", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
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
        ModuleStage(route: route) { screen }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder var screen: some View {
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

struct ToastView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if let t = model.toast {
            Text(t).font(.system(size: 13)).padding(.horizontal, 18).padding(.vertical, 11)
                .glassEffect(.regular, in: .capsule)
                // Checkup's strip and orb own the bottom of the window, so there it sits under the headline instead.
                .padding(model.route == .care ? .top : .bottom, model.route == .care ? 214 : 92)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
