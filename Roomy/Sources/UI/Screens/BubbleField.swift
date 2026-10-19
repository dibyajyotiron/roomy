import SwiftUI

/// Disk Map's bubbles: every item a drop of Liquid Glass sized by what it takes up, tinted by what it is and carrying
/// its Finder icon, floating over the open folder. They spring to a tidy packed layout, shoulder each other aside,
/// swell under the pointer and can be thrown; drops that touch flow into each other like liquid. The simulation runs
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
                    FolderDisc(size: geo.size)
                    // The glass drops share one container so touching drops merge; their icons and labels sit in a layer
                    // above it, because the container composites its glass over anything inside it.
                    GlassEffectContainer(spacing: 12) {
                        ZStack(alignment: .topLeading) {
                            ForEach(sim.bodies, id: \.id) { b in
                                GlassBubble(b: b, hot: sim.hovered == b.id, picked: picked.contains(b.node.id)).position(b.p)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    ZStack(alignment: .topLeading) {
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

/// The open folder: a soft disc of the theme's colour that the glass drops float over and bend.
struct FolderDisc: View {
    var size: CGSize
    var body: some View {
        let d = min(size.width, size.height) * 0.99
        Circle()
            .fill(RadialGradient(colors: [Palette.accent.opacity(0.30), Palette.accent.opacity(0.10), Palette.accent.opacity(0.04)],
                                 center: UnitPoint(x: 0.42, y: 0.35), startRadius: 0, endRadius: d * 0.6))
            .overlay(Circle().strokeBorder(Palette.accent.opacity(0.22), lineWidth: 1))
            .frame(width: d, height: d)
            .position(x: size.width / 2, y: size.height / 2)
    }
}

/// One item as a drop of Liquid Glass: the real glass material tinted by safety class, with the item's Finder icon,
/// name and size inside when there's room.
struct GlassBubble: View {
    var b: BubbleSim.Body
    var hot: Bool
    var picked: Bool
    var body: some View {
        let r = b.r
        Color.clear.glassEffect(.regular.tint(b.node.cls.color.opacity(hot ? 0.45 : 0.3)), in: Circle())
            .frame(width: max(1, r * 2), height: max(1, r * 2))
            .overlay(Circle().strokeBorder(Palette.accent, lineWidth: 2.5).padding(-3).opacity(picked ? 1 : 0))
    }
}

/// A drop's Finder icon, name and size, drawn above the glass so it stays crisp.
struct BubbleLabel: View {
    var b: BubbleSim.Body
    var body: some View {
        let r = b.r, n = b.node
        VStack(spacing: r >= 46 ? 3 : 0) {
            if r >= 18 {
                FileIcon(path: n.other || n.path.hasPrefix("macos:") ? "/System" : n.path, size: min(72, r * (r >= 46 ? 0.6 : 0.95)))
            }
            if r >= 46 {
                Text(n.display).font(.system(size: r > 80 ? 13 : 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                Text(Fmt.bytes(n.bytes)).font(.system(size: r > 80 ? 12 : 10)).monospacedDigit().foregroundStyle(.secondary)
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
                b.target = pl.center; b.targetR = pl.r; b.node = pl.node
                if snap { b.p = pl.center; b.r = pl.r }
                return b
            }
            // New bubbles start small, a little towards the middle, and push each other out as they grow.
            let start = CGPoint(x: pl.center.x + (mid.x - pl.center.x) * 0.3 + .random(in: -6...6), y: pl.center.y + (mid.y - pl.center.y) * 0.3 + .random(in: -6...6))
            return Body(id: pl.id, node: pl.node, p: snap ? pl.center : start, r: snap ? pl.r : 1, target: pl.center, targetR: pl.r)
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
                    let d = max(0.001, hypot(dx, dy)), minD = bodies[i].r + bodies[j].r + 2
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
