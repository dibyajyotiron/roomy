import SwiftUI

/// Mole's dry-run findings, with the existing grouped review and Finder links.
struct CheckupReview: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var onClean: () -> Void
    @State private var open: Set<String> = []

    struct Group: Identifiable { var id: String; var title: String; var note: String; var items: [CleanItem] }

    var groups: [Group] {
        var result = model.snap.categories.compactMap { c -> Group? in
            let items = c.items.filter { $0.byMole == true }
            return items.isEmpty ? nil : Group(id: c.key, title: c.title, note: c.note, items: items)
        }
        let leftovers = model.snap.leftovers.filter { $0.byMole == true }
        if !leftovers.isEmpty {
            result.append(Group(id: "leftovers", title: "App leftovers", note: "Leftovers reported by Mole's preview.", items: leftovers))
        }
        return result
    }
    var held: [CleanItem] { model.snap.categories.flatMap(\.held) }
    var totalCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    Notice(symbol: "info.circle", tint: Palette.ink3,
                           text: "This is Mole's preview. Clean runs Mole again with its normal rules and your Mole keep list, including emptying Trash. Findings and space freed can change.")
                    ForEach(groups) { groupCard($0) }
                    if !held.isEmpty { heldCard }
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
            }
            footer
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 520, idealHeight: 680)
        .presentationBackground { AreaGround(area: .cleanup) }
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review before cleaning").font(.system(size: 24, weight: .bold)).tracking(-0.3)
                Text("\(Fmt.bytes(model.checkupBytes)) estimated · \(totalCount) items · \(groups.count) groups")
                    .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit().contentTransition(.numericText())
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 10)
    }

    func groupCard(_ g: Group) -> some View {
        let expanded = open.contains(g.id)
        return VStack(spacing: 0) {
            Button { withAnimation(.snappy) { if expanded { open.remove(g.id) } else { open.insert(g.id) } } } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(g.title).font(.system(size: 14, weight: .semibold))
                            Text("\(g.items.count) items").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(g.note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.bytes(g.items.reduce(0) { $0 + $1.bytes })).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle()).padding(.horizontal, 14).padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            if expanded {
                Divider().padding(.leading, 14)
                ForEach(g.items) { itemRow($0) }
            }
        }
        .glass(12)
    }

    func itemRow(_ i: CleanItem) -> some View {
        HStack(spacing: 12) {
            FileIcon(path: i.path, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(i.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(Paths.short(i.path) + (i.count > 1 ? " · \(i.count) items inside" : "")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Fmt.bytes(i.bytes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            if !i.path.hasPrefix("mole:") && !i.path.hasPrefix("docker:") {
                Button { reveal(i.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    var heldCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Skipped in this preview").font(.system(size: 14, weight: .semibold))
            Text("Mole evaluates these again when Clean runs.").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(held) { i in
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
            Text("\(totalCount) preview items").font(.system(size: 12, weight: .medium)).monospacedDigit()
            Spacer()
            Text(model.safeMode ? "Safe mode: nothing is removed" : "Mole permanently removes cleanup items and empties Trash")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Button { dismiss(); onClean() } label: { Text("Clean \(Fmt.bytes(model.checkupBytes))").frame(minWidth: 120) }
                .buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(model.checkupBytes == 0 || model.scanIsStale || model.isCleaning)
        }
        .padding(.horizontal, 24).padding(.vertical, 14).background(.bar)
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
