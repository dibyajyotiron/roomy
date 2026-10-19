import SwiftUI
import Charts

struct ProtectionView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Protection", subtitle: "macOS's built-in protections. Anything that's off opens the setting that turns it on.")
            ScrollView {
                if model.snap.protection.isEmpty { NotScannedYet() } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(model.snap.protection) { c in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: c.on == true ? "checkmark.shield.fill" : c.on == false ? "exclamationmark.shield.fill" : "questionmark.circle")
                                        .font(.system(size: 20)).foregroundStyle(c.on == true ? Palette.ok : c.on == false ? Palette.warn : Palette.ink3)
                                    Text(c.title).font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Tag(text: c.on == true ? "On" : c.on == false ? "Off" : "Unknown", color: c.on == true ? Palette.ok : c.on == false ? Palette.warn : nil)
                                }
                                Text(c.summary).font(.system(size: 13)).foregroundStyle(Palette.ink2)
                                Text(c.detail).font(.system(size: 11)).foregroundStyle(Palette.ink3)
                                if c.on != true, let fix = ProtectionFix.for(c.title) {
                                    Button(fix.label) { NSWorkspace.shared.open(fix.url) }.buttonStyle(.glass).controlSize(.small).padding(.top, 2)
                                }
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading).glass(14)
                        }
                    }
                    .padding(.horizontal, 28)
                }
            }
        }
    }
}

struct MaintenanceView: View {
    @Environment(AppModel.self) var model
    @State private var running = false

    /// Mole's preview says what a step would do in the past tense ("Icon services cache rebuilt"). Said plainly, with
    /// what it changes for you.
    static func explain(_ text: String) -> (title: String, detail: String) {
        let t = text.lowercased()
        if t.contains("quicklook") || t.contains("quick look") { return ("Refresh Quick Look thumbnails", "Clears stale file previews. Finder makes fresh ones as you browse.") }
        if t.contains("icon services") || t.contains("icon cache") { return ("Rebuild the icon cache", "Fixes blank or wrong app icons. Icons may redraw for a moment.") }
        if t.contains("saved state") { return ("Tidy saved app states", "Removes window-restore data left by apps. Apps reopen with fresh windows.") }
        if t.contains("dns") { return ("Refresh the DNS cache", "Forgets stale web addresses, which can fix sites that won't load.") }
        if t.contains("launch services") || t.contains("open with") { return ("Repair the Open With list", "Rebuilds which apps open which files, removing duplicates and apps that are gone.") }
        if t.contains("spotlight") { return ("Tidy Spotlight", "Refreshes Spotlight's rules so search results stay current.") }
        if t.contains("database") || t.contains("vacuum") { return ("Compact app databases", "Shrinks Mail's and other databases. The apps must be closed.") }
        if t.contains("quarantine") { return ("Trim the download history", "Clears old entries from the list macOS keeps of downloaded files.") }
        if t.contains("periodic") { return ("Run periodic maintenance", "macOS's own daily, weekly and monthly housekeeping.") }
        let first = text.prefix(1).uppercased() + text.dropFirst()
        return (first, "")
    }

    var body: some View {
        let tasks = model.snap.maintenance.filter { !$0.unverifiable }
        let pending = tasks.flatMap { t in t.steps.filter { $0.state == "Would run" }.map { (t.title, $0) } }
        VStack(spacing: 0) {
            ScreenHeader(title: "Maintenance", subtitle: "Routine upkeep macOS doesn't always do on its own: refresh caches, repair app records, tidy databases.",
                         value: pending.isEmpty ? "All fine" : "\(pending.count)", valueCaption: pending.isEmpty ? "nothing to run" : "task\(pending.count == 1 ? "" : "s") to run")
            ScrollView {
                if tasks.isEmpty { NotScannedYet() } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if !pending.isEmpty {
                            SectionLabel(title: "What runs", note: "Each one is safe to repeat. Steps that need an administrator are skipped.")
                            ListCard {
                                ForEach(Array(pending.enumerated()), id: \.offset) { _, p in
                                    let e = Self.explain(p.1.text)
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "wrench.and.screwdriver").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.accent)
                                            .frame(width: 32, height: 32).background(Circle().fill(Palette.accent.opacity(0.14)))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(e.title).font(.system(size: 13.5, weight: .semibold))
                                            if !e.detail.isEmpty { Text(e.detail).font(.system(size: 12)).foregroundStyle(Palette.ink2) }
                                            Text(p.0).font(.system(size: 11)).foregroundStyle(Palette.ink3)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    RowDivider()
                                }
                            }
                        }
                        if !model.snap.diagnosis.isEmpty {
                            SectionLabel(title: "What Mole noticed")
                            Notice(symbol: "stethoscope", tint: Palette.accent, text: model.snap.diagnosis.joined(separator: "\n"))
                        }
                        SectionLabel(title: "Everything it checks")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                            ForEach(tasks) { t in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(t.title).font(.system(size: 14, weight: .semibold))
                                    ForEach(t.steps, id: \.self) { s in
                                        HStack(alignment: .top, spacing: 8) {
                                            Circle().fill(s.state == "Would run" ? Palette.accent : s.state == "Needs you" ? Palette.warn : Palette.ok).frame(width: 7, height: 7).padding(.top, 5)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(s.state == "Would run" ? Self.explain(s.text).title : s.text).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                                                Text(s.state == "Would run" ? "Will run" : s.state).font(.system(size: 11)).foregroundStyle(Palette.ink3)
                                            }
                                        }
                                    }
                                }
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading).glass(14)
                            }
                        }
                        Text("Freeing memory isn't listed: its effect can't be measured here. Use Free Up Memory in Activity or the menu bar, which show the measured change.")
                            .font(.system(size: 12)).foregroundStyle(Palette.ink3)
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
            }
            if !pending.isEmpty {
                FooterBar(bytes: 0, count: pending.count, label: running ? "Running…" : "Run \(pending.count) Task\(pending.count == 1 ? "" : "s")",
                          note: pending.map { Self.explain($0.1.text).title }.joined(separator: " · "), enabled: !running,
                          headline: "\(pending.count) task\(pending.count == 1 ? "" : "s") to run") {
                    Task { running = true; await model.runMaintenance(); running = false }
                }
            }
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) var model
    @State private var open: Set<UUID> = []
    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "History", subtitle: "Everything Roomy cleaned, newest first. Safe-mode runs are marked: nothing was removed in those.")
            ScrollView {
                if model.snap.history.isEmpty { EmptyState(symbol: "clock", title: "Nothing cleaned yet", text: "Cleanups appear here with what they freed.") } else {
                    ListCard { ForEach(Array(model.snap.history.enumerated()), id: \.element.id) { i, h in
                        if i > 0 { RowDivider() }
                        VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Image(systemName: h.simulated ? "shield.lefthalf.filled" : h.failures == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(h.simulated ? Palette.ink3 : h.failures == nil ? Palette.ok : Palette.warn).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.title).font(.system(size: 13, weight: .medium))
                                Text(h.date.formatted(date: .abbreviated, time: .shortened) + " · \(h.items) items" + (h.trashed.map { " · \(Fmt.bytes($0)) in the Trash" } ?? ""))
                                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                            }
                            Spacer()
                            if h.simulated { Tag(text: "Safe mode") }
                            Text(Fmt.bytes(h.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                        if let r = h.removed, !r.isEmpty {
                            Button { withAnimation(.snappy) { if open.contains(h.id) { open.remove(h.id) } else { open.insert(h.id) } } } label: {
                                Label(open.contains(h.id) ? "Hide what was removed" : "Show what was removed (\(r.count))", systemImage: open.contains(h.id) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain).foregroundStyle(Palette.accent).padding(.leading, 34)
                            if open.contains(h.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(r.enumerated()), id: \.offset) { _, line in
                                        Text(line).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    }
                                }
                                .padding(.leading, 34)
                            }
                        }
                        if let f = h.failures {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Couldn't remove \(f.count):").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.warn)
                                ForEach(Array(f.prefix(8).enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(2).textSelection(.enabled)
                                }
                                if f.count > 8 { Text("and \(f.count - 8) more").font(.system(size: 11)).foregroundStyle(Palette.ink3) }
                            }
                            .padding(.leading, 34)
                        }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    } }
                    .padding(.horizontal, 28)
                }
            }
        }
    }
}

/// Where to switch each protection back on.
enum ProtectionFix {
    static func `for`(_ title: String) -> (label: String, url: URL)? {
        let pane = "x-apple.systempreferences:com.apple.preference.security"
        switch title {
        case "Gatekeeper": return ("Open Privacy & Security", URL(string: pane + "?Security")!)
        case "FileVault": return ("Turn On FileVault…", URL(string: pane + "?FileVault")!)
        case "Firewall": return ("Turn On Firewall…", URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")!)
        case "System Integrity Protection": return ("How to turn it on", URL(string: "https://support.apple.com/guide/security/system-integrity-protection-secb7ea06b49/web")!)
        case "XProtect": return ("Check for Updates", URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
        default: return nil
        }
    }
}
