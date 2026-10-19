import Foundation

/// Demo mode, for README screenshots: `ROOMY_DEMO=<sanitised snapshot.json> Roomy.app/Contents/MacOS/Roomy`.
/// Roomy shows that snapshot as a finished scan and never scans, cleans or saves. Activity lists only everyday
/// processes, every process you own reads "you", and the hardware line is generic, so no screenshot carries a
/// username, account, project or the machine's details.
enum Demo {
    static let snapshot = ProcessInfo.processInfo.environment["ROOMY_DEMO"]
    static var on: Bool { snapshot != nil }

    static let hardware = "Apple silicon · macOS 26"

    /// Processes shown in Activity during a demo (by name, as Activity shows them).
    static let processes: Set<String> = [
        "WindowServer", "kernel_task", "launchd", "Finder", "Dock", "SystemUIServer", "Spotlight", "mds", "mds_stores", "mdworker_shared",
        "Safari", "Mail", "Music", "Photos", "Messages", "Notes", "Calendar", "Preview", "Xcode", "Simulator", "Terminal", "Activity Monitor",
        "Google Chrome", "Google Chrome Helper", "Google Chrome Helper (Renderer)", "Google Chrome Helper (GPU)", "Visual Studio Code", "Code Helper",
        "Code Helper (Renderer)", "Code Helper (Plugin)", "Slack", "Zoom", "Spotify", "Roomy", "coreaudiod", "bluetoothd", "airportd", "cloudd",
        "bird", "trustd", "mDNSResponder", "softwareupdated", "photoanalysisd", "mediaanalysisd", "corespotlightd", "UserEventAgent",
        "loginwindow", "ControlCenter", "NotificationCenter", "WindowManager", "distnoted", "cfprefsd", "opendirectoryd", "syslogd", "powerd",
        "thermalmonitord", "logd", "configd", "sysmond", "top", "Safari Networking", "Safari Web Content", "com.apple.WebKit.WebContent",
        "com.apple.WebKit.Networking", "com.apple.WebKit.GPU", "Xcode Previews", "SourceKitService", "swift-frontend", "node", "python3", "git",
    ]
}
