import SwiftUI

/// Disk Map's bubbles: every item a sphere of tinted glass sized by what it takes up, carrying its Finder icon.
/// They spring to a packed layout with air between them, shoulder each other aside, swell under the pointer and can
/// be thrown. The simulation runs
/// only while something moves, so a still map costs nothing.
struct BubbleField: View {
    var items: [LensNode]
    var picked: Set<String>
    var onOpen: (LensNode) -> Void
    var onBack: (() -> Void)?
    @Binding var hover: LensNode?
    var tip: (LensNode) -> BubbleTip.Info
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var sim = BubbleSim()
    @State private var running = true
    @State private var pointer: CGPoint?
    @State private var grab: (id: String, offset: CGSize, moved: Bool)?

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: !running)) { tl in
                let _ = advance(tl.date, geo.size)
                ZStack {
                    ZStack(alignment: .topLeading) {
                        ForEach(sim.bodies, id: \.id) { b in
                            LensSphere(b: b, hot: sim.hovered == b.id, picked: picked.contains(b.node.id)).position(b.p)
                        }
                        ForEach(sim.bodies, id: \.id) { b in BubbleLabel(b: b).position(b.p) }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    pointer = p
                    let b = sim.hit(p)
                    if b?.id != sim.hovered { sim.hovered = b?.id; hover = b?.node; wake() }
                case .ended:
                    pointer = nil
                    if sim.hovered != nil { sim.hovered = nil; hover = nil; wake() }
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if grab == nil {
                        if let b = sim.hit(g.startLocation) {
                            grab = (b.id, CGSize(width: b.p.x - g.startLocation.x, height: b.p.y - g.startLocation.y), false)
                        } else { grab = ("", .zero, false) }
                    }
                    guard var gr = grab, !gr.id.isEmpty, !reduceMotion else { return }
                    if !gr.moved && hypot(g.translation.width, g.translation.height) > 4 { gr.moved = true; grab = gr; sim.grabbed = gr.id }
                    if gr.moved {
                        sim.hold(gr.id, at: CGPoint(x: g.location.x + gr.offset.width, y: g.location.y + gr.offset.height),
                                 velocity: CGVector(dx: g.velocity.width, dy: g.velocity.height))
                        pointer = g.location
                        wake()
                    }
                }
                .onEnded { g in
                    defer { grab = nil; sim.grabbed = nil; wake() }
                    if let gr = grab, gr.moved { return }   // a throw: the bubble flies back to its place
                    if let b = sim.hit(g.location) { onOpen(b.node) } else { onBack?() }
                })
            .overlay(alignment: .topLeading) {
                if let n = hover, let p = pointer, grab?.moved != true {
                    let w: CGFloat = 270
                    BubbleTip(info: tip(n))
                        .frame(width: w)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: min(max(8, p.x + 18), geo.size.width - w - 8), y: min(max(8, p.y + 18), max(8, geo.size.height - 150)))
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                        .id(n.id)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(items.prefix(8).map { "\($0.display), \(Fmt.bytes($0.bytes))" }.joined(separator: "; "))
        }
    }

    func wake() { sim.moving = true; running = true }

    /// Brings the simulation up to date for this frame, and lets the timeline rest once nothing moves.
    func advance(_ now: Date, _ size: CGSize) {
        if sim.needsSync(items, size) {
            sim.sync(items, in: size, snap: reduceMotion)
            DispatchQueue.main.async { running = true }
        }
        if !sim.step(now, still: reduceMotion) { DispatchQueue.main.async { if !sim.moving { running = false } } }
    }
}

/// One item as a sphere of tinted glass in the area's hue: nearly clear in the middle, deepening towards the edge,
/// with light gathering along its lower rim and a soft highlight up top. Spheres keep a little air between them;
/// what kind of thing it is shows as a dot beside its size, not as its colour.
struct LensSphere: View {
    var b: BubbleSim.Body
    var hot: Bool
    var picked: Bool
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let r = max(1, b.r), a = Ground.hue(.files, Theme.current), dark = scheme == .dark
        ZStack {
            Circle().fill(RadialGradient(stops: [
                .init(color: a.color(sat: 0.6, bri: dark ? 0.55 : 1).opacity(dark ? 0.10 : 0.22), location: 0),
                .init(color: a.color(sat: 0.8, bri: dark ? 0.6 : 0.98).opacity(dark ? 0.22 : 0.34), location: 0.72),
                .init(color: a.color(sat: 0.9, bri: dark ? 0.85 : 0.95).opacity(dark ? 0.5 : 0.55), location: 1),
            ], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: r))
            // light gathering in the lower rim, as it does in a glass ball
            Circle().strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.0), location: 0.35),
                                                         .init(color: a.color(sat: 0.35, bri: 1).opacity(hot ? 1 : 0.8), location: 1)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: max(1.5, r * 0.06))
                .blur(radius: max(1, r * 0.035))
            Circle().strokeBorder(.white.opacity(dark ? 0.22 : 0.5), lineWidth: 0.8)
            Ellipse().fill(.white.opacity(dark ? 0.16 : 0.4)).frame(width: r * 0.9, height: r * 0.32).blur(radius: r * 0.08)
                .offset(y: -r * 0.6)
        }
        .frame(width: r * 2, height: r * 2)
        .brightness(hot ? 0.06 : 0)
        .shadow(color: a.color(sat: 1, bri: 0.4).opacity(dark ? 0.5 : 0.18), radius: r * 0.18, y: r * 0.1)
        .overlay(Circle().strokeBorder(Palette.accent, lineWidth: 2.5).padding(-4).opacity(picked ? 1 : 0))
        .animation(.easeOut(duration: 0.18), value: hot)
    }
}

/// A drop's Finder icon, name and size, drawn above the glass so it stays crisp.
struct BubbleLabel: View {
    var b: BubbleSim.Body
    var body: some View {
        let r = b.r, n = b.node
        VStack(spacing: r >= 46 ? 3 : 0) {
            if r >= 18 {
                FileIcon(path: n.other || n.path.hasPrefix("macos:") ? "/System" : n.path, size: min(96, r * (r >= 46 ? 0.62 : 0.95)))
            }
            if r >= 46 {
                Text(n.display).font(.system(size: r > 110 ? 17 : r > 80 ? 13 : 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                HStack(spacing: 4) {
                    Circle().fill(n.cls.color).frame(width: 6, height: 6)
                    Text(Fmt.bytes(n.bytes)).font(.system(size: r > 110 ? 15 : r > 80 ? 12 : 10, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
        }
        .frame(maxWidth: r * 1.5)
        .frame(width: max(1, r * 2), height: max(1, r * 2))
        .allowsHitTesting(false)
    }
}

/// What a bubble is, shown beside the pointer.
struct BubbleTip: View {
    struct Info { var title: String; var bytes: Int64; var kind: String; var color: Color; var why: String; var hint: String; var locked: Bool }
    var info: Info
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(info.color).frame(width: 8, height: 8)
                Text(info.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Fmt.bytes(info.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            Text(info.kind).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(info.why).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineLimit(3)
            Label(info.hint, systemImage: info.locked ? "lock" : "hand.point.up.left")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}

/// A small spring-and-collision simulation. Each bubble is pulled to its spot in the packed layout; overlapping bubbles
/// push apart (the bigger one moves less) and trade momentum, so a thrown or swelling bubble nudges its neighbours.
final class BubbleSim {
    struct Body {
        var id: String
        var node: LensNode
        var p: CGPoint
        var v = CGVector.zero
        var r: CGFloat
        var target: CGPoint
        var targetR: CGFloat
    }
    var bodies: [Body] = []
    var size: CGSize = .zero
    var hovered: String?
    var grabbed: String?
    var moving = true
    private var ids: [String] = []
    private var last: Date?

    func needsSync(_ items: [LensNode], _ size: CGSize) -> Bool { size != self.size || items.map(\.id) != ids }

    func sync(_ items: [LensNode], in size: CGSize, snap: Bool) {
        let placed = CirclePack.layout(items, grandkids: [:], in: size)
        let old = Dictionary(bodies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        bodies = placed.map { pl in
            if var b = old[pl.id] {
                b.target = pl.center; b.targetR = pl.r * 0.9; b.node = pl.node
                if snap { b.p = pl.center; b.r = pl.r * 0.9 }
                return b
            }
            // New bubbles start small, a little towards the middle, and push each other out as they grow.
            let start = CGPoint(x: pl.center.x + (mid.x - pl.center.x) * 0.3 + .random(in: -6...6), y: pl.center.y + (mid.y - pl.center.y) * 0.3 + .random(in: -6...6))
            return Body(id: pl.id, node: pl.node, p: snap ? pl.center : start, r: snap ? pl.r * 0.9 : 1, target: pl.center, targetR: pl.r * 0.9)
        }
        ids = items.map(\.id)
        self.size = size
        moving = true
        last = nil
    }

    func hit(_ p: CGPoint) -> Body? {
        bodies.filter { hypot($0.p.x - p.x, $0.p.y - p.y) <= $0.r }.min { $0.r < $1.r }
    }

    func hold(_ id: String, at p: CGPoint, velocity: CGVector) {
        guard let i = bodies.firstIndex(where: { $0.id == id }) else { return }
        bodies[i].p = p
        bodies[i].v = CGVector(dx: max(-2400, min(2400, velocity.dx)), dy: max(-2400, min(2400, velocity.dy)))
    }

    /// Advances to `now`. Returns whether anything is still moving.
    func step(_ now: Date, still: Bool) -> Bool {
        if still {
            for i in bodies.indices { bodies[i].p = bodies[i].target; bodies[i].r = bodies[i].targetR }
            moving = false
            return false
        }
        let dt = CGFloat(min(1.0 / 30, max(1.0 / 240, now.timeIntervalSince(last ?? now.addingTimeInterval(-1.0 / 60)))))
        last = now
        var active = grabbed != nil
        let n = bodies.count
        for i in 0..<n {
            let want = bodies[i].targetR * (bodies[i].id == hovered ? 1.07 : 1)
            let dr = want - bodies[i].r
            bodies[i].r += dr * min(1, dt * 10)
            if abs(dr) > 0.15 { active = true }
            guard bodies[i].id != grabbed else { continue }
            // Slightly under-damped spring: settles with a soft overshoot.
            let k: CGFloat = 30, c: CGFloat = 8
            let ax = (bodies[i].target.x - bodies[i].p.x) * k - bodies[i].v.dx * c
            let ay = (bodies[i].target.y - bodies[i].p.y) * k - bodies[i].v.dy * c
            bodies[i].v.dx += ax * dt; bodies[i].v.dy += ay * dt
            bodies[i].p.x += bodies[i].v.dx * dt; bodies[i].p.y += bodies[i].v.dy * dt
        }
        for _ in 0..<3 where n > 1 {
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    let dx = bodies[j].p.x - bodies[i].p.x, dy = bodies[j].p.y - bodies[i].p.y
                    let d = max(0.001, hypot(dx, dy)), minD = bodies[i].r + bodies[j].r + 8
                    guard d < minD else { continue }
                    let nx = dx / d, ny = dy / d, overlap = minD - d
                    let mi = bodies[i].r * bodies[i].r, mj = bodies[j].r * bodies[j].r
                    var wi = mj / (mi + mj), wj = mi / (mi + mj)
                    if bodies[i].id == grabbed { wi = 0; wj = 1 } else if bodies[j].id == grabbed { wi = 1; wj = 0 }
                    bodies[i].p.x -= nx * overlap * wi; bodies[i].p.y -= ny * overlap * wi
                    bodies[j].p.x += nx * overlap * wj; bodies[j].p.y += ny * overlap * wj
                    let rv = (bodies[j].v.dx - bodies[i].v.dx) * nx + (bodies[j].v.dy - bodies[i].v.dy) * ny
                    if rv < 0 {
                        let imp = -1.25 * rv
                        bodies[i].v.dx -= imp * nx * wi; bodies[i].v.dy -= imp * ny * wi
                        bodies[j].v.dx += imp * nx * wj; bodies[j].v.dy += imp * ny * wj
                    }
                }
            }
        }
        for i in 0..<n {
            let r = bodies[i].r
            if bodies[i].p.x < r { bodies[i].p.x = r; bodies[i].v.dx = abs(bodies[i].v.dx) * 0.4 }
            if bodies[i].p.x > size.width - r { bodies[i].p.x = size.width - r; bodies[i].v.dx = -abs(bodies[i].v.dx) * 0.4 }
            if bodies[i].p.y < r { bodies[i].p.y = r; bodies[i].v.dy = abs(bodies[i].v.dy) * 0.4 }
            if bodies[i].p.y > size.height - r { bodies[i].p.y = size.height - r; bodies[i].v.dy = -abs(bodies[i].v.dy) * 0.4 }
            // While a bubble is swollen its neighbours rest slightly off their spots, so only speed counts then.
            if hypot(bodies[i].v.dx, bodies[i].v.dy) > 2 || hovered == nil && hypot(bodies[i].p.x - bodies[i].target.x, bodies[i].p.y - bodies[i].target.y) > 0.6 {
                active = true
            }
        }
        moving = active
        return active
    }
}
