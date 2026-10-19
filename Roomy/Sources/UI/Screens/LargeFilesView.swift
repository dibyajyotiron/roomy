import SwiftUI
import QuickLook
import Pow

/// A one-time warning in front of screens where you choose your own files to remove.
struct AdvancedGate<Content: View>: View {
    enum Kind { case large, lens }
    @Environment(AppModel.self) var model
    var kind: Kind
    @ViewBuilder var content: Content
    @State private var agree = false

    var acknowledged: Bool { Demo.on || (kind == .large ? model.ackLarge : model.ackLens) }

    var body: some View {
        if acknowledged { content } else {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 46)).foregroundStyle(Palette.warn)
                    .symbolEffect(.bounce, value: agree)
                Text("For advanced users").font(.system(size: 26, weight: .bold))
                VStack(alignment: .leading, spacing: 10) {
                    Text(kind == .large
                         ? "This screen lists your own files: videos, disk images, virtual machines, archives and documents. Roomy can't know whether a file is the only copy, still in use, or important to you."
                         : "Disk Map lets you remove your own files and folders. Roomy can't know whether something is the only copy, still in use, or important to you.")
                    Text("Removed files go to the Trash, but anything you empty from the Trash is gone. Check every item before you remove it. If you're not sure what something is, leave it.")
                    Text("You are responsible for what you choose to remove. Data loss caused by removing files you didn't understand isn't covered by Roomy.")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 13.5)).foregroundStyle(Palette.ink2).lineSpacing(3)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(20).glass(14)
                Toggle(isOn: $agree.animation(.snappy)) { Text("I understand, and I take responsibility for what I remove.") }
                    .toggleStyle(.checkbox).font(.system(size: 13))
                HStack(spacing: 10) {
                    Button("Go Back") { model.route = .care }.buttonStyle(.glass).controlSize(.extraLarge)
                    Button("Continue") { withAnimation(.smooth) { if kind == .large { model.ackLarge = true } else { model.ackLens = true } } }
                        .buttonStyle(.glassProminent).controlSize(.extraLarge).disabled(!agree)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        }
    }
}

struct LargeFilesView: View {
    @Environment(AppModel.self) var model
    @State private var sort = 0
    @State private var kind = "All"
    @State private var preview: URL?
    @State private var confirm = false

    struct Info { var kind: String; var group: String; var risk: String; var tone: Color; var locked: Bool }

    static func info(_ f: LargeFile) -> Info {
        let ext = (f.path as NSString).pathExtension.lowercased()
        let k = fileKind(f.path)
        if f.path.hasSuffix(".photoslibrary") { return Info(kind: "Photos library", group: "Other", risk: "Your whole photo library. Manage it in Photos.", tone: Palette.bad, locked: true) }
        if f.insideAppData || (!f.isPackage && !CleanupEngine.isUserFile(Paths.expand(f.path))) { return Info(kind: k, group: "Locked", risk: f.path.lowercased().contains("postgres") || f.path.lowercased().contains("mysql") ? "Part of a database. Removing one file corrupts the database, so it stays." : "Outside your own folders, or inside app data. Remove it from the app that owns it.", tone: Palette.ink3, locked: true) }
        if ["vmwarevm", "pvm", "utm"].contains(ext) { return Info(kind: "Virtual machine", group: "Virtual machines", risk: "A whole computer, with its own files inside. Delete it from the app that made it.", tone: Palette.bad, locked: false) }
        if ["dmg", "pkg", "mpkg", "iso", "xip"].contains(ext) { return Info(kind: k, group: "Installers & archives", risk: "An installer. Usually safe to remove once the app is installed.", tone: Palette.ok, locked: false) }
        if ["zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz"].contains(ext) { return Info(kind: k, group: "Installers & archives", risk: "An archive. Check you've kept what's inside before removing it.", tone: Palette.warn, locked: false) }
        if ["mov", "mp4", "m4v", "mkv", "avi", "webm", "mxf", "braw", "r3d"].contains(ext) { return Info(kind: k, group: "Videos", risk: "A video. Make sure it's backed up or a copy.", tone: Palette.warn, locked: false) }
        if ["sqlite", "db", "sql", "dump", "bak", "realm", "mdb"].contains(ext) { return Info(kind: k, group: "Databases & backups", risk: "Data an app or a project may still need. Check before removing.", tone: Palette.bad, locked: false) }
        if ["gguf", "safetensors", "bin", "pt", "ckpt", "onnx", "mlmodel"].contains(ext) { return Info(kind: "AI model or binary data", group: "Other", risk: "May be a model a tool loads. Remove it from that tool if you can.", tone: Palette.warn, locked: false) }
        return Info(kind: k, group: "Documents & other", risk: "Your file. Open it with Quick Look if you're not sure what it is.", tone: Palette.warn, locked: false)
    }

    var files: [LargeFile] {
        let l = model.snap.largeFiles.filter { kind == "All" || Self.info($0).group == kind }
        switch sort {
        case 1: return l.sorted { ($0.lastOpened ?? .distantPast) < ($1.lastOpened ?? .distantPast) }
        default: return l.sorted { $0.bytes > $1.bytes }
        }
    }

    var selected: [LargeFile] { model.snap.largeFiles.filter { model.selection.contains("large:" + $0.path) } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Large & Old Files", subtitle: "Files over 100 MB, or untouched for a year. Only files in your own folders can be selected.", value: model.snap.largeFiles.isEmpty ? nil : Fmt.bytes(model.snap.largeFiles.filter { !Self.info($0).locked }.reduce(0) { $0 + $1.bytes }), valueCaption: "you can review") {
                Picker("Sort", selection: $sort) { Text("Largest").tag(0); Text("Oldest").tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            if model.snap.scannedAt == nil { NotScannedYet(); Spacer() } else {
                Notice(symbol: "exclamationmark.triangle", tint: Palette.warn,
                       text: "For advanced users. Check each file with Quick Look before you remove it. Files go to the Trash; once you empty it, they're gone.")
                    .padding(.horizontal, 28).padding(.bottom, 10)
                kindChips.padding(.horizontal, 28).padding(.bottom, 10)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                            if i > 0 { RowDivider() }
                            row(f).transition(.movingParts.vanish(Palette.accent.opacity(0.5)))
                        }
                    }
                    .glass().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
                FooterBar(bytes: selected.reduce(0) { $0 + $1.bytes }, count: selected.count, label: "Move to Trash", note: "You can put them back from the Trash") { confirm = true }
            }
        }
        .quickLookPreview($preview)
        .confirmationDialog("Move \(selected.count) file\(selected.count == 1 ? "" : "s") to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) {
                let s = selected
                Task { await model.clean("Large & Old Files", targets: s.map { Actions.Target(path: $0.path, bytes: $0.bytes) }) { model.selection.subtract(s.map { "large:" + $0.path }) } }
            }
        } message: { Text(selected.prefix(5).map { Paths.name($0.path) }.joined(separator: ", ") + (selected.count > 5 ? "…" : "")) }
    }

    var kindChips: some View {
        let groups = Dictionary(grouping: model.snap.largeFiles, by: { Self.info($0).group }).mapValues { $0.reduce(0) { $0 + $1.bytes } }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(["All"] + groups.keys.sorted { groups[$0]! > groups[$1]! }, id: \.self) { g in
                    let on = kind == g
                    Button { withAnimation(.snappy) { kind = g } } label: {
                        HStack(spacing: 6) { Text(g).foregroundStyle(Palette.ink2); Text(Fmt.bytes(g == "All" ? model.snap.largeFiles.reduce(0) { $0 + $1.bytes } : groups[g]!)).fontWeight(.semibold).monospacedDigit() }
                            .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 26)
                            .background(Capsule().fill(on ? Palette.accent.opacity(0.16) : Palette.fill))
                            .overlay(Capsule().strokeBorder(on ? Palette.accent.opacity(0.6) : .clear))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    func row(_ f: LargeFile) -> some View {
        let inf = Self.info(f)
        let id = "large:" + f.path
        let on = model.selection.contains(id)
        let app = opensWith(f.path)
        let crumbs = Paths.short(Paths.parent(f.path)).replacingOccurrences(of: "~/", with: "").split(separator: "/").suffix(3).joined(separator: " › ")
        return HStack(spacing: 12) {
            if inf.locked { Image(systemName: "lock.fill").foregroundStyle(Palette.ink3).frame(width: 20) }
            else { Button { model.toggle(id) } label: { CheckMark(on: on, tint: Palette.warn) }.buttonStyle(.plain).frame(width: 20) }
            Thumbnail(path: f.path, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(Paths.name(f.path)).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(inf.kind).foregroundStyle(Palette.ink2)
                    Text("·"); Text(crumbs.isEmpty ? "Home" : crumbs).lineLimit(1)
                    Text("·"); Text("Opened \(Fmt.ago(f.lastOpened).lowercased())")
                }
                .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                HStack(spacing: 6) {
                    Circle().fill(inf.tone).frame(width: 6, height: 6)
                    Text(inf.risk).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let app {
                HStack(spacing: 5) { FileIcon(path: app.path, size: 16); Text(app.name).font(.system(size: 11)).foregroundStyle(Palette.ink3).lineLimit(1) }
                    .frame(maxWidth: 140, alignment: .trailing).help("Opens with \(app.name)")
            }
            Button { preview = URL(fileURLWithPath: Paths.expand(f.path)) } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help("Quick Look")
            Button { reveal(f.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
            Text(Fmt.bytes(f.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(on ? Palette.warn.opacity(0.07) : .clear)
        .rowHover()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { preview = URL(fileURLWithPath: Paths.expand(f.path)) }
    }
}
