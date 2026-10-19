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
    var body: some View {
        let tasks = model.snap.maintenance.filter { !$0.unverifiable }
        let pending = tasks.flatMap(\.steps).filter { $0.state == "Would run" }.count
        VStack(spacing: 0) {
            ScreenHeader(title: "Maintenance", subtitle: "Routine upkeep macOS doesn't always do on its own: refresh caches, repair app records, tidy databases.") {
                Button(running ? "Running…" : pending > 0 ? "Run \(pending) Task\(pending == 1 ? "" : "s")" : "Run Maintenance") { Task { running = true; await model.runMaintenance(); running = false } }
                    .buttonStyle(.glassProminent).disabled(running || tasks.isEmpty)
                    .help("Runs the tasks marked to run. Steps that need an administrator are skipped.")
            }
            ScrollView {
                if tasks.isEmpty { NotScannedYet() } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.snap.diagnosis.isEmpty {
                            Notice(symbol: "stethoscope", tint: Palette.accent, text: model.snap.diagnosis.joined(separator: "\n"))
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                            ForEach(tasks) { t in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(t.title).font(.system(size: 14, weight: .semibold))
                                    ForEach(t.steps, id: \.self) { s in
                                        HStack(alignment: .top, spacing: 8) {
                                            Circle().fill(s.state == "Would run" ? Palette.accent : s.state == "Needs you" ? Palette.warn : Palette.ok).frame(width: 7, height: 7).padding(.top, 5)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(s.text).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                                                Text(s.state).font(.system(size: 11)).foregroundStyle(Palette.ink3)
                                            }
                                        }
                                    }
                                }
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading).glass(14)
                            }
                        }
                        Text("Freeing memory isn't listed: its effect can't be measured here. Use Free Up Memory in Activity, which shows the measured change.")
                            .font(.system(size: 12)).foregroundStyle(Palette.ink3)
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)
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
