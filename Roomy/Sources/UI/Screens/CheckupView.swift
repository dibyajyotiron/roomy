import SwiftUI

/// Checkup: the room fills the window. What the scan finds lands in it; the words and the one action sit
/// bottom left, like a show page in the TV app, and the summary sits on glass bottom right.
struct CheckupView: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var justCleaned = false
    @State private var cleaning = false
    @State private var openedSettings = false
    @State private var confirmNoAccess = false
    @State private var showReview = false
    private let room = RoomScene.shared

    var safeBytes: Int64 { model.checkupBytes }
    var reviewBytes: Int64 { model.snap.largeFiles.filter { !LargeFilesView.info($0).locked }.reduce(0) { $0 + $1.bytes } + model.snap.duplicates.reduce(0) { $0 + $1.wasted } }
    var progress: Double { Double(model.finished.count) / Double(AppModel.steps.count) }
    var showingAccess: Bool { model.needsAccessStep && model.phase != .scanning && (model.phase == .idle || model.accessPrompted) }

    /// What's in the room: one bucket per place Checkup cleans, plus your own files, which stay.
    var buckets: [RoomScene.Bucket] {
        let s = model.snap
        var out: [RoomScene.Bucket] = [Route.systemJunk, .userCache, .developer, .mail, .systemData].map { r in
            let b = r.categories.compactMap { s.category($0) }.flatMap(\.items).filter { $0.byMole == true }.reduce(0) { $0 + $1.bytes }
            return RoomScene.Bucket(key: r.rawValue, step: "cleanup", color: NSColor(r.gradient.last ?? .gray), bytes: b, removable: true)
        }
        out.append(RoomScene.Bucket(key: Route.aiCare.rawValue, step: "ai", color: NSColor(Route.aiCare.gradient.last ?? .gray),
                                    bytes: model.checkupItems.reduce(0) { $0 + $1.bytes }, removable: true))
        out.append(RoomScene.Bucket(key: Route.large.rawValue, step: "large", color: .brown, bytes: reviewBytes, removable: false))
        return out
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomSceneView(room: room, dark: scheme == .dark, paint: model.theme.paint, reduceMotion: reduceMotion) { key in
                if let r = Route(rawValue: key) { model.route = r }
            }
            .backgroundExtensionEffect()
            .ignoresSafeArea()

            HStack(alignment: .bottom, spacing: 32) {
                VStack(alignment: .leading, spacing: 22) {
                    Group {
                        if model.engineMissing { engine }
                        else if showingAccess { access }
                        else {
                            switch model.phase {
                            case .idle: idle
                            case .scanning: scanning
                            case .done: headline
                            }
                        }
                    }
                    // The old words leave at once so two headlines never overlap; the new ones rise in.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .identity))
                    dock
                }
                .frame(maxWidth: 520, alignment: .leading)
                .animation(.smooth(duration: 0.45), value: model.phase)
                .animation(.smooth(duration: 0.45), value: showingAccess)
                Spacer(minLength: 0)
                if model.phase == .done && !showingAccess { results.transition(.opacity.combined(with: .offset(y: 12))) }
            }
            .padding(.horizontal, 40).padding(.bottom, 36)
            .animation(.smooth, value: model.phase)
        }
        // The room tells the scan's story: untidy before, each finding swept into a trash bag by the bin as its part
        // of the scan reports, and the bags into the bin on Clean. Starting a scan moves nothing.
        .onAppear {
            switch model.phase {
            case .done: if model.awaitingClean { room.settle(buckets, animated: false) }   // after a clean the room stays tidy
            case .idle: room.scatter(buckets, animated: false)
            case .scanning: room.scatter(buckets, animated: false); room.collect(buckets, finished: Set(model.finished))
            }
        }
        .onAppear { model.monitor.watch() }
        .onDisappear { model.monitor.unwatch() }
        .onChange(of: model.phase) { old, new in
            if new == .scanning { justCleaned = false; room.beginScan() }
            if old == .scanning && new == .done { room.settle(buckets, animated: true) }
        }
        .onChange(of: model.finished.count) { if model.phase == .scanning { room.collect(buckets, finished: Set(model.finished)) } }
        .onChange(of: buckets) { if model.phase == .done && model.awaitingClean && !cleaning { room.settle(buckets, animated: true) } }
        .onChange(of: model.hasFullDiskAccess) { _, granted in
            // Access granted while a scan was waiting: start it.
            if granted && model.accessPrompted { model.scanAll() }
        }
        .sheet(isPresented: $showReview) { CheckupReview(onClean: clean).environment(model) }
        .confirmationDialog("Scan without Full Disk Access?", isPresented: $confirmNoAccess) {
            Button("Scan Anyway") { model.scanWithoutAccess = true; model.scanAll() }
        } message: {
            Text("macOS will ask before Roomy looks in Desktop, Documents and Downloads, and in other apps' data, one question for each. Anything you don't allow is skipped. You can allow Full Disk Access later in Settings.")
        }
    }

    // MARK: words

    var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Let's make some room").font(.system(size: 40, weight: .bold)).tracking(-0.8)
            Text("Checkup looks at caches, logs, developer and AI leftovers, large files and your Mac's health, then shows what's safe before anything is touched.")
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var access: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("First, let Roomy look around").font(.system(size: 36, weight: .bold)).tracking(-0.7)
            Text("macOS asks before an app opens your Desktop, Documents and Downloads, or another app's data, once for each. Allow Full Disk Access and Roomy can look everywhere without a question for every folder. A scan only reads; nothing changes until you choose.")
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if openedSettings {
                Label("Switch on Roomy in the list, or add it with +. If Roomy doesn't notice, quit and reopen it.", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var engine: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One thing first").font(.system(size: 36, weight: .bold)).tracking(-0.7)
            Text("Roomy cleans with Mole, a free, open-source cleaner with careful safety rules. It comes inside Roomy, but this copy of Roomy was built without it. Reinstall Roomy, or install Mole with Homebrew (brew install mole), then reopen Roomy.")
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var scanning: some View {
        let current = AppModel.steps.first { model.running.contains($0.id) && !model.finished.contains($0.id) }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Looking around…").font(.system(size: 40, weight: .bold)).tracking(-0.8)
            Text(current?.title ?? "Finishing up").font(.system(size: 15)).foregroundStyle(.secondary)
                .contentTransition(.opacity).animation(.easeOut, value: current?.id)
            HStack(spacing: 6) {
                ForEach(AppModel.steps, id: \.id) { s in
                    let done = model.finished.contains(s.id)
                    Capsule().fill(done ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.quaternary)).frame(width: done ? 30 : 18, height: 5)
                        .animation(.spring(duration: 0.45, bounce: 0.3), value: done)
                        .help(s.title)
                }
            }
            .padding(.top, 2)
        }
    }

    var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            if justCleaned, let r = model.lastResult {
                Text(r.simulated ? Fmt.bytes(r.bytes) : "Freed \(Fmt.bytes(r.bytes))").font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit().tracking(-1)
                    .contentTransition(.numericText(value: Double(r.bytes)))
                Text(r.simulated ? "Safe mode is on, so nothing was removed. This is what Clean would free."
                     : ["\(r.items) items removed", r.trashed.map { "\(Fmt.bytes($0)) of it in the Trash" }, r.failures.map { "\($0.count) couldn't be removed" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                Button("See what was removed") { model.route = .history }.buttonStyle(.link).padding(.top, 2)
            } else {
                Text(Fmt.bytes(safeBytes)).font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit().tracking(-1)
                    .contentTransition(.numericText(value: Double(safeBytes)))
                Text(model.awaitingClean && model.scanIsStale ? "found more than an hour ago. Scan again before cleaning."
                     : safeBytes > 0 ? "safe to clean right now" : "Nothing left that's safe to clean automatically")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: actions

    @ViewBuilder var dock: some View {
        if model.engineMissing {
            EmptyView()
        } else if showingAccess {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button { FullDiskAccess.openSettings(); openedSettings = true } label: { Text("Open Privacy & Security").padding(.horizontal, 6) }
                        .buttonStyle(.glassProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
                    Button("Scan Without It") { confirmNoAccess = true }
                        .buttonStyle(.glass).controlSize(.extraLarge)
                }
            }
        } else {
            switch model.phase {
            case .idle:
                Button { model.scanAll() } label: { Text("Scan").frame(minWidth: 120) }
                    .buttonStyle(.glassProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
            case .scanning:
                Text("\(Int(progress * 100))%").font(.system(size: 15, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
                    .frame(width: 120, height: 40).glassEffect(.regular, in: .capsule)
            case .done:
                // One action at a time: clean what this scan bagged, then the room is ready to scan again.
                if model.awaitingClean && model.scanIsStale && !cleaning {
                    // Guardrail: never clean on findings that may no longer be true.
                    Button { model.scanAll() } label: { Text("Scan Again").frame(minWidth: 120) }
                        .buttonStyle(.glassProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
                        .help("This scan is more than an hour old. Scan again so Clean works on what's on your Mac now.")
                } else if cleaning {
                    // A live capsule, not a greyed-out button: a clean can take a minute and must never look stuck.
                    CleaningCapsule()
                } else if model.awaitingClean {
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            Button { clean() } label: { Text("Clean \(Fmt.bytes(safeBytes))").frame(minWidth: 120) }
                                .buttonStyle(.glassProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
                                .disabled(safeBytes == 0 || model.isCleaning)
                            Button("Review…") { showReview = true }
                                .buttonStyle(.glass).controlSize(.extraLarge)
                                .help("See and choose everything Clean will remove")
                        }
                    }
                } else {
                    Button { model.scanAll() } label: { Text("Scan").frame(minWidth: 120) }
                        .buttonStyle(.glassProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    func clean() {
        guard !cleaning, !model.isCleaning else { return }
        cleaning = true
        room.throwAway()
        Task {
            await model.smartClean()
            // Let the last piece land before the number changes.
            try? await Task.sleep(for: .milliseconds(2600))
            withAnimation(.smooth) { justCleaned = true; cleaning = false; model.awaitingClean = false }
        }
    }

    // MARK: summary

    var broken: Int { model.snap.launchItems.filter { $0.broken != nil }.count }
    var speedDetail: String {
        if let top = model.monitor.apps.max(by: { $0.cpu < $1.cpu }), top.cpu >= 25 { return "\(top.name) is busy right now" }
        return "Memory and processor, live"
    }

    var results: some View {
        let off = model.snap.protection.filter { $0.on == false }.count
        return VStack(alignment: .leading, spacing: 0) {
            ResultRow(route: .userCache, title: "Cleanup", detail: "Caches, logs and old versions · review the list", value: Fmt.bytes(safeBytes)) {
                if model.awaitingClean { showReview = true } else { model.route = .userCache }
            }
            Divider().padding(.leading, 58)
            ResultRow(route: .large, title: "Your review", detail: "Large files and duplicates", value: Fmt.bytes(reviewBytes)) { model.route = .large }
            Divider().padding(.leading, 58)
            ResultRow(route: .protection, title: "Protection", detail: off == 0 ? "All of macOS's protections are on" : "Some protections are off",
                      value: off == 0 ? "All on" : "\(off) off") { model.route = .protection }
            Divider().padding(.leading, 58)
            ResultRow(route: .status, title: "Speed", detail: speedDetail, value: model.monitor.pressure.label.replacingOccurrences(of: "Pressure ", with: "").capitalized) { model.route = .status }
            if let t = model.snap.trashBytes, t > 0 {
                Divider().padding(.leading, 58)
                ResultRow(route: .trash, title: "Trash", detail: "Never emptied by Checkup: it's your undo", value: Fmt.bytes(t)) { model.route = .trash }
            }
            if broken > 0 {
                Divider().padding(.leading, 58)
                ResultRow(route: .startup, title: "Startup Items", detail: "Helpers whose app is gone", value: "\(broken) broken") { model.route = .startup }
            }
            Group {
                if let at = model.snap.scannedAt {
                    Text("Scanned \(at.formatted(.relative(presentation: .named))). Click anything in the room to see where it came from.")
                } else {
                    Text("Click anything in the room to see where it came from.")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
        }
        .padding(.top, 4)
        .frame(width: 380)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// One summary row: identity, what it is, the number, and a way into the module.
struct ResultRow: View {
    var route: Route
    var title: String
    var detail: String
    var value: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                LiquidIcon(route: route, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHover()
    }
}

/// Shown in place of Clean while a clean runs: a spinner and the time so far, so it's clear Roomy is working.
struct CleaningCapsule: View {
    @State private var started = Date()
    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { ctx in
            let secs = Int(ctx.date.timeIntervalSince(started))
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Cleaning…").font(.system(size: 15, weight: .semibold))
                if secs >= 3 {
                    Text(secs < 60 ? "\(secs)s" : "\(secs / 60)m \(secs % 60)s")
                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary).contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 22).frame(minWidth: 160, minHeight: 40)
            .glassEffect(.regular, in: .capsule)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cleaning")
    }
}
