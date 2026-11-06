import SwiftUI

/// The window's size class, read from the window itself (never from the Mac model), so a 13-inch laptop, a split
/// screen and a small window on a big display all get the same treatment.
/// - compact width (under 1,180pt): side columns shrink to what they must show, so content keeps its room.
/// - short height (under 760pt): secondary lines and sparklines drop, so lists keep at least a few rows.
struct WindowSize: Equatable {
    var width: CGFloat = 1400
    var height: CGFloat = 900
    var compact: Bool { width < 1180 }
    var short: Bool { height < 760 }
}

private struct WindowSizeKey: EnvironmentKey { static let defaultValue = WindowSize() }

extension EnvironmentValues {
    var windowSize: WindowSize {
        get { self[WindowSizeKey.self] }
        set { self[WindowSizeKey.self] = newValue }
    }
}
