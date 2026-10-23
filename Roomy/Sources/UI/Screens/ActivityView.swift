import SwiftUI
import Charts

/// Activity: one place for what the Mac is doing right now. Six resources across the top; the chosen one opens into
/// its charts, the numbers Activity Monitor shows (each explains itself on hover) and every process using it.
struct ActivityView: View {
    @Environment(AppModel.self) var model
    @AppStorage("activityResource") private var resourceRaw = Resource.cpu.rawValue
    @State private var selection: Set<Int32> = []
    @State private var search = ""
    @State private var scope = Scope.all
    @State private var confirmQuit: ProcessRow?
    @State private var freeing = false
    @State private var freed: Int64?

    enum Scope: String, CaseIterable { case all = "All Processes", mine = "My Processes", apps = "Apps" }

    var resource: Resource { Resource(rawValue: resourceRaw) ?? .cpu }
    var m: Monitor { model.monitor }

    var rows: [ProcessRow] {
        m.processes.filter { r in
            (scope == .all || scope == .mine && r.mine || scope == .apps && r.mine && r.appPath != nil)
                && (search.isEmpty || r.name.localizedCaseInsensitiveContains(search) || String(r.pid) == search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Each section reads the monitor inside its own view, so a new process list doesn't redraw the charts and a
            // new reading doesn't redraw 400 table rows.
            // Glass controls stay outside the live views: redrawing them every update would keep restarting their springs.
            ScreenHeader(title: "Activity", subtitle: subtitle) {
                HStack(spacing: 10) {
                    Live { LiveDot(live: m.lastUpdate != nil) }
                    Button { ActivityMonitorApp.open() } label: { Label("Activity Monitor", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.glass).help("Open Apple's Activity Monitor")
                }
            }
            Live { cards }.padding(.horizontal, 28).padding(.bottom, 12)
            if resource == .thermals {
                ScrollView { ThermalsPanel().padding(.horizontal, 28).padding(.bottom, 24) }
            } else {
                if resource == .memory {
                    // Memory: where it is and what would help, side by side, so the process list keeps its room.
                    Live { MemoryPanels { freeUp } }.padding(.horizontal, 28).padding(.bottom, 12)
                } else {
                    Live { detail }.padding(.horizontal, 28).padding(.bottom, 12)
                }
                processes.padding(.horizontal, 28).padding(.bottom, 16)
            }
        }
        .onAppear { m.watchProcesses() }
        .onDisappear { m.unwatchProcesses() }
        .confirmationDialog("Quit \(confirmQuit?.name ?? "this process")?", isPresented: Binding(get: { confirmQuit != nil }, set: { if !$0 { confirmQuit = nil } }), presenting: confirmQuit) { p in
            Button("Quit") { if !m.quit(p, force: false) { model.flash("\(p.name) didn't quit.") } }
            Button("Force Quit", role: .destructive) { if !m.quit(p, force: true) { model.flash("\(p.name) couldn't be force quit.") } }
        } message: { p in
            Text(ActivityMonitorApp.restartsItself.contains(p.name) ? "macOS starts \(p.name) again on its own." : "Unsaved changes in \(p.name) may be lost if you force it to quit.")
        }
    }

    var subtitle: String {
        if Demo.on { return Demo.hardware }
        let s = m.status
        return [s?.hardware?.cpu_model, Fmt.bytes(Int64(ProcessInfo.processInfo.physicalMemory)) + " memory", s?.hardware?.os_version, s?.uptime.map { "up \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: resource cards

    var cards: some View {
        let h = m.history
        let s = m.sample
        return HStack(spacing: 10) {
            card(.cpu, value: "\(Int(s.cpu.rounded()))", unit: "%", caption: "\(Int(s.user.rounded()))% user · \(Int(s.system.rounded()))% system", series: h.map(\.cpu), max: 100)
            card(.memory, value: Fmt.split(m.memUsed).0, unit: Fmt.split(m.memUsed).1, caption: m.pressure.label, series: h.map(\.memory.pressurePercent), max: 100,
                 tint: [Palette.ok, Palette.warn, Palette.bad][m.pressure.level])
            card(.energy, value: s.power.map { String(format: "%.1f", $0) } ?? "—", unit: "W",
                 caption: m.battery.present ? "\(m.battery.percent)% · \(m.battery.charging ? "charging" : m.battery.onAC ? "on power" : "on battery")" : "Whole Mac",
                 series: h.map { $0.power ?? 0 }, max: nil)
            card(.disk, value: Fmt.rate(s.diskRead + s.diskWrite).value, unit: Fmt.rate(s.diskRead + s.diskWrite).unit, caption: "\(Fmt.rate(s.diskRead).joined) read",
                 series: h.map { $0.diskRead + $0.diskWrite }, max: nil)
            card(.network, value: Fmt.rate(s.netIn + s.netOut).value, unit: Fmt.rate(s.netIn + s.netOut).unit, caption: "\(Fmt.rate(s.netIn).joined) in",
                 series: h.map { $0.netIn + $0.netOut }, max: nil)
            card(.thermals, value: m.thermal.cpu.map { "\(Int($0.rounded()))" } ?? "—", unit: "°C",
                 caption: m.fans.hasFans ? "\(Int(m.fans.rpm).formatted()) RPM fans" : ThermalsPanel.stateLabel(m.thermal.state),
                 series: m.tempHistory.map(\.1), max: nil, tint: ThermalsPanel.color(m.thermal.cpu ?? 0))
        }
        .frame(height: 104)
    }

    func card(_ r: Resource, value: String, unit: String, caption: String, series: [Double], max: Double?, tint: Color? = nil) -> some View {
        let on = resource == r
        return Button { withAnimation(.snappy) { resourceRaw = r.rawValue; selection = [] } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: r.symbol).font(.system(size: 11, weight: .semibold))
                    Text(r.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spark(values: series, max: max, tint: tint ?? Palette.accent).frame(height: 18)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(Palette.accent.opacity(0.22)) : .regular, in: .rect(cornerRadius: 14))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: detail

    @ViewBuilder var detail: some View {
        let s = m.sample, mem = s.memory
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                chart.frame(maxWidth: .infinity).frame(height: 132)
                if resource == .memory { MemoryBar(memory: mem) }
                if resource == .cpu, !s.perCore.isEmpty { CoreBars(cores: s.perCore) }
            }
            VStack(alignment: .leading, spacing: 5) {
                switch resource {
                case .cpu:
                    MetricRow("User", "\(f1(s.user))%", Explain.user, swatch: Palette.accent)
                    MetricRow("System", "\(f1(s.system))%", Explain.system, swatch: Palette.bad)
                    MetricRow("Idle", "\(f1(s.idle))%", Explain.idle)
                    MetricRow("Load average", String(format: "%.2f · %.2f · %.2f", s.load.0, s.load.1, s.load.2), Explain.load)
                    MetricRow("Processes", m.processCount > 0 ? m.processCount.formatted() : "—", Explain.processes)
                    MetricRow("Threads", m.threadCount > 0 ? m.threadCount.formatted() : "—", Explain.threads)
                    MetricRow("Graphics", s.gpu.map { "\(Int($0))%" } ?? "—", Explain.gpu)
                case .memory:
                    MetricRow("Physical memory", Fmt.bytes(mem.total), Explain.physical)
                    MetricRow("Memory used", Fmt.bytes(mem.used), Explain.used)
                    MetricRow("App memory", Fmt.bytes(mem.app), Explain.app, swatch: Palette.accent)
                    MetricRow("Wired memory", Fmt.bytes(mem.wired), Explain.wired, swatch: Palette.warn)
                    MetricRow("Compressed", Fmt.bytes(mem.compressed), Explain.compressed, swatch: .purple)
                    MetricRow("Cached files", Fmt.bytes(mem.cached), Explain.cached, swatch: .secondary)
                    MetricRow("Swap used", Fmt.bytes(mem.swapUsed), Explain.swap)
                    freeUp
                case .energy:
                    MetricRow("System power", s.power.map { String(format: "%.1f W", $0) } ?? "—", Explain.power)
                    if m.battery.present {
                        MetricRow("Battery", "\(m.battery.percent)%", Explain.battery)
                        MetricRow(m.battery.charging ? "Until full" : "Time left", m.battery.minutesLeft.map { "\($0 / 60) h \($0 % 60) min" } ?? (m.battery.onAC && !m.battery.charging ? "On power" : "Calculating"), Explain.timeLeft)
                        if let c = m.battery.cycles { MetricRow("Charge cycles", "\(c)", Explain.cycles) }
                        if let hl = m.battery.health { MetricRow("Condition", hl, Explain.condition) }
                    } else {
                        MetricRow("Power source", "Power adapter", Explain.desktopPower)
                    }
                    MetricRow("Graphics", s.gpu.map { "\(Int($0))%" } ?? "—", Explain.gpu)
                case .disk:
                    MetricRow("Data read", Fmt.rate(s.diskRead).joined, Explain.dataRead, swatch: Palette.accent)
                    MetricRow("Data written", Fmt.rate(s.diskWrite).joined, Explain.dataWritten, swatch: Palette.bad)
                    MetricRow("Reads", "\(Int(s.diskReadOps)) /s", Explain.reads)
                    MetricRow("Writes", "\(Int(s.diskWriteOps)) /s", Explain.writes)
                    MetricRow("Free space", Fmt.bytes(model.snap.disk.free), Explain.freeSpace)
                case .network:
                    MetricRow("Data received", Fmt.rate(s.netIn).joined, Explain.received, swatch: Palette.accent)
                    MetricRow("Data sent", Fmt.rate(s.netOut).joined, Explain.sent, swatch: Palette.warn)
                    MetricRow("Packets in", "\(Int(s.packetsIn)) /s", Explain.packets)
                    MetricRow("Packets out", "\(Int(s.packetsOut)) /s", Explain.packets)
                case .thermals: EmptyView()
                }
            }
            .frame(width: 270)
        }
        .padding(14)
        .glass(14)
    }

    @ViewBuilder var chart: some View {
        let h = m.history
        switch resource {
        case .cpu:
            LiveChart(series: [.init(name: "System", color: Palette.bad, values: h.map(\.system)), .init(name: "User", color: Palette.accent, values: h.map(\.user))],
                      stacked: true, top: 100, label: { "\(Int($0))%" })
        case .memory:
            LiveChart(series: [.init(name: "Memory pressure", color: [Palette.ok, Palette.warn, Palette.warn, Palette.bad, Palette.bad][min(4, m.sample.memory.pressureLevel)],
                                     values: h.map(\.memory.pressurePercent))], stacked: true, top: 100, label: { "\(Int($0))%" })
                .overlay(alignment: .topLeading) { Explained(Explain.pressure) { Text("Memory pressure").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(6) } }
        case .energy:
            LiveChart(series: [.init(name: "Power", color: Palette.warn, values: h.map { $0.power ?? 0 })], stacked: false, top: nil, label: { "\(Int($0)) W" })
        case .disk:
            LiveChart(series: [.init(name: "Read", color: Palette.accent, values: h.map(\.diskRead)), .init(name: "Written", color: Palette.bad, values: h.map(\.diskWrite))],
                      stacked: false, top: nil, label: { Fmt.rate($0).joined })
        case .network:
            LiveChart(series: [.init(name: "Received", color: Palette.accent, values: h.map(\.netIn)), .init(name: "Sent", color: Palette.warn, values: h.map(\.netOut))],
                      stacked: false, top: nil, label: { Fmt.rate($0).joined })
        case .thermals: EmptyView()
        }
    }

    var freeUp: some View {
        Button(freeing ? "Freeing…" : freed.map { $0 > 0 ? "Freed \(Fmt.bytes($0))" : "Free Up Memory" } ?? "Free Up Memory") {
            freeing = true
            Task {
                let f = await m.freeMemory(simulate: model.safeMode)
                freed = f; freeing = false
                if model.safeMode { model.flash("Safe mode: memory wasn't purged. Turn Safe mode off in Settings to use Free Up.") }
            }
        }
        .controlSize(.small).disabled(freeing).padding(.top, 2)
        .help(Explain.freeUp)
    }

    func f1(_ v: Double) -> String { String(format: "%.1f", v) }

    // MARK: processes

    var processes: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("View", selection: $scope) { ForEach(Scope.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("Search processes", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Live {
                    if let p = selectedRow {
                        Button { reveal(p.path ?? p.appPath ?? "") } label: { Image(systemName: "magnifyingglass") }
                            .help("Show in Finder").disabled(p.path == nil && p.appPath == nil)
                        Button("Quit…") { confirmQuit = p }
                            .disabled(!p.mine).help(p.mine ? "Quit \(p.name)" : "Belongs to macOS or another user, so it can't be quit from here.")
                    }
                }
                Text(resource.tableNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
            Live {
                ProcessTable(resource: resource, rows: rows, selection: $selection) { p in confirmQuit = p }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { if m.processes.isEmpty { ProgressView("Reading processes…").controlSize(.small) } }
            }
        }
    }

    var selectedRow: ProcessRow? { selection.count == 1 ? m.processes.first { $0.pid == selection.first } : nil }
}

/// Evaluates its content in its own body, so whatever the content reads is tracked for this view alone.
struct Live<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

enum Resource: String, CaseIterable {
    case cpu, memory, energy, disk, network, thermals
    var title: String { ["CPU", "Memory", "Energy", "Disk", "Network", "Thermals"][Self.allCases.firstIndex(of: self)!] }
    var symbol: String { ["cpu", "memorychip", "bolt", "internaldrive", "network", "thermometer.medium"][Self.allCases.firstIndex(of: self)!] }
    var tableNote: String {
        switch self {
        case .cpu: "100% is one core, as in Activity Monitor"
        case .memory: "Memory each process holds right now"
        case .energy: "Energy impact, macOS's own score"
        case .disk: "Your processes; macOS's own are private"
        case .network: "Per second, averaged over a few seconds"
        case .thermals: ""
        }
    }
}

// MARK: - Process table

struct ProcessTable: View {
    var resource: Resource
    var rows: [ProcessRow]
    @Binding var selection: Set<Int32>
    var quit: (ProcessRow) -> Void
    @State private var cpuSort = [KeyPathComparator(\ProcessRow.cpu, order: .reverse)]
    @State private var memSort = [KeyPathComparator(\ProcessRow.memory, order: .reverse)]
    @State private var energySort = [KeyPathComparator(\ProcessRow.energy, order: .reverse)]
    @State private var diskSort = [KeyPathComparator(\ProcessRow.diskTotal, order: .reverse)]
    @State private var netSort = [KeyPathComparator(\ProcessRow.netTotal, order: .reverse)]

    var body: some View {
        Group {
            switch resource {
            case .cpu, .thermals:
                Table(rows.sorted(using: cpuSort), selection: $selection, sortOrder: $cpuSort) {
                    TableColumn("Process", value: \.name) { ProcessName(row: $0) }.width(min: 200, ideal: 280)
                    TableColumn("% CPU", value: \.cpu) { Text(String(format: "%.1f", $0.cpu)).monospacedDigit() }.width(70)
                    TableColumn("CPU Time", value: \.cpuTime) { Text($0.cpuTime).monospacedDigit() }.width(80)
                    TableColumn("Threads", value: \.threads) { Text("\($0.threads)").monospacedDigit() }.width(60)
                    TableColumn("PID", value: \.pid) { Text("\($0.pid)").monospacedDigit().foregroundStyle(.secondary) }.width(60)
                    TableColumn("User", value: \.user) { Text($0.user).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                }
            case .memory:
                Table(rows.sorted(using: memSort), selection: $selection, sortOrder: $memSort) {
                    TableColumn("Process", value: \.name) { ProcessName(row: $0) }.width(min: 200, ideal: 280)
                    TableColumn("Memory", value: \.memory) { Text(Fmt.bytes($0.memory)).monospacedDigit() }.width(80)
                    TableColumn("Threads", value: \.threads) { Text("\($0.threads)").monospacedDigit() }.width(60)
                    TableColumn("Ports", value: \.ports) { Text("\($0.ports)").monospacedDigit() }.width(60)
                    TableColumn("PID", value: \.pid) { Text("\($0.pid)").monospacedDigit().foregroundStyle(.secondary) }.width(60)
                    TableColumn("User", value: \.user) { Text($0.user).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                }
            case .energy:
                Table(rows.sorted(using: energySort), selection: $selection, sortOrder: $energySort) {
                    TableColumn("Process", value: \.name) { ProcessName(row: $0) }.width(min: 200, ideal: 280)
                    TableColumn("Energy Impact", value: \.energy) { Text(String(format: "%.1f", $0.energy)).monospacedDigit() }.width(100)
                    TableColumn("% CPU", value: \.cpu) { Text(String(format: "%.1f", $0.cpu)).monospacedDigit() }.width(70)
                    TableColumn("PID", value: \.pid) { Text("\($0.pid)").monospacedDigit().foregroundStyle(.secondary) }.width(60)
                    TableColumn("User", value: \.user) { Text($0.user).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                }
            case .disk:
                Table(rows.sorted(using: diskSort), selection: $selection, sortOrder: $diskSort) {
                    TableColumn("Process", value: \.name) { ProcessName(row: $0) }.width(min: 200, ideal: 280)
                    TableColumn("Read /s", value: \.diskReadValue) { Text($0.diskRead.map { Fmt.rate($0).joined } ?? "—").monospacedDigit() }.width(90)
                    TableColumn("Written /s", value: \.diskWriteValue) { Text($0.diskWrite.map { Fmt.rate($0).joined } ?? "—").monospacedDigit() }.width(90)
                    TableColumn("PID", value: \.pid) { Text("\($0.pid)").monospacedDigit().foregroundStyle(.secondary) }.width(60)
                    TableColumn("User", value: \.user) { Text($0.user).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                }
            case .network:
                Table(rows.sorted(using: netSort), selection: $selection, sortOrder: $netSort) {
                    TableColumn("Process", value: \.name) { ProcessName(row: $0) }.width(min: 200, ideal: 280)
                    TableColumn("Received /s", value: \.netIn) { Text(Fmt.rate($0.netIn).joined).monospacedDigit() }.width(90)
                    TableColumn("Sent /s", value: \.netOut) { Text(Fmt.rate($0.netOut).joined).monospacedDigit() }.width(90)
                    TableColumn("PID", value: \.pid) { Text("\($0.pid)").monospacedDigit().foregroundStyle(.secondary) }.width(60)
                    TableColumn("User", value: \.user) { Text($0.user).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                }
            }
        }
        .contextMenu(forSelectionType: Int32.self) { ids in
            if let id = ids.first, let p = rows.first(where: { $0.pid == id }) {
                Button("Quit…") { quit(p) }.disabled(!p.mine)
                if let path = p.path ?? p.appPath { Button("Show in Finder") { reveal(path) } }
                Button("Copy PID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(p.pid)", forType: .string) }
            }
        }
    }
}

extension ProcessRow {
    var diskReadValue: Double { diskRead ?? -1 }
    var diskWriteValue: Double { diskWrite ?? -1 }
    var diskTotal: Double { (diskRead ?? 0) + (diskWrite ?? 0) }
    var netTotal: Double { netIn + netOut }
}

struct ProcessName: View {
    var row: ProcessRow
    var body: some View {
        HStack(spacing: 7) {
            if let p = row.appPath ?? row.path { FileIcon(path: p, size: 16) } else { Image(systemName: "gearshape").frame(width: 16).foregroundStyle(.secondary) }
            Text(row.name).lineLimit(1)
        }
        .help(row.path ?? row.name)
    }
}

// MARK: - Thermals

struct ThermalsPanel: View {
    @Environment(AppModel.self) var model

    static func color(_ c: Double) -> Color { c >= 90 ? Palette.bad : c >= 75 ? Palette.warn : c > 0 ? Palette.ok : .secondary }
    static func stateLabel(_ s: ProcessInfo.ThermalState) -> String {
        switch s { case .nominal: "Running cool"; case .fair: "Warm"; case .serious: "Slowing down to cool"; case .critical: "Too hot"; @unknown default: "Unknown" }
    }

    var body: some View {
        let m = model.monitor
        let t = m.thermal
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Explained(Explain.thermalState) {
                        HStack(spacing: 8) {
                            Circle().fill(t.state == .nominal ? Palette.ok : t.state == .fair ? Palette.warn : Palette.bad).frame(width: 9, height: 9)
                            Text(Self.stateLabel(t.state)).font(.system(size: 17, weight: .semibold))
                        }
                    }
                    Text(t.state == .nominal || t.state == .fair ? "macOS isn't limiting performance to cool down." : "macOS is slowing the processor to bring temperatures down.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Chart(Array(m.tempHistory.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("Time", p.0), y: .value("°C", p.1)).foregroundStyle(Self.color(p.1).opacity(0.25)).interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.0), y: .value("°C", p.1)).foregroundStyle(Self.color(p.1)).interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 20...110).chartXAxis(.hidden)
                    .chartYAxis { AxisMarks(values: [40, 70, 100]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)°") } } }
                    .frame(height: 140)
                    Text("Processor temperature, last three minutes").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass(14)
                FanPanel().frame(width: 300)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(t.groups) { g in
                    Explained(g.explain + " Average of \(g.count) sensor\(g.count == 1 ? "" : "s"); the hottest reads \(Int(g.hottest.rounded())) °C.") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(g.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(Int(g.average.rounded()))").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text("°C").font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            Gauge(value: min(1, max(0, (g.average - 20) / 90))) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity).tint(Self.color(g.average))
                            Text("Hottest \(Int(g.hottest.rounded())) °C").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass(14)
                    }
                }
            }
            if t.groups.isEmpty { Text("This Mac doesn't report temperatures to apps.").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
}

struct FanPanel: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let f = model.monitor.fans
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Fans", systemImage: "fan").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if f.hasFans { Tag(text: f.heldElsewhere ? "Held by another app" : f.preset == .auto ? "Managed by macOS" : f.preset.rawValue) }
            }
            if !f.hasFans {
                Text("This Mac cools itself without fans.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                ForEach(f.fans, id: \.id) { fan in
                    Explained("Fan \(fan.id + 1) spins between \(Int(fan.min).formatted()) and \(Int(fan.max).formatted()) RPM. macOS speeds it up as the processor warms.") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(f.fans.count > 1 ? (fan.id == 0 ? "Left" : "Right") : "Fan").font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(fan.rpm).formatted()) RPM").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                            }
                            Gauge(value: fan.max > 0 ? min(1, fan.rpm / fan.max) : 0) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity).tint(Palette.accent)
                        }
                    }
                }
                if f.helper == .ready {
                    Picker("Fan speed", selection: Binding(get: { f.preset }, set: { p in Task { await f.apply(p) } })) {
                        ForEach(Fans.Preset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().disabled(f.busy)
                    Text(f.preset == .auto ? "macOS decides. Cool runs the fans at 60%, Max at full speed. Back to Auto when Roomy quits." : "Back to Auto when Roomy quits.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Button(f.helper == .outdated ? "Update Fan Control…" : "Allow Fan Control…") { Task { await f.installHelper() } }
                        .disabled(f.busy)
                    Text("Installs a small helper that can only change fan speed. macOS asks for an administrator's password once.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let p = f.problem { Text(p).font(.system(size: 11)).foregroundStyle(Palette.warn) }
                if f.busy { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Waiting for the fans…").font(.system(size: 11)).foregroundStyle(.secondary) } }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass(14)
    }
}

// MARK: - Small parts

/// A three-minute chart drawn as paths: stacked areas (CPU, memory) or lines with a soft fill (disk, network, power),
/// with three gridlines and a legend. Cheap enough to redraw every two seconds.
struct LiveChart: View {
    struct Series { var name: String; var color: Color; var values: [Double] }
    var series: [Series]
    var stacked: Bool
    var top: Double?
    var label: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if series.count > 1 || !stacked {
                HStack(spacing: 12) {
                    ForEach(series, id: \.name) { s in HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 8, height: 8); Text(s.name) } }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Canvas { ctx, size in
                let n = series.map(\.values.count).max() ?? 0
                let sums = (0..<n).map { i in series.reduce(0.0) { $0 + ($1.values.indices.contains(i) ? $1.values[i] : 0) } }
                let peak = stacked ? (sums.max() ?? 0) : (series.flatMap(\.values).max() ?? 0)
                let ceiling = Swift.max(top ?? peak * 1.15, 0.0001)
                let labelW: CGFloat = 54
                let w = size.width - labelW, hgt = size.height
                for f in [0.0, 0.5, 1.0] {
                    let y = hgt - CGFloat(f) * hgt
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: w, y: y)) }, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
                    ctx.draw(Text(label(ceiling * f)).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: w + 4, y: Swift.min(Swift.max(y, 6), hgt - 6)), anchor: .leading)
                }
                guard n > 1 else { return }
                let step = w / CGFloat(Swift.max(1, Monitor.historyLength - 1))
                let x0 = w - CGFloat(n - 1) * step
                func y(_ v: Double) -> CGFloat { hgt - CGFloat(Swift.min(v, ceiling) / ceiling) * hgt }
                var base = [Double](repeating: 0, count: n)
                for s in series {
                    let vals = (0..<n).map { s.values.indices.contains($0) ? s.values[$0] : 0 }
                    let upper = stacked ? zip(base, vals).map(+) : vals
                    var line = Path()
                    for i in 0..<n { let p = CGPoint(x: x0 + CGFloat(i) * step, y: y(upper[i])); if i == 0 { line.move(to: p) } else { line.addLine(to: p) } }
                    var area = line
                    for i in stride(from: n - 1, through: 0, by: -1) { area.addLine(to: CGPoint(x: x0 + CGFloat(i) * step, y: stacked ? y(base[i]) : hgt)) }
                    area.closeSubpath()
                    ctx.fill(area, with: .color(s.color.opacity(stacked ? 0.7 : 0.16)))
                    if !stacked { ctx.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)) }
                    if stacked { base = upper }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.map { "\($0.name) \(label($0.values.last ?? 0))" }.joined(separator: ", "))
    }
}

/// A small area line, drawn as one path: far cheaper than a chart for six cards that redraw every two seconds.
struct Spark: View {
    var values: [Double]
    var max: Double?
    var tint: Color
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let top = Swift.max(max ?? (values.max() ?? 1) * 1.15, 0.0001)
            let step = size.width / CGFloat(Swift.max(1, Monitor.historyLength - 1))
            let x0 = size.width - CGFloat(values.count - 1) * step
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: x0 + CGFloat(i) * step, y: size.height - CGFloat(Swift.min(v, top) / top) * size.height)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: x0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.32), tint.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct MemoryBar: View {
    var memory: MemoryReading
    var body: some View {
        let parts: [(String, Int64, Color)] = [("App", memory.app, Palette.accent), ("Wired", memory.wired, Palette.warn), ("Compressed", memory.compressed, .purple),
                                              ("Cached", memory.cached, .secondary.opacity(0.5))]
        GeometryReader { g in
            HStack(spacing: 1.5) {
                ForEach(parts, id: \.0) { p in
                    Rectangle().fill(p.2).frame(width: max(0, g.size.width * CGFloat(p.1) / CGFloat(max(1, memory.total))))
                        .help("\(p.0): \(Fmt.bytes(p.1))")
                }
                Spacer(minLength: 0)
            }
            .clipShape(Capsule())
            .background(Capsule().fill(Palette.fill))
        }
        .frame(height: 8)
    }
}

struct CoreBars: View {
    var cores: [Double]
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 2).fill(Palette.accent.opacity(0.35 + v / 160)).frame(height: max(2, 22 * v / 100))
                    .help("Core \(i + 1): \(Int(v))%")
            }
        }
        .frame(height: 22, alignment: .bottom)
    }
}

struct LiveDot: View {
    var live: Bool
    var body: some View {
        HStack(spacing: 6) {
            // Still on purpose: a repeating symbol effect redraws the whole glass window every frame (about 17% CPU).
            Circle().fill(live ? Palette.ok : Palette.ink3).frame(width: 7, height: 7)
            Text(live ? "Live" : "Connecting").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// A number with its meaning: hovering the row explains what it measures.
struct MetricRow: View {
    var title: String
    var value: String
    var explain: String
    var swatch: Color?
    init(_ title: String, _ value: String, _ explain: String, swatch: Color? = nil) { self.title = title; self.value = value; self.explain = explain; self.swatch = swatch }
    var body: some View {
        Explained(explain) {
            HStack(spacing: 6) {
                if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8) }
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
    }
}

/// Shows an explanation beside anything you point at for a moment.
struct Explained<Content: View>: View {
    var text: String
    @ViewBuilder var content: Content
    @State private var hovering = false
    @State private var shown = false
    init(_ text: String, @ViewBuilder content: () -> Content) { self.text = text; self.content = content() }
    var body: some View {
        content
            .onHover { h in
                hovering = h
                if h { Task { try? await Task.sleep(for: .milliseconds(450)); if hovering { shown = true } } } else { shown = false }
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text).font(.system(size: 12)).frame(width: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(12)
            }
            .accessibilityHint(text)
    }
}

enum ActivityMonitorApp {
    static let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
    static func open() { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    static let restartsItself: Set<String> = ["Dock", "Finder", "SystemUIServer", "ControlCenter", "NotificationCenter", "Spotlight", "WindowManager"]
}

/// What each number means, in plain words.
enum Explain {
    static let user = "Time the processor spends running apps and the programs you use."
    static let system = "Time the processor spends inside macOS itself: drivers, file systems, networking."
    static let idle = "Time the processor has nothing to do. Higher is calmer."
    static let load = "How many tasks were running or waiting for the processor on average over the last 1, 5 and 15 minutes. Below the number of cores is comfortable."
    static let processes = "Programs running right now, including macOS's own background ones."
    static let threads = "Separate lines of work inside those programs. Thousands is normal."
    static let gpu = "How busy the graphics processor is. Video, games, animations and AI models use it."
    static let physical = "The memory chips in this Mac."
    static let used = "App memory plus wired plus compressed memory, the same sum Activity Monitor shows. Other monitors often count it as total minus available, so their number can differ by a gigabyte or two."
    static let app = "Memory apps and their helpers are using for their own data."
    static let wired = "Memory macOS keeps for itself and can't compress or move to disk."
    static let compressed = "Memory macOS squeezed to make room, instead of writing it to disk. A lot of it means memory is tight."
    static let cached = "Files macOS kept in memory so they open fast next time. It's given back the moment apps need it, so it doesn't count as used."
    static let swap = "Memory macOS moved to the SSD because RAM was full. Some is normal; a growing amount with high pressure means the Mac needs more memory than it has."
    static let pressure = "How hard macOS is working to find memory, from the kernel's own pressure level: green is fine, yellow means it's compressing a lot, red means it's swapping and things slow down. This is what Activity Monitor graphs."
    static let freeUp = "Runs macOS's purge to drop cached files from memory. It needs your password, and usually makes little difference: macOS frees cache on its own when apps need memory."
    static let power = "What the whole Mac draws right now, read from its power controller, in watts."
    static let battery = "How full the battery is."
    static let timeLeft = "macOS's estimate at the current power draw."
    static let cycles = "Each full discharge counts as one cycle. Mac batteries are rated for about 1,000."
    static let condition = "macOS's verdict on the battery's health."
    static let desktopPower = "This Mac has no battery; it runs on its power adapter."
    static let dataRead = "Data read from the internal SSD per second."
    static let dataWritten = "Data written to the internal SSD per second. Swap and big copies show up here."
    static let reads = "Read requests the SSD handles per second."
    static let writes = "Write requests the SSD handles per second."
    static let freeSpace = "Space left on the startup disk."
    static let received = "Data arriving over Wi-Fi, Ethernet and other networks per second."
    static let sent = "Data leaving this Mac per second."
    static let packets = "Network packets per second. Many small packets with little data is typical for video calls and games."
    static let thermalState = "macOS's own verdict on heat. When it's serious or critical, macOS slows the processor to cool down; Activity Monitor doesn't show this."
}

/// Activity's Memory view: two panels side by side, the same height. Left, where the Mac's memory is; right, what
/// would help. They stack when the window is too narrow for both.
struct MemoryPanels<FreeUp: View>: View {
    @ViewBuilder var freeUp: FreeUp
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                MemoryOverview(freeUp: { freeUp }).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                MemoryAdviceCard().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 720)
            VStack(spacing: 12) {
                MemoryOverview(freeUp: { freeUp })
                MemoryAdviceCard()
            }
        }
    }
}

/// Where the Mac's memory is, as one bar the width of its RAM: apps, macOS, compressed, cached files and free, which add
/// up to the whole bar. Swap is a hatched piece outside the bar, so "full, and spilling onto the SSD" reads at a glance.
struct MemoryOverview<FreeUp: View>: View {
    @Environment(AppModel.self) var model
    @ViewBuilder var freeUp: FreeUp

    var body: some View {
        let m = model.monitor.sample.memory
        let level = model.monitor.pressure.level
        let tint = [Palette.ok, Palette.warn, Palette.bad][level]
        let parts = [MemoryPart(name: "Apps", bytes: m.app, color: Palette.accent, help: Explain.app),
                     MemoryPart(name: "macOS", bytes: m.wired, color: Color.primary.opacity(0.38), help: Explain.wired),
                     MemoryPart(name: "Compressed", bytes: m.compressed, color: Palette.warn, help: Explain.compressed),
                     MemoryPart(name: "Cached files", bytes: m.cached, color: Palette.accent.opacity(0.3), help: Explain.cached),
                     MemoryPart(name: "Free", bytes: m.free, color: Color.primary.opacity(0.08), help: "Memory nothing is using right now.")]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Where your \(Fmt.bytes(m.total)) is").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Explained(Explain.pressure) {
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        Text(["Pressure normal", "Pressure rising", "Pressure high"][level]).font(.system(size: 11.5, weight: .medium)).foregroundStyle(tint)
                        Spark(values: model.monitor.history.map(\.memory.pressurePercent), max: 100, tint: tint).frame(width: 64, height: 16)
                    }
                }
            }
            MemoryMap(parts: parts, total: m.total, swap: m.swapUsed)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(parts) { p in
                    Explained(p.help) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            RoundedRectangle(cornerRadius: 2.5).fill(p.color).frame(width: 9, height: 9).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(Fmt.bytes(p.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            }
                        }
                    }
                }
                if m.swapUsed > 0 {
                    Explained(Explain.swap) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Hatch(color: Palette.bad).frame(width: 9, height: 9).clipShape(RoundedRectangle(cornerRadius: 2.5)).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            VStack(alignment: .leading, spacing: 1) {
                                Text("On the SSD").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(Fmt.bytes(m.swapUsed)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Explained(Explain.used) {
                    Text("\(Fmt.bytes(m.used)) in use, as Activity Monitor counts it").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                freeUp
            }
        }
        .padding(14)
        .glass(14)
    }
}

/// One part of the Mac's memory, as the bar and its legend show it.
struct MemoryPart: Identifiable { var id: String { name }; var name: String; var bytes: Int64; var color: Color; var help: String }

/// The bar: RAM as its full width, split into its parts, and swap as a hatched piece past its end.
struct MemoryMap: View {
    var parts: [MemoryPart]
    var total: Int64
    var swap: Int64
    var body: some View {
        GeometryReader { g in
            let over = swap > 0 ? min(0.45, Double(swap) / Double(max(1, total))) : 0
            let gap: CGFloat = over > 0 ? 6 : 0
            let ram = (g.size.width - gap) / CGFloat(1 + over)
            let sum = max(1, parts.reduce(0) { $0 + $1.bytes })
            HStack(spacing: gap) {
                HStack(spacing: 1.5) {
                    ForEach(parts) { p in
                        if p.bytes > 0 { Rectangle().fill(p.color).frame(width: max(2, ram * CGFloat(p.bytes) / CGFloat(sum))) }
                    }
                }
                .frame(width: ram, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                if over > 0 {
                    Hatch(color: Palette.bad)
                        .frame(width: max(8, g.size.width - ram - gap))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.bad.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
            }
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(parts.map { "\($0.name) \(Fmt.bytes($0.bytes))" }.joined(separator: ", ") + (swap > 0 ? ", and \(Fmt.bytes(swap)) moved to the SSD" : ""))
    }
}

/// Diagonal stripes: memory that isn't in RAM any more.
struct Hatch: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.12)))
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width { p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0)); x += 5 }
            ctx.stroke(p, with: .color(color.opacity(0.55)), lineWidth: 1.4)
        }
    }
}

/// What would help: a one-line verdict, apps open but not in use (with what quitting each frees), the apps macOS has
/// squeezed most (as a bar of how much of each is squeezed), and the most useful tip. From live readings only.
struct MemoryAdviceCard: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let a = model.monitor.memoryAdvice
        let total = model.monitor.sample.memory.total
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                // Worded to agree with the pressure shown beside it: "tight" only when macOS itself says so.
                Image(systemName: a.pressured ? "exclamationmark.triangle.fill" : a.tight ? "arrow.down.right.and.arrow.up.left.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(a.pressured ? Palette.warn : a.tight ? Palette.accent : Palette.ok)
                Text(a.pressured ? (a.wanted > total ? "Open apps want \(Fmt.bytes(a.wanted)) on a \(Fmt.bytes(total)) Mac" : "Memory is tight")
                     : a.tight ? "Memory is full, and macOS is coping by squeezing what apps aren't using" : "Memory is fine")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .help(a.summary)
            if !a.idle.isEmpty {
                section("Open but not in use", trailing: "frees about \(Fmt.bytes(a.idleTotal))") {
                    ForEach(a.idle.prefix(3)) { i in
                        HStack(spacing: 8) {
                            FileIcon(path: i.path, size: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(i.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(i.lastUsed).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(Fmt.bytes(i.footprint)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                            Button("Quit") { quit(i.path, i.name) }.controlSize(.small)
                                .help("Asks \(i.name) to quit, the same as ⌘Q: it can ask you to save first.")
                        }
                    }
                }
            }
            if !a.pushedOut.isEmpty {
                section("Squeezed or on the SSD", trailing: nil) {
                    ForEach(a.pushedOut.prefix(a.idle.isEmpty ? 4 : 2)) { p in
                        HStack(spacing: 8) {
                            if let path = p.path { FileIcon(path: path, size: 18) } else { Image(systemName: "gearshape").frame(width: 18) }
                            Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 6)
                            SqueezeBar(share: Double(p.compressed) / Double(max(1, p.footprint))).frame(width: 64, height: 6)
                            Text("\(Fmt.bytes(p.compressed)) of \(Fmt.bytes(p.footprint))").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(minWidth: 92, alignment: .trailing)
                        }
                        .help("macOS has compressed or moved to the SSD \(Fmt.bytes(p.compressed)) of the \(Fmt.bytes(p.footprint)) \(p.name) holds: memory it isn't using right now.")
                    }
                }
            }
            if let tip = a.tips.first {
                Label { Text(tip).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "lightbulb").font(.system(size: 10)).foregroundStyle(Palette.accent)
                }
                .help(a.tips.joined(separator: "\n\n"))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glass(14)
    }

    @ViewBuilder func section<Rows: View>(_ title: String, trailing: String?, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let trailing { Text("· " + trailing).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            rows()
        }
    }

    func quit(_ path: String, _ name: String) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
        guard !apps.isEmpty else { return }
        apps.forEach { $0.terminate() }
        model.flash("Asked \(name) to quit.")
    }
}

/// How much of an app's memory macOS has squeezed: the amber part is compressed or on the SSD, the rest is in use.
struct SqueezeBar: View {
    var share: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.accent.opacity(0.35))
                Capsule().fill(Palette.warn).frame(width: g.size.width * CGFloat(min(1, max(0, share))))
            }
        }
        .accessibilityHidden(true)
    }
}
