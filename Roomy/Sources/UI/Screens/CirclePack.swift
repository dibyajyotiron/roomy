import CoreGraphics
import Foundation

/// Front-chain circle packing (Wang et al.), ported from d3-hierarchy's packSiblings.
enum CirclePack {
    final class Circle { var x = 0.0, y = 0.0, r: Double; init(r: Double) { self.r = r } }
    final class Node { let c: Circle; var next: Node!; var prev: Node!; init(_ c: Circle) { self.c = c } }

    static func place(_ b: Circle, _ a: Circle, _ c: Circle) {
        let dx = b.x - a.x, dy = b.y - a.y, d2 = dx * dx + dy * dy
        if d2 > 0 {
            let a2 = pow(a.r + c.r, 2), b2 = pow(b.r + c.r, 2)
            if a2 > b2 {
                let x = (d2 + b2 - a2) / (2 * d2), y = sqrt(max(0, b2 / d2 - x * x))
                c.x = b.x - x * dx - y * dy; c.y = b.y - x * dy + y * dx
            } else {
                let x = (d2 + a2 - b2) / (2 * d2), y = sqrt(max(0, a2 / d2 - x * x))
                c.x = a.x + x * dx - y * dy; c.y = a.y + x * dy + y * dx
            }
        } else { c.x = a.x + c.r; c.y = a.y }
    }

    static func intersects(_ a: Circle, _ b: Circle) -> Bool {
        let dr = a.r + b.r - 1e-6, dx = b.x - a.x, dy = b.y - a.y
        return dr > 0 && dr * dr > dx * dx + dy * dy
    }

    static func score(_ n: Node) -> Double {
        let a = n.c, b = n.next.c, ab = a.r + b.r
        let dx = (a.x * b.r + b.x * a.r) / ab, dy = (a.y * b.r + b.y * a.r) / ab
        return dx * dx + dy * dy
    }

    /// Packs circles around the origin and returns the radius of a circle enclosing them all.
    @discardableResult
    static func siblings(_ circles: [Circle]) -> Double {
        let n = circles.count
        guard n > 0 else { return 0 }
        circles[0].x = 0; circles[0].y = 0
        guard n > 1 else { return circles[0].r }
        circles[0].x = -circles[1].r; circles[1].x = circles[0].r; circles[1].y = 0
        if n > 2 {
            place(circles[1], circles[0], circles[2])
            var a = Node(circles[0]), b = Node(circles[1]), c = Node(circles[2])
            a.next = b; c.prev = b; b.next = c; a.prev = c; c.next = a; b.prev = a
            var i = 3
            pack: while i < n {
                place(a.c, b.c, circles[i])
                c = Node(circles[i])
                var j = b.next!, k = a.prev!, sj = b.c.r, sk = a.c.r
                repeat {
                    if sj <= sk {
                        if intersects(j.c, c.c) { b = j; a.next = b; b.prev = a; continue pack }
                        sj += j.c.r; j = j.next
                    } else {
                        if intersects(k.c, c.c) { a = k; a.next = b; b.prev = a; continue pack }
                        sk += k.c.r; k = k.prev
                    }
                } while j !== k.next
                c.prev = a; c.next = b; a.next = c; b.prev = c; b = c
                var aa = score(a)
                c = c.next
                while c !== b { let ca = score(c); if ca < aa { a = c; aa = ca }; c = c.next }
                b = a.next
                i += 1
            }
        }
        // Enclose: centre on the bounding box, radius reaching the farthest edge.
        let minX = circles.map { $0.x - $0.r }.min()!, maxX = circles.map { $0.x + $0.r }.max()!
        let minY = circles.map { $0.y - $0.r }.min()!, maxY = circles.map { $0.y + $0.r }.max()!
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        for c in circles { c.x -= cx; c.y -= cy }
        return circles.map { sqrt($0.x * $0.x + $0.y * $0.y) + $0.r }.max()!
    }

    struct Placed: Identifiable { var id: String; var center: CGPoint; var r: CGFloat; var depth: Int; var node: LensNode; var parentID: String? }

    /// Two levels: the folder's items, and inside each one its own biggest items.
    static func layout(_ kids: [LensNode], grandkids: [String: [LensNode]], in size: CGSize) -> [Placed] {
        guard !kids.isEmpty, size.width > 20, size.height > 20 else { return [] }
        let cs = kids.map { Circle(r: sqrt(Double(max($0.bytes, 1)))) }
        let R = siblings(cs)
        let scale = (min(size.width, size.height) / 2 - 6) / R
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        var out: [Placed] = []
        for (k, c) in zip(kids, cs) {
            let center = CGPoint(x: mid.x + c.x * scale, y: mid.y + c.y * scale)
            let r = CGFloat(c.r * scale) - 2
            out.append(Placed(id: k.id, center: center, r: max(2, r), depth: 1, node: k, parentID: nil))
            if let g = grandkids[k.id], g.count > 1, r > 44 {
                let inner = g.filter { !$0.other }.prefix(12).map { Circle(r: sqrt(Double(max($0.bytes, 1)))) }
                guard !inner.isEmpty else { continue }
                let ir = siblings(Array(inner))
                // the inner circles keep their share of the parent's area
                let share = sqrt(Double(g.filter { !$0.other }.prefix(12).reduce(0) { $0 + $1.bytes }) / Double(max(k.bytes, 1)))
                let s = (Double(r) - 5) * min(1, share * 1.15) / ir
                for (n, ic) in zip(g.filter { !$0.other }.prefix(12), inner) {
                    out.append(Placed(id: k.id + ">" + n.id, center: CGPoint(x: center.x + ic.x * s, y: center.y + ic.y * s), r: max(1.5, CGFloat(ic.r * s) - 1.5),
                                      depth: 2, node: n, parentID: k.id))
                }
            }
        }
        return out
    }
}
