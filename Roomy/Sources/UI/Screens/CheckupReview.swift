import SwiftUI

/// Everything Checkup is about to clean, in one list: grouped like the cleanup modules, each group and item with a
/// checkbox, its size and where it lives. Unticked items stay on the Mac. "Always keep" adds an item to Mole's keep
/// list for good. Items held by open apps are listed at the end, so nothing is a surprise.
struct CheckupReview: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var onClean: () -> Void
    @State private var open: Set<String> = []

    struct Group: Identifiable { var id: String; var title: String; var note: String; var items: [CleanItem]; var ai = false }

    var groups: [Group] {
        var g = model.snap.categories.compactMap { c -> Group? in
            let items = c.items.filter { $0.byMole == true }
            return items.isEmpty ? nil : Group(id: c.key, title: c.title, note: c.note, items: items)
        }
        let ai = model.snap.aiCare.clear.map { CleanItem(path: $0.path, name: $0.name, bytes: $0.bytes, note: $0.why) }
        if !ai.isEmpty { g.append(Group(id: "ai", title: "AI Tools", note: "Caches and old versions AI tools leave behind. Chats, projects and models stay.", items: ai, ai: true)) }
        return g
    }
    var held: [CleanItem] { model.snap.categories.flatMap(\.held) }

    func isOn(_ i: CleanItem, ai: Bool) -> Bool { ai ? model.selection.contains("ai:" + i.path) : !model.checkupSkip.contains(i.path) }
    func set(_ i: CleanItem, ai: Bool, _ on: Bool) {
        if ai { if on { model.selection.insert("ai:" + i.path) } else { model.selection.remove("ai:" + i.path) } }
        else { if on { model.checkupSkip.remove(i.path) } else { model.checkupSkip.insert(i.path) } }
    }

    var selectedCount: Int { groups.reduce(0) { n, g in n + g.items.filter { isOn($0, ai: g.ai) }.count } }
    var totalCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(groups) { groupCard($0) }
                    if !held.isEmpty { heldCard }
                    if let t = model.snap.trashBytes, t > 0 {
                        Label("Your Trash (\(Fmt.bytes(t))) isn't touched. Empty it in Mail & Trash when you're sure.", systemImage: "trash")
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
            }
            footer
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 600, idealHeight: 680)
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review before cleaning").font(.system(size: 24, weight: .bold)).tracking(-0.3)
                let apps = Set(held.compactMap { $0.held }).count
                Text("\(Fmt.bytes(model.checkupBytes)) in \(selectedCount) of \(totalCount) items · \(groups.count) groups" + (apps > 0 ? " · \(held.count) kept because their apps are open" : ""))
                    .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit().contentTransition(.numericText())
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 10)
    }

    func groupCard(_ g: Group) -> some View {
        let on = g.items.filter { isOn($0, ai: g.ai) }
        let state: Bool? = on.count == g.items.count ? true : on.isEmpty ? false : nil
        let expanded = open.contains(g.id)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { for i in g.items { set(i, ai: g.ai, state != true) } } label: { TriCheck(state: state) }.buttonStyle(.plain)
                    .accessibilityLabel(state == true ? "Untick \(g.title)" : "Tick \(g.title)")
                Button { withAnimation(.snappy) { if expanded { open.remove(g.id) } else { open.insert(g.id) } } } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(g.title).font(.system(size: 14, weight: .semibold))
                                Text("\(on.count)/\(g.items.count) selected").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(g.note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        let sel = on.reduce(0) { $0 + $1.bytes }, all = g.items.reduce(0) { $0 + $1.bytes }
                        Text(sel == all ? Fmt.bytes(all) : "\(Fmt.bytes(sel)) of \(Fmt.bytes(all))").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            if expanded {
                Divider().padding(.leading, 44)
                ForEach(g.items) { i in itemRow(i, ai: g.ai) }
            }
        }
        .glass(12)
    }

    func itemRow(_ i: CleanItem, ai: Bool) -> some View {
        HStack(spacing: 12) {
            Button { set(i, ai: ai, !isOn(i, ai: ai)) } label: { CheckMark(on: isOn(i, ai: ai)) }.buttonStyle(.plain)
            FileIcon(path: i.path, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(i.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(Paths.short(i.path) + (i.count > 1 ? " · \(i.count) items inside" : "")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Fmt.bytes(i.bytes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            if !ai {
                Button { MoleWhitelist.keepAlways(i.path); set(i, ai: false, false); model.flash("\(i.name) will always be kept.") } label: { Image(systemName: "lock.shield") }
                    .buttonStyle(.borderless).help("Always keep: never clean this again")
            }
            Button { reveal(i.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.leading, 14).padding(.trailing, 14).padding(.vertical, 6)
        .opacity(isOn(i, ai: ai) ? 1 : 0.55)
    }

    var heldCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Kept this time").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Not cleaned").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("These belong to apps that are open or need your review. Quit an app and scan again to include its cache.").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(held.prefix(12)) { i in
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle").foregroundStyle(.tertiary)
                    Text(i.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(i.held ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass(12)
    }

    var footer: some View {
        HStack(spacing: 10) {
            Text("\(selectedCount) selected").font(.system(size: 12, weight: .medium)).monospacedDigit()
            Button("All") { for g in groups { for i in g.items { set(i, ai: g.ai, true) } } }.buttonStyle(.link)
            Button("None") { for g in groups { for i in g.items { set(i, ai: g.ai, false) } } }.buttonStyle(.link)
            Button("Recommended") { model.checkupSkip = []; model.preselectAI() }.buttonStyle(.link)
            Spacer()
            Text(model.safeMode ? "Safe mode: nothing is removed" : "Caches are removed permanently · AI items go to the Trash").font(.system(size: 11)).foregroundStyle(.secondary)
            Button { dismiss(); onClean() } label: { Text("Clean \(Fmt.bytes(model.checkupBytes))").frame(minWidth: 120) }
                .buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(model.checkupBytes == 0 || model.scanIsStale || model.isCleaning)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(.bar)
    }
}

/// A checkbox that can also be partly ticked.
struct TriCheck: View {
    var state: Bool?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(state == false ? Palette.ink3 : Palette.accent, lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(state == false ? .clear : Palette.accent))
            Image(systemName: state == nil ? "minus" : "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white).opacity(state == false ? 0 : 1)
        }
        .frame(width: 18, height: 18)
        .animation(.spring(duration: 0.25, bounce: 0.2), value: state)
    }
}
