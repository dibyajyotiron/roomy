import SwiftUI

/// The same colours System Settings › Storage uses: saturated system colours that adapt to light and dark.
enum SegmentColor {
    static let map: [String: Color] = [
        "others": Color(nsColor: .systemRed), "apps": Color(nsColor: .systemOrange), "docs": Color(nsColor: .systemYellow),
        "photos": Color(nsColor: .systemGreen), "messages": Color(nsColor: .systemMint), "icloud": Color(nsColor: .systemTeal),
        "mail": Color(nsColor: .systemBlue), "podcasts": Color(nsColor: .systemPurple), "developer": Color(nsColor: .systemIndigo),
        "sysdata": Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil ? NSColor(white: 0.52, alpha: 1) : NSColor(white: 0.50, alpha: 1) }),
        "macos": Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil ? NSColor(white: 0.38, alpha: 1) : NSColor(white: 0.64, alpha: 1) }),
    ]
    static func of(_ k: String) -> Color { map[k] ?? .gray }
}

struct Stripes: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.28)))
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path(); p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(p, with: .color(.gray.opacity(0.7)), lineWidth: 2.5)
                x += 7
            }
        }
    }
}

/// Disk bar coloured by System Settings' categories, with what's hidden from apps shown as stripes.
struct StorageBar: View {
    var report: StorageReport
    var disk: DiskInfo
    var height: CGFloat
    var selected: String?
    var onSelect: ((String) -> Void)? = nil

    struct Part: Identifiable { var id: String; var name: String; var bytes: Int64; var hidden = false }
    var parts: [Part] {
        var out: [Part] = []
        for s in report.segments {
            if s.key == "sysdata" {
                out.append(Part(id: "sysdata", name: "System Data", bytes: (s.bytes ?? 0) - report.hiddenBytes))
                if report.hiddenBytes > 0 { out.append(Part(id: "hidden", name: report.measuredWithAccess == true ? "Only macOS can see" : "Not visible yet", bytes: report.hiddenBytes, hidden: true)) }
            } else if let b = s.bytes, b > 0 { out.append(Part(id: s.key, name: s.name, bytes: b)) }
        }
        return out
    }

    @State private var hover: String?

    private func frames(_ width: CGFloat, gap: CGFloat) -> [(part: Part, x: CGFloat, w: CGFloat)] {
        let total = Double(max(1, disk.total))
        var x: CGFloat = 0
        return parts.map { p in
            let w = max(2, width * Double(p.bytes) / total - gap)
            defer { x += w + gap }
            return (p, x, w)
        }
    }

    var body: some View {
        GeometryReader { g in
            let gap: CGFloat = height > 10 ? 1.5 : 1
            let laid = frames(g.size.width, gap: gap)
            let tips = height >= 10
            ZStack(alignment: .topLeading) {
                HStack(spacing: gap) {
                    if parts.isEmpty {
                        Capsule().fill(Palette.fill).overlay(alignment: .leading) {
                            Capsule().fill(Palette.accent).frame(width: g.size.width * Double(disk.used) / Double(max(1, disk.total)))
                        }
                    } else {
                        ForEach(laid, id: \.part.id) { f in
                            let key = f.part.id == "hidden" ? "sysdata" : f.part.id
                            Group {
                                if f.part.hidden { Stripes() } else { Rectangle().fill(SegmentColor.of(f.part.id)) }
                            }
                            .frame(width: f.w)
                            .brightness(hover == f.part.id ? 0.06 : 0)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect?(key) }
                            .help(tips ? "" : "\(f.part.name): \(Fmt.bytes(f.part.bytes))")
                        }
                        Spacer(minLength: 0)
                    }
                }
                .background(Palette.fill)
                .clipShape(RoundedRectangle(cornerRadius: height / 2.6, style: .continuous))
                .onContinuousHover { phase in
                    guard tips else { return }
                    switch phase {
                    case .active(let pt): hover = laid.first { pt.x >= $0.x && pt.x <= $0.x + $0.w + gap }?.part.id
                    case .ended: hover = nil
                    }
                }
                // A small caret under the segment that's open in the list.
                if let sel = selected, let f = laid.first(where: { ($0.part.id == "hidden" ? "sysdata" : $0.part.id) == sel && !$0.part.hidden }) {
                    Triangle().fill(Color.primary.opacity(0.55)).frame(width: 9, height: 5)
                        .position(x: f.x + f.w / 2, y: height + 6)
                }
                // Apple-style tooltip: name and size, springing between segments as the pointer moves.
                if tips, let h = hover, let f = laid.first(where: { $0.part.id == h }) {
                    SegmentTip(name: f.part.name, bytes: f.part.bytes, color: f.part.hidden ? .gray : SegmentColor.of(f.part.id))
                        .fixedSize()
                        .position(x: min(max(f.x + f.w / 2, 70), g.size.width - 70), y: -30)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(duration: 0.32, bounce: 0.18), value: hover)
            .animation(.spring(duration: 0.4, bounce: 0.15), value: selected)
        }
        .frame(height: height)
        .zIndex(1)
    }
}

/// The hover bubble: a soft rounded card with a pointer, like the one in System Settings › Storage.
struct SegmentTip: View {
    var name: String
    var bytes: Int64
    var color: Color
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(.system(size: 12, weight: .semibold))
            }
            Text(Fmt.bytes(bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(bytes)))
        }
        .padding(.horizontal, 11).padding(.top, 6).padding(.bottom, 11)
        .background {
            TipShape().fill(.regularMaterial)
                .overlay(TipShape().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        }
    }
}

struct TipShape: Shape {
    func path(in r: CGRect) -> Path {
        let arrow: CGFloat = 6, body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - arrow)
        var p = Path(roundedRect: body, cornerRadius: 9, style: .continuous)
        p.move(to: CGPoint(x: r.midX - 7, y: body.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX + 7, y: body.maxY))
        p.closeSubpath()
        return p
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p
    }
}

struct StorageView: View {
    @Environment(AppModel.self) var model
    @State private var sel = "sysdata"
    @State private var expanded: Set<String> = []

    var body: some View {
        let r = model.snap.storage
        let d = model.snap.disk
        VStack(spacing: 0) {
            ScreenHeader(title: "Storage", subtitle: "The same categories as System Settings › Storage, with what's inside each one. Nothing here deletes: each row sends you to the tool that removes it safely.", value: Fmt.bytes(model.snap.disk.free), valueCaption: "free")
            if r.segments.isEmpty { NotScannedYet(); Spacer() } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(d.name).font(.system(size: 15, weight: .bold))
                        Spacer()
                        Text("\(Fmt.bytes(d.used)) of \(Fmt.bytes(d.total)) used · \(Fmt.bytes(d.free)) free").font(.system(size: 13)).monospacedDigit().foregroundStyle(Palette.ink2)
                    }
                    StorageBar(report: r, disk: d, height: 22, selected: sel) { k in withAnimation(.snappy) { sel = k; expanded = [] } }
                    legend(r)
                }
                .padding(.horizontal, 28)
                HStack(alignment: .top, spacing: 14) {
                    segmentList(r).frame(width: 250)
                    if let seg = r.segments.first(where: { $0.key == sel }) { detail(seg, r).id(seg.key).transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)).animation(.easeOut(duration: 0.2)), removal: .identity)) }
                }
                .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 20)
                .animation(.snappy, value: sel)
            }
        }
    }

    func legend(_ r: StorageReport) -> some View {
        let bar = StorageBar(report: r, disk: model.snap.disk, height: 1, selected: nil)
        return FlowLayout(spacing: 14, line: 6) {
            ForEach(bar.parts) { p in
                let key = p.id == "hidden" ? "sysdata" : p.id
                Button { withAnimation(.snappy) { sel = key } } label: {
                    HStack(spacing: 6) {
                        Group { if p.hidden { Stripes() } else { SegmentColor.of(p.id) } }.frame(width: 9, height: 9).clipShape(Circle())
                        Text(p.name).foregroundStyle(sel == key ? .primary : .secondary).fontWeight(sel == key ? .semibold : .regular)
                        Text(Fmt.bytes(p.bytes)).monospacedDigit().foregroundStyle(Palette.ink3)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    func segmentList(_ r: StorageReport) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(r.segments.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { RowDivider() }
                    Button { withAnimation(.snappy) { sel = s.key; expanded = [] } } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3).fill(SegmentColor.of(s.key)).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.system(size: 13, weight: .medium))
                                Text(s.needsAccess ? (model.hasFullDiskAccess ? "Scan again to measure" : "Needs Full Disk Access") : s.locked ? "Locked · part of macOS" : s.key == "sysdata" ? "\(Fmt.bytes(r.hiddenBytes)) \(r.measuredWithAccess == true ? "only macOS can see" : "not visible yet")" : "\(s.children.count) item\(s.children.count == 1 ? "" : "s")")
                                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                            }
                            Spacer()
                            Text(s.bytes.map(Fmt.bytes) ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink3)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(sel == s.key ? SegmentColor.of(s.key).opacity(0.16) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .glass().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func detail(_ s: StorageSegment, _ r: StorageReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(s.name).font(.system(size: 19, weight: .bold))
                    Text(s.bytes.map(Fmt.bytes) ?? "Size hidden").font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink2)
                    if s.locked { ClassTag(cls: .system) }
                }
                if s.key == "sysdata" {
                    Text("\(Fmt.bytes((s.bytes ?? 0) - r.hiddenBytes)) named below + \(Fmt.bytes(r.hiddenBytes)) \(r.measuredWithAccess == true ? "only macOS can see" : "not visible yet")")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.ink3)
                }
                Text(s.what).font(.system(size: 13)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                if let v = s.versusApple {
                    HStack(alignment: .top, spacing: 8) {
                        Text("vs. System Settings").fontWeight(.semibold)
                        Text(v).foregroundStyle(Palette.ink2)
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 2)
                }
                if s.needsAccess {
                    if model.hasFullDiskAccess {
                        Notice(symbol: "checkmark.shield", tint: Palette.ok,
                               text: "Full Disk Access is on now. Scan again to measure \(s.name).",
                               action: model.canScan ? ("Scan Again", { model.scanAll() }) : nil)
                    } else {
                        Notice(symbol: "lock.shield", tint: Palette.warn,
                               text: "macOS keeps \(s.name) private. Apps can't read its size until you allow Full Disk Access. Roomy only reads sizes; it never opens your messages or photos.",
                               action: ("Open Privacy & Security", openFDA))
                    }
                }
                if s.key == "sysdata" && r.measuredWithAccess != true && model.hasFullDiskAccess {
                    Notice(symbol: "checkmark.shield", tint: Palette.ok,
                           text: "Full Disk Access is on now. Scan again and most of what's \"not visible yet\" gets measured and named.",
                           action: model.canScan ? ("Scan Again", { model.scanAll() }) : nil)
                }
                if !s.children.isEmpty {
                    ListCard {
                        ForEach(Array(s.children.enumerated()), id: \.element.id) { i, c in
                            if i > 0 { RowDivider() }
                            itemRow(c, key: "\(i)")
                            if expanded.contains("\(i)"), let kids = c.children {
                                ForEach(kids) { k in RowDivider(); itemRow(k, key: "\(i)>\(k.id)", indent: true) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 18)
        }
    }

    func itemRow(_ c: StorageItem, key: String, indent: Bool = false) -> some View {
        let locked = c.cls == .system || c.cls == .hidden
        return HStack(spacing: 12) {
            Image(systemName: locked ? "lock.fill" : c.cls == .app ? "square.grid.2x2" : c.cls == .clean ? "arrow.3.trianglepath" : c.cls == .appdata ? "shippingbox" : "folder")
                .font(.system(size: 12)).foregroundStyle(Palette.ink3).frame(width: 18)
            if c.cls == .app || c.path.hasSuffix(".app") { FileIcon(path: c.path, size: 24) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { Text(c.name).font(.system(size: 13, weight: .medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true); ClassTag(cls: c.cls) }
                Text(c.why).font(.system(size: 11)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
                let kids = indent ? nil : c.children
                if c.action != nil || kids != nil {
                    HStack(spacing: 12) {
                        if let a = c.action { actionButton(a, c).controlSize(.small) }
                        if let kids {
                            Button(expanded.contains(key) ? "Hide" : "Show \(kids.count)") { withAnimation(.snappy) { if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) } } }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            if c.action == nil && locked { Text("Locked").font(.system(size: 11)).foregroundStyle(Palette.ink3) }
            Text(c.bytes.map(Fmt.bytes) ?? "Hidden").font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(minWidth: 68, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .padding(.leading, indent ? 30 : 0)
        .background(indent ? Color.primary.opacity(0.04) : .clear)
    }

    @ViewBuilder func actionButton(_ a: StorageAction, _ c: StorageItem) -> some View {
        switch a {
        case .uninstall: Button("Uninstall…") { model.route = .uninstaller }.buttonStyle(.bordered)
        case .open(let r): Button("Open \(Route(rawValue: r)?.title ?? r)") { if let rt = Route(rawValue: r) { model.route = rt } }.buttonStyle(.bordered)
        case .evict: Button("Remove download") { model.flash("Use Finder: right-click the folder › Remove Download. The files stay in iCloud.") }.buttonStyle(.bordered)
        case .diskMap: Button("Show in Disk Map") { model.route = .lens }.buttonStyle(.bordered)
        case .grantAccess:
            if model.hasFullDiskAccess { Button("Scan Again") { model.scanAll() }.buttonStyle(.bordered).disabled(!model.canScan) }
            else { Button("Grant Full Disk Access", action: openFDA).buttonStyle(.glassProminent) }
        case .openApp(let n): Button("Open \(n)") { reveal(c.path) }.buttonStyle(.bordered)
        }
    }

    func openFDA() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
}

/// Wraps its children onto new lines, like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var line: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > w { x = 0; y += h + line; h = 0 }
            x += sz.width + spacing; h = max(h, sz.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(w, maxX), height: y + h)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, h: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += h + line; h = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; h = max(h, sz.height)
        }
    }
}
