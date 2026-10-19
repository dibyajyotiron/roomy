import SwiftUI
import AppKit

/// What Checkup's round button says and does. Checkup keeps it up to date; the button only draws it.
@MainActor @Observable
final class OrbState {
    var title = "Scan"
    /// 0...1 while a scan runs: the ring around the button fills.
    var progress: Double?
    /// A clean is running: a spinner instead of a word.
    var busy = false
    var enabled = true
    var visible = false
    var help = ""
    var tint: Color = .accentColor
    /// How far the orb's centre sits above the window's bottom edge (0 when it hangs half outside).
    var lift: CGFloat = 0
    /// How far right of the window's centre the orb sits. Always 0: the orb stays in one place on every screen.
    var shift: CGFloat = 0
    @ObservationIgnored var action: () -> Void = {}
}

/// The screen's one action as a glass orb centred on the window's bottom edge, half inside the window and half outside.
/// It lives in two borderless panels, children of the main window, so it can hang over the edge: a wide one for the
/// part of its glow that falls outside the window (it ignores the mouse), and a tight one for the orb itself. The glow
/// inside the window is drawn by the window (`InWindowGlow`), so it blends with whatever is under it. They move with
/// the window and lift inside it when the window sits on the bottom of the screen or goes full screen.
@MainActor
final class OrbPanel {
    static let shared = OrbPanel()
    let state = OrbState()
    /// The orb and its ring.
    static let side: CGFloat = 132
    /// The glow around it, wide enough that its blur fades out well inside the panel.
    static let glowSide: CGFloat = 440
    private var panel: NSPanel?
    private var glow: NSPanel?
    private weak var host: NSWindow?
    private var tokens: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var slideTimer: Timer?

    private func makePanel(_ side: CGFloat) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.animationBehavior = .none
        p.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        return p
    }

    func attach(to window: NSWindow) {
        guard host !== window else { return }
        detach()
        host = window
        let g = makePanel(Self.glowSide)
        g.contentView = NSHostingView(rootView: OrbGlow(state: state).frame(width: Self.glowSide, height: Self.glowSide))
        g.ignoresMouseEvents = true
        let p = makePanel(Self.side)
        let v = FirstClickHostingView(rootView: OrbButton(state: state).frame(width: Self.side, height: Self.side))
        v.frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        p.contentView = v
        p.ignoresMouseEvents = !state.visible
        glow = g
        panel = p
        window.addChildWindow(g, ordered: .above)
        window.addChildWindow(p, ordered: .above)
        appearWhenOnScreen(tries: 40)
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didDeminiaturizeNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.place(); if self.state.visible { self.show(true) } }
            })
        }
        tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detach() }
        })
        // Full screen, Spaces, Stage Manager and app switching can each drop or bury a child window. Put the panels
        // back whenever any of them happens, and check every couple of seconds (cheap: it only reads a few flags).
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeMainNotification, NSWindow.didEndLiveResizeNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ensure() }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSApplication.didUnhideNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ensure() }
            })
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.ensure() } }
        place()
    }

    /// While the orb should show and its window is on screen, both panels are its children and ordered in.
    func ensure() {
        guard state.visible, let w = host, w.isVisible, !w.isMiniaturized, let p = panel, let g = glow else { return }
        var moved = false
        for c in [g, p] where c.parent !== w { c.parent?.removeChildWindow(c); w.addChildWindow(c, ordered: .above); moved = true }
        if moved || !g.isVisible || !p.isVisible {
            place()
            g.orderFront(nil)
            p.orderFront(nil)
        }
    }

    /// Checkup asks for the orb before its window is on screen; order the panels in as soon as the window is.
    private func appearWhenOnScreen(tries: Int) {
        guard let w = host, panel != nil else { return }
        if w.isVisible { show(state.visible); return }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.appearWhenOnScreen(tries: tries - 1) }
    }

    func detach() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        watchdog?.invalidate()
        watchdog = nil
        for p in [glow, panel].compactMap({ $0 }) { p.parent?.removeChildWindow(p); p.orderOut(nil) }
        panel = nil
        glow = nil
        host = nil
    }

    func show(_ on: Bool) {
        state.visible = on
        guard let p = panel else { return }
        p.ignoresMouseEvents = !on
        // A child added before its window was on screen is never ordered in by AppKit: ensure() does it.
        if on { ensure() }
    }

    /// Centred on the window's bottom edge (or under the content column); lifted so the whole orb stays on screen.
    private func place(animated: Bool = false) {
        guard let w = host, let p = panel, let g = glow else { return }
        let f = w.frame, r: CGFloat = 46
        var cy = f.minY
        // Full screen has no edge to hang over: there the orb sits just inside the bottom.
        if w.styleMask.contains(.fullScreen) { cy = f.minY + r + 26 }
        if state.lift != cy - f.minY { state.lift = cy - f.minY }
        let cx = f.midX + state.shift
        let po = NSPoint(x: (cx - Self.side / 2).rounded(), y: (cy - Self.side / 2).rounded())
        let go = NSPoint(x: (cx - Self.glowSide / 2).rounded(), y: (cy - Self.glowSide / 2).rounded())
        slideTimer?.invalidate()
        guard animated, p.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            p.setFrameOrigin(po); g.setFrameOrigin(go); return
        }
        // AppKit's animator doesn't move child windows, so the slide is stepped by hand: 0.38s, easing out.
        let p0 = p.frame.origin, g0 = g.frame.origin, start = Date()
        slideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                let u = min(1, Date().timeIntervalSince(start) / 0.38)
                let k = CGFloat(1 - pow(1 - u, 3))
                p.setFrameOrigin(NSPoint(x: (p0.x + (po.x - p0.x) * k).rounded(), y: (p0.y + (po.y - p0.y) * k).rounded()))
                g.setFrameOrigin(NSPoint(x: (g0.x + (go.x - g0.x) * k).rounded(), y: (g0.y + (go.y - g0.y) * k).rounded()))
                if u >= 1 { t.invalidate(); self?.slideTimer = nil }
            }
        }
    }

    func slide() { place(animated: true) }
}

/// The orb's glow: still at rest, turning slowly while something runs.
struct OrbAura: View {
    var state: OrbState
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        let working = (state.progress != nil || state.busy) && !reduceMotion
        TimelineView(.animation(paused: !working)) { tl in
            let turn = working ? tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) / 12 * 360 : 0
            Aura(tint: state.tint, d: 92, strength: state.enabled || state.busy ? 1 : 0.35).rotationEffect(.degrees(turn))
        }
        .frame(width: OrbPanel.glowSide, height: OrbPanel.glowSide)
        .scaleEffect(state.visible ? 1 : 0.4)
        .opacity(state.visible ? 1 : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.62), value: state.visible)
        .allowsHitTesting(false)
    }
}

/// The part of the glow that falls below the window, over the desktop.
struct OrbGlow: View {
    var state: OrbState
    var body: some View {
        OrbAura(state: state)
            .mask(alignment: .bottom) { Rectangle().frame(height: max(0, OrbPanel.glowSide / 2 - state.lift)) }
    }
}

/// The orb's upper half as the window draws it, exactly under the panel's orb. The panel's orb covers it and takes
/// the clicks; if the panel is ever missing, this one still shows and still works.
struct InWindowOrb: View {
    var state: OrbState
    var body: some View {
        Button(action: { state.action() }) {
            Group {
                if state.busy { ProgressView().controlSize(.regular).tint(.white) }
                else {
                    Text(state.title).font(.system(size: state.title.count > 5 ? 15 : 17, weight: .medium, design: state.progress == nil ? .default : .rounded))
                        .monospacedDigit().foregroundStyle(.white).shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                }
            }
            .frame(width: 92, height: 92).contentShape(Circle())
        }
        .buttonStyle(OrbStyle(tint: state.tint, d: 92))
        .disabled(!state.enabled)
        .scaleEffect(state.visible ? 1 : 0.4)
        .opacity(state.visible ? 1 : 0)
        .allowsHitTesting(state.visible)
        .animation(.spring(response: 0.55, dampingFraction: 0.62), value: state.visible)
        .offset(x: state.shift, y: 46 - state.lift)
        .animation(.smooth(duration: 0.38), value: state.shift)
        .accessibilityHidden(true)
    }
}

/// The part of the glow inside the window, drawn by the window so it mixes with the room or the ground under it:
/// added as light in dark mode, laid over softly in light mode.
struct InWindowGlow: View {
    var state: OrbState
    @Environment(\.colorScheme) var scheme
    var body: some View {
        // Still, even while something runs: animating it here would lay out the whole window every frame.
        Aura(tint: state.tint, d: 92, strength: state.enabled || state.busy ? 1 : 0.35)
            .frame(width: OrbPanel.glowSide, height: OrbPanel.glowSide)
            .scaleEffect(state.visible ? 1 : 0.4)
            .opacity(state.visible ? 1 : 0)
            .animation(.spring(response: 0.55, dampingFraction: 0.62), value: state.visible)
            .blendMode(scheme == .dark ? .plusLighter : .normal)
            .opacity(scheme == .dark ? 0.85 : 0.55)
            .offset(x: state.shift, y: OrbPanel.glowSide / 2 - state.lift)
            .animation(.smooth(duration: 0.38), value: state.shift)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Takes the first click, so the orb works even while Roomy's window isn't in front.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The orb: a sphere of the accent lit from inside, with a thin bright rim, sitting in a wide soft aura of three
/// related hues. While a scan runs a ring around it fills and the aura turns slowly; otherwise it is still, so it
/// costs nothing at rest.
struct OrbButton: View {
    var state: OrbState
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let d: CGFloat = 92

    var body: some View {
        let a = state.tint
        ZStack {
            if let p = state.progress {
                ZStack {
                    Circle().stroke(.white.opacity(0.16), lineWidth: 3.5)
                    Circle().trim(from: 0, to: max(0.02, p))
                        .stroke(AngularGradient(colors: [.white.opacity(0.35), .white], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(0.02, p))),
                                style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: a.mix(with: .white, by: 0.5), radius: 5)
                        .animation(.smooth(duration: 0.6), value: p)
                }
                .frame(width: d + 18, height: d + 18)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            Button(action: { state.action() }) {
                label.frame(width: d, height: d).contentShape(Circle())
            }
            .buttonStyle(OrbStyle(tint: a, d: d))
            .disabled(!state.enabled)
            .help(state.help)
            .accessibilityLabel(state.busy ? "Cleaning" : state.title)
        }
        .scaleEffect(state.visible ? 1 : 0.4)
        .opacity(state.visible ? 1 : 0)
        .allowsHitTesting(state.visible)
        .animation(.spring(response: 0.55, dampingFraction: 0.62), value: state.visible)
        .animation(.smooth(duration: 0.35), value: state.progress == nil)
    }

    @ViewBuilder var label: some View {
        if state.busy {
            ProgressView().controlSize(.regular).tint(.white)
        } else {
            Text(state.title)
                .font(.system(size: state.title.count > 5 ? 15 : 17, weight: .medium, design: state.progress == nil ? .default : .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                .contentTransition(.numericText())
                .animation(.snappy, value: state.title)
        }
    }
}

/// The light around the orb: the accent in a wide pool, with a cooler and a warmer relative well round the colour
/// wheel on either side, so the halo reads as coloured light rather than a tinted haze. Still at rest.
struct Aura: View {
    var tint: Color
    var d: CGFloat
    var strength: Double
    var body: some View {
        ZStack {
            Circle().fill(tint.mix(with: .white, by: 0.08)).frame(width: d * 2.0, height: d * 2.0).blur(radius: 42).opacity(0.62 * strength)
            Circle().fill(tint.hueShifted(72).mix(with: .white, by: 0.06)).frame(width: d * 1.2, height: d * 1.2).blur(radius: 30)
                .offset(x: -d * 0.4, y: -d * 0.1).opacity(0.6 * strength)
            Circle().fill(tint.hueShifted(-78).mix(with: .white, by: 0.06)).frame(width: d * 1.1, height: d * 1.1).blur(radius: 30)
                .offset(x: d * 0.38, y: d * 0.1).opacity(0.55 * strength)
        }
    }
}

/// The orb's glass: lit from inside near the top, deepening to the edge, with light gathered in its lower half, a soft
/// highlight, a thin bright rim and a fine dark line outside it for definition. It swells under the pointer and gives
/// when pressed.
struct OrbStyle: ButtonStyle {
    var tint: Color
    var d: CGFloat
    @State private var hover = false
    @Environment(\.isEnabled) var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                ZStack {
                    Circle().fill(RadialGradient(colors: [tint.mix(with: .white, by: 0.32), tint, tint.mix(with: .black, by: 0.42)],
                                                 center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: d * 0.62))
                    Circle().fill(RadialGradient(colors: [tint.hueShifted(20).mix(with: .white, by: 0.5).opacity(0.75), .clear],
                                                 center: UnitPoint(x: 0.5, y: 1.08), startRadius: 0, endRadius: d * 0.55))
                        .blendMode(.screen)
                    Ellipse().fill(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .frame(width: d * 0.66, height: d * 0.34).offset(y: -d * 0.27).blur(radius: 2)
                    Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.18), .white.opacity(0.45)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1.3)
                    Circle().stroke(.black.opacity(0.14), lineWidth: 0.6).padding(-0.4)
                }
                .shadow(color: tint.mix(with: .black, by: 0.55).opacity(0.5), radius: 12, y: 7)
            }
            .saturation(enabled ? 1 : 0.3)
            .opacity(enabled ? 1 : 0.72)
            .scaleEffect(configuration.isPressed ? 0.93 : hover && enabled ? 1.04 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: hover)
            .onHover { hover = $0 }
    }
}
