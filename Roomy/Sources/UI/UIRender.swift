import SwiftUI
import AppKit

/// Testing aid: `Roomy.app/Contents/MacOS/Roomy -RoomyRenderUI <folder>` draws the rail (resting, pointed at, open),
/// every area's liquid icon, the orb in each state and every area's ground, in light and dark, to PNGs, then quits.
@MainActor
enum UIRender {
    static func run(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            save(Gallery().environment(\.colorScheme, scheme), "\(dir)/gallery-\(name).png")
        }
        exit(0)
    }

    static func save<V: View>(_ v: V, _ path: String) {
        let r = ImageRenderer(content: v)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    struct Gallery: View {
        @Environment(\.colorScheme) var scheme
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach([Area.checkup, .cleanup, .apps, .files, .health, .storage]) { a in
                    ZStack(alignment: .leading) {
                        AreaGround(area: a)
                        HStack(spacing: 34) {
                            VStack(spacing: 6) {
                                RailItem(area: .checkup, selected: a == .checkup, news: false) {}
                                RailItem(area: .cleanup, selected: a == .cleanup, news: false) {}
                                RailItem(area: .apps, selected: a == .apps, news: true) {}
                                RailItem(area: .files, selected: a == .files, news: false) {}
                            }
                            ZStack {
                                RailTile(area: .health, selected: false)
                                RailGlyph(symbol: Area.health.railSymbol, area: .health, lit: true)
                            }
                            .frame(width: 46, height: 46)
                            .overlay(alignment: .leading) { RailTip(text: "Health").fixedSize().offset(x: 54) }
                            Spacer().frame(width: 60)
                            LiquidIcon(route: a.routes[0], size: 120, interactive: false)
                            LiquidIcon(route: a.routes[min(1, a.routes.count - 1)], size: 56, interactive: false)
                            orb(a, title: "Scan", progress: nil)
                            orb(a, title: "42%", progress: 0.42)
                        }
                        .padding(.leading, 20)
                    }
                    .frame(width: 1100, height: 230)
                    .clipped()
                }
            }
        }

        func orb(_ a: Area, title: String, progress: Double?) -> some View {
            let s = OrbState()
            s.title = title; s.progress = progress; s.visible = true; s.enabled = true
            s.tint = a.color(sat: 0.85, bri: 0.85)
            return OrbButton(state: s).frame(width: 200, height: 200)
        }
    }
}
