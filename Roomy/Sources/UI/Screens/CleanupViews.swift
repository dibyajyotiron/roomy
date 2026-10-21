import SwiftUI
import Pow

/// One selectable row. `held` and `locked` rows are shown so you know where space goes but can't be selected.
struct ItemRow: View {
    enum Mode { case select, held(String), locked(String), managed(String) }
    var path: String
    var title: String
    var subtitle: String
    var bytes: Int64?
    var mode: Mode = .select
    var on = false
    var icon: AnyView? = nil
    var toggle: () -> Void = {}

    var defaultIcon: AnyView {
        if path.hasPrefix("docker:"), let app = AppIconLookup.path(for: "docker") ?? AppIconLookup.path(for: "orbstack") {
            return AnyView(FileIcon(path: app, size: 36))
        }
        if path.hasPrefix("mole:"), let app = AppIconLookup.path(for: title) { return AnyView(FileIcon(path: app, size: 36)) }
        if path.hasPrefix("docker:") || path.hasPrefix("mole:") {
            return AnyView(Image(systemName: "gearshape.2.fill").font(.system(size: 20)).foregroundStyle(Palette.ink3))
        }
        return AnyView(FileIcon(path: path, size: 36))
    }

    var body: some View {
        Button(action: { if case .select = mode { toggle() } }) {
            HStack(spacing: 12) {
                Group {
                    switch mode {
                    case .select: CheckMark(on: on)
                    case .held: Image(systemName: "pause.circle").foregroundStyle(Palette.warn)
                    case .locked: Image(systemName: "lock.fill").foregroundStyle(Palette.ink3)
                    case .managed: Image(systemName: "house").foregroundStyle(Palette.ink3)
                    }
                }
                .frame(width: 22)
                (icon ?? defaultIcon)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Palette.ink3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 10)
                switch mode {
                case .held(let why): Tag(text: why, color: Palette.warn).frame(maxWidth: 280, alignment: .trailing)
                case .locked(let why), .managed(let why): Text(why).font(.system(size: 11)).foregroundStyle(Palette.ink3).lineLimit(2).frame(maxWidth: 300, alignment: .trailing)
                case .select: EmptyView()
                }
                Text(Fmt.bytes(bytes)).font(.system(size: 13.5, weight: .semibold, design: .rounded)).monospacedDigit().frame(minWidth: 72, alignment: .trailing)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHover()
        .contextMenu {
            if !path.hasPrefix("docker:") && !path.hasPrefix("mole:") { Button("Show in Finder") { reveal(path) } }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Paths.expand(path), forType: .string) }
        }
    }
}

struct CategoryScreen: View {
    @Environment(AppModel.self) var model
    var route: Route

    var cats: [CleanCategory] { route.categories.compactMap { model.snap.category($0) } }
    var moleBytes: Int64 { cats.flatMap(\.items).filter { $0.byMole == true }.reduce(0) { $0 + $1.bytes } }

    var subtitle: String {
        switch route {
        case .systemJunk: "Logs, system caches and temporary files macOS rebuilds."
        case .userCache: "App and browser caches that rebuild themselves. Caches of apps that are open right now are skipped."
        case .developer: "Xcode build products, Homebrew downloads, npm and pnpm stores, and Docker build cache. Mole applies its normal developer cleanup rules."
        case .mail: "Attachments Mail already downloaded. The messages stay in Mail and download them again when you open them."
        case .trash: "What's in your Trash bins, including on external drives. Mole's normal Clean also empties Trash unless protected by your Mole keep list."
        case .systemData: "Local Time Machine snapshots, failed backups, iPhone and iPad backups, firmware and update files."
        default: ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            let toReview = cats.flatMap(\.items).filter(\.review).reduce(0) { $0 + $1.bytes }
            ScreenHeader(title: route.title, subtitle: subtitle, value: cats.isEmpty ? nil : Fmt.bytes(cats.reduce(0) { $0 + $1.bytes }), valueCaption: "estimated by Mole",
                         valueDetail: toReview > 0 ? "\(Fmt.bytes(toReview)) waits for you to choose" : nil)
            if cats.isEmpty { NotScannedYet(); Spacer() } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !model.snap.cacheHolders.isEmpty && [.userCache, .developer].contains(route) {
                            Notice(symbol: "pause.circle", tint: Palette.warn,
                                   text: "Skipped while open: \(model.snap.cacheHolders.prefix(6).joined(separator: ", ")). Quit them and scan again to include their caches.")
                                .padding(.bottom, 4)
                        }
                        if route == .trash { TrashCard() }
                        ForEach(cats) { c in section(c) }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
                if moleBytes > 0 {
                    FooterBar(bytes: moleBytes, count: cats.flatMap(\.items).count, label: "Clean",
                              note: "Review together with Mole's other findings before running its normal Clean") {
                        model.cleanRequested = true
                        model.route = .care
                    }
                }
            }
        }
    }

    @ViewBuilder func section(_ c: CleanCategory) -> some View {
        if route.categories.count > 1 { SectionLabel(title: c.title, bytes: c.bytes, note: c.note) } else { Spacer().frame(height: 4) }
        if let b = c.blocked {
            Notice(symbol: "lock.shield", tint: Palette.warn, text: b, action: ("Open Privacy & Security", {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }))
        } else if let s = c.skipped {
            Notice(symbol: "moon.zzz", tint: Palette.ink3, text: s)
        }
        if !c.items.isEmpty {
            ListCard {
                ForEach(Array(c.items.enumerated()), id: \.element.id) { i, it in
                    if i > 0 { RowDivider() }
                    ItemRow(path: it.path, title: it.name, subtitle: [Paths.short(it.path).hasPrefix("docker:") ? nil : Paths.short(it.path), it.note].compactMap { $0 }.joined(separator: " · "),
                            bytes: it.bytes, mode: .managed("Preview · cleaned from Checkup"))
                        .transition(.movingParts.vanish(Palette.accent.opacity(0.5)))
                }
            }
        }
        if !c.held.isEmpty {
            SectionLabel(title: "Held back", note: "In use or needs a decision, so Roomy leaves it alone.")
            ListCard { ForEach(Array(c.held.enumerated()), id: \.element.id) { i, it in
                if i > 0 { RowDivider() }
                ItemRow(path: it.path, title: it.name, subtitle: it.note ?? "", bytes: it.bytes > 0 ? it.bytes : nil, mode: .held(CleanupEngine.plainReason(it.held ?? "Held")))
            } }
        }
        if !c.kept.isEmpty {
            Text("Mole reported these as kept in this preview.")
                .font(.system(size: 12)).foregroundStyle(Palette.ink3).padding(.top, 8).padding(.horizontal, 2)
        }
        if c.items.isEmpty && c.blocked == nil && c.skipped == nil && c.held.isEmpty && c.kept.isEmpty {
            ListCard { HStack { Image(systemName: "checkmark.circle").foregroundStyle(Palette.ok); Text("Nothing to clean here.").foregroundStyle(Palette.ink2); Spacer() }.padding(14) }
        }
        if !c.checkedEmpty.isEmpty {
            FlowTags(title: "Also checked, nothing found", tags: Array(c.checkedEmpty.prefix(14))).padding(.top, 10)
        }
    }
}

struct Notice: View {
    var symbol: String
    var tint: Color
    var text: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action { Button(action.0, action: action.1).buttonStyle(.bordered) }
        }
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

struct FlowTags: View {
    var title: String
    var tags: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink3)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { ForEach(tags, id: \.self) { Tag(text: $0) } }
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { ForEach(tags, id: \.self) { Tag(text: $0) } } }
            }
        }
    }
}

/// Simple selectable list screens: Leftovers, Installers, Project Artifacts, App Slimming.
struct SimpleListScreen: View {
    @Environment(AppModel.self) var model
    var title: String
    var subtitle: String
    var items: [CleanItem]
    var action: String
    var note: String
    var empty: (String, String)
    var caption = "can be cleaned"
    var selectHint = ""
    /// Groups rows under a header with its own checkbox (Leftovers groups by the app they came from).
    var groupBy: ((CleanItem) -> String)? = nil

    var selected: [CleanItem] { items.filter { $0.byMole != true && model.selection.contains($0.path) } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: title, subtitle: subtitle, value: items.isEmpty ? nil : Fmt.bytes(items.filter { !$0.review }.reduce(0) { $0 + $1.bytes }), valueCaption: caption,
                         valueDetail: items.contains(where: \.review) ? "of \(Fmt.bytes(items.reduce(0) { $0 + $1.bytes })) found, the rest is yours to check" : nil)
            if model.snap.scannedAt == nil { NotScannedYet(); Spacer() }
            else if items.isEmpty { EmptyState(symbol: "checkmark.circle", title: empty.0, text: empty.1); Spacer() }
            else {
                let selectable = items.filter { $0.byMole != true && $0.held == nil }
                if selectable.count > 1 {
                    HStack {
                        let all = selectable.allSatisfy { model.selection.contains($0.path) }
                        Button(all ? "Deselect All" : "Select All (\(selectable.count))") {
                            withAnimation(.snappy) {
                                if all { model.selection.subtract(selectable.map(\.path)) } else { model.selection.formUnion(selectable.map(\.path)) }
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        Text(selectHint).font(.system(size: 11)).foregroundStyle(Palette.ink3)
                        Spacer()
                    }
                    .padding(.horizontal, 28).padding(.bottom, 8)
                }
                ScrollView {
                    if let groupBy {
                        let groups = Dictionary(grouping: items, by: groupBy).map { ($0.key, $0.value) }.sorted { $0.1.reduce(0) { $0 + $1.bytes } > $1.1.reduce(0) { $0 + $1.bytes } }
                        VStack(spacing: 10) {
                            ForEach(groups, id: \.0) { g in groupCard(g.0, g.1) }
                        }
                        .padding(.horizontal, 28).padding(.bottom, 20)
                    } else {
                        ListCard {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                                if i > 0 { RowDivider() }
                                row(it)
                            }
                        }
                        .padding(.horizontal, 28).padding(.bottom, 20)
                    }
                }
                FooterBar(bytes: selected.reduce(0) { $0 + $1.bytes }, count: selected.count, label: action, note: note) {
                    Task { await model.clean(title, targets: selected.map { Actions.Target(path: $0.path, bytes: $0.bytes) }) }
                }
            }
        }
    }

    func row(_ it: CleanItem) -> some View {
        ItemRow(path: it.path, title: it.name, subtitle: [Paths.short(it.path), it.note].compactMap { $0 }.joined(separator: " · "),
                bytes: it.bytes, mode: it.byMole == true ? .managed("Preview · cleaned from Checkup") : .select,
                on: model.selection.contains(it.path)) { model.toggle(it.path) }
            .transition(.movingParts.vanish(Palette.accent.opacity(0.5)))
    }

    func groupCard(_ title: String, _ rows: [CleanItem]) -> some View {
        let selectable = rows.filter { $0.byMole != true && $0.held == nil }
        let on = selectable.filter { model.selection.contains($0.path) }
        let state: Bool? = on.isEmpty ? false : on.count == selectable.count ? true : nil
        return ListCard {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.snappy) { if state == true { model.selection.subtract(selectable.map(\.path)) } else { model.selection.formUnion(selectable.map(\.path)) } }
                } label: { TriCheck(state: state) }.buttonStyle(.plain).disabled(selectable.isEmpty)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(on.count)/\(rows.count) selected").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(Fmt.bytes(rows.reduce(0) { $0 + $1.bytes })).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            ForEach(rows) { it in RowDivider(); row(it) }
        }
    }
}

struct LeftoversView: View {
    @Environment(AppModel.self) var model

    /// The app a leftover came from: its bundle ID without team prefix, "group." or file suffixes, or its name when the
    /// app is still in the Trash.
    static func app(_ i: CleanItem) -> String {
        if let r = i.name.range(of: " (in your Trash)") { return String(i.name[..<r.lowerBound]) + " (in your Trash)" }
        if i.name.hasSuffix(" (uninstalled)") { return i.name }
        if Paths.name(i.path).hasPrefix(".") { return "Hidden folders in your Home" }
        var core = i.name.replacing(regex: #"^[A-Z0-9]{10}\."#, with: "")
        if core.lowercased().hasPrefix("group.") { core = String(core.dropFirst(6)) }
        for suffix in [".plist", ".savedState", ".binarycookies", ".web"] where core.hasSuffix(suffix) { core = String(core.dropLast(suffix.count)) }
        let parts = core.split(separator: ".")
        return parts.count > 3 ? parts.prefix(3).joined(separator: ".") : core
    }
    var body: some View {
        SimpleListScreen(title: "Leftovers", subtitle: "Files apps and command-line tools left behind after you deleted them, grouped by app.",
                         items: model.snap.leftovers, action: "Move to Trash", note: "Goes to the Trash, so you can put it back",
                         empty: ("No leftovers", "Every folder in your Library belongs to an app you still have."),
                         selectHint: "Caches, logs and web storage start selected. Data folders may hold things you'd want back, so you choose.",
                         groupBy: LeftoversView.app)
    }
}

struct InstallersView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        SimpleListScreen(title: "Installers", subtitle: "Disk images, packages and archives you already installed from. You can download them again.",
                         items: model.snap.installers, action: "Move to Trash", note: "Goes to the Trash",
                         empty: ("No installers", "No .dmg, .pkg or installer archives were found."))
    }
}

struct ArtifactsView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let items = model.snap.artifacts.map { CleanItem(path: $0.path, name: "\($0.kind) in \(Paths.name($0.project))", bytes: $0.bytes, note: "\($0.ageDays) days since last change", review: true) }
        SimpleListScreen(title: "Project Artifacts", subtitle: "Rebuildable project folders like node_modules, .venv, dist and .next. Your next build or install recreates them.",
                         items: items, action: "Remove", note: "Rebuilt the next time you build",
                         empty: ("No old build folders", "Projects that haven't changed recently have no dependency or build folders left."))
    }
}

struct SlimmingView: View {
    @Environment(AppModel.self) var model
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { Text("Language files").tag(0); Text("Universal binaries").tag(1) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300).padding(.top, 12)
            if tab == 0 {
                // Listed for reference only. Removing anything inside an app breaks its code signature, and macOS may then
                // refuse to open it; the app also puts the files back with its next update.
                SimpleListScreen(title: "App Slimming", subtitle: "Translations for languages you don't use, inside apps. Removing them breaks an app's signature, so Roomy only lists them.",
                                 items: model.snap.languageFiles.map { var x = $0; x.held = "Review only"; return x }, action: "Remove", note: "Changes the app's code signature",
                                 empty: ("Nothing to slim", "No app ships languages you don't use."), caption: "listed for reference")
                    .disabled(true)
            } else {
                SimpleListScreen(title: "App Slimming", subtitle: "Intel code this Mac never runs. Removing it breaks the app's signature, so it's listed for reference only.",
                                 items: model.snap.universalBinaries.map { var x = $0; x.held = "Review only"; return x }, action: "Remove", note: "Changes the app's code signature",
                                 empty: ("No universal binaries", "Every app is Apple silicon only."), caption: "listed for reference")
                    .disabled(true)
            }
        }
    }
}

/// A separate manual Trash action, with confirmation. Normal Mole Clean may also empty Trash.
struct TrashCard: View {
    @Environment(AppModel.self) var model
    @State private var bytes: Int64?
    @State private var count = 0
    @State private var confirm = false
    @State private var emptying = false
    static let trash = HOME + "/.Trash"

    var body: some View {
        HStack(spacing: 14) {
            FileIcon(path: Self.trash, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trash").font(.system(size: 14, weight: .semibold))
                Text(bytes == nil ? "Measuring…" : count == 0 ? "Empty" : "\(count) item\(count == 1 ? "" : "s") · \(Fmt.bytes(bytes)) · space returns when you empty it")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: Self.trash)) }.buttonStyle(.glass)
            Button(emptying ? "Emptying…" : "Empty Trash…") { confirm = true }
                .buttonStyle(.glassProminent).disabled(count == 0 || emptying)
        }
        .padding(14).glass(12).padding(.top, 14)
        .task { await measure() }
        .confirmationDialog("Empty the Trash?", isPresented: $confirm) {
            Button("Empty Trash", role: .destructive) { Task { await empty() } }
        } message: { Text("\(count) item\(count == 1 ? "" : "s"), \(Fmt.bytes(bytes)), will be deleted for good. This can't be undone.") }
    }

    func measure() async {
        count = Paths.children(Self.trash).filter { Paths.name($0) != ".DS_Store" }.count
        bytes = await diskSizes([Self.trash])[Self.trash] ?? 0
        model.snap.trashBytes = bytes
    }

    func empty() async {
        emptying = true
        let items = Paths.children(Self.trash)
        if model.safeMode {
            model.flash("Safe mode: the Trash wasn't emptied. It holds \(Fmt.bytes(bytes)).")
        } else {
            var failed = 0
            for i in items { do { try FileManager.default.removeItem(atPath: i) } catch { failed += 1 } }
            model.snap.history.insert(HistoryEntry(date: Date(), title: "Emptied the Trash", bytes: bytes ?? 0, items: items.count - failed, simulated: false,
                                                   failures: failed > 0 ? ["\(failed) item\(failed == 1 ? "" : "s") couldn't be deleted (in use or locked)"] : nil), at: 0)
            model.snap.disk = ExtrasEngine.disk()
            model.save()
            model.flash(failed == 0 ? "Emptied the Trash: \(Fmt.bytes(bytes)) freed." : "Emptied most of the Trash; \(failed) item\(failed == 1 ? "" : "s") couldn't be deleted.")
        }
        emptying = false
        await measure()
    }
}
