import SwiftUI

/// Disk Map: the disk as bubbles, the folder as a list beside them. Point at anything to learn what it is; click a
/// folder to open it. Like Mole's Analyze, anything can go to the Trash except what macOS, another account or a
/// running app depends on, and those say why.
struct DiskMapView: View {
    @Environment(AppModel.self) var model
    @State private var stack: [LensNode] = []
    @State private var kids: [LensNode] = []
    @State private var hover: LensNode?
    @State private var picked: [String: LensNode] = [:]
    @State private var loading = false
    @State private var confirm = false

    var node: LensNode? { stack.last }
    var visible: [LensNode] { kids.filter { $0.bytes > 0 } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Disk Map", subtitle: "Point at a bubble to see what it is. Click a folder to open it, and pick what you no longer need.")
            if model.snap.lens == nil { NotScannedYet(); Spacer() } else {
                path.padding(.horizontal, 28).padding(.bottom, 10)
                HStack(alignment: .top, spacing: 18) {
                    list.frame(minWidth: 320, idealWidth: 360, maxWidth: 400)
                    VStack(spacing: 8) {
                        BubbleField(items: visible, picked: Set(picked.keys), onOpen: open, onBack: stack.count > 1 ? back : nil, hover: $hover, tip: tip)
                            .contextMenu { if let k = hover { menu(k) } }
                        legend
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 12)
                let items = Array(picked.values)
                FooterBar(bytes: items.reduce(0) { $0 + $1.bytes }, count: items.count, label: "Move to Trash…",
                          note: items.isEmpty ? "Select items in the list, or right-click a bubble" : "Everything goes to the Trash, so you can put it back") { confirm = true }
            }
        }
        .task(id: model.snap.lens?.bytes) { if stack.isEmpty, let r = model.snap.lens { await load([r]) } }
        .confirmationDialog("Move \(picked.count) item\(picked.count == 1 ? "" : "s") to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) {
                let items = Array(picked.values)
                Task {
                    // You picked these yourself in the map, so an app you chose may go to the Trash too.
                    await model.clean("Disk Map", targets: items.map { Actions.Target(path: $0.path, bytes: $0.bytes) }, allowApps: true) {
                        let gone = Set(items.map(\.id)); kids.removeAll { gone.contains($0.id) }; picked = [:]
                    }
                }
            }
        } message: {
            let items = picked.values.sorted { $0.bytes > $1.bytes }
            let names = items.prefix(5).map(\.display).joined(separator: ", ") + (items.count > 5 ? " and \(items.count - 5) more" : "")
            Text(items.contains { $0.cls == .appdata } ? "\(names).\n\nSome of these belong to apps. The app that uses them may lose settings or data." : names)
        }
    }

    // MARK: navigation

    func load(_ s: [LensNode]) async {
        stack = s; hover = nil
        guard let n = s.last else { return }
        loading = true
        kids = n.path == "/" && n.other ? DiskMapEngine.macOSParts(of: n, storage: model.snap.storage) : await model.lensChildren(n)
        loading = false
    }

    func canOpen(_ n: LensNode) -> Bool { n.isDir && !n.other || (n.path == "/" && n.other) }

    func open(_ n: LensNode) {
        if canOpen(n) { Task { await load(stack + [n]) } }
        else if lock(n) == nil { toggle(n) }
    }

    func back() { Task { await load(Array(stack.dropLast())) } }

    /// Why an item can't be picked, or nil when it can.
    func lock(_ n: LensNode) -> String? {
        if n.other { return n.path == "/" ? "macOS manages all of this. Open it to see the parts." : n.name == "Smaller items" ? "Many small items together. Open the folder to choose among them." : "macOS manages this." }
        switch n.cls {
        case .system, .hidden: return "Part of macOS. Shown so you know where the space goes."
        case .app: return "An app. Remove it with the Uninstaller so its leftovers go too."
        default: return Actions.trashLock(n.path)
        }
    }

    func toggle(_ n: LensNode) { if picked[n.id] == nil { picked[n.id] = n } else { picked[n.id] = nil } }

    func tip(_ n: LensNode) -> BubbleTip.Info {
        let l = lock(n), o = canOpen(n)
        let hint = o ? (l == nil ? "Click to open · right-click to select" : "Click to open. " + l!) : (l ?? "Click to select it for the Trash")
        return .init(title: n.display, bytes: n.bytes, kind: [n.cls.label, n.owner].compactMap { $0 }.joined(separator: " · "), color: n.cls.color,
                     why: n.why, hint: hint, locked: l != nil)
    }

    @ViewBuilder func menu(_ k: LensNode) -> some View {
        if canOpen(k) { Button("Open") { open(k) } }
        if lock(k) == nil { Button(picked[k.id] == nil ? "Select for the Trash" : "Deselect") { toggle(k) } }
        if k.cls == .app { Button("Uninstall…") { model.route = .uninstaller } }
        if !k.other && !k.path.hasPrefix("macos:") {
            Divider()
            Button("Show in Finder") { reveal(k.path) }
        }
    }

    // MARK: parts

    var path: some View {
        HStack(spacing: 6) {
            Button { back() } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                .buttonStyle(.borderless).disabled(stack.count < 2).help("Back")
            ForEach(Array(stack.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
                Button(i == 0 ? model.snap.disk.name : s.display) { Task { await load(Array(stack.prefix(i + 1))) } }
                    .buttonStyle(.plain).font(.system(size: 13, weight: i == stack.count - 1 ? .semibold : .regular))
                    .foregroundStyle(i == stack.count - 1 ? .primary : .secondary)
            }
            if loading { ProgressView().controlSize(.small).padding(.leading, 6) }
            Spacer()
            if let n = node { Text("\(Fmt.bytes(n.bytes)) in \(visible.count) item\(visible.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit() }
        }
    }

    var legend: some View {
        // The hint gives way first when the map is narrow; the colour keys never wrap.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                keys
                Spacer(minLength: 8)
                Text(stack.count > 1 ? "Drag a bubble to throw it · click empty space to go back" : "Drag a bubble to throw it").lineLimit(1)
            }
            HStack(spacing: 12) { keys; Spacer(minLength: 0) }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    @ViewBuilder var keys: some View {
        ForEach([SafetyClass.clean, .user, .appdata, .app, .system], id: \.self) { c in
            HStack(spacing: 5) { Circle().fill(c.color).frame(width: 7, height: 7); Text(c.label).lineLimit(1) }.fixedSize()
        }
    }

    var list: some View {
        let mx = max(1, visible.map(\.bytes).max() ?? 1)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, k in
                    if i > 0 { RowDivider().padding(.leading, 46) }
                    LensRow(node: k, share: Double(k.bytes) / Double(mx), lock: lock(k), canOpen: canOpen(k), picked: picked[k.id] != nil,
                            highlighted: hover?.id == k.id, toggle: { toggle(k) }, open: { open(k) })
                        .onHover { h in hover = h ? k : (hover?.id == k.id ? nil : hover) }
                        .contextMenu { menu(k) }
                }
                if visible.isEmpty && !loading {
                    Text("Nothing over 100 MB here.").font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
                }
            }
        }
        .glass()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One item in the folder: its Finder icon, name and size; a checkbox when it can go, a lock that says why when it can't.
struct LensRow: View {
    var node: LensNode
    var share: Double
    var lock: String?
    var canOpen: Bool
    var picked: Bool
    var highlighted: Bool
    var toggle: () -> Void
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if lock == nil {
                    Button(action: toggle) { CheckMark(on: picked) }.buttonStyle(.plain).help(picked ? "Deselect" : "Select for the Trash")
                } else {
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(.tertiary).help(lock!)
                }
            }
            .frame(width: 18)
            FileIcon(path: node.other || node.path.hasPrefix("macos:") ? "/System" : node.path, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.display).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(node.cls.color).frame(width: 6, height: 6)
                    Text(node.cls.label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if hovering && !node.other && !node.path.hasPrefix("macos:") {
                Button { reveal(node.path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.bytes(node.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Capsule().fill(node.cls.color.opacity(0.7)).frame(width: max(3, share * 72), height: 3)
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).opacity(canOpen ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(highlighted || hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityHint(lock ?? (canOpen ? "Opens the folder" : "Selects it for the Trash"))
    }
}
