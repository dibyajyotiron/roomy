import SwiftUI

// MARK: - Module identity

extension Route {
    /// The module's hue, light to deep. The Living Room tints each finding's clutter with it.
    var gradient: [Color] {
        let h = Theme.hex
        switch self {
        case .care: return [h(0xF7B267), h(0xD9622B)]
        case .systemJunk: return [h(0xFF7EB6), h(0xC2348A)]
        case .userCache: return [h(0x6FF0DA), h(0x167F94)]
        case .developer: return [h(0x9AA6FF), h(0x4447D6)]
        case .artifacts: return [h(0xFFC07A), h(0xD9582E)]
        case .aiCare: return [h(0x9DA8B8), h(0x434C5E)]
        case .mail: return [h(0x7CCBFF), h(0x2A67D2)]
        case .trash: return [h(0xA9B4C8), h(0x4B5872)]
        case .systemData: return [h(0xB5BED6), h(0x525C78)]
        case .uninstaller: return [h(0x7DB2FF), h(0x2C4FD0)]
        case .updates: return [h(0x7DF0AE), h(0x179966)]
        case .leftovers: return [h(0xFFDA7A), h(0xD98A24)]
        case .startup: return [h(0xFF9A88), h(0xD23F36)]
        case .slimming: return [h(0xD4F58A), h(0x5FA322)]
        case .lens: return [h(0x86E8FF), h(0x5B4BF5)]
        case .large: return [h(0xFFCF7A), h(0xDB6F28)]
        case .dups: return [h(0xDEA6FF), h(0x8546DE)]
        case .photos: return [h(0xFFAA94), h(0xDA4F78)]
        case .installers: return [h(0xF5BE8C), h(0xAE5A26)]
        case .protection: return [h(0x6EF0BE), h(0x0F946A)]
        case .status: return [h(0x7BDBFF), h(0x2477DC)]
        case .maintenance: return [h(0xA8CCFF), h(0x4466B3)]
        case .history: return [h(0xC4C6E4), h(0x63679A)]
        case .storage: return [h(0x9EE2FF), h(0x3B6BE0)]
        case .settings: return [h(0xC9CED8), h(0x5A6170)]
        }
    }
}

/// A module's identity: its SF Symbol, drawn the way Apple's own sidebar apps draw theirs (Music, TV, Finder): no tile,
/// no gradient, the glyph alone in the accent colour.
struct ModuleBadge: View {
    var route: Route
    var size: CGFloat = 20
    var tint: Color = Palette.accent
    var body: some View {
        Image(systemName: route.symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.62, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
