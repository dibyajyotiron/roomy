import SwiftUI
import AppKit

/// The window's top level: seven areas, each with its own hue. The rail switches areas; an area with several modules
/// lists them in a quiet column beside it.
enum Area: String, CaseIterable, Identifiable {
    case checkup, cleanup, apps, files, health, storage, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .checkup: "Checkup"; case .cleanup: "Cleanup"; case .apps: "Applications"; case .files: "Your Files"
        case .health: "Health"; case .storage: "Storage"; case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .checkup: "house"; case .cleanup: "trash"; case .apps: "square.grid.2x2"; case .files: "folder"
        case .health: "waveform.path.ecg"; case .storage: "internaldrive"; case .settings: "gearshape"
        }
    }

    /// The rail draws each area as a solid glyph.
    var railSymbol: String {
        switch self {
        case .checkup: "house.fill"; case .cleanup: "trash.fill"; case .apps: "square.grid.2x2.fill"; case .files: "folder.fill"
        case .health: "heart.fill"; case .storage: "internaldrive.fill"; case .settings: "gearshape.fill"
        }
    }

    /// One line under the area's title in its list.
    var blurb: String {
        switch self {
        case .cleanup: "Caches, logs and leftovers that rebuild on their own."
        case .apps: "Remove apps cleanly, update them and keep startup lean."
        case .files: "Big, old and duplicate files. You decide what goes."
        case .health: "Protection, activity and upkeep."
        default: ""
        }
    }

    var routes: [Route] {
        switch self {
        case .checkup: [.care]
        case .storage: [.storage]
        case .settings: [.settings]
        case .cleanup: Route.sections[1].1
        case .apps: Route.sections[2].1
        case .files: Route.sections[3].1
        case .health: Route.sections[4].1
        }
    }

    static func of(_ r: Route) -> Area { allCases.first { $0.routes.contains(r) } ?? .checkup }

    /// The area's hue in degrees and its saturation, the same family as its liquid icons.
    var hue: (h: Double, s: Double) {
        switch self {
        case .checkup: (262, 0.68); case .cleanup: (168, 0.72); case .apps: (36, 0.86); case .files: (352, 0.72)
        case .health: (204, 0.78); case .storage: (238, 0.62); case .settings: (220, 0.14)
        }
    }

    func color(sat: Double, bri: Double, shift: Double = 0) -> Color { spec.color(sat: sat, bri: bri, shift: shift) }
    var spec: Hue { Hue(h: hue.h, s: hue.s) }

    /// In a theme, each area leans a few degrees off the theme's hue, so areas stay apart while the window stays one
    /// colour family.
    var lean: Double {
        switch self { case .checkup, .settings: 0; case .cleanup: -10; case .apps: 10; case .files: -18; case .health: 18; case .storage: -5 }
    }
}

/// A hue in degrees and a saturation, from which grounds, glows and spheres take their colours.
struct Hue: Equatable {
    var h: Double
    var s: Double
    func color(sat: Double, bri: Double, shift: Double = 0) -> Color {
        let x = ((h + shift).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        return Color(hue: x, saturation: min(1, s * sat), brightness: bri)
    }
}

/// Where the window's colour comes from: the chosen theme (its accent's hue, leaning a little per area), or, with the
/// By area theme, each area's own hue.
enum Ground {
    @MainActor static func hue(_ a: Area, _ t: Theme) -> Hue {
        if t.id == "area" { return a.spec }
        let c = NSColor(t.accent ?? Color(nsColor: .controlAccentColor)).usingColorSpace(.sRGB) ?? .systemBlue
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &al)
        if a == .settings { return Hue(h: Double(h) * 360, s: 0.14) }
        return Hue(h: Double(h) * 360 + a.lean, s: min(0.9, max(0.55, Double(s))))
    }

    /// The orb's colour: the theme's accent, or the area's own colour with the By area theme.
    @MainActor static func tint(_ a: Area, _ t: Theme) -> Color {
        t.id == "area" ? a.color(sat: 0.85, bri: 0.85) : (t.accent ?? .accentColor)
    }
}

/// The ground under everything: a mesh of the area's hue with a bloom of light in the upper right, a glow where the
/// content sits and a deeper corner at the lower left, finished with a whisper of grain so the gradients never band.
/// Deep in dark mode, luminous and pale in light mode. Areas crossfade into each other.
struct AreaGround: View {
    var area: Area
    var theme: Theme = Theme.current
    @Environment(\.colorScheme) var scheme
    var body: some View {
        ZStack {
            ForEach(["\(area.rawValue)·\(theme.id)"], id: \.self) { _ in layer(Ground.hue(area, theme)).transition(.opacity) }
            Image(nsImage: Grain.tile).resizable(resizingMode: .tile)
                .opacity(scheme == .dark ? 0.05 : 0.035).blendMode(.overlay).allowsHitTesting(false)
        }
        .animation(.smooth(duration: 0.6), value: "\(area.rawValue)·\(theme.id)")
        .ignoresSafeArea()
    }

    func layer(_ a: Hue) -> some View {
        let dark = scheme == .dark
        let c = { (sat: Double, bri: Double, shift: Double) in a.color(sat: sat, bri: bri, shift: shift) }
        let colors: [Color] = dark ? [
            c(0.95, 0.15, -10), c(0.9, 0.24, -2), c(0.85, 0.42, 12),
            c(1.0, 0.10, -8), c(0.92, 0.30, 0), c(0.8, 0.52, 16),
            c(1.0, 0.05, -12), c(1.0, 0.11, -4), c(0.9, 0.26, 18),
        ] : [
            c(0.07, 1.0, -10), c(0.12, 0.99, -2), c(0.24, 0.98, 12),
            c(0.1, 0.97, -8), c(0.15, 0.99, 0), c(0.28, 0.97, 16),
            c(0.2, 0.93, -12), c(0.18, 0.95, -4), c(0.24, 0.96, 18),
        ]
        return ZStack {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.55], [0.6, 0.45], [1, 0.4],
                [0, 1], [0.45, 1], [1, 1],
            ], colors: colors)
            RadialGradient(colors: [c(0.8, dark ? 0.62 : 1, 6).opacity(dark ? 0.3 : 0.5), .clear],
                           center: UnitPoint(x: 0.56, y: 0.46), startRadius: 0, endRadius: 520)
        }
    }
}

/// Fine monochrome noise, made once, tiled over the ground.
enum Grain {
    static let tile: NSImage = {
        let n = 128
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<(n * n) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8(truncatingIfNeeded: seed >> 56)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
        }
        let data = CFDataCreate(nil, px, px.count)!
        let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: data)!,
                         decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: n, height: n))
    }()
}

/// The rail: area symbols floating on the ground beside a hairline. Pointing at one raises a soft tile behind it, lights
/// it in the area's colour and names it at once; the open area keeps its tile and its colour.
struct IconRail: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let current = Area.of(model.route)
        VStack(spacing: 6) {
            ForEach([Area.checkup, .cleanup, .apps, .files, .health]) { a in
                RailItem(area: a, selected: a == current, news: model.areaHasNews(a)) { go(a) }
            }
            Spacer(minLength: 12)
            // Above the disk dial: the rail is anchored at the bottom, so the button appears in the free space and the
            // dial and Settings never move.
            RailUpdateButton()
            DiskDial()
            RailItem(area: .settings, selected: current == .settings, news: false) { go(.settings) }
        }
        .padding(.vertical, 12)
        .frame(width: 62)
        .background(alignment: .trailing) {
            // a hairline that fades out at both ends
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Color.primary.opacity(0.12), location: 0.2),
                                   .init(color: Color.primary.opacity(0.12), location: 0.8), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 0.5).offset(x: 8)
        }
    }

    func go(_ a: Area) { withAnimation(.smooth(duration: 0.38)) { model.route = model.lastRoute[a] ?? a.routes[0] } }
}

struct RailItem: View {
    var area: Area
    var selected: Bool
    var news: Bool
    var action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RailTile(area: area, selected: selected).opacity(selected || hover ? 1 : 0).scaleEffect(selected || hover ? 1 : 0.82)
                RailGlyph(symbol: area.railSymbol, area: area, lit: selected || hover)
                if news && !selected {
                    Circle().fill(area.color(sat: 0.6, bri: 1)).frame(width: 7, height: 7)
                        .shadow(color: area.color(sat: 1, bri: 1).opacity(0.9), radius: 4)
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                        .offset(x: 15, y: -15)
                }
            }
            .frame(width: 46, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .overlay(alignment: .leading) {
            if hover { RailTip(text: area.title).fixedSize().offset(x: 54).transition(.opacity.combined(with: .offset(x: -5))) }
        }
        .zIndex(hover ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: selected)
        .accessibilityLabel(area.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Gives a little when pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The soft raised tile behind a pointed-at or open rail item: a pane of frosted light with a bright top edge.
struct RailTile: View {
    var area: Area
    var selected: Bool
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.17 : 0.8), .white.opacity(dark ? 0.05 : 0.42)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(area.color(sat: 0.9, bri: dark ? 0.8 : 0.9).opacity(selected ? (dark ? 0.14 : 0.1) : 0)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.38 : 0.95), .white.opacity(dark ? 0.06 : 0.3)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .shadow(color: .black.opacity(dark ? 0.28 : 0.08), radius: 7, y: 3)
    }
}

/// A rail symbol as a moulded glyph: a face lit from above over a darker underside that gives it thickness. Lit, it
/// takes the area's colour and glows.
struct RailGlyph: View {
    var symbol: String
    var area: Area
    var lit: Bool
    var size: CGFloat = 18
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let dark = scheme == .dark
        let face: [Color] = lit ? [area.color(sat: 0.42, bri: 1, shift: -6), area.color(sat: 1, bri: dark ? 0.9 : 0.8, shift: 6)]
            : dark ? [.white.opacity(0.92), Color(white: 0.66)] : [Color(white: 0.5), Color(white: 0.3)]
        let under: Color = lit ? area.color(sat: 1, bri: 0.36) : dark ? .black.opacity(0.6) : Color(white: 0.1).opacity(0.22)
        let glyph = Image(systemName: symbol).font(.system(size: size, weight: .semibold))
        ZStack {
            glyph.foregroundStyle(under).offset(y: size * (dark || lit ? 0.09 : 0.06))
            glyph.foregroundStyle(LinearGradient(colors: face, startPoint: .top, endPoint: .bottom))
            glyph.foregroundStyle(.white.opacity(lit ? 0.55 : dark ? 0.45 : 0.3))
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)))
        }
        .shadow(color: lit ? area.color(sat: 1, bri: 0.8).opacity(dark ? 0.6 : 0.4) : .black.opacity(dark ? 0.3 : 0.1), radius: lit ? 7 : 2, y: 1)
        .animation(.easeOut(duration: 0.16), value: lit)
    }
}

/// A rail item's name, shown the moment the pointer arrives: a small dark label with a pointer toward the item.
struct RailTip: View {
    var text: String
    var body: some View {
        let fill = Color(white: 0.11).opacity(0.88)
        HStack(spacing: 0) {
            TipArrow().fill(fill).frame(width: 6, height: 11)
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

/// Points left.
struct TipArrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// How full the disk is, as a small glowing ring at the rail's foot. Click it for Storage.
struct DiskDial: View {
    @Environment(AppModel.self) var model
    @State private var hover = false
    var body: some View {
        let d = model.snap.disk
        let used = d.total > 0 ? Double(d.total - d.free) / Double(d.total) : 0
        let on = model.route == .storage
        let a = Area.storage
        Button { withAnimation(.smooth(duration: 0.38)) { model.route = .storage } } label: {
            ZStack {
                RailTile(area: a, selected: on).opacity(on || hover ? 1 : 0)
                Circle().stroke(Color.primary.opacity(0.14), lineWidth: 3.5).frame(width: 28, height: 28)
                Circle().trim(from: 0, to: used)
                    .stroke(AngularGradient(colors: [a.color(sat: 0.5, bri: 1), a.color(sat: 1, bri: 0.95, shift: 30)], center: .center),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 28, height: 28)
                    .shadow(color: a.color(sat: 1, bri: 0.9).opacity(on || hover ? 0.8 : 0.4), radius: 4)
                Text("\(Int((1 - used) * 100))%").font(.system(size: 8.5, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(on || hover ? .primary : .secondary)
            }
            .frame(width: 46, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .overlay(alignment: .leading) {
            if hover { RailTip(text: "Storage · \(Fmt.bytes(d.free)) free").fixedSize().offset(x: 54).transition(.opacity.combined(with: .offset(x: -5))) }
        }
        .zIndex(hover ? 1 : 0)
        .accessibilityLabel("Storage, \(Fmt.bytes(d.free)) free")
    }
}

/// The modules of one area: its title, a line on what it's for, then each module with the size it found. The
/// selection is a raised pill that slides between rows.
struct AreaList: View {
    @Environment(AppModel.self) var model
    var area: Area
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(area.title).font(.system(size: 22, weight: .bold)).tracking(-0.4)
            Text(area.blurb).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3).padding(.bottom, 16)
            VStack(spacing: 3) {
                ForEach(Array(area.routes.enumerated()), id: \.element) { i, r in row(r).modifier(RiseIn(delay: Double(i) * 0.03)) }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 58).padding(.horizontal, 14).padding(.bottom, 16)
        .frame(width: 236)
    }

    func row(_ r: Route) -> some View {
        let on = model.route == r
        return Button { withAnimation(.smooth(duration: 0.3)) { model.route = r } } label: {
            HStack(spacing: 11) {
                LiquidIcon(route: r, size: 32, interactive: false)
                Text(r.title).font(.system(size: 13.5, weight: on ? .semibold : .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let b = model.badge(for: r) {
                    Text(b).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(on ? .primary : .secondary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 9).frame(height: 46)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.surface)
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Palette.surfaceLine, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "sel", in: ns)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHover()
    }
}

/// Finds the window a view lives in, once it has one.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = Probe()
        v.onWindow = onWindow
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if let w = v.window { onWindow(w) }
    }
    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow?(w) }
        }
    }
}

/// A new Roomy, as a solid round button in the rail just above the disk dial. One click downloads it (a ring around the
/// button fills) and Roomy quits, installs it and reopens. Nothing shows while Roomy is up to date.
struct RailUpdateButton: View {
    @State private var updater = AppUpdater.shared
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        switch updater.state {
        case .available(let v): button(v, busy: false, tip: "Update to Roomy \(v)")
        case .downloading(let v): button(v, busy: true, tip: updater.progress.map { "Downloading Roomy \(v) · \(Int($0 * 100))%" } ?? "Downloading Roomy \(v)")
        case .ready(let v): button(v, busy: true, tip: "Installing Roomy \(v)…")
        default: EmptyView()
        }
    }

    func button(_ version: String, busy: Bool, tip: String) -> some View {
        Button { updater.update() } label: {
            ZStack {
                Circle().fill(Palette.accent)
                    .shadow(color: Palette.accent.opacity(0.45), radius: hover && !busy ? 8 : 5, y: 2)
                Image(systemName: "square.and.arrow.down").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .offset(y: -1)
                if busy {
                    Circle().stroke(Palette.accent.opacity(0.2), lineWidth: 2.5).padding(-5)
                    TimelineView(.animation(paused: updater.progress != nil || reduceMotion)) { tl in
                        let p = updater.progress
                        let spin = p == nil && !reduceMotion ? tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360 : 0
                        Circle().trim(from: 0, to: p.map { max(0.03, $0) } ?? 0.28)
                            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(spin - 90)).padding(-5)
                            .animation(p == nil ? nil : .smooth(duration: 0.5), value: p)
                    }
                }
            }
            .frame(width: 34, height: 34)
            .scaleEffect(hover && !busy ? 1.06 : 1)
            .frame(width: 46, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .overlay(alignment: .leading) {
            if hover { RailTip(text: tip).fixedSize().offset(x: 54).transition(.opacity.combined(with: .offset(x: -5))) }
        }
        .zIndex(hover ? 1 : 0)
        .help(busy ? tip : "Download Roomy \(version); Roomy then quits, installs it and reopens.")
        .accessibilityLabel(busy ? tip : "Update Roomy to \(version)")
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}
