import SwiftUI
import AppKit

@main
struct RoomyApp: App {
    @State private var model = AppModel()

    init() {
        if let what = UserDefaults.standard.string(forKey: "RoomyMoleSelfTest") { MoleCheck.selfTest(what) }
        if let id = UserDefaults.standard.string(forKey: "RoomyLeftoverProbe") { LeftoverFinder.probe(id) }
        if let since = UserDefaults.standard.string(forKey: "RoomyReadCleanLog") { Mole.readCleanLogTest(since) }
        if let out = UserDefaults.standard.string(forKey: "RoomyRulesProbe") { RoomyRules.probe(to: out) }
        if let dir = UserDefaults.standard.string(forKey: "RoomyRenderUI") {
            DispatchQueue.main.async { MainActor.assumeIsolated { UIRender.run(to: dir) } }
        }
        if let dir = UserDefaults.standard.string(forKey: "RoomyRenderStory") {
            let dark = UserDefaults.standard.bool(forKey: "RoomyRenderDark")
            DispatchQueue.main.async { MainActor.assumeIsolated { RoomRender.run(to: dir, dark: dark) } }
        }
        // Testing aid: `open Roomy.app --args -RoomyAppearance light` (or dark) overrides the system appearance.
        switch UserDefaults.standard.string(forKey: "RoomyAppearance") {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    var body: some Scene {
        Window("Roomy", id: "main") {
            // Testing aid: `-RoomyPanelPreview YES` shows the menu bar panel in the window, for screenshots.
            if UserDefaults.standard.bool(forKey: "RoomyPanelPreview") { MenuBarPanel().environment(model).fixedSize() } else {
            RootView()
                .environment(model)
                .tint(model.theme.accent ?? .accentColor)
                .onAppear { NSWindow.allowsAutomaticWindowTabbing = false }
            }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) { UpdateMenuItem() }
            CommandMenu("Scan") {
                Button("Run Checkup") { model.route = .care; model.scanAll() }.keyboardShortcut("r", modifiers: [.command]).disabled(!model.canScan)
                Divider()
                Button("Storage") { model.route = .storage }.keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Activity") { model.route = .status }.keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Disk Map") { model.route = .lens }.keyboardShortcut("3", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environment(model).tint(model.theme.accent ?? .accentColor).frame(width: 640, height: 620)
        }

        MenuBarExtra {
            MenuBarPanel().environment(model).tint(model.theme.accent ?? .accentColor)
        } label: {
            Image(nsImage: RoomGlyph.template)
        }
        .menuBarExtraStyle(.window)
    }
}

/// "Check for Updates…" in the Roomy menu, or "Update to …" once a new version is out.
struct UpdateMenuItem: View {
    @State private var updater = AppUpdater.shared
    var body: some View {
        switch updater.state {
        case .off: Button("Check for Updates…") {}.disabled(true)
        case .available(let v): Button("Update to Roomy \(v)") { updater.update() }
        case .downloading(let v), .ready(let v): Button("Updating to Roomy \(v)…") {}.disabled(true)
        case .checking: Button("Checking for Updates…") {}.disabled(true)
        default: Button("Check for Updates…") { updater.checkNow() }
        }
    }
}

/// The menu bar glyph: Roomy's room drawn as a line icon, rendered as a template image.
enum RoomGlyph {
    static let template: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { r in
            NSColor.black.setStroke()
            let outer = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 3.6, yRadius: 3.6)
            outer.lineWidth = 1.5; outer.stroke()
            let inner = NSRect(x: 6.6, y: 6.6, width: 4.8, height: 4.8)
            let back = NSBezierPath(roundedRect: inner, xRadius: 0.8, yRadius: 0.8)
            back.lineWidth = 1.3; back.stroke()
            let lines = NSBezierPath()
            for (a, b) in [(NSPoint(x: 3, y: 3), NSPoint(x: inner.minX, y: inner.minY)), (NSPoint(x: 15, y: 3), NSPoint(x: inner.maxX, y: inner.minY)),
                           (NSPoint(x: 3, y: 15), NSPoint(x: inner.minX, y: inner.maxY)), (NSPoint(x: 15, y: 15), NSPoint(x: inner.maxX, y: inner.maxY))] {
                lines.move(to: a); lines.line(to: b)
            }
            lines.lineWidth = 1.1; lines.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
