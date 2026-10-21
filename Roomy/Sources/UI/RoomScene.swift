import SwiftUI
import SceneKit
import AppKit

/// Checkup's room, built from scanned furniture and props (CC0, Poly Haven) and lit by a real interior HDRI.
///
/// The story: the room starts untidy, with paper, notepads, postcards, cans, boxes and bottles standing for what a
/// scan can find, and your books strewn over the sofa, the table and the floor. As each part of the scan reports, its
/// finds light up and are tossed one by one into a single bag by the bin, which starts empty and is full when the scan
/// ends; your books fly back onto the shelf (Roomy never removes your files on its own). Clean drops the bag into the
/// bin, and a fresh, empty bag takes its place.
///
/// Cost: shared geometry and materials, 512 px textures on small props, no physics or particles, and the view
/// renders only while something moves.
@MainActor
final class RoomScene {
    static let shared = RoomScene()

    /// A kind of thing a scan finds. `removable` clutter goes in the bag; the rest is yours and stays.
    struct Bucket: Equatable {
        var key: String
        var step: String
        var color: NSColor
        var bytes: Int64
        var removable: Bool
    }

    let scene = SCNScene()
    let cameraNode = SCNNode()
    weak var view: SCNView?
    var reduceMotion = false

    /// Scene units per metre (the room was laid out before the scanned assets arrived).
    private let U: CGFloat = 1.9
    /// Clutter is drawn a little larger than life so it still reads from across the room.
    private let CL: CGFloat = 1.55

    private let clutterRoot = SCNNode()
    private let sun = SCNNode(), fill = SCNNode(), ambient = SCNNode(), lamp = SCNNode(), window = SCNNode()
    private let lampShade = SCNMaterial(), sky = SCNMaterial(), paint = SCNMaterial()
    private let binBody = SCNNode(), binLid = SCNNode()
    private var dark: Bool?
    private var paintColor: NSColor?

    private enum Place { case room, bagged, shelved }
    private final class Piece {
        let node: SCNNode
        let key: String
        let step: String
        let removable: Bool
        var slot: Int
        var place: Place = .room
        /// A book's thickness, height and depth; nil for clutter.
        var book: SCNVector3?
        var shelf: Int?
        /// A cardboard box: folded flat on its way into the bag.
        var folds = false
        init(node: SCNNode, key: String, step: String, removable: Bool, slot: Int) {
            self.node = node; self.key = key; self.step = step; self.removable = removable; self.slot = slot
        }
    }
    private var pieces: [Piece] = []
    private var processed: Set<String> = []
    /// Seconds between one find and the next going into the bag: unhurried for a few, brisker for many.
    private func toss(_ n: Int) -> TimeInterval { min(0.2, 2.6 / Double(max(1, n))) }

    // MARK: layout

    private let bin = SCNVector3(3.9, 0, -3.55)
    /// The one bag stands beside the bin.
    private let bagSpot = SCNVector3(2.75, 0, -3.0)

    /// Where clutter lies in an untidy room: all over the rug and floor, on the coffee table and sofa, under the window.
    private let slots: [(SCNVector3, CGFloat)] = [
        (SCNVector3(-2.0, 0, -1.4), 0.4), (SCNVector3(0.3, 0.75, -2.65), 1.2), (SCNVector3(-0.4, 0, -0.9), 2.1),
        (SCNVector3(-2.0, 0.82, -5.0), 0.3), (SCNVector3(-3.9, 0, -2.6), 1.9), (SCNVector3(1.6, 0, -1.2), 2.8),
        (SCNVector3(-1.1, 0.75, -3.0), 0.9), (SCNVector3(1.9, 0, -3.9), 0.2), (SCNVector3(-4.7, 0, -0.6), 2.4),
        (SCNVector3(-0.2, 0.82, -5.1), 1.4), (SCNVector3(-3.0, 0, -4.1), 0.7), (SCNVector3(0.4, 0, 0.2), 1.1),
        (SCNVector3(-1.2, 0, -0.2), 2.6), (SCNVector3(1.4, 0, -2.3), 0.5), (SCNVector3(-5.0, 0, -3.8), 1.6),
        (SCNVector3(0.9, 0, -4.4), 2.2), (SCNVector3(2.4, 0, -0.9), 1.0), (SCNVector3(-1.15, 0.82, -4.85), 2.0),
        (SCNVector3(-2.7, 0, -0.2), 0.6), (SCNVector3(0.9, 0, -0.6), 1.7), (SCNVector3(-3.5, 0, -3.3), 2.9),
        (SCNVector3(-0.15, 0.75, -3.1), 0.4), (SCNVector3(-4.5, 0, -1.6), 1.3), (SCNVector3(2.2, 0, 0.6), 2.3),
        (SCNVector3(0.0, 0.02, -1.8), 0.8), (SCNVector3(1.7, 0, 0.0), 2.5), (SCNVector3(-3.9, 0, 0.4), 1.2),
        (SCNVector3(-1.0, 0.75, -2.4), 2.7), (SCNVector3(3.3, 0, -1.6), 0.3), (SCNVector3(-5.3, 0, -1.0), 1.8),
    ]
    /// Your things: books dropped on the coffee table, the sofa and the floor.
    private let ownSlots: [(SCNVector3, CGFloat)] = [
        (SCNVector3(-0.65, 0.75, -2.45), 0.25), (SCNVector3(-2.45, 0.82, -4.95), 1.1), (SCNVector3(0.35, 0.82, -4.8), 2.4),
        (SCNVector3(-1.9, 0.02, -2.0), 0.7), (SCNVector3(1.15, 0, -3.3), 1.9), (SCNVector3(-5.0, 0, -2.2), 0.4),
        (SCNVector3(3.1, 0, -4.75), 2.8), (SCNVector3(-0.9, 0, -0.55), 1.5),
    ]
    /// Gaps on the bookcase where the strewn books belong: the left edge of a slot and its board, filled in order.
    private var shelfSpots: [SCNVector3] = []

    private init() {
        scene.background.contents = NSColor(white: 0.1, alpha: 1)
        buildRoom()
        buildBin()
        buildLights()
        buildCamera()
        scene.rootNode.addChildNode(clutterRoot)
        buildBag()
    }

    // MARK: assets

    /// The bundled room assets. `ROOMY_ROOM_ASSETS` points elsewhere for offscreen previews.
    static let assets: URL = {
        if let p = ProcessInfo.processInfo.environment["ROOMY_ROOM_ASSETS"] { return URL(fileURLWithPath: p) }
        return Bundle.main.resourceURL!.appendingPathComponent("Room")
    }()

    private var models: [String: SCNNode] = [:]

    /// A scanned model at real size (metres), Y up, with its texture paths resolved. Loaded once; callers get clones
    /// that share geometry and materials.
    private func model(_ name: String) -> SCNNode {
        if let m = models[name] { return m.clone() }
        let dir = Self.assets.appendingPathComponent("models/\(name)")
        let root = SCNNode()
        if let s = try? SCNScene(url: dir.appendingPathComponent("\(name)_1k.usdc"), options: [.convertToYUp: true, .convertUnitsToMeters: 1.0]) {
            for c in s.rootNode.childNodes { root.addChildNode(c) }
        }
        // Poly Haven models use one texture set each, named by convention. USD import doesn't wire most maps up,
        // so bind them directly.
        let tex = dir.appendingPathComponent("textures")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tex.path)) ?? []
        func map(_ keys: [String]) -> URL? {
            files.first { f in keys.contains { f.hasPrefix("\(name)_\($0)_") } }.map { tex.appendingPathComponent($0) }
        }
        let diff = map(["diff"]), nor = map(["nor_gl"]), rough = map(["rough", "roughness"]), metal = map(["metal", "metallic"])
        root.enumerateHierarchy { n, _ in
            n.castsShadow = true
            for m in n.geometry?.materials ?? [] {
                m.lightingModel = .physicallyBased
                m.diffuse.contents = diff ?? m.diffuse.contents
                m.normal.contents = nor
                m.roughness.contents = rough ?? NSNumber(value: 0.7)
                m.metalness.contents = metal ?? NSNumber(value: 0)
                for p in [m.diffuse, m.normal, m.roughness, m.metalness] { p.mipFilter = .linear }
            }
        }
        models[name] = root
        return root.clone()
    }

    /// The separate pieces inside a set (each postcard, each notepad), each re-centred to sit on the floor.
    private var partCache: [String: [SCNNode]] = [:]
    private func parts(_ name: String, layFlat: Bool = false) -> [SCNNode] {
        if let p = partCache[name] { return p }
        var out: [SCNNode] = []
        model(name).enumerateHierarchy { n, _ in
            guard n.geometry != nil else { return }
            let inner = SCNNode(geometry: n.geometry)
            inner.transform = n.worldTransform
            inner.castsShadow = true
            let tilt = SCNNode()
            tilt.addChildNode(inner)
            if layFlat { tilt.eulerAngles.x = -.pi / 2 }
            let wrap = SCNNode()
            wrap.addChildNode(tilt)
            let (mn, mx) = wrap.boundingBox
            tilt.position = SCNVector3(-(mn.x + mx.x) / 2, -mn.y, -(mn.z + mx.z) / 2)
            out.append(wrap)
        }
        partCache[name] = out
        return out
    }

    private func texture(_ name: String, _ map: String) -> URL { Self.assets.appendingPathComponent("textures/\(name)/\(name)_\(map)_1k.jpg") }

    /// A tiling PBR material from one of the bundled texture sets.
    private func surface(_ name: String, repeat r: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = texture(name, "diff")
        m.normal.contents = texture(name, "nor_gl")
        m.roughness.contents = texture(name, "rough")
        m.metalness.contents = NSNumber(value: 0)
        for p in [m.diffuse, m.normal, m.roughness] {
            p.wrapS = .repeat; p.wrapT = .repeat
            p.contentsTransform = SCNMatrix4MakeScale(r, r, 1)
            p.mipFilter = .linear
        }
        return m
    }

    // MARK: materials

    private func pbr(_ color: NSColor, roughness: Double = 0.85, metal: Double = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = NSNumber(value: roughness)
        m.metalness.contents = NSNumber(value: metal)
        return m
    }
    private static func rgb(_ h: UInt32) -> NSColor { NSColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }

    private lazy var paper: SCNMaterial = {
        let m = pbr(Self.rgb(0xEFEBE3), roughness: 0.95)
        m.normal.contents = Self.crumple
        return m
    }()

    /// A soft round contact shadow, so things sit on the floor even where the sun doesn't reach.
    private lazy var blob: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
            NSGradient(colors: [NSColor(white: 0, alpha: 0.45), NSColor(white: 0, alpha: 0)])?.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
            return true
        }
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        return m
    }()
    private func shadow(_ size: CGFloat) -> SCNNode {
        let p = SCNPlane(width: size, height: size)
        p.materials = [blob]
        let n = SCNNode(geometry: p)
        n.eulerAngles.x = -.pi / 2
        n.position.y = 0.006
        n.castsShadow = false
        n.name = "shadow"
        return n
    }

    // MARK: the room

    private func add(_ geo: SCNGeometry, _ m: SCNMaterial, _ p: SCNVector3, to parent: SCNNode, rotY: CGFloat = 0) {
        geo.materials = [m]
        let n = SCNNode(geometry: geo)
        n.position = p
        n.eulerAngles.y = rotY
        parent.addChildNode(n)
    }

    private func place(_ name: String, at p: SCNVector3, rotY: CGFloat = 0, scale: CGFloat = 1) -> SCNNode {
        let n = model(name)
        n.position = p
        n.eulerAngles.y = rotY
        n.scale = SCNVector3(U * scale, U * scale, U * scale)
        scene.rootNode.addChildNode(n)
        return n
    }

    private func buildRoom() {
        let room = SCNNode()

        // Oak floor, plaster walls (tinted with the room colour), wool rug: real scanned surfaces.
        // The floor stops at the walls, so the window looks out on the garden, not on more floor.
        let floor = SCNPlane(width: 40, height: 60)
        floor.materials = [surface("wood_floor", repeat: 16)]
        floor.materials[0].diffuse.contentsTransform = SCNMatrix4MakeScale(16 * 40 / 60, 16, 1)
        floor.materials[0].normal.contentsTransform = SCNMatrix4MakeScale(16 * 40 / 60, 16, 1)
        floor.materials[0].roughness.contentsTransform = SCNMatrix4MakeScale(16 * 40 / 60, 16, 1)
        let floorNode = SCNNode(geometry: floor)
        floorNode.eulerAngles.x = -.pi / 2
        floorNode.position = SCNVector3(13.9, 0, 4)
        room.addChildNode(floorNode)

        let plaster = surface("white_plaster_02", repeat: 1)
        paint.lightingModel = .physicallyBased
        paint.diffuse.contents = NSColor.white
        paint.normal.contents = plaster.normal.contents
        paint.roughness.contents = plaster.roughness.contents
        paint.normal.intensity = 0.45
        for p in [paint.normal, paint.roughness] { p.wrapS = .repeat; p.wrapT = .repeat; p.mipFilter = .linear }
        let wallScale = { (w: CGFloat, h: CGFloat) -> SCNMatrix4 in SCNMatrix4MakeScale(w / 3.8, h / 3.8, 1) }
        func wall(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ p: SCNVector3) {
            let m = paint.copy() as! SCNMaterial
            let along = max(w, l)
            for prop in [m.normal, m.roughness] { prop.contentsTransform = wallScale(along, h) }
            walls.append(m)
            add(SCNBox(width: w, height: h, length: l, chamferRadius: 0), m, p, to: room)
        }
        // The back wall, and the left wall with a window (opening z -3.6...0.6, y 1.1...6.3).
        wall(40, 14, 0.3, SCNVector3(4, 7, -6.15))
        let wx: CGFloat = -6.15, t: CGFloat = 0.3
        wall(t, 1.1, 30, SCNVector3(wx, 0.55, 9))
        wall(t, 7.7, 30, SCNVector3(wx, 10.15, 9))
        wall(t, 5.2, 2.4, SCNVector3(wx, 3.7, -4.8))
        wall(t, 5.2, 23.4, SCNVector3(wx, 3.7, 12.3))
        let white = pbr(Self.rgb(0xF2F0EB), roughness: 0.5)
        add(SCNBox(width: 0.12, height: 5.2, length: 0.08, chamferRadius: 0), white, SCNVector3(wx, 3.7, -1.5), to: room)
        add(SCNBox(width: 0.12, height: 0.08, length: 4.2, chamferRadius: 0), white, SCNVector3(wx, 3.9, -1.5), to: room)
        add(SCNBox(width: 0.5, height: 0.08, length: 4.4, chamferRadius: 0.02), white, SCNVector3(wx + 0.2, 1.08, -1.5), to: room)
        add(SCNBox(width: 40, height: 0.28, length: 0.06, chamferRadius: 0.01), white, SCNVector3(4, 0.14, -5.99), to: room)
        add(SCNBox(width: 0.06, height: 0.28, length: 30, chamferRadius: 0.01), white, SCNVector3(-5.99, 0.14, 9), to: room)

        add(SCNBox(width: 5.8, height: 0.04, length: 3.9, chamferRadius: 0.015), surface("poly_wool_herringbone", repeat: 3), SCNVector3(-0.7, 0.02, -2.85), to: room)

        // A print hung low over the sofa, below the band of wall Checkup's headline sits on.
        let dark = pbr(Self.rgb(0x26262A), roughness: 0.5)
        add(SCNBox(width: 2.0, height: 1.3, length: 0.06, chamferRadius: 0.01), dark, SCNVector3(-1.2, 2.16, -5.96), to: room)
        let art = SCNMaterial()
        art.lightingModel = .physicallyBased
        art.diffuse.contents = Self.print
        art.roughness.contents = NSNumber(value: 0.9)
        add(SCNPlane(width: 1.84, height: 1.14), art, SCNVector3(-1.2, 2.16, -5.925), to: room)

        // Linen curtains either side of the window, on a rail.
        let linen = pbr(Self.rgb(0xE6DFD3), roughness: 1)
        linen.normal.contents = Self.folds
        linen.normal.wrapS = .repeat
        for z: CGFloat in [-4.25, 1.25] { add(SCNBox(width: 0.12, height: 6.4, length: 1.1, chamferRadius: 0.04), linen, SCNVector3(-5.86, 3.35, z), to: room) }
        let rail = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 6.6))
        rail.geometry?.materials = [dark]
        rail.position = SCNVector3(-5.82, 6.62, -1.5)
        rail.eulerAngles.x = .pi / 2
        room.addChildNode(rail)

        // Plant in the corner by the window.
        let plant = SCNNode()
        add(SCNCylinder(radius: 0.36, height: 0.7), pbr(Self.rgb(0xA8664A), roughness: 0.9), SCNVector3(-5.2, 0.35, -5.2), to: plant)
        let leafMats = [0x4A7449, 0x587F4E, 0x3E6440].map { pbr(Self.rgb(UInt32($0)), roughness: 0.6) }
        for i in 0..<11 {
            let leaf = SCNSphere(radius: 0.5)
            leaf.segmentCount = 16
            leaf.materials = [leafMats[i % 3]]
            let l = SCNNode(geometry: leaf)
            l.scale = SCNVector3(0.28, 1.25, 0.05)
            l.position = SCNVector3(0, 0.55, 0)
            let stem = SCNNode()
            stem.position = SCNVector3(-5.2, 0.7, -5.2)
            stem.eulerAngles = SCNVector3(0.35 + CGFloat(i % 3) * 0.12, CGFloat(i) * 0.58, 0)
            stem.addChildNode(l)
            plant.addChildNode(stem)
        }
        plant.enumerateHierarchy { n, _ in n.castsShadow = true }

        // Floor lamp beside the sofa; it glows in the evening.
        let lx: CGFloat = 1.45, lz: CGFloat = -5.35
        add(SCNCylinder(radius: 0.3, height: 0.04), dark, SCNVector3(lx, 0.02, lz), to: room)
        add(SCNCylinder(radius: 0.022, height: 3.1), dark, SCNVector3(lx, 1.55, lz), to: room)

        // Soft darkening where floor meets wall and under furniture: light rarely reaches there.
        let corner = SCNMaterial()
        corner.lightingModel = .constant
        corner.diffuse.contents = Self.cornerShade
        corner.writesToDepthBuffer = false
        corner.blendMode = .alpha
        func shade(_ w: CGFloat, _ h: CGFloat, _ p: SCNVector3, _ e: SCNVector3) {
            let pl = SCNPlane(width: w, height: h)
            pl.materials = [corner]
            let n = SCNNode(geometry: pl); n.position = p; n.eulerAngles = e; n.castsShadow = false
            room.addChildNode(n)
        }
        shade(40, 0.9, SCNVector3(4, 0.005, -5.5), SCNVector3(-CGFloat.pi / 2, 0, 0))
        shade(30, 0.9, SCNVector3(-5.5, 0.005, 9), SCNVector3(-CGFloat.pi / 2, CGFloat.pi / 2, 0))
        shade(40, 0.7, SCNVector3(4, 0.63, -5.96), SCNVector3(CGFloat.pi, 0, CGFloat.pi))
        shade(30, 0.7, SCNVector3(-5.96, 0.63, 9), SCNVector3(CGFloat.pi, -CGFloat.pi / 2, CGFloat.pi))
        func under(_ w: CGFloat, _ l: CGFloat, _ x: CGFloat, _ z: CGFloat) {
            let pl = SCNPlane(width: w, height: l)
            pl.materials = [blob]
            let n = SCNNode(geometry: pl); n.position = SCNVector3(x, 0.045, z); n.eulerAngles.x = -.pi / 2; n.castsShadow = false
            room.addChildNode(n)
        }
        under(4.4, 2.2, -1.2, -5.15)
        under(3.0, 1.8, -0.4, -2.8)
        under(3.0, 1.4, 4.5, -5.55)
        under(1.3, 1.3, -5.2, -5.2)
        under(1.1, 1.1, -3.75, -5.35)

        // One flattened node for everything static: far fewer draw calls.
        let flat = room.flattenedClone()
        flat.castsShadow = true
        scene.rootNode.addChildNode(flat)
        scene.rootNode.addChildNode(plant)

        // Scanned furniture.
        _ = place("sofa_02", at: SCNVector3(-1.2, 0, -5.2))
        _ = place("throw_pillows_01", at: SCNVector3(-1.25, 0.72, -5.35), scale: 0.95)
        _ = place("modern_coffee_table_01", at: SCNVector3(-0.4, 0.04, -2.8))
        _ = place("side_table_tall_01", at: SCNVector3(-3.75, 0, -5.35))
        _ = place("ceramic_vase_01", at: SCNVector3(-3.75, 0.76 * U, -5.35), scale: 0.9)
        let shelf = place("wooden_bookshelf_worn", at: SCNVector3(4.45, 0, -5.55))
        stockShelf(shelf)

        lampShade.lightingModel = .physicallyBased
        lampShade.diffuse.contents = Self.rgb(0xF4EEE2)
        lampShade.roughness.contents = NSNumber(value: 1)
        lampShade.isDoubleSided = true
        let shade3 = SCNCone(topRadius: 0.3, bottomRadius: 0.46, height: 0.5)
        shade3.materials = [lampShade]
        let shadeNode = SCNNode(geometry: shade3)
        shadeNode.position = SCNVector3(lx, 3.25, lz)
        scene.rootNode.addChildNode(shadeNode)
        lamp.position = SCNVector3(lx, 2.75, lz + 0.5)
        scene.rootNode.addChildNode(lamp)

        // Sky outside the window.
        sky.lightingModel = .constant
        sky.isDoubleSided = true
        sky.emission.contents = Self.garden
        sky.diffuse.contents = Self.garden
        let skyPlane = SCNPlane(width: 60, height: 30)
        skyPlane.materials = [sky]
        let skyNode = SCNNode(geometry: skyPlane)
        skyNode.position = SCNVector3(-16, 6, 0)
        skyNode.eulerAngles.y = .pi / 2
        skyNode.castsShadow = false
        scene.rootNode.addChildNode(skyNode)

    }
    private var walls: [SCNMaterial] = []

    /// Books on the scanned bookcase's shelves.
    private func stockShelf(_ shelf: SCNNode) {
        let (mn, mx) = shelf.boundingBox
        let w = (mx.x - mn.x) * U * 0.86, h = (mx.y - mn.y) * U
        let tones: [UInt32] = [0x3E4C63, 0x8E4F36, 0xB8934F, 0x56705A, 0x7D8289, 0x5F4553, 0xCFC5B4]
        let mats = tones.map { pbr(Self.rgb($0), roughness: 0.85) }
        let books = SCNNode()
        var gaps3: [(Int, SCNVector3)] = []
        // Top surfaces of the scanned case's boards, in metres (read once from its mesh), and the gap above each.
        let boardTops: [CGFloat] = [0.11, 0.39, 0.67, 0.96, 1.28, 1.66]
        let gaps: [CGFloat] = [0.24, 0.24, 0.25, 0.27, 0.34, 0.36]
        let boards = boardTops.map { $0 * U }
        for (row, boardY) in boards.enumerated() {
            var x = shelf.position.x - w / 2 + 0.22
            var k = row * 5
            while x < shelf.position.x + w / 2 - 0.4 {
                let room = gaps[row] * U - 0.05
                let bw = 0.065 + CGFloat((k * 13) % 7) * 0.011, bh = room * (0.72 + CGFloat((k * 29) % 9) * 0.03)
                add(SCNBox(width: bw, height: bh, length: 0.42, chamferRadius: 0.006), mats[k % mats.count],
                    SCNVector3(x + bw / 2, boardY + bh / 2 + 0.005, shelf.position.z + 0.02), to: books)
                x += bw + 0.01
                k += 1
                if k % 8 == 5 {
                    // a gap: room for three books that are lying around the room right now
                    if (1...4).contains(row) { for j in 0..<3 { gaps3.append((row, SCNVector3(x + 0.03 + CGFloat(j) * 0.135, boardY, shelf.position.z))) } }
                    x += 0.45
                }
                if row == 2 && x > shelf.position.x { break }   // leave room for a vase
            }
        }
        let flat = books.flattenedClone()
        flat.castsShadow = true
        scene.rootNode.addChildNode(flat)
        // Middle shelves first: they're the ones in view.
        shelfSpots = gaps3.sorted { abs(Double($0.0) - 2.5) < abs(Double($1.0) - 2.5) }.map(\.1)
    }

    /// A brushed-steel pedal bin with a lid that opens from the back.
    private let binScale: CGFloat = 1.4
    private func buildBin() {
        let steel = pbr(Self.rgb(0xB9BDC3), roughness: 0.3, metal: 1)
        let trim = pbr(Self.rgb(0x2A2B2E), roughness: 0.5)
        let r: CGFloat = 0.36, h: CGFloat = 0.95
        let walls = SCNTube(innerRadius: r - 0.025, outerRadius: r, height: h)
        walls.radialSegmentCount = 48
        walls.materials = [steel]
        let w = SCNNode(geometry: walls); w.position.y = h / 2; binBody.addChildNode(w)
        let base = SCNCylinder(radius: r - 0.02, height: 0.04); base.materials = [pbr(Self.rgb(0x1E1F22), roughness: 0.8)]
        let b = SCNNode(geometry: base); b.position.y = 0.05; binBody.addChildNode(b)
        let rim = SCNTorus(ringRadius: r - 0.01, pipeRadius: 0.018); rim.materials = [trim]
        let rimNode = SCNNode(geometry: rim); rimNode.position.y = h; binBody.addChildNode(rimNode)
        let pedal = SCNBox(width: 0.22, height: 0.03, length: 0.14, chamferRadius: 0.01); pedal.materials = [trim]
        let pedalNode = SCNNode(geometry: pedal); pedalNode.position = SCNVector3(0, 0.05, r + 0.05); binBody.addChildNode(pedalNode)
        let lid = SCNCylinder(radius: r + 0.012, height: 0.05); lid.radialSegmentCount = 48; lid.materials = [steel]
        let lidNode = SCNNode(geometry: lid); lidNode.position = SCNVector3(0, 0.025, r)    // hinge at the back edge
        binLid.addChildNode(lidNode)
        binLid.position = SCNVector3(0, h + 0.01, -r)
        binBody.addChildNode(binLid)
        binBody.addChildNode(shadow(1.2))
        binBody.position = bin
        binBody.scale = SCNVector3(binScale, binScale, binScale)
        binBody.eulerAngles.y = -0.5
        binBody.childNodes.forEach { $0.castsShadow = $0.name != "shadow" }
        scene.rootNode.addChildNode(binBody)
    }

    private func buildLights() {
        let s = SCNLight()
        s.type = .spot
        s.castsShadow = true
        s.shadowMode = .forward
        s.shadowSampleCount = 16
        s.shadowRadius = 9
        s.shadowMapSize = CGSize(width: 2048, height: 2048)
        s.shadowColor = NSColor(white: 0, alpha: 0.82)
        s.shadowBias = 0.08
        s.spotInnerAngle = 26
        s.spotOuterAngle = 48
        s.zNear = 1
        s.zFar = 60
        sun.light = s
        sun.position = SCNVector3(-17, 12, -4.0)
        sun.look(at: SCNVector3(0.5, 0, 0.6))
        scene.rootNode.addChildNode(sun)

        // The window itself as a soft area light.
        let w = SCNLight()
        w.type = .area
        w.areaType = .rectangle
        w.areaExtents = simd_float3(4.2, 5.2, 1)
        w.drawsArea = false
        window.light = w
        window.position = SCNVector3(-5.9, 3.7, -1.5)
        window.eulerAngles.y = -.pi / 2
        scene.rootNode.addChildNode(window)

        let a = SCNLight(); a.type = .ambient; ambient.light = a
        scene.rootNode.addChildNode(ambient)
        let f = SCNLight(); f.type = .omni; fill.light = f
        fill.position = SCNVector3(3, 7, 5)
        scene.rootNode.addChildNode(fill)

        let l = SCNLight()
        l.type = .omni
        l.color = NSColor(red: 1, green: 0.76, blue: 0.5, alpha: 1)
        l.attenuationStartDistance = 0.5
        l.attenuationEndDistance = 9
        lamp.light = l
    }

    private func buildCamera() {
        let c = SCNCamera()
        c.fieldOfView = 36
        c.zNear = 0.1
        c.zFar = 120
        c.wantsHDR = true
        c.wantsExposureAdaptation = false
        c.whitePoint = 2.4
        c.contrast = 0.1
        c.saturation = 0.95
        c.screenSpaceAmbientOcclusionIntensity = 1.2
        c.screenSpaceAmbientOcclusionRadius = 0.3
        c.screenSpaceAmbientOcclusionBias = 0.03
        c.screenSpaceAmbientOcclusionDepthThreshold = 0.2
        c.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        c.bloomIntensity = 0.16
        c.bloomThreshold = 1.0
        c.bloomBlurRadius = 16
        c.vignettingIntensity = 0.35
        c.vignettingPower = 0.9
        // A photographic finish: shallow focus on the room's middle, and a little film grain.
        c.wantsDepthOfField = true
        c.focusDistance = 11.5
        c.fStop = 4.0
        c.apertureBladeCount = 7
        c.focalBlurSampleCount = 12
        c.grainIntensity = 0.035
        c.grainScale = 1
        c.grainIsColored = false
        cameraNode.camera = c
        cameraNode.position = SCNVector3(7.9, 4.7, 6.8)
        let target = SCNNode()
        target.position = SCNVector3(0.5, 0.9, -3.2)
        scene.rootNode.addChildNode(target)
        let look = SCNLookAtConstraint(target: target)
        look.isGimbalLockEnabled = true
        cameraNode.constraints = [look]
        scene.rootNode.addChildNode(cameraNode)
    }

    // MARK: generated textures (small, made once)

    private struct Pixels {
        let w: Int, h: Int
        var px: [UInt8]
        init(_ w: Int, _ h: Int) { self.w = w; self.h = h; px = [UInt8](repeating: 255, count: w * h * 4) }
        mutating func set(_ x: Int, _ y: Int, _ r: Double, _ g: Double, _ b: Double) {
            let i = (y * w + x) * 4
            px[i] = UInt8(max(0, min(255, r * 255))); px[i + 1] = UInt8(max(0, min(255, g * 255))); px[i + 2] = UInt8(max(0, min(255, b * 255)))
        }
        var image: NSImage {
            let data = CFDataCreate(nil, px, px.count)!
            let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: data)!,
                             decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        }
    }
    private static func normals(_ h: [Double], _ n: Int, strength: Double) -> NSImage {
        var p = Pixels(n, n)
        for y in 0..<n { for x in 0..<n {
            let l = h[y * n + (x + n - 1) % n], r = h[y * n + (x + 1) % n], u = h[((y + n - 1) % n) * n + x], d = h[((y + 1) % n) * n + x]
            var nx = (l - r) * strength, ny = (u - d) * strength, nz = 1.0
            let len = (nx * nx + ny * ny + nz * nz).squareRoot(); nx /= len; ny /= len; nz /= len
            p.set(x, y, nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5)
        } }
        return p.image
    }
    /// Soft vertical folds for the curtains.
    private static let folds: NSImage = {
        let n = 128
        var h = [Double](repeating: 0, count: n * n)
        for y in 0..<n { for x in 0..<n { h[y * n + x] = sin(Double(x) / Double(n) * .pi * 2 * 5) * 0.5 + 0.5 } }
        return normals(h, n, strength: 6)
    }()
    /// Creases for crumpled paper.
    private static let crumple: NSImage = {
        let n = 128
        var h = [Double](repeating: 0, count: n * n)
        var s: UInt64 = 3
        var lines: [(Double, Double, Double)] = []
        for _ in 0..<14 { s = s &* 6364136223846793005 &+ 1; let a = Double(s >> 40) / 16777216 * .pi; s = s &* 6364136223846793005 &+ 1; lines.append((cos(a), sin(a), Double(s >> 40) / 16777216 * Double(n))) }
        for y in 0..<n { for x in 0..<n {
            var v = 0.0
            for (cx, cy, d) in lines { v += max(0, 1 - abs(Double(x) * cx + Double(y) * cy - d) / 3) }
            h[y * n + x] = v
        } }
        return normals(h, n, strength: 3)
    }()
    /// What the window looks out on: sky fading to a pale horizon over a soft band of distant trees and lawn. It's
    /// multiplied over the sky colour, so evening tints it too; depth of field keeps it soft.
    private static let garden: NSImage = NSImage(size: NSSize(width: 256, height: 128), flipped: false) { r in
        NSGradient(colors: [rgb(0xC9D9EC), rgb(0xF4F6F8)], atLocations: [1, 0.42], colorSpace: .deviceRGB)?.draw(in: r, angle: -90)
        let trees = NSBezierPath()
        trees.move(to: NSPoint(x: 0, y: 0)); trees.line(to: NSPoint(x: 0, y: 48))
        var x: CGFloat = 0
        var s: UInt64 = 7
        while x < 256 {
            s = s &* 6364136223846793005 &+ 1
            let w = 10 + CGFloat(s >> 59) * 2, h = 46 + CGFloat((s >> 40) & 15)
            trees.curve(to: NSPoint(x: x + w, y: 48), controlPoint1: NSPoint(x: x + w * 0.1, y: h + 6), controlPoint2: NSPoint(x: x + w * 0.9, y: h + 6))
            x += w
        }
        trees.line(to: NSPoint(x: 256, y: 0)); trees.close()
        rgb(0x8E9E86).setFill(); trees.fill()
        rgb(0xA9B79A).setFill(); NSRect(x: 0, y: 0, width: 256, height: 22).fill()
        return true
    }

    private static let cornerShade: NSImage = NSImage(size: NSSize(width: 4, height: 64), flipped: false) { r in
        NSGradient(colors: [NSColor(white: 0, alpha: 0.38), NSColor(white: 0, alpha: 0.12), NSColor(white: 0, alpha: 0)], atLocations: [0, 0.35, 1], colorSpace: .deviceRGB)?.draw(in: r, angle: 90)
        return true
    }
    private static let print: NSImage = NSImage(size: NSSize(width: 420, height: 260), flipped: false) { r in
        rgb(0xEFE7DA).setFill(); r.fill()
        rgb(0xD99A5B).setFill(); NSBezierPath(ovalIn: NSRect(x: 230, y: 120, width: 90, height: 90)).fill()
        let back = NSBezierPath(); back.move(to: .zero); back.curve(to: NSPoint(x: 420, y: 70), controlPoint1: NSPoint(x: 140, y: 190), controlPoint2: NSPoint(x: 260, y: 40))
        back.line(to: NSPoint(x: 420, y: 0)); back.close(); rgb(0x9DB0A0).setFill(); back.fill()
        let front = NSBezierPath(); front.move(to: NSPoint(x: 0, y: 40)); front.curve(to: NSPoint(x: 420, y: 20), controlPoint1: NSPoint(x: 180, y: 0), controlPoint2: NSPoint(x: 300, y: 120))
        front.line(to: NSPoint(x: 420, y: 0)); front.line(to: .zero); front.close(); rgb(0x5E7466).setFill(); front.fill()
        return true
    }

    // MARK: clutter

    private enum Kind { case paperBall, notepad, postcard, can, food, box, bottle, books }

    /// What each kind of finding looks like in the room.
    private static func kinds(for key: String) -> [Kind] {
        switch key {
        case "systemJunk": [.paperBall, .notepad, .paperBall, .notepad]
        case "userCache": [.can, .food, .paperBall]
        case "developer": [.box, .food, .can]
        case "mail": [.postcard, .postcard, .notepad]
        case "systemData": [.box, .paperBall]
        case "aiCare": [.bottle, .paperBall, .can]
        default: [.books]
        }
    }

    private var variant = 0
    private func make(_ kind: Kind) -> SCNNode {
        variant += 1
        let n = SCNNode()
        let s = U * CL
        var footprint: CGFloat = 0.5
        func addScaled(_ m: SCNNode) { m.scale = SCNVector3(s, s, s); n.addChildNode(m) }
        switch kind {
        case .paperBall:
            let g = SCNSphere(radius: 0.065)
            g.isGeodesic = true
            g.segmentCount = 3
            g.materials = [paper]
            let b = SCNNode(geometry: g)
            b.position.y = 0.055 * s
            b.scale = SCNVector3(s, s * 0.85, s * 1.08)
            b.castsShadow = true
            n.addChildNode(b)
            footprint = 0.42
        case .notepad:
            let p = parts("office_notepads")
            if !p.isEmpty { addScaled(p[variant % p.count].clone()) }
            footprint = 0.8
        case .postcard:
            let p = parts("postcard_set_01", layFlat: true)
            if !p.isEmpty { addScaled(p[variant % p.count].clone()) }
            footprint = 0.6
        case .can:
            addScaled(model("can_rusted"))
            footprint = 0.42
        case .food:
            let p = parts("long_life_food")
            if !p.isEmpty { addScaled(p[variant % p.count].clone()) }
            footprint = 0.5
        case .box:
            addScaled(model("cardboard_box_01"))
            footprint = 1.25
        case .bottle:
            addScaled(model("plastic_bottle_gallon"))
            footprint = 0.55
        case .books:
            return makeBook(variant).0
        }
        n.addChildNode(shadow(footprint))
        return n
    }

    // MARK: books

    /// Books lying around are drawn this much larger than on the shelf.
    private let bookDrop: CGFloat = 1.4
    private lazy var pages: SCNMaterial = pbr(Self.rgb(0xE9E1CD), roughness: 0.95)
    private lazy var covers: [SCNMaterial] = [0x7A2E2A, 0x2F4A6B, 0x3F5D45, 0xB08A3E, 0x5B3A5E, 0x2B2B30, 0xC4B49A, 0x8C5A3C]
        .map { pbr(Self.rgb(UInt32($0)), roughness: 0.72) }

    /// One hardback, standing as it would on a shelf: cloth on the sides and spine, page edges top, bottom and back.
    /// Returns the book and its thickness, height and depth.
    private func makeBook(_ i: Int) -> (SCNNode, SCNVector3) {
        let t: CGFloat = 0.075 + CGFloat((i * 7) % 5) * 0.011
        let h: CGFloat = 0.33 + CGFloat((i * 11) % 5) * 0.014
        let d: CGFloat = 0.27 + CGFloat((i * 5) % 4) * 0.02
        let g = SCNBox(width: t, height: h, length: d, chamferRadius: 0.005)
        let c = covers[i % covers.count]
        g.materials = [c, c, pages, c, pages, pages]   // front (spine), right, back, left, top, bottom
        let b = SCNNode(geometry: g)
        b.castsShadow = true
        let n = SCNNode()
        n.addChildNode(b)
        return (n, SCNVector3(t, h, d))
    }

    /// Where a shelved book stands: upright in its gap, spine flush with the books beside it.
    private func shelfPosition(_ p: Piece) -> SCNVector3? {
        guard let i = p.shelf, i < shelfSpots.count, let b = p.book else { return nil }
        let s = shelfSpots[i]
        return SCNVector3(s.x + b.x / 2, s.y + b.y / 2 + 0.005, s.z + 0.02 + 0.21 - b.z / 2)
    }

    private func claimShelf(_ p: Piece) {
        guard p.shelf == nil else { return }
        let used = Set(pieces.compactMap(\.shelf))
        p.shelf = (0..<shelfSpots.count).first { !used.contains($0) }
    }

    // MARK: appearance

    /// Day in light mode, evening with the lamp on in dark mode. `paint` is the wall colour from Settings.
    func apply(dark: Bool, paint color: NSColor) {
        if self.dark == dark && paintColor == color { return }
        let first = self.dark == nil
        self.dark = dark
        paintColor = color
        SCNTransaction.begin()
        SCNTransaction.animationDuration = first ? 0 : 0.6
        paint.diffuse.contents = color
        for m in walls { m.diffuse.contents = color }
        scene.lightingEnvironment.contents = Self.assets.appendingPathComponent("hdri/brown_photostudio_04_1k.hdr")
        scene.lightingEnvironment.intensity = dark ? 0.06 : 0.75
        let skyColor = dark ? NSColor(red: 0.10, green: 0.14, blue: 0.26, alpha: 1) : NSColor(red: 0.93, green: 0.96, blue: 1.0, alpha: 1)
        // The garden outside: daylight, or the same view at dusk, tinted by the evening sky.
        sky.multiply.contents = dark ? skyColor : NSColor.white
        sky.emission.intensity = dark ? 0.5 : 0.95
        sun.light?.color = dark ? NSColor(red: 0.62, green: 0.72, blue: 1.0, alpha: 1) : NSColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1)
        sun.light?.intensity = dark ? 600 : 3600
        window.light?.intensity = dark ? 60 : 700
        window.light?.color = dark ? NSColor(red: 0.55, green: 0.65, blue: 1, alpha: 1) : NSColor(red: 0.92, green: 0.96, blue: 1, alpha: 1)
        fill.light?.color = dark ? NSColor(red: 0.55, green: 0.6, blue: 0.8, alpha: 1) : NSColor(red: 1, green: 0.97, blue: 0.93, alpha: 1)
        fill.light?.intensity = dark ? 40 : 160
        lamp.light?.intensity = dark ? 34 : 0
        lampShade.emission.contents = dark ? NSColor(red: 1, green: 0.78, blue: 0.52, alpha: 1) : NSColor.black
        ambient.light?.intensity = dark ? 14 : 40
        ambient.light?.color = dark ? NSColor(red: 0.6, green: 0.65, blue: 0.85, alpha: 1) : NSColor(red: 1, green: 0.98, blue: 0.96, alpha: 1)
        cameraNode.camera?.exposureOffset = dark ? 0.4 : 0.5
        SCNTransaction.commit()
        wake(first ? 0.3 : 0.8)
    }

    // MARK: rendering on demand

    private var sleepWork: DispatchWorkItem?
    /// Renders frames for the next `seconds`, then lets the view rest. Nothing draws while the room is still.
    func wake(_ seconds: TimeInterval) {
        guard let view else { return }
        view.isPlaying = true
        sleepWork?.cancel()
        let w = DispatchWorkItem { [weak view] in view?.isPlaying = false }
        sleepWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.15, execute: w)
    }

    // MARK: the story

    /// How many pieces each bucket gets: more for more space, but never so many the room turns into noise.
    static func counts(_ buckets: [Bucket]) -> [String: Int] {
        var out: [String: Int] = [:]
        for removable in [true, false] {
            let group = buckets.filter { $0.removable == removable && $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
            let total = group.reduce(0) { $0 + $1.bytes }
            guard total > 0 else { continue }
            let gb = Double(total) / 1e9
            let n = removable ? min(26, max(group.count, Int((7 + log2(gb + 1) * 4.5).rounded()))) : min(8, max(3, Int((log2(gb + 1) * 1.6).rounded())))
            var left = n
            for (i, b) in group.enumerated() {
                let share = i == group.count - 1 ? left : max(1, Int((Double(n) * Double(b.bytes) / Double(total)).rounded()))
                let k = min(left, share)
                if k > 0 { out[b.key] = k; left -= k }
            }
        }
        return out
    }

    /// What an untidy room looks like before Roomy has ever looked.
    static let firstLook: [Bucket] = [
        .init(key: "systemJunk", step: "cleanup", color: .systemPink, bytes: 2_000_000_000, removable: true),
        .init(key: "userCache", step: "cleanup", color: .systemTeal, bytes: 3_000_000_000, removable: true),
        .init(key: "developer", step: "cleanup", color: .systemIndigo, bytes: 3_000_000_000, removable: true),
        .init(key: "mail", step: "cleanup", color: .systemBlue, bytes: 800_000_000, removable: true),
        .init(key: "aiCare", step: "ai", color: .systemGray, bytes: 1_000_000_000, removable: true),
        .init(key: "large", step: "large", color: .brown, bytes: 20_000_000_000, removable: false),
    ]

    /// A free spot to lie in. Big things (boxes, the bottle) only go on the floor, never on the table or sofa.
    private func freeSlot(own: Bool, floorOnly: Bool = false) -> Int {
        let used = Set(pieces.filter { $0.place == .room && $0.removable != own }.map(\.slot))
        let count = own ? ownSlots.count : slots.count
        let fits = { (i: Int) in !floorOnly || own || self.slots[i].0.y == 0 }
        return (0..<count).first { !used.contains($0) && fits($0) } ?? (0..<count).first(where: fits) ?? 0
    }

    private func roomSpot(_ p: Piece) -> (SCNVector3, CGFloat) { p.removable ? slots[p.slot % slots.count] : ownSlots[p.slot % ownSlots.count] }

    private func newPiece(_ b: Bucket, index: Int) -> Piece {
        let kinds = Self.kinds(for: b.key)
        let kind = kinds[index % kinds.count]
        variant += 1
        let (node, dims): (SCNNode, SCNVector3?) = kind == .books ? { let (n, d) = makeBook(variant); return (n, d) }() : (make(kind), nil)
        node.name = b.key
        let p = Piece(node: node, key: b.key, step: b.step, removable: b.removable, slot: freeSlot(own: !b.removable, floorOnly: kind == .box || kind == .bottle))
        p.book = dims
        p.folds = kind == .box
        clutterRoot.addChildNode(node)
        pieces.append(p)
        return p
    }

    private func setInRoom(_ p: Piece) {
        if p.place == .shelved, let at = shelfPosition(p) {
            p.node.position = at; p.node.eulerAngles = SCNVector3Zero; p.node.opacity = 1; p.node.isHidden = false
            p.node.scale = SCNVector3(1, 1, 1)
            return
        }
        let (pos, rot) = roomSpot(p)
        if let b = p.book {
            // Dropped on its cover, a little crooked, and drawn a size up so it reads from across the room.
            p.node.position = SCNVector3(pos.x, pos.y + b.x * bookDrop / 2, pos.z)
            p.node.eulerAngles = SCNVector3(p.slot % 3 == 1 ? 0.08 : 0, rot, .pi / 2)
            p.node.opacity = 1; p.node.isHidden = false; p.node.scale = SCNVector3(bookDrop, bookDrop, bookDrop)
            return
        }
        p.node.position = pos
        p.node.eulerAngles = SCNVector3(0, rot, 0)
        p.node.opacity = 1
        p.node.isHidden = false
        p.node.scale = SCNVector3(1, 1, 1)
        p.node.childNode(withName: "shadow", recursively: false)?.opacity = 1
    }

    private var bagged: [Piece] { pieces.filter { $0.place == .bagged } }

    /// Adds or removes pieces so each bucket shows the right amount.
    private func reconcile(_ buckets: [Bucket], only steps: Set<String>? = nil, animated: Bool) -> [Piece] {
        let want = Self.counts(buckets)
        var added: [Piece] = []
        for b in buckets where steps == nil || steps!.contains(b.step) {
            let mine = pieces.filter { $0.key == b.key }
            let n = want[b.key] ?? 0
            if mine.count > n { for p in mine.suffix(mine.count - n) { remove(p, animated: animated) } }
            if mine.count < n {
                for i in mine.count..<n {
                    let p = newPiece(b, index: i)
                    setInRoom(p)
                    if animated { appear(p.node, delay: Double(added.count) * 0.06) }
                    added.append(p)
                }
            }
        }
        return added
    }

    private func remove(_ p: Piece, animated: Bool) {
        pieces.removeAll { $0 === p }
        p.node.name = nil
        guard animated, p.place == .room else { p.node.removeFromParentNode(); return }
        let out = SCNAction.group([.fadeOut(duration: 0.25), .scale(to: 0.6, duration: 0.25)])
        out.timingMode = .easeIn
        p.node.runAction(.sequence([out, .removeFromParentNode()]))
    }

    private func appear(_ node: SCNNode, delay: TimeInterval, to scale: CGFloat = 1) {
        node.opacity = 0
        node.scale = SCNVector3(0.7 * scale, 0.7 * scale, 0.7 * scale)
        let grow = SCNAction.scale(to: scale, duration: 0.42)
        grow.timingFunction = Self.settle
        node.runAction(.sequence([.wait(duration: delay), .group([.fadeIn(duration: 0.2), grow])]))
    }

    /// Before Roomy has ever looked: the room as it is, untidy. A bag from an earlier scan is left alone.
    func scatter(_ buckets: [Bucket], animated: Bool) {
        guard pieces.isEmpty && bagFill == 0 else { return }
        processed = []
        let source = buckets.contains { $0.bytes > 0 } ? buckets : Self.firstLook
        _ = reconcile(source, animated: animated)
        pieces.forEach(setInRoom)
        wake(animated ? 1 : 0.3)
    }

    /// A scan started. Nothing moves; findings are picked up as each part reports.
    func beginScan() { processed = [] }

    /// A part of the scan finished: anything new it found shows up where it lies, its finds light up, and then they
    /// go one by one into the bag. Books it found go back on the shelf.
    func collect(_ buckets: [Bucket], finished steps: Set<String>) {
        let fresh = steps.subtracting(processed)
        guard !fresh.isEmpty else { return }
        processed.formUnion(fresh)
        let added = reconcile(buckets, only: fresh, animated: true)
        let lead = added.isEmpty ? 0.1 : 0.6
        let sweep = pieces.filter { $0.removable && $0.place == .room && fresh.contains($0.step) }
        let books = pieces.filter { !$0.removable && $0.place == .room && fresh.contains($0.step) }
        tidy(sweep, books, lead: lead)
    }

    /// The finished state: findings in the bag by the bin, which is now full; your books on the shelf.
    func settle(_ buckets: [Bucket], animated: Bool) {
        let added = reconcile(buckets, animated: animated)
        let sweep = pieces.filter { $0.removable && $0.place == .room }
        let books = pieces.filter { !$0.removable && $0.place == .room }
        processed = ["cleanup", "apps", "lens", "ai", "large", "dev", "health", "dups"]
        if animated {
            let end = tidy(sweep, books, lead: added.isEmpty ? 0.1 : 0.6)
            if !bagged.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + end) { [weak self] in self?.fillBag(to: 1); self?.tie() }
            }
            wake(end + 1.4)
        } else {
            for p in sweep { p.place = .bagged; p.node.isHidden = true }
            for p in books { claimShelf(p); p.place = .shelved }
            pieces.filter { $0.place != .bagged }.forEach(setInRoom)
            bagFill = bagged.isEmpty ? 0 : 1
            bagModel?.scale = bagScale(bagFill)
            wake(0.3)
        }
    }

    /// Lights up what was found, tosses the clutter into the bag one piece at a time and flies the books home.
    /// Returns when the last piece lands.
    @discardableResult
    private func tidy(_ sweep: [Piece], _ books: [Piece], lead: TimeInterval) -> TimeInterval {
        guard !sweep.isEmpty || !books.isEmpty else { return lead }
        select(sweep + books, lead: lead)
        let start = lead + (reduceMotion ? 0.2 : 0.55)
        bagUp(sweep, lead: start)
        shelve(books, lead: start + 0.1)
        let end = start + max(Double(sweep.count) * toss(sweep.count) + 0.6, Double(books.count) * 0.24 + 1.1)
        wake(end + 1.2)
        return end
    }

    // MARK: picking things up

    /// A soft ring of light, drawn once and tinted per use.
    private lazy var ringMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { r in
            NSGradient(colors: [.clear, .clear, NSColor(white: 1, alpha: 0.95), NSColor(white: 1, alpha: 0.35), .clear],
                       atLocations: [0, 0.52, 0.74, 0.86, 1], colorSpace: .deviceRGB)?.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
            return true
        }
        m.blendMode = .add
        m.writesToDepthBuffer = false
        return m
    }()

    /// Each find lights up where it lies (a ring of the accent colour under it) and hops, as if picked out.
    private func select(_ found: [Piece], lead: TimeInterval) {
        guard !reduceMotion else { return }
        let tint = NSColor(Theme.currentAccent).usingColorSpace(.sRGB) ?? .systemBlue
        let m = ringMaterial.copy() as! SCNMaterial
        m.multiply.contents = tint
        for (i, p) in found.enumerated() {
            let delay = lead + Double(i) * 0.035
            let size: CGFloat = p.book != nil ? 0.75 : 0.9
            let plane = SCNPlane(width: size, height: size)
            plane.materials = [m]
            let ring = SCNNode(geometry: plane)
            ring.eulerAngles.x = -.pi / 2
            ring.castsShadow = false
            let (spot, _) = roomSpot(p)
            ring.position = SCNVector3(p.node.position.x, spot.y + 0.015, p.node.position.z)
            ring.opacity = 0
            ring.scale = SCNVector3(0.3, 0.3, 0.3)
            clutterRoot.addChildNode(ring)
            let grow = SCNAction.scale(to: 1, duration: 0.32)
            grow.timingFunction = Self.settle
            ring.runAction(.sequence([.wait(duration: delay), .group([.fadeOpacity(to: 0.9, duration: 0.18), grow]),
                                      .wait(duration: 0.5 + Double(i) * 0.12), .fadeOut(duration: 0.35), .removeFromParentNode()]))
            let up = SCNAction.moveBy(x: 0, y: 0.16, z: 0, duration: 0.14); up.timingMode = .easeOut
            let down = SCNAction.moveBy(x: 0, y: -0.16, z: 0, duration: 0.2); down.timingMode = .easeIn
            p.node.runAction(.sequence([.wait(duration: delay + 0.05), up, down]), forKey: "hop")
        }
    }

    /// Each piece is tossed into the bag in turn: a short arc to its mouth, shrinking as it drops in, and the bag fills
    /// a little more with every one.
    private func bagUp(_ sweep: [Piece], lead: TimeInterval) {
        guard !sweep.isEmpty else { return }
        let total = CGFloat(max(1, pieces.filter(\.removable).count))
        var landed = CGFloat(bagged.count)
        for p in sweep { p.place = .bagged }
        let mouth = SCNVector3(bagSpot.x, 0.95, bagSpot.z)
        for (i, p) in sweep.enumerated() {
            let delay = lead + Double(i) * toss(sweep.count)
            landed += 1
            let fill = landed / total
            if reduceMotion {
                p.node.runAction(.sequence([.wait(duration: delay), .fadeOut(duration: 0.25), .hide()]), forKey: "move")
            } else {
                p.node.removeAction(forKey: "hop")
                arc(p.node, to: mouth, height: 1.0, duration: 0.6, delay: delay, spin: true, shrinkTo: p.folds ? 0.22 : 0.3, squash: p.folds ? 0.15 : 1)
                p.node.runAction(.sequence([.wait(duration: delay + 0.5), .fadeOut(duration: 0.1), .hide()]), forKey: "fade")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + (reduceMotion ? 0.25 : 0.6)) { [weak self] in self?.fillBag(to: fill) }
        }
    }

    /// Books fly back to their gap on the shelf and slide in, spine out.
    private func shelve(_ books: [Piece], lead: TimeInterval) {
        for (i, p) in books.enumerated() {
            claimShelf(p)
            p.place = .shelved
            guard let at = shelfPosition(p) else { continue }
            let delay = lead + Double(i) * 0.24
            if reduceMotion {
                p.node.runAction(.sequence([.wait(duration: delay), .fadeOut(duration: 0.2),
                                            .run { n in n.position = at; n.eulerAngles = SCNVector3Zero }, .fadeIn(duration: 0.25)]), forKey: "move")
                continue
            }
            p.node.removeAction(forKey: "hop")
            let front = SCNVector3(at.x, at.y, at.z + 0.45)
            var start = SCNVector3Zero, e0 = SCNVector3Zero, s0: CGFloat = 1
            let duration = 0.8
            let fly = SCNAction.customAction(duration: duration) { n, el in
                let u = CGFloat(Double(el) / duration)
                let t = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
                let peak = max(start.y, front.y) + 1.1
                let y = start.y + (front.y - start.y) * t + 4 * (peak - max(start.y, front.y)) * u * (1 - u)
                n.position = SCNVector3(start.x + (front.x - start.x) * t, y, start.z + (front.z - start.z) * t)
                n.eulerAngles = SCNVector3(e0.x * (1 - t), e0.y * (1 - t), e0.z * (1 - t))
                let k = s0 + (1 - s0) * t
                n.scale = SCNVector3(k, k, k)
            }
            let slide = SCNAction.move(to: at, duration: 0.22)
            slide.timingFunction = Self.settle
            p.node.runAction(.sequence([.wait(duration: delay), .run { n in start = n.position; e0 = n.eulerAngles; s0 = n.scale.y }, fly, slide]), forKey: "move")
        }
    }

    // MARK: the bag

    /// Stays beside the bin; its child is the bag itself, replaced after every clean.
    private let bagNode = SCNNode()
    private var bagModel: SCNNode?
    /// How full the bag is, 0 to 1. It only ever fills until it's thrown away.
    private var bagFill: CGFloat = 0

    private func buildBag() {
        bagNode.position = bagSpot
        bagNode.name = "userCache"
        bagNode.addChildNode(shadow(1.5))
        clutterRoot.addChildNode(bagNode)
        newBag(animated: false)
    }

    /// A fresh, empty bag: the plastic slumped by the bin, waiting.
    private func newBag(animated: Bool) {
        let m = model("trashbag")
        m.eulerAngles.y = 0.5
        bagModel = m
        bagFill = 0
        m.scale = bagScale(0)
        bagNode.addChildNode(m)
        if animated { m.opacity = 0; m.runAction(.fadeIn(duration: 0.5)) }
    }

    /// Empty, the bag is a low slump of plastic; full, it stands at its scanned size.
    private func bagScale(_ f: CGFloat) -> SCNVector3 {
        let s = U * 1.3
        return SCNVector3(s * (0.84 + 0.16 * f), s * (0.18 + 0.82 * f), s * (0.84 + 0.16 * f))
    }

    /// Grows the bag to `f` full with a soft squash, as if something just dropped in.
    private func fillBag(to f: CGFloat) {
        guard let m = bagModel else { return }
        let target = max(bagFill, min(1, f))
        guard target > bagFill || f >= 1 else { return }
        bagFill = target
        let to = bagScale(target)
        if reduceMotion { m.scale = to; wake(0.2); return }
        var from = SCNVector3Zero
        let grow = SCNAction.customAction(duration: 0.42) { n, el in
            let u = Double(el) / 0.42
            let k = CGFloat(1 - pow(1 - u, 3))
            let sq = CGFloat(sin(u * .pi)) * 0.09
            n.scale = SCNVector3((from.x + (to.x - from.x) * k) * (1 + sq), (from.y + (to.y - from.y) * k) * (1 - sq), (from.z + (to.z - from.z) * k) * (1 + sq))
        }
        m.runAction(.sequence([.run { n in from = n.scale }, grow]), forKey: "fill")
        bagNode.childNode(withName: "shadow", recursively: false)?.scale = SCNVector3(0.55 + 0.45 * target, 0.55 + 0.45 * target, 1)
        wake(0.6)
    }

    /// Full: a quick twist at the neck, as the bag is tied.
    private func tie() {
        guard let m = bagModel, !reduceMotion else { return }
        let twist = SCNAction.rotateBy(x: 0, y: 0.45, z: 0, duration: 0.18); twist.timingMode = .easeOut
        let back = SCNAction.rotateBy(x: 0, y: -0.45, z: 0, duration: 0.42); back.timingFunction = Self.settle
        m.runAction(.sequence([.wait(duration: 0.3), twist, back]), forKey: "tie")
        wake(1.2)
    }

    /// Clean: the bag goes into the bin and the room is left tidy, with a fresh bag ready. (In Safe mode no files are
    /// touched; the room still shows what Clean would do, and the next scan finds the same clutter again.)
    func throwAway() {
        guard bagFill > 0 else { return }
        openLid(true)
        let flight = reduceMotion ? 0.3 : 0.85
        let into = SCNVector3(bin.x, 0.75, bin.z)
        if reduceMotion {
            bagNode.runAction(.sequence([.wait(duration: 0.35), .fadeOut(duration: flight)]), forKey: "move")
        } else {
            arc(bagNode, to: into, height: 1.5, duration: flight, delay: 0.35, spin: false, shrinkTo: 0.6, tumble: 0.6)
            bagNode.runAction(.sequence([.wait(duration: 0.35 + flight * 0.82), .fadeOut(duration: flight * 0.18)]), forKey: "fade")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + flight) { [weak self] in self?.nod() }
        let done = 0.35 + flight + 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + done) { [weak self] in
            guard let self else { return }
            self.openLid(false)
            for p in self.bagged { self.pieces.removeAll { $0 === p }; p.node.removeFromParentNode() }
            self.bagModel?.removeFromParentNode()
            self.bagNode.removeAllActions()
            self.bagNode.position = self.bagSpot
            self.bagNode.eulerAngles = SCNVector3Zero
            self.bagNode.scale = SCNVector3(1, 1, 1)
            self.bagNode.opacity = 1
            self.bagNode.childNode(withName: "shadow", recursively: false)?.opacity = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.newBag(animated: true); self?.wake(0.8) }
        }
        wake(done + 1.6)
    }

    private func openLid(_ open: Bool) {
        let a = SCNAction.rotateTo(x: open ? -1.25 : 0, y: 0, z: 0, duration: open ? 0.32 : 0.38, usesShortestUnitArc: true)
        a.timingFunction = open ? { t in Float(1 - pow(1 - Double(t), 3)) } : Self.settle
        binLid.runAction(a, forKey: "lid")
    }

    /// The bin dips slightly as something lands in it.
    private func nod() {
        let down = SCNAction.scale(to: binScale * 0.975, duration: 0.07)
        let up = SCNAction.scale(to: binScale, duration: 0.24)
        up.timingFunction = Self.settle
        binBody.runAction(.sequence([down, up]), forKey: "nod")
    }

    /// Moves a node along a lifted arc: it rises, travels and lands softly, the way you'd toss something
    /// underhand. Its contact shadow fades while it's in the air.
    private func arc(_ node: SCNNode, to end: SCNVector3, height: CGFloat, duration: TimeInterval, delay: TimeInterval,
                     spin: Bool, shrinkTo: CGFloat = 1, squash: CGFloat = 1, tumble amount: CGFloat? = nil) {
        node.removeAction(forKey: "move")
        let shadow = node.childNode(withName: "shadow", recursively: false)
        let tumble = amount ?? (spin ? CGFloat.random(in: 1.5...2.6) : 0)
        var start = SCNVector3Zero, yaw0: CGFloat = 0, base: CGFloat = 1
        let fly = SCNAction.customAction(duration: duration) { n, elapsed in
            let u = CGFloat(Double(elapsed) / duration)
            let t = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
            let peak = max(start.y, end.y) + height
            let y = start.y + (end.y - start.y) * u + 4 * (peak - max(start.y, end.y)) * u * (1 - u)
            n.position = SCNVector3(start.x + (end.x - start.x) * t, y, start.z + (end.z - start.z) * t)
            n.eulerAngles = SCNVector3(tumble * u * 0.6, yaw0 + (spin ? 2.4 : 0) * t, tumble * u * 0.25)
            let s = base * (1 + (shrinkTo - 1) * u)
            let fold = 1 + (squash - 1) * u * u
            n.scale = SCNVector3(s, s * fold, s)
            shadow?.opacity = max(0, 1 - 4 * min(u, 1 - u))
        }
        let begin = SCNAction.run { n in start = n.position; yaw0 = n.eulerAngles.y; base = n.scale.y }
        node.runAction(.sequence([.wait(duration: delay), begin, fly]), forKey: "move")
    }

    /// Quick to start, gentle to finish, with no overshoot.
    private static let settle: SCNActionTimingFunction = { t in Float(1 - pow(1 - Double(t), 3.2)) }

    /// The bucket key of the piece under a click, if any.
    func key(at point: CGPoint, in view: SCNView) -> String? {
        for hit in view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
            var n: SCNNode? = hit.node
            while let c = n {
                if c.parent === clutterRoot, let k = c.name { return k }
                n = c.parent
            }
        }
        return nil
    }
}

/// The room as a SwiftUI view. It renders only while something moves.
struct RoomSceneView: NSViewRepresentable {
    var room: RoomScene
    var dark: Bool
    var paint: Color
    var reduceMotion: Bool
    var onPick: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(room: room) }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        v.scene = room.scene
        v.pointOfView = room.cameraNode
        v.antialiasingMode = .multisampling2X
        v.preferredFramesPerSecond = 60
        v.rendersContinuously = false
        v.isPlaying = false
        v.allowsCameraControl = false
        v.backgroundColor = .black
        v.addGestureRecognizer(NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.click(_:))))
        room.view = v
        // Draw the room at once on arrival, rather than waiting for something in it to move.
        DispatchQueue.main.async { room.wake(0.4) }
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        room.reduceMotion = reduceMotion
        room.apply(dark: dark, paint: NSColor(paint))
        context.coordinator.onPick = onPick
    }

    static func dismantleNSView(_ v: SCNView, coordinator: Coordinator) {
        v.isPlaying = false
    }

    @MainActor final class Coordinator: NSObject {
        let room: RoomScene
        var onPick: ((String) -> Void)?
        init(room: RoomScene) { self.room = room }
        @objc func click(_ g: NSClickGestureRecognizer) {
            guard let v = g.view as? SCNView, let key = room.key(at: g.location(in: v), in: v) else { return }
            onPick?(key)
        }
    }
}
