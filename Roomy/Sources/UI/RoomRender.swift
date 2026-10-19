import SceneKit
import AppKit
import Metal

/// Testing aid: `Roomy.app/Contents/MacOS/Roomy -RoomyRenderStory <folder>` plays the room's whole story offscreen
/// (untidy, each part of a scan bagging its finds, books shelved, the bag thrown away) and writes frames as PNGs,
/// then quits. No window or file outside that folder is touched.
@MainActor
enum RoomRender {
    static func run(to dir: String, dark: Bool) {
        let room = RoomScene.shared
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = room.scene
        renderer.pointOfView = room.cameraNode
        room.apply(dark: dark, paint: NSColor(Theme.current.paint))
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let start = CACurrentMediaTime()
        let buckets = RoomScene.firstLook
        func shot(_ name: String) {
            let img = renderer.snapshot(atTime: CACurrentMediaTime() - start, with: CGSize(width: 1280, height: 800), antialiasingMode: .multisampling2X)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        // (seconds from start, what happens)
        var plan: [(Double, () -> Void)] = [
            (0.2, { room.scatter(buckets, animated: false) }),
            (0.8, { shot("00-untidy") }),
            (1.0, { room.beginScan(); room.collect(buckets, finished: ["cleanup"]) }),
            (1.75, { shot("01-selected") }),
            (1.95, { shot("01b-box-folding") }),
            (2.1, { shot("01c-box-folding") }),
            (2.3, { shot("02-tossing") }),
            (3.4, { shot("03-bag-filling") }),
            (4.6, { room.collect(buckets, finished: ["cleanup", "large"]) }),
            (5.5, { shot("04-books-flying") }),
            (7.0, { shot("05-books-shelved") }),
            (7.4, { room.settle(buckets, animated: true) }),
            (10.0, { shot("06-bag-full") }),
            (10.4, { room.throwAway() }),
            (11.05, { shot("07-into-bin") }),
            (13.2, { shot("08-tidy-new-bag") }),
            (13.6, { exit(0) }),
        ]
        // `-RoomyRenderDense YES`: a frame every tenth of a second while the first finds are tossed.
        if UserDefaults.standard.bool(forKey: "RoomyRenderDense") {
            for i in 0..<24 { let t = 2.4 + Double(i) * 0.05; plan.append((t, { shot(String(format: "dense-%.2f", t)) })) }
        }
        for (t, f) in plan { DispatchQueue.main.asyncAfter(deadline: .now() + t) { f() } }
        // Actions only advance when a frame renders, so keep rendering small frames between the saved ones.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { _ = renderer.snapshot(atTime: CACurrentMediaTime() - start, with: CGSize(width: 64, height: 40), antialiasingMode: .none) }
        }
    }
}
