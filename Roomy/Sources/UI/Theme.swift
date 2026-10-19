import SwiftUI
import AppKit

/// A colour theme for the whole window: a wash behind the glass sidebar and content (deep in dark mode, soft in light
/// mode), the accent every control uses, and the wall paint in Checkup's room. "System" keeps macOS's own look.
struct Theme: Identifiable, Hashable {
    var id: String
    var name: String
    var paint: Color
    var accent: Color?
    /// Top-leading and bottom-trailing wash colours, light then dark. Empty for the system look.
    var light: [Color] = []
    var dark: [Color] = []

    static func hex(_ h: UInt32) -> Color { Color(red: Double((h >> 16) & 255) / 255, green: Double((h >> 8) & 255) / 255, blue: Double(h & 255) / 255) }

    static let all: [Theme] = [
        Theme(id: "system", name: "System", paint: hex(0xE2DFDA), accent: nil),
        Theme(id: "plum", name: "Heather", paint: hex(0xE4D9E0), accent: hex(0x9B6BDF),
              light: [hex(0xF6F1FB), hex(0xE6DCF3)], dark: [hex(0x2A1C40), hex(0x120B1D)]),
        Theme(id: "emerald", name: "Sage", paint: hex(0xD9E2D6), accent: hex(0x3E9E6A),
              light: [hex(0xF1F7F1), hex(0xDCEBDF)], dark: [hex(0x14302A), hex(0x0A1714)]),
        Theme(id: "ocean", name: "Mist", paint: hex(0xD8E1EA), accent: hex(0x3B82E0),
              light: [hex(0xF0F4FA), hex(0xDCE6F3)], dark: [hex(0x172640), hex(0x0A101C)]),
        Theme(id: "sunset", name: "Clay", paint: hex(0xEAD8CB), accent: hex(0xD06A3E),
              light: [hex(0xFAF2EC), hex(0xF1DFD3)], dark: [hex(0x3A2018), hex(0x170C08)]),
        Theme(id: "aurora", name: "Eucalyptus", paint: hex(0xD5E3DF), accent: hex(0x22A39A),
              light: [hex(0xEDF7F6), hex(0xD5ECE9)], dark: [hex(0x0F3433), hex(0x061615)]),
        Theme(id: "graphite", name: "Linen", paint: hex(0xE6E2DA), accent: hex(0xA6824F),
              light: [hex(0xF9F5EE), hex(0xEDE4D6)], dark: [hex(0x2B241A), hex(0x13100B)]),
    ]

    /// The accent of the chosen theme, for drawing code that needs a concrete colour (charts, canvases, gradients).
    nonisolated(unsafe) static var currentAccent: Color = .accentColor
}

/// The theme's wash: a diagonal gradient with a soft glow of the accent where light would fall, under all the glass.
struct ThemeWash: View {
    var theme: Theme
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let c = scheme == .dark ? theme.dark : theme.light
        if c.count == 2, let a = theme.accent {
            ZStack {
                LinearGradient(colors: c, startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [a.opacity(scheme == .dark ? 0.32 : 0.16), .clear], center: UnitPoint(x: 0.78, y: 0.05), startRadius: 0, endRadius: 760)
                RadialGradient(colors: [a.opacity(scheme == .dark ? 0.14 : 0.08), .clear], center: UnitPoint(x: 0.1, y: 1.0), startRadius: 0, endRadius: 620)
            }
            .ignoresSafeArea()
        } else {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        }
    }
}

/// Safety colours, the same everywhere. Tuned to read on both the light and dark window background.
extension SafetyClass {
    var color: Color {
        switch self {
        case .clean: Color(nsColor: .systemGreen)
        case .user: Color(nsColor: .systemOrange)
        case .appdata: Color(nsColor: .systemBlue)
        case .app: Color(nsColor: .systemPink)
        case .system: Color(nsColor: .systemGray)
        case .hidden: Color(nsColor: .systemGray)
        }
    }
}

/// Semantic colours: they follow light and dark mode and increased contrast.
enum Palette {
    /// The theme's accent (the system accent with the System theme).
    static var accent: Color { Theme.currentAccent }
    static let ok = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)
    static let bad = Color(nsColor: .systemRed)
    static let ink2 = Color(nsColor: .secondaryLabelColor)
    static let ink3 = Color(nsColor: .tertiaryLabelColor)
    static let hair = Color(nsColor: .separatorColor)
    static let fill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    static let card = Color(nsColor: .controlBackgroundColor)
}
