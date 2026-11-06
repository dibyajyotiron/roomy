import SwiftUI
import Pow

struct AICareView: View {
    @Environment(AppModel.self) var model
    @State private var tool = "all"
    @State private var ages: [String: Int] = [:]
    @State private var showAllKept = false
    @State private var confirm = false
    @Namespace private var chips

    var care: AICare { model.snap.aiCare }
    func f<T>(_ l: [T], _ tool: (T) -> String) -> [T] { self.tool == "all" ? l : l.filter { tool($0) == self.tool } }
    func toolRec(_ id: String) -> AITool? { care.tools.first { $0.id == id } }

    var selectedTargets: [Actions.Target] {
        var t: [Actions.Target] = []
        for i in care.clear + care.review where model.selection.contains("ai:" + i.path) { t.append(.init(path: i.path, bytes: i.bytes, aiTool: i.tool)) }
        for w in care.worktrees where !w.locked && model.selection.contains("ai:" + w.path) {
            t.append(.init(path: w.path, bytes: w.bytes, command: w.repoRoot != nil ? ["git", "worktree", "remove", Paths.expand(w.path)] : nil, directory: w.repoRoot,
                           aiTool: w.tool, requiresCleanWorktree: true))
        }
        for c in care.cliTools where c.idleDays >= 30 && model.selection.contains("ai:" + c.path) {
            t.append(.init(path: c.path, bytes: c.bytes, command: c.uninstall.isEmpty ? nil : c.uninstall, aiTool: c.tool))
        }
        for c in care.chats { if let d = ages[c.path], d > 0 { t += c.older(than: d).map { .init(path: $0.path, bytes: $0.bytes, aiTool: c.tool) } } }
        return t
    }

    var body: some View {
        let total = care.tools.reduce(0) { $0 + $1.bytes }
        VStack(spacing: 0) {
            ScreenHeader(title: "AI Cleanup & Care",
                         subtitle: care.tools.isEmpty ? "Caches, old versions, chats and worktrees AI tools leave behind." :
                            "What \(care.tools.count) AI tools keep on this Mac. Caches start selected. Chats, worktrees and tools wait for you, and models stay with the tools that manage them.",
                         value: care.tools.isEmpty ? nil : Fmt.bytes(care.cleanable), valueCaption: "can be cleaned",
                         valueDetail: care.tools.isEmpty ? nil : "of \(Fmt.bytes(total)) kept by AI tools")
            if care.tools.isEmpty { if model.snap.scannedAt == nil { NotScannedYet() } else { EmptyState(symbol: "cpu", title: "No AI tools found", text: "Roomy checks Claude, Codex, Cursor, LM Studio, Ollama and more.") }; Spacer() }
            else {
                toolStrip
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        group("Clear safely", "Caches and temporary files are rebuilt when needed. Old versions are builds a newer one replaced.", f(care.clear, \.tool)) { i in
                            row(i, id: "ai:" + i.path)
                        }
                        group("Waiting for the app to quit", "In use right now, so they're never touched.", f(care.held, \.tool)) { i in
                            ItemRow(path: i.path, title: i.name, subtitle: "\(toolRec(i.tool)?.name ?? i.tool) · \(i.why)", bytes: i.bytes, mode: .held(i.held ?? ""),
                                    icon: AnyView(ToolBadge(tool: toolRec(i.tool), name: toolRec(i.tool)?.name ?? i.tool)))
                        }
                        if !f(care.chats, \.tool).isEmpty {
                            SectionLabel(title: "Chats", note: "Pick an age to include chats older than that. Nothing is selected until you do.")
                            ListCard { ForEach(Array(f(care.chats, \.tool).enumerated()), id: \.element.id) { i, c in
                                if i > 0 { RowDivider() }
                                chatRow(c)
                            } }
                        }
                        group("Worktrees", "Extra checkouts agents made for tasks. Ones with uncommitted changes stay locked.", f(care.worktrees, \.tool)) { w in
                            if w.locked {
                                ItemRow(path: w.path, title: w.name, subtitle: "\(w.project) · \(w.why)", bytes: w.bytes, mode: .locked("Git status unavailable or has changes"),
                                        icon: AnyView(ToolBadge(tool: toolRec(w.tool), name: toolRec(w.tool)?.name ?? w.tool)))
                            } else {
                                ItemRow(path: w.path, title: w.name, subtitle: "\(w.project) · \(Fmt.ago(w.modified)) · \(w.why)", bytes: w.bytes, on: model.selection.contains("ai:" + w.path),
                                        icon: AnyView(ToolBadge(tool: toolRec(w.tool), name: toolRec(w.tool)?.name ?? w.tool))) { model.toggle("ai:" + w.path) }
                            }
                        }
                        group("Generated files and old runtimes", "Things you might still want. They go to the Trash, so you can put them back.", f(care.review, \.tool)) { i in
                            row(i, id: "ai:" + i.path)
                        }
                        group("Idle command-line tools", "No activity for 30 days or more. Removed with their own uninstall command.", f(care.cliTools.filter { $0.idleDays >= 30 }, \.tool)) { c in
                            ItemRow(path: c.path, title: c.name, subtitle: "Last used \(Fmt.ago(c.lastUsed).lowercased()) · \(c.uninstall.joined(separator: " "))", bytes: c.bytes,
                                    on: model.selection.contains("ai:" + c.path), icon: AnyView(ToolBadge(tool: toolRec(c.tool), name: c.name))) { model.toggle("ai:" + c.path) }
                        }
                        let kept = f(care.kept, \.tool)
                        group("Stays with the tool", "Models, sandboxes, indexes, sign-ins and settings. Removing them here could break the tool, so manage them from the tool itself.",
                              showAllKept ? kept : Array(kept.prefix(4)), more: kept.count > 4 ? (showAllKept ? "Show fewer" : "Show all \(kept.count)", { withAnimation(.snappy) { showAllKept.toggle() } }) : nil) { i in
                            ItemRow(path: i.path, title: i.name, subtitle: "\(toolRec(i.tool)?.name ?? i.tool) · \(i.why)", bytes: i.bytes, mode: .locked(Paths.short(i.path)),
                                    icon: AnyView(ToolBadge(tool: toolRec(i.tool), name: toolRec(i.tool)?.name ?? i.tool)))
                        }
                        if !care.notFound.isEmpty { FlowTags(title: "Also checked, not installed", tags: care.notFound).padding(.top, 14) }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
                let t = selectedTargets
                FooterBar(bytes: t.reduce(0) { $0 + $1.bytes }, count: t.count, label: "Clean Selected", note: "Caches are removed · everything else goes to the Trash first") { confirm = true }
            }
        }
        .confirmationDialog("Clean \(Fmt.bytes(selectedTargets.reduce(0) { $0 + $1.bytes }))?", isPresented: $confirm) {
            Button("Clean") { let t = selectedTargets; Task { await model.clean("AI Cleanup & Care", targets: t) { ages = [:] } } }
        } message: {
            Text("Open tools, models, sandboxes, sign-ins and worktrees with uncommitted changes are never touched. Files go to the Trash; worktrees are removed with git; idle tools with their own uninstall command.")
        }
    }

    var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(id: "all", label: "All tools", bytes: care.tools.reduce(0) { $0 + $1.bytes }, badge: nil, open: false)
                    ForEach(care.tools) { t in chip(id: t.id, label: t.name, bytes: t.bytes, badge: AnyView(ToolBadge(tool: t, name: t.name, size: 20)), open: t.isOpen) }
                }
            }
            .padding(.vertical, 6)
        }
        .mask(HStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28) })
        .padding(.leading, 28).padding(.trailing, 44)
    }

    func chip(id: String, label: String, bytes: Int64, badge: AnyView?, open: Bool) -> some View {
        let on = tool == id
        return Button { withAnimation(.snappy) { tool = id } } label: {
            HStack(spacing: 7) {
                badge
                Text(label).foregroundStyle(on ? .primary : .secondary)
                Text(Fmt.bytes(bytes)).fontWeight(.semibold).monospacedDigit()
                if open { Circle().fill(Palette.ok).frame(width: 6, height: 6).help("Open now") }
            }
            .font(.system(size: 12))
            .padding(.leading, badge == nil ? 12 : 6).padding(.trailing, 12).frame(height: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(Palette.accent.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
        .glassEffectID(id, in: chips)
    }

    @ViewBuilder
    func group<T: Identifiable, R: View>(_ title: String, _ note: String, _ items: [T], more: (String, () -> Void)? = nil, @ViewBuilder row: @escaping (T) -> R) -> some View {
        if !items.isEmpty {
            SectionLabel(title: title, note: note)
            ListCard {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    if i > 0 { RowDivider() }
                    row(it).transition(.movingParts.vanish(Palette.accent.opacity(0.5)))
                }
                if let more {
                    RowDivider()
                    Button(more.0, action: more.1).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 9)
                }
            }
        }
    }

    func row(_ i: AIItem, id: String) -> some View {
        ItemRow(path: i.path, title: i.name, subtitle: "\(toolRec(i.tool)?.name ?? i.tool) · \(i.why)", bytes: i.bytes, on: model.selection.contains(id),
                icon: AnyView(ToolBadge(tool: toolRec(i.tool), name: toolRec(i.tool)?.name ?? i.tool))) { model.toggle(id) }
    }

    func chatRow(_ c: AIChats) -> some View {
        let d = ages[c.path] ?? 0
        let picked = d > 0 ? c.older(than: d) : []
        return HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Palette.ink3).frame(width: 20)
            ToolBadge(tool: toolRec(c.tool), name: toolRec(c.tool)?.name ?? c.tool, size: 26).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.system(size: 13, weight: .medium))
                Text("\(c.files.count.formatted()) chats · \(Fmt.bytes(c.bytes)) in total · \(c.how)").font(.system(size: 11)).foregroundStyle(Palette.ink3).lineLimit(2)
            }
            Spacer(minLength: 10)
            Picker("Older than", selection: Binding(get: { d }, set: { v in withAnimation(.snappy) { ages[c.path] = v } })) {
                Text("Keep all").tag(0)
                ForEach([180, 90, 30], id: \.self) { days in
                    Text(days == 30 ? "1 month+" : "\(days / 30) months+").tag(days)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            Text(d == 0 ? "—" : Fmt.bytes(picked.reduce(0) { $0 + $1.bytes })).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing).contentTransition(.numericText())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
