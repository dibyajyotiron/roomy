import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - Surfaces

struct Glass: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.hair.opacity(0.6), lineWidth: 0.5))
    }
}

extension View {
    func glass(_ radius: CGFloat = 12) -> some View { modifier(Glass(radius: radius)) }
}

/// Every module opens the same way on the window background: its liquid icon, a large title, one line on what it does,
/// and the one number that matters.
struct ScreenHeader<Trailing: View>: View {
    @Environment(AppModel.self) var model
    var icon: Route? = nil
    var title: String
    var subtitle: String
    var value: String? = nil
    var valueCaption: String? = nil
    /// Context for the number, smaller than the caption: a total, or how much waits for you to choose.
    var valueDetail: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            LiquidIcon(route: icon ?? model.route, size: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.4)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
            }
            Spacer(minLength: 16)
            if let value {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                    if let valueCaption { Text(valueCaption).font(.system(size: 12)).foregroundStyle(.secondary) }
                    if let valueDetail { Text(valueDetail).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit().padding(.top, 2) }
                }
                .fixedSize()
            }
            trailing
        }
        .padding(.horizontal, 28).padding(.top, 60).padding(.bottom, 16)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(icon: Route? = nil, title: String, subtitle: String, value: String? = nil, valueCaption: String? = nil, valueDetail: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle, value: value, valueCaption: valueCaption, valueDetail: valueDetail) { EmptyView() }
    }
}

struct SectionLabel: View {
    var title: String
    var bytes: Int64? = nil
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink2)
                if let bytes { Text("· \(Fmt.bytes(bytes))").font(.system(size: 12)).foregroundStyle(Palette.ink3).contentTransition(.numericText()) }
            }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18).padding(.bottom, 8).padding(.horizontal, 2)
    }
}

// MARK: - Controls

struct CheckMark: View {
    var on: Bool
    var tint: Color = Palette.accent
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(on ? tint : Palette.ink3, lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? tint : .clear))
            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                .scaleEffect(on ? 1 : 0.2).opacity(on ? 1 : 0)
        }
        .frame(width: 18, height: 18)
        .animation(.spring(duration: 0.25, bounce: 0.2), value: on)
    }
}

struct Tag: View {
    var text: String
    var color: Color? = nil
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill((color ?? .secondary).opacity(0.16)))
            .foregroundStyle(color ?? .secondary)
    }
}

struct ClassTag: View {
    var cls: SafetyClass
    var body: some View { Tag(text: cls.label, color: cls.color) }
}

// MARK: - Icons and thumbnails

@MainActor
enum IconCache {
    static var store: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = store[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: Paths.expand(path))
        store[path] = i
        return i
    }
}

/// The real icon Finder shows for an app, file or folder.
struct FileIcon: View {
    var path: String
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: IconCache.icon(path)).resizable().interpolation(.high).frame(width: size, height: size)
    }
}

/// Quick Look's thumbnail when there is one (photos, videos, PDFs), the Finder icon otherwise.
struct Thumbnail: View {
    var path: String
    var size: CGFloat = 40
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } else { FileIcon(path: path, size: size) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: path) {
            let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: Paths.expand(path)), size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let r = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                withAnimation(.easeOut(duration: 0.2)) { image = r.nsImage }
            }
        }
    }
}

/// A tool's real app icon (installed app, found by bundle ID). Tools without an app get their SF Symbol.
struct ToolBadge: View {
    var tool: AITool?
    var name: String
    var size: CGFloat = 22
    static let bundleIDs: [String: [String]] = [
        "Cursor": ["com.todesktop.230313mzl4w4u92"], "Windsurf": ["com.exafunction.windsurf"], "Antigravity": ["com.google.antigravity"],
        "Claude": ["com.anthropic.claudefordesktop"], "Claude Code": ["com.anthropic.claudefordesktop"], "Codex": ["com.openai.codex", "com.openai.chat"],
        "ChatGPT": ["com.openai.chat"], "LM Studio": ["ai.elementlabs.lmstudio"], "Ollama": ["com.electron.ollama"], "OpenCode": ["ai.opencode.desktop"],
        "Qoder": ["com.qoder.ide"],
    ]
    static let symbols: [String: String] = ["Claude Code": "terminal.fill", "Cursor": "cursorarrow.rays", "Windsurf": "wind", "Antigravity": "arrow.up.forward.circle.fill",
                                            "OpenClaw": "terminal.fill", "GitHub Copilot CLI": "chevron.left.forwardslash.chevron.right", "Hugging Face": "face.smiling",
                                            "OpenCode": "chevron.left.forwardslash.chevron.right", "Ollama": "cube.fill", "Qoder": "q.square.fill"]
    var appPath: String? {
        if let p = tool?.appPath { return p }
        for id in Self.bundleIDs[name] ?? [] { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u.path } }
        return nil
    }
    var body: some View {
        if let p = appPath {
            FileIcon(path: p, size: size)
        } else {
            // No app to borrow an icon from: the tool's symbol on a neutral disc, like a generic Finder item.
            Image(systemName: Self.symbols[name] ?? "terminal")
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
        }
    }
}

/// The installed app a row names, so held items such as "OrbStack container data" show OrbStack's icon.
@MainActor
enum AppIconLookup {
    static let apps: [(String, String)] = (Paths.children("/Applications") + Paths.children(HOME + "/Applications"))
        .filter { $0.hasSuffix(".app") }.map { (Paths.name($0).replacingOccurrences(of: ".app", with: "").lowercased(), $0) }
        .sorted { $0.0.count > $1.0.count }
    static func path(for title: String) -> String? {
        let t = title.lowercased()
        return apps.first { $0.0.count > 2 && t.contains($0.0) }?.1
    }
}

// MARK: - Lists and footer

struct ListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .glass()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct RowDivider: View { var body: some View { Rectangle().fill(Palette.hair).frame(height: 1) } }

/// The screen's one action, on a floating Liquid Glass bar.
struct FooterBar: View {
    @Environment(AppModel.self) var model
    var bytes: Int64
    var count: Int
    var label: String
    var note: String
    var enabled: Bool = true
    var action: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(Fmt.bytes(bytes)).font(.system(size: 15, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
                    Text("selected · \(count) item\(count == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.safeMode {
                Label("Safe mode", systemImage: "shield.lefthalf.filled").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ok)
                    .help("Nothing is removed while Safe mode is on. Turn it off in Settings.")
            }
            Button(label, action: action).buttonStyle(.glassProminent).controlSize(.large).disabled(bytes == 0 && count == 0 || !enabled)
        }
        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 24).padding(.bottom, 14).padding(.top, 6)
        .animation(.snappy, value: bytes)
    }
}

/// Apple's empty-state layout with the module's liquid icon above the title and a line of explanation.
struct EmptyState<Actions: View>: View {
    @Environment(AppModel.self) var model
    var symbol: String
    var title: String
    var text: String
    @ViewBuilder var actions: Actions
    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 14) {
                LiquidIcon(route: model.route, size: 84)
                Text(title).font(.system(size: 19, weight: .semibold))
            }
        } description: { Text(text) } actions: { actions }
            .frame(maxWidth: .infinity).padding(.vertical, 28)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, text: String) { self.init(symbol: symbol, title: title, text: text) { EmptyView() } }
}

struct NotScannedYet: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if model.phase == .scanning {
            EmptyState(symbol: "magnifyingglass", title: "Scanning…", text: "Results appear here as soon as this part of the scan finishes.") { ProgressView().controlSize(.small) }
        } else {
            EmptyState(symbol: model.route.symbol, title: "Not scanned yet", text: "Run a Checkup to scan your Mac. Nothing is changed while it scans.") {
                Button("Scan Now") { model.scanAll() }.buttonStyle(.glassProminent).controlSize(.large)
            }
        }
    }
}

/// Hover highlight for list rows without changing layout.
struct RowHover: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content.background(Color.primary.opacity(hover ? 0.05 : 0)).onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}
extension View { func rowHover() -> some View { modifier(RowHover()) } }

extension Color {
    func mix(with other: Color, by f: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white, b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        return Color(red: a.redComponent + (b.redComponent - a.redComponent) * f, green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f)
    }
}

func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.expand(path))]) }

/// Kind of file in plain words: "Disk image", "MPEG-4 movie", "VMware virtual machine".
func fileKind(_ path: String) -> String {
    let url = URL(fileURLWithPath: Paths.expand(path))
    if let t = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, let d = t.localizedDescription { return d.prefix(1).uppercased() + d.dropFirst() }
    return url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased() + " file"
}

func opensWith(_ path: String) -> (name: String, path: String)? {
    guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: Paths.expand(path))) else { return nil }
    return ((app.lastPathComponent as NSString).deletingPathExtension, app.path)
}
