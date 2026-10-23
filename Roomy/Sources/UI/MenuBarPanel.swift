import SwiftUI
import AppKit

/// The menu bar panel: the Mac at a glance. Health and hardware on top, six live tiles (processor, graphics, memory,
/// disk, network, fans), the battery, the apps using the most, camera and microphone, Keep awake, and what Roomy has
/// done so far. Every tile opens the screen with the full story.
struct MenuBarPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow

    func open(_ r: Route) {
        model.route = r
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    var body: some View {
        let m = model.monitor
        VStack(spacing: 10) {
            HealthHeader()
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { CPUTile().onTap { open(.status) }; GPUTile().onTap { open(.status) } }
                GridRow { MemoryTile().onTap { open(.status) }; DiskTile().onTap { open(.storage) } }
                GridRow { NetworkTile().onTap { open(.status) }; FanTile() }
            }
            if m.battery.present { BatteryStrip() }
            TopApps(open: { open(.status) })
            PresenceRow()
            TotalsRow(open: { open(.history) })
            HStack {
                Button { open(.care) } label: { Text("Open Roomy").padding(.horizontal, 6) }.buttonStyle(.glassProminent)
                Spacer()
                Button("Quit Roomy") { NSApp.terminate(nil) }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { m.watch(); if !Demo.on { model.snap.disk = ExtrasEngine.disk() } }
        .onDisappear { m.unwatch() }
    }
}

// MARK: - Header

private struct HealthHeader: View {
    @Environment(AppModel.self) var model

    static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf).replacingOccurrences(of: "Apple ", with: "")
    }()

    var facts: [String] {
        if Demo.on { return Demo.hardware.components(separatedBy: " · ") + ["up 4 days"] }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let days = Int(ProcessInfo.processInfo.systemUptime / 86400)
        return [Self.chip, Fmt.bytes(Int64(ProcessInfo.processInfo.physicalMemory)).replacingOccurrences(of: ".0", with: ""),
                "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""),
                days > 0 ? "up \(days) day\(days == 1 ? "" : "s")" : "up today"].filter { !$0.isEmpty }
    }

    var body: some View {
        let score = model.monitor.status?.health_score
        let (word, tint): (String, Color) = switch score {
        case nil: ("Checking", .secondary)
        case let s? where s >= 80: ("Healthy", Palette.ok)
        case let s? where s >= 60: ("Fair", Palette.warn)
        default: ("Needs attention", Palette.bad)
        }
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Palette.fill, lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(score ?? 0) / 100).stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(score.map(String.init) ?? "–").font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            }
            .frame(width: 46, height: 46)
            .animation(.smooth, value: score)
            .accessibilityElement().accessibilityLabel("Health \(score.map(String.init) ?? "not measured yet") of 100, \(word)")
            VStack(alignment: .leading, spacing: 5) {
                Text(word).font(.system(size: 17, weight: .semibold)).help(model.monitor.status?.health_score_msg ?? "")
                HStack(spacing: 4) {
                    ForEach(facts, id: \.self) { f in
                        Text(f).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.horizontal, 7).frame(height: 19).background(Capsule().fill(Palette.fill))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.bottom, 2)
    }
}

// MARK: - Tiles

/// One live reading: a symbol and name with an optional tag, a big number, a picture of it, and one caption line.
private struct Tile<Picture: View>: View {
    var symbol: String
    var title: String
    var tag: String? = nil
    var tagTint: Color? = nil
    var value: String
    var unit: String
    var caption: String
    /// A small action in the tile's corner (Free Up), with what it last did.
    var action: (title: String, busy: Bool, run: () -> Void)? = nil
    @ViewBuilder var picture: () -> Picture

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent).frame(width: 14)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if let action {
                    Button(action: action.run) {
                        HStack(spacing: 4) {
                            if action.busy { ProgressView().controlSize(.mini) }
                            Text(action.title).font(.system(size: 11, weight: .semibold)).fixedSize()
                        }
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Capsule().fill(Palette.accent.opacity(0.16)))
                        .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain).disabled(action.busy)
                } else if let tag { Tag(text: tag, color: tagTint) }
            }
            .frame(height: 22)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                Text(unit).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            picture().frame(height: 22).padding(.vertical, 6)
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fill))
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Opens a screen when the tile is clicked, with a soft wash under the pointer.
    func onTap(_ action: @escaping () -> Void) -> some View { modifier(Tappable(action: action)) }
}

private struct Tappable: ViewModifier {
    var action: () -> Void
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(hover ? 0.05 : 0)).allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

private func temp(_ c: Double?) -> String? { c.map { "\(Int($0.rounded())) °C" } }

private struct CPUTile: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let m = model.monitor, s = m.sample
        let cores = s.perCore.isEmpty ? ProcessInfo.processInfo.activeProcessorCount : s.perCore.count
        Tile(symbol: "cpu", title: "Processor", tag: temp(m.thermal.cpu), tagTint: (m.thermal.cpu ?? 0) > 95 ? Palette.warn : nil,
             value: "\(Int(s.cpu.rounded()))", unit: "%", caption: String(format: "load %.1f · %d cores", s.load.0, cores)) {
            CoreColumns(values: s.perCore)
        }
    }
}

private struct GPUTile: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let m = model.monitor
        let state = switch m.thermal.state { case .nominal: "cool"; case .fair: "warm"; case .serious: "hot"; case .critical: "very hot"; @unknown default: "—" }
        Tile(symbol: "rectangle.3.group", title: "Graphics", tag: temp(m.thermal.groups.first { $0.id == "gpu" }?.average),
             value: m.sample.gpu.map { "\(Int($0.rounded()))" } ?? "–", unit: "%",
             caption: "Mac is \(state)" + (m.sample.power.map { String(format: " · %.1f W", $0) } ?? "")) {
            Spark(values: m.history.compactMap(\.gpu), max: 100, tint: Palette.accent)
        }
    }
}

private struct MemoryTile: View {
    @Environment(AppModel.self) var model
    @State private var freeing = false
    @State private var freed: Int64?
    var body: some View {
        let m = model.monitor
        let p = m.pressure
        let share = Double(m.memUsed) / Double(max(1, m.memTotal))
        let caption = freed.map { $0 > 0 ? "Freed \(Fmt.bytes($0)) just now" : model.safeMode ? "Safe mode: nothing was freed" : "Nothing more to free" }
            ?? (Demo.on ? "in use" : "\(Fmt.bytes(m.memUsed)) of \(Fmt.bytes(m.memTotal)) · \(["normal", "rising", "high"][p.level])")
        Tile(symbol: "memorychip", title: "Memory", tag: ["Normal", "Rising", "High"][p.level], tagTint: [Palette.ok, Palette.warn, Palette.bad][p.level],
             value: "\(Int((share * 100).rounded()))", unit: "%", caption: caption,
             action: (freeing ? "Freeing" : "Free Up", freeing, {
                 // macOS's purge, which asks for your password; the result is measured, never estimated.
                 Task { freeing = true; freed = await m.freeMemory(simulate: model.safeMode); freeing = false }
             })) {
            Spark(values: m.history.map { Double($0.memory.used) / Double(max(1, $0.memory.total)) * 100 }, max: 100, tint: Palette.accent)
        }
        .help("Free Up releases memory apps no longer use (macOS's purge; it asks for your password) and shows what it actually freed.")
    }
}

private struct DiskTile: View {
    @Environment(AppModel.self) var model
    @Environment(\.openWindow) var openWindow
    var body: some View {
        let d = model.snap.disk
        let used = max(0, d.total - d.free)
        let share = d.total > 0 ? Double(used) / Double(d.total) : 0
        let (v, u) = Fmt.split(d.free)
        let ready = model.awaitingClean && !model.scanIsStale && model.checkupBytes > 0
        Tile(symbol: "internaldrive", title: "Disk", tag: d.total > 0 ? Fmt.bytes(d.total) : nil, value: v, unit: "\(u) free",
             caption: ready ? "\(Fmt.bytes(model.checkupBytes)) ready to clean" : "\(Fmt.bytes(used)) used · \(Int((share * 100).rounded()))%",
             action: (ready ? "Clean" : "Free Up", model.phase == .scanning || model.isCleaning, {
                 // Into Checkup: clean what the last scan bagged, or scan first.
                 if ready { model.cleanRequested = true }
                 model.route = .care
                 NSApp.activate(ignoringOtherApps: true)
                 openWindow(id: "main")
                 if !ready && model.canScan { model.scanAll() }
             })) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.fill)
                    Capsule().fill(share > 0.9 ? Palette.warn : Palette.accent).frame(width: max(8, g.size.width * share))
                }
                .frame(height: 8).frame(maxHeight: .infinity)
            }
        }
    }
}

private struct NetworkTile: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let m = model.monitor
        let down: Fmt.Rate = Fmt.rate(m.sample.netIn), up: Fmt.Rate = Fmt.rate(m.sample.netOut)
        Tile(symbol: "network", title: "Network", value: down.value, unit: down.unit, caption: "↑ \(up.joined) sent") {
            Spark(values: m.history.map(\.netIn), max: nil, tint: Palette.accent)
        }
    }
}

/// Fan speed and the three presets. Changing speed needs Roomy's fan helper; without it the tile says how to allow it.
private struct FanTile: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let f = model.monitor.fans
        let state = !f.hasFans ? "Cools without fans" : f.heldElsewhere ? "Held by another app" : f.preset == .auto ? "Managed by macOS" : "\(f.preset.rawValue) until Roomy quits"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "fan").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent).frame(width: 14)
                Text("Fans").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if f.hasFans { Tag(text: "\(Int((f.share * 100).rounded()))%") }
            }
            .frame(height: 20)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(f.hasFans ? Int(f.rpm).formatted() : "–").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                Text("RPM").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Text(f.problem ?? state).font(.system(size: 11)).foregroundStyle(f.problem == nil ? Color.secondary : Palette.warn).lineLimit(1).padding(.top, 2)
            Spacer(minLength: 6)
            if f.hasFans {
                if f.helper == .ready {
                    Picker("Fan speed", selection: Binding(get: { f.preset }, set: { p in Task { await f.apply(p) } })) {
                        ForEach(Fans.Preset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).disabled(f.busy)
                    .help("Auto lets macOS decide. Cool runs the fans at 60%, Max at full speed. They go back to Auto when Roomy quits.")
                } else {
                    Button(f.helper == .outdated ? "Update Fan Control…" : "Allow Fan Control…") { Task { await f.installHelper() } }
                        .controlSize(.small).disabled(f.busy)
                        .help("Installs a small helper that can only change fan speed. macOS asks for an administrator's password once.")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fill))
        .overlay(alignment: .topTrailing) { if f.busy { ProgressView().controlSize(.mini).padding(12) } }
    }
}

/// One bar per core, as busy as that core is.
private struct CoreColumns: View {
    var values: [Double]
    var body: some View {
        Canvas { ctx, size in
            guard !values.isEmpty else { return }
            let gap: CGFloat = 2.5
            let w = (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * (w + gap)
                let track = Path(roundedRect: CGRect(x: x, y: 0, width: w, height: size.height), cornerRadius: 2)
                ctx.fill(track, with: .color(Palette.fill))
                let h = max(2, size.height * CGFloat(min(100, max(0, v)) / 100))
                ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - h, width: w, height: h), cornerRadius: 2), with: .color(Palette.accent))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Battery, apps, presence, totals

private struct BatteryStrip: View {
    @Environment(AppModel.self) var model
    @State private var sinceFull: SinceFullCharge?
    var body: some View {
        let b = model.monitor.battery
        let state: String = {
            if b.charging { return b.minutesLeft.map { "Charging · \(Self.time($0)) to full" } ?? "Charging" }
            if b.onAC { return b.percent >= 95 ? "Charged" : "Plugged in, not charging" }
            return b.minutesLeft.map { "On battery · \(Self.time($0)) left" } ?? "On battery"
        }()
        let tint = b.percent <= 15 && !b.onAC ? Palette.bad : b.percent <= 30 && !b.onAC ? Palette.warn : Palette.ok
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: b.charging ? "battery.100.bolt" : "battery.100").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                        Text("Battery").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(b.percent)%").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                        Text(state).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    // Health first: it's the number that matters, with the cycle count beside it.
                    if !Demo.on, let h = b.healthPercent {
                        Tag(text: "Health \(h)%" + (b.cycles.map { " · \($0) cycles" } ?? ""), color: h >= 80 ? Palette.ok : Palette.warn)
                            .help("Your battery holds \(h)% of the charge it held when new (System Settings calls this Maximum Capacity). Apple suggests a service below 80%.")
                    } else if let c = b.cycles, !Demo.on { Tag(text: "\(c) cycles") }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.fill)
                            Capsule().fill(tint).frame(width: max(6, g.size.width * CGFloat(b.percent) / 100))
                        }
                    }
                    .frame(width: 120, height: 8)
                }
            }
            if let s = sinceFull, !Demo.on {
                Text(Self.sinceText(s))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .help("Read from macOS's power log, which records the charge each time your Mac switches between battery and power.")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fill))
        .accessibilityElement(children: .combine)
        .task(id: "\(b.onAC)\(b.percent / 5)") {
            sinceFull = await SinceFullCharge.read(now: b.percent, onBattery: !b.onAC)
        }
    }

    /// "Since full 3 h ago: used 86% · 2 h 59 min on battery".
    static func sinceText(_ s: SinceFullCharge) -> String {
        let ago = Date().timeIntervalSince(s.at)
        let when = ago < 3600 ? "\(max(1, Int(ago / 60))) min ago" : ago < 86_400 * 2 ? "\(Int(ago / 3600)) h ago" : "\(Int(ago / 86_400)) days ago"
        if s.used == 0 { return "Full charge \(when) · not used on battery since" }
        return "Since full \(when): used \(s.used)% · \(time(Int(s.onBattery / 60))) on battery"
    }

    static func time(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }
}

private struct TopApps: View {
    @Environment(AppModel.self) var model
    var open: () -> Void
    @State private var byCPU = false

    var body: some View {
        let ncpu = Double(ProcessInfo.processInfo.activeProcessorCount)
        let all = Demo.on ? model.monitor.apps.filter { Demo.processes.contains($0.name) } : model.monitor.apps
        let apps = Array(all.sorted { byCPU ? $0.cpu > $1.cpu : $0.mem > $1.mem }.prefix(5))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Using the most").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                sortButton("Memory", on: !byCPU).frame(width: 72, alignment: .trailing)
                sortButton("CPU", on: byCPU).frame(width: 52, alignment: .trailing)
                Color.clear.frame(width: 26)
            }
            .padding(.bottom, 4)
            if apps.isEmpty {
                Text("Measuring…").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }
            ForEach(apps) { a in
                // Shown like Activity Monitor: 100% is one full core.
                let cpu = a.cpu * ncpu
                HStack(spacing: 8) {
                    if let p = a.path { FileIcon(path: p, size: 16) } else { Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16) }
                    Text(a.name.hasPrefix("com.apple.WebKit") ? "Web pages" : a.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.bytes(a.mem)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                    Text(String(format: "%.1f", cpu)).font(.system(size: 12, weight: cpu >= 80 ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(cpu >= 80 ? Palette.warn : .secondary).frame(width: 52, alignment: .trailing)
                    Menu {
                        if let p = a.path, let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == p }) {
                            Button("Quit \(a.name)") { app.terminate() }
                        }
                        Button("Show in Activity") { open() }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)) }
                    .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).foregroundStyle(.secondary).frame(width: 26)
                    .accessibilityLabel("Actions for \(a.name)")
                }
                .frame(height: 24)
            }
            if !byCPU && !Demo.on { MemoryBreakdown(m: model.monitor.sample.memory).padding(.top, 6) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fill))
    }

    func sortButton(_ title: String, on: Bool) -> some View {
        Button { withAnimation(.snappy) { byCPU = title == "CPU" } } label: {
            HStack(spacing: 2) {
                Text(title)
                if on { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .font(.system(size: 11, weight: on ? .semibold : .regular)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain).help("Sort by \(title.lowercased())")
    }
}

/// Camera and microphone (read every two seconds while the panel is open) beside Keep awake and Keep screen on. Each
/// switch says plainly whether it's on and what that means.
private struct PresenceRow: View {
    @State private var awake = KeepAwake.shared
    @State private var camera = false
    @State private var mic = false

    var body: some View {
        let text = camera && mic ? "Both in use" : camera ? "Camera on" : mic ? "Mic on" : "Not in use"
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                dot("video", on: camera)
                dot("mic", on: mic)
                Text("Camera and mic: " + text.lowercased()).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .help(camera || mic ? "An app is using your \(camera && mic ? "camera and microphone" : camera ? "camera" : "microphone") right now." : "No app is using your camera or microphone.")
            HStack(spacing: 8) {
                pill(on: awake.system, off: "Keep awake", onText: "Staying awake", symbol: "cup.and.saucer") { awake.system.toggle() }
                    .help("Stops your Mac from going to sleep while it's on. Ends when you switch it off or quit Roomy.")
                pill(on: awake.display, off: "Keep screen on", onText: "Screen stays on", symbol: "display") { awake.display.toggle() }
                    .help("Stops the display from dimming or sleeping while it's on. Ends when you switch it off or quit Roomy.")
            }
            if awake.system || awake.display {
                Text(awake.display ? "Your screen won't dim or sleep, and your Mac stays awake, until you switch this off or quit Roomy."
                                   : "Your Mac won't go to sleep until you switch this off or quit Roomy. The screen can still turn off.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.snappy, value: "\(awake.system)\(awake.display)")
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fill))
        .task {
            while !Task.isCancelled {
                let (c, m) = await Task.detached(priority: .utility) { (Presence.cameraInUse(), Presence.microphoneInUse()) }.value
                if c != camera || m != mic { withAnimation(.snappy) { camera = c; mic = m } }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Off: a quiet outline saying what it would do. On: filled with the accent, saying what it's doing.
    func pill(on: Bool, off: String, onText: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(on ? onText : off, systemImage: on && NSImage(systemSymbolName: symbol + ".fill", accessibilityDescription: nil) != nil ? symbol + ".fill" : symbol)
                .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 9).frame(maxWidth: .infinity).frame(height: 26)
                .contentShape(Capsule())
                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
                .background(Capsule().fill(on ? Palette.accent : Color.clear))
                .overlay(Capsule().strokeBorder(on ? Color.clear : Color.primary.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func dot(_ symbol: String, on: Bool) -> some View {
        Image(systemName: on ? symbol + ".fill" : symbol).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(on ? (symbol == "video" ? Palette.ok : Palette.warn) : Color.secondary)
            .frame(width: 16)
    }
}

/// What Roomy has done on this Mac, from History.
private struct TotalsRow: View {
    @Environment(AppModel.self) var model
    var open: () -> Void
    var body: some View {
        let real = model.snap.history.filter { !$0.simulated }
        let freed = real.filter { $0.title != "Maintenance" }.reduce(Int64(0)) { $0 + $1.bytes }
        let removed = real.filter { $0.title.hasPrefix("Uninstalled") }.count
        let tasks = real.filter { $0.title == "Maintenance" }.reduce(0) { $0 + $1.items }
        HStack(spacing: 0) {
            total(Fmt.bytes(freed), "freed")
            Divider().frame(height: 26)
            total("\(removed)", removed == 1 ? "app uninstalled" : "apps uninstalled")
            Divider().frame(height: 26)
            total("\(tasks)", tasks == 1 ? "maintenance task" : "maintenance tasks")
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fill))
        .onTap(open)
        .help("Everything Roomy has removed, from History")
    }
    func total(_ v: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Where all of the Mac's memory is right now, in parts that add up exactly to its RAM: apps, compressed, macOS
/// (wired: the kernel, drivers and the GPU), cached files and free. The app list above shows footprints, like Activity
/// Monitor, which count each app's compressed and swapped-out memory at full size, so those add up to more.
private struct MemoryBreakdown: View {
    var m: MemoryReading
    var body: some View {
        let parts: [(String, Int64, Color)] = [("Apps", m.app, Palette.accent), ("Compressed", m.compressed, Palette.warn),
                                               ("macOS", m.wired, .gray), ("Cached files", m.cached, Palette.ok.opacity(0.7)), ("Free", m.free, .secondary.opacity(0.25))]
        let total = max(1, parts.reduce(0) { $0 + $1.1 })
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(parts, id: \.0) { p in
                        if p.1 > 0 { RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: max(2, g.size.width * CGFloat(p.1) / CGFloat(total))) }
                    }
                }
            }
            .frame(height: 6).clipShape(Capsule())
            Text(parts.filter { $0.1 > 0 }.map { "\($0.0) \(Fmt.bytes($0.1))" }.joined(separator: " · ")
                 + (m.swapUsed > 0 ? " · \(Fmt.bytes(m.swapUsed)) swapped to disk" : ""))
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .help("Your \(Fmt.bytes(m.total)) of memory right now. App sizes above are footprints, as Activity Monitor shows them: they count each app's compressed and swapped-out memory at full size, so together they can add up to more than your memory.")
        .accessibilityElement(children: .combine)
    }
}
