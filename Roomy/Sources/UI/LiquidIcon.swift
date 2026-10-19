import SwiftUI

/// A module's icon as a slab of coloured glass: an organic pebble with real thickness, light gathering at its far edge,
/// a bright rim and a soft highlight, carrying the module's SF Symbol. Point at it and it behaves like liquid: it
/// tilts toward the pointer, its surface ripples and it wobbles like jelly on the way in; click and it squashes.
struct LiquidIcon: View {
    var route: Route
    var size: CGFloat = 52
    var interactive = true
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var tilt = CGSize.zero
    @State private var hovering = false
    @State private var bounce = 0
    /// Where the ripple rests, and when the current hover began; the ripple continues from there, never jumping.
    @State private var phase = 0.0
    @State private var hoverStart = Date()

    var body: some View {
        let st = LiquidStyle.of(route)
        TimelineView(.animation(paused: !hovering || reduceMotion)) { tl in
            let ripple = hovering && !reduceMotion ? phase + tl.date.timeIntervalSince(hoverStart) * 2.4 : phase
            let shape = Pebble(seed: st.seed, phase: ripple, amount: st.seed.amount * (hovering ? 1.6 : 1))
            ZStack {
                // coloured light passing through the glass onto the surface below, plus a neutral contact shadow
                shape.fill(st.mid).blur(radius: size * 0.13).opacity(0.5).scaleEffect(0.86).offset(y: size * 0.12)
                Ellipse().fill(.black.opacity(0.22)).frame(width: size * 0.62, height: size * 0.12).blur(radius: size * 0.05).offset(y: size * 0.43)
                // the slab's side wall
                shape.fill(LinearGradient(colors: [st.deep, st.deep.mix(with: .black, by: 0.45)], startPoint: .top, endPoint: .bottom))
                    .offset(y: size * 0.05)
                // the face
                ZStack {
                    shape.fill(LinearGradient(colors: [st.light, st.mid, st.deep], startPoint: .topLeading, endPoint: .bottomTrailing))
                    // light gathering at the far edge, as it does in thick glass
                    shape.fill(RadialGradient(colors: [st.light.opacity(0.95), st.light.opacity(0)], center: UnitPoint(x: 0.5 - tilt.width * 0.2, y: 1.02),
                                              startRadius: 0, endRadius: size * 0.55)).blendMode(.screen)
                    // a darker band just inside the edge: the glass's thickness bending the light
                    shape.stroke(st.deep.opacity(0.55), lineWidth: size * 0.1).blur(radius: size * 0.05)
                    // soft highlight where the light hits, sliding opposite the tilt
                    Ellipse().fill(.white.opacity(0.55)).frame(width: size * 0.5, height: size * 0.22).blur(radius: size * 0.06)
                        .offset(x: -size * 0.12 - tilt.width * size * 0.1, y: -size * 0.25 - tilt.height * size * 0.08)
                }
                .clipShape(shape)
                // bright rim, strongest at the top
                shape.stroke(LinearGradient(stops: [.init(color: .white.opacity(0.85), location: 0), .init(color: .white.opacity(0.08), location: 0.45),
                                                    .init(color: st.light.opacity(0.6), location: 1)], startPoint: .top, endPoint: .bottom),
                             lineWidth: max(0.8, size * 0.022))
                // the symbol floats a little above the face
                Image(systemName: route.symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.white, st.light.mix(with: .white, by: 0.55)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: st.deep.opacity(0.7), radius: size * 0.03, y: size * 0.035)
                    .offset(x: tilt.width * size * 0.06, y: tilt.height * size * 0.05)
            }
            .frame(width: size, height: size)
        }
        .rotation3DEffect(.degrees(Double(hypot(tilt.width, tilt.height)) * 16), axis: (x: -tilt.height, y: tilt.width, z: 0), perspective: 0.55)
        .keyframeAnimator(initialValue: Jelly(), trigger: bounce) { content, j in
            content.scaleEffect(x: j.x, y: j.y, anchor: .bottom)
        } keyframes: { _ in
            KeyframeTrack(\.x) { SpringKeyframe(1.14, duration: 0.11); SpringKeyframe(0.93, duration: 0.14); SpringKeyframe(1.05, duration: 0.16); SpringKeyframe(1.0, duration: 0.34) }
            KeyframeTrack(\.y) { SpringKeyframe(0.86, duration: 0.11); SpringKeyframe(1.08, duration: 0.14); SpringKeyframe(0.97, duration: 0.16); SpringKeyframe(1.0, duration: 0.34) }
        }
        .scaleEffect(hovering ? 1.06 : 1)
        .contentShape(Rectangle())
        .onContinuousHover { p in
            guard interactive else { return }
            switch p {
            case .active(let pt):
                if !hovering { hoverStart = Date(); hovering = true; if !reduceMotion { bounce += 1 } }
                let t = CGSize(width: max(-1, min(1, (pt.x / size - 0.5) * 2)), height: max(-1, min(1, (pt.y / size - 0.5) * 2)))
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.6)) { tilt = reduceMotion ? .zero : t }
            case .ended:
                phase += Date().timeIntervalSince(hoverStart) * 2.4
                withAnimation(.spring(response: 0.55, dampingFraction: 0.45)) { hovering = false; tilt = .zero }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { if interactive && !reduceMotion { bounce += 1 } })
        .animation(.spring(response: 0.4, dampingFraction: 0.55), value: hovering)
        .accessibilityHidden(true)
    }

    struct Jelly { var x: CGFloat = 1; var y: CGFloat = 1 }
}

/// An organic outline: a blend of circle and squircle, gently lobed, whose lobes can ripple.
struct Pebble: Shape {
    struct Seed { var squircle: Double; var lobes: Double; var amount: Double; var twist: Double }
    var seed: Seed
    var phase: Double
    var amount: Double

    // Only the depth of the lobes animates; the phase comes straight from the timeline, so it never spins to catch up.
    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let R = min(r.width, r.height) / 2 * 0.86
        var p = Path()
        let n = 120
        for i in 0...n {
            let t = Double(i) / Double(n) * 2 * .pi
            // superellipse (n = 4) radius, normalised so the shape stays inside the circle
            let se = pow(pow(abs(cos(t)), 4) + pow(abs(sin(t)), 4), -0.25) / 1.1892
            let base = (1 - seed.squircle) * 0.97 + seed.squircle * se * 1.06
            let k = 1 + amount * sin(seed.lobes * t + phase + seed.twist) + amount * 0.45 * sin((seed.lobes + 1) * t - phase * 0.7)
            let rr = R * base * k
            let pt = CGPoint(x: c.x + rr * cos(t - .pi / 2), y: c.y + rr * sin(t - .pi / 2))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Colours and outline per section, with each module's hue nudged so siblings feel related but distinct.
struct LiquidStyle {
    var light: Color, mid: Color, deep: Color
    var seed: Pebble.Seed

    @MainActor private static var cache: [Route: LiquidStyle] = [:]

    @MainActor static func of(_ r: Route) -> LiquidStyle {
        if let s = cache[r] { return s }
        let section = Route.sections.firstIndex { $0.1.contains(r) }
        let siblings = section.map { Route.sections[$0].1 } ?? [r]
        let i = Double(siblings.firstIndex(of: r) ?? 0), n = Double(max(1, siblings.count - 1))
        // (hue°, saturation) and outline per section: Checkup violet, Cleanup mint, Applications amber,
        // Your Files coral, Health azure; Storage indigo, Settings graphite.
        let (hue, sat, seed): (Double, Double, Pebble.Seed) = {
            switch (r, section) {
            case (.storage, _): return (238, 0.62, .init(squircle: 0.55, lobes: 2, amount: 0.03, twist: 0.4))
            case (.settings, _): return (220, 0.12, .init(squircle: 0.65, lobes: 3, amount: 0.025, twist: 1.1))
            case (_, 0): return (262, 0.68, .init(squircle: 0.25, lobes: 3, amount: 0.05, twist: 0))
            case (_, 1): return (168, 0.72, .init(squircle: 0.12, lobes: 2, amount: 0.055, twist: 0.8))
            case (_, 2): return (36, 0.86, .init(squircle: 0.85, lobes: 4, amount: 0.03, twist: 0.3))
            case (_, 3): return (352, 0.72, .init(squircle: 0.0, lobes: 5, amount: 0.04, twist: 1.7))
            default: return (204, 0.78, .init(squircle: 0.45, lobes: 3, amount: 0.05, twist: 2.4))
            }
        }()
        let h = (hue + (i - n / 2) * 7).truncatingRemainder(dividingBy: 360) / 360
        let h1 = h < 0 ? h + 1 : h
        let s = LiquidStyle(light: Color(hue: h1, saturation: sat * 0.45, brightness: 1.0),
                            mid: Color(hue: h1, saturation: sat, brightness: 0.88),
                            deep: Color(hue: (h1 + 0.02).truncatingRemainder(dividingBy: 1), saturation: min(1, sat * 1.1), brightness: 0.42),
                            seed: seed)
        cache[r] = s
        return s
    }
}
