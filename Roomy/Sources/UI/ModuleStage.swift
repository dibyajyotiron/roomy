import SwiftUI

/// What a module is for and what it looks at, for its title page.
extension Route {
    var pitch: String {
        switch self {
        case .systemJunk: "Logs, temporary files and system caches that macOS rebuilds on its own."
        case .userCache: "Caches your apps keep. They come back as needed; the ones of apps that are open are left alone."
        case .developer: "What developer tools leave behind: build data, package downloads and caches."
        case .artifacts: "Build output in your projects that a build makes again."
        case .aiCare: "Caches and old versions of AI tools, and what they keep that you may not need."
        case .mail: "Copies of attachments Mail downloaded, which stay on your mail server."
        case .trash: "What's in your Trash. Mole's normal Clean also empties it unless it's on your Mole keep list."
        case .systemData: "The parts of System Data you can do something about."
        case .uninstaller: "Remove an app together with everything it left in your Library."
        case .updates: "Newer versions of apps you installed with Homebrew."
        case .leftovers: "Files from apps you've already removed."
        case .startup: "What starts when you log in, and helpers whose app is gone."
        case .slimming: "Parts of apps you don't need, like languages you don't use."
        case .lens: "Everything on your disk as bubbles sized by what they take up."
        case .large: "Big and old files, for you to decide about."
        case .dups: "Identical copies of the same file."
        case .photos: "Photos that look nearly the same, for you to pick from."
        case .installers: "Installer files you've already used."
        case .protection: "The protections built into macOS, and whether they're on."
        case .maintenance: "Upkeep macOS benefits from, each task explained before it runs."
        case .storage: "What's using your disk, in the same categories as System Settings."
        default: ""
        }
    }

    /// What the scan looks at, as SF Symbol and words.
    var looksAt: [(String, String)] {
        switch self {
        case .systemJunk: [("doc.text", "System and app logs"), ("internaldrive", "System caches"), ("clock.arrow.circlepath", "Temporary files")]
        case .userCache: [("square.stack.3d.up", "App caches"), ("globe", "Browser caches"), ("moon.zzz", "Caches of apps you no longer use")]
        case .developer: [("hammer", "Xcode build data"), ("shippingbox", "Homebrew downloads"), ("curlybraces", "npm, pnpm and Yarn caches"), ("cube", "Docker build cache, for review")]
        case .artifacts: [("folder", "node_modules, build and dist"), ("chevron.left.forwardslash.chevron.right", "Python environments"), ("calendar", "Only projects untouched for 30 days")]
        case .aiCare: [("cpu", "AI tool caches"), ("clock.arrow.circlepath", "Old versions"), ("bubble.left.and.bubble.right", "Old chats and worktrees, for review")]
        case .mail: [("paperclip", "Downloaded attachments"), ("tray.and.arrow.down", "Mail Downloads")]
        case .trash: [("trash", "Your Trash"), ("envelope", "Mail's trash")]
        case .systemData: [("internaldrive", "Local snapshots and backups"), ("arrow.down.circle", "Firmware and updates"), ("lock", "What only macOS can see")]
        case .uninstaller: [("square.grid.2x2", "Every app you installed"), ("folder", "Its files in your Library"), ("power", "Its login and background items")]
        case .updates: [("arrow.triangle.2.circlepath", "Homebrew apps with a newer version")]
        case .leftovers: [("puzzlepiece.extension", "Preferences and caches"), ("shippingbox", "Containers and app data"), ("hand.raised", "Your data stays unless you choose")]
        case .startup: [("power", "Login items"), ("gearshape.2", "Background agents"), ("exclamationmark.triangle", "Helpers whose app is gone")]
        case .slimming: [("character.bubble", "Unused languages"), ("cpu", "Universal binaries, for review")]
        case .lens: [("house", "Your home folder"), ("square.grid.2x2", "Applications"), ("lock", "System, view only")]
        case .large: [("doc.richtext", "Large files"), ("calendar", "Files you haven't opened in a while")]
        case .dups: [("doc.on.doc", "Identical files, matched by content"), ("checkmark.shield", "One copy always kept")]
        case .photos: [("photo.on.rectangle.angled", "Near-identical photos"), ("hand.point.up.left", "You choose which to keep")]
        case .installers: [("shippingbox.and.arrow.backward", "Disk images and packages"), ("archivebox", "Installer archives")]
        case .protection: [("checkmark.shield", "Gatekeeper and XProtect"), ("lock.shield", "FileVault"), ("network", "Firewall")]
        case .maintenance: [("wrench.and.screwdriver", "Upkeep tasks"), ("text.bubble", "Each one explained"), ("checkmark.circle", "Checked afterwards")]
        case .storage: [("chart.bar", "Every category"), ("magnifyingglass", "What's inside each one")]
        default: []
        }
    }
}

/// A module's three moments, in the same symmetric frame: a title page until its part has been scanned, the scanner
/// while it is, and then its results. They blur from one into the next.
struct ModuleStage<Results: View>: View {
    @Environment(AppModel.self) var model
    var route: Route
    @ViewBuilder var results: Results

    enum Stage: String { case landing, scanning, results }

    var stage: Stage {
        guard let part = AppModel.scanPart(for: route) else { return .results }
        // Results already in stay on screen while they're refreshed (a disk walk takes minutes); the scanner page is
        // for a part that has never been scanned.
        if model.hasScanned(part) { return .results }
        let steps = AppModel.steps.map(\.id).filter { AppModel.part(of: $0) == part }
        if model.isRescanning(route) || (model.phase == .scanning && !steps.allSatisfy { model.finished.contains($0) }) { return .scanning }
        return .landing
    }

    var body: some View {
        let s = stage
        ZStack {
            switch s {
            case .results: results
            case .landing, .scanning: ModuleTitlePage(route: route, scanning: s == .scanning)
            }
        }
        .id(s)
        .transition(.asymmetric(insertion: AnyTransition(.blurReplace).combined(with: .scale(scale: 0.98)),
                                removal: .opacity.animation(.easeOut(duration: 0.15))))
        .animation(.smooth(duration: 0.45), value: s)
    }
}

/// The title page: the module's glass icon large on the left in a pool of its light, and on the right its name, what
/// it's for and what it looks at. While scanning, the icon breathes and a light runs under the words.
struct ModuleTitlePage: View {
    @Environment(AppModel.self) var model
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var route: Route
    var scanning: Bool
    @State private var breathe = false

    var body: some View {
        let st = LiquidStyle.of(route)
        GeometryReader { geo in
            let big = min(230, max(150, geo.size.width * 0.24))
            HStack(spacing: max(36, geo.size.width * 0.06)) {
                LiquidIcon(route: route, size: big)
                    .scaleEffect(scanning && breathe ? 1.05 : 1)
                    .background(Circle().fill(st.mid.opacity(scanning ? 0.55 : 0.38)).frame(width: big * 1.8, height: big * 1.8).blur(radius: big * 0.42))
                VStack(alignment: .leading, spacing: 0) {
                    Text(route.title)
                        .font(.system(size: 36, weight: .semibold)).tracking(-0.8)
                    Text(scanning ? "Looking through your Mac. Nothing changes while Roomy looks." : route.pitch)
                        .font(.system(size: 14.5)).foregroundStyle(.secondary).contentTransition(.opacity)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360, alignment: .leading)
                        .padding(.top, 8)
                    if scanning { ShimmerBar().frame(width: 220).padding(.top, 16) }
                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(Array(route.looksAt.enumerated()), id: \.offset) { i, item in
                            HStack(spacing: 11) {
                                Image(systemName: item.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(LinearGradient(colors: [st.light, st.mid], startPoint: .top, endPoint: .bottom)))
                                    .shadow(color: st.mid.opacity(0.5), radius: 4, y: 2)
                                Text(item.1).font(.system(size: 14, weight: .medium))
                            }
                            .modifier(RiseIn(delay: 0.08 + Double(i) * 0.05))
                        }
                    }
                    .padding(.top, 22)
                    .opacity(scanning ? 0.7 : 1)
                }
                .frame(maxWidth: 380, alignment: .leading)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .offset(y: -24)
        }
        .onAppear {
            guard scanning, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityElement(children: .combine)
    }
}
