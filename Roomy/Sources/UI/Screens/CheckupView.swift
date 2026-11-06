import SwiftUI

/// Checkup: the room fills the window. The headline sits at the top, a strip of scan tiles above the bottom edge, and
/// the one action is the orb hanging off the window's bottom edge. As each part of the scan reports, its finds light
/// up and are tossed one by one into the bag by the bin; your own files go back on the shelf.
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
    private let orb = OrbPanel.shared

    var safeBytes: Int64 { model.checkupBytes }
    var reviewBytes: Int64 { model.snap.largeFiles.filter { !LargeFilesView.info($0).locked }.reduce(0) { $0 + $1.bytes } + model.snap.duplicates.reduce(0) { $0 + $1.wasted } }
    var progress: Double { Double(model.finished.count) / Double(AppModel.steps.count) }
    var showingAccess: Bool { model.needsAccessStep && model.phase != .scanning && (model.phase == .idle || model.accessPrompted) }

    /// What's in the room: one bucket per place Checkup cleans, plus your own files, which stay.
    var buckets: [RoomScene.Bucket] {
        let s = model.snap
        var out: [RoomScene.Bucket] = [Route.systemJunk, .userCache, .developer, .mail, .trash, .systemData].map { r in
            let b = r.categories.compactMap { s.category($0) }.flatMap(\.items)
                .filter { $0.byMole == true }.reduce(0) { $0 + $1.bytes }
            return RoomScene.Bucket(key: r.rawValue, step: "cleanup", color: NSColor(r.gradient.last ?? .gray), bytes: b, removable: true)
        }
        out.append(RoomScene.Bucket(key: Route.large.rawValue, step: "large", color: .brown, bytes: reviewBytes, removable: false))
        return out
    }

    var body: some View {
        ZStack {
            RoomSceneView(room: room, dark: scheme == .dark, paint: model.theme.paint, reduceMotion: reduceMotion) { key in
                if let r = Route(rawValue: key) { model.route = r }
            }
            .ignoresSafeArea()

            // A soft veil under the headline, so the words read against any wall colour.
            LinearGradient(colors: [(scheme == .dark ? Color.black : .white).opacity(scheme == .dark ? 0.5 : 0.55), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.34))
                .ignoresSafeArea().allowsHitTesting(false)

            // A veil along the left edge so the rail reads over the room.
            LinearGradient(colors: [(scheme == .dark ? Color.black : .white).opacity(scheme == .dark ? 0.45 : 0.5), .clear],
                           startPoint: .leading, endPoint: UnitPoint(x: 0.12, y: 0.5))
                .ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
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
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
                .transition(.asymmetric(insertion: AnyTransition(.blurReplace).combined(with: .offset(y: 10)), removal: .opacity.animation(.easeOut(duration: 0.12))))
                .id(headlineKey)
                Spacer(minLength: 0)
                if model.phase != .idle && !showingAccess && !model.engineMissing {
                    ScanStrip(tiles: tiles, scanning: model.phase == .scanning)
                        .padding(.bottom, 74)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.top, 62).padding(.horizontal, 110)
            .animation(.smooth(duration: 0.5), value: headlineKey)
            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: model.phase)

            // Return triggers the orb's action from the main window too.
            Button("", action: primary).keyboardShortcut(.defaultAction).opacity(0).frame(width: 0, height: 0)
                .disabled(!orb.state.enabled || !orb.state.visible).accessibilityHidden(true)
        }
        .onAppear { syncOrb(); orb.state.action = primary }
        .onAppear {
            // Clean pressed on a cleanup module: settle the findings, then open the review.
            guard model.cleanRequested else { return }
            model.cleanRequested = false
            guard model.checkupBytes > 0, !model.scanIsStale, model.phase != .scanning else { return }
            model.awaitingClean = true
            model.phase = .done
            room.settle(buckets, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { showReview = true }
        }
        .onChange(of: orbKey) { syncOrb() }
        .onChange(of: model.theme.id) { syncOrb() }
        // The room tells the scan's story: untidy before, each finding tossed into the bag by the bin as its part of the
        // scan reports, books back on the shelf, and the bag into the bin on Clean. Starting a scan moves nothing.
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
        // Testing aid, demo only: `-RoomyOpenReview YES` opens the review once the scan is done, for screenshots.
        .onChange(of: model.phase) { _, phase in
            if Demo.on, phase == .done, UserDefaults.standard.bool(forKey: "RoomyOpenReview") {
                Task { try? await Task.sleep(for: .seconds(2.5)); showReview = true }
            }
        }
        .confirmationDialog("Scan without Full Disk Access?", isPresented: $confirmNoAccess) {
            Button("Scan Anyway") { model.scanWithoutAccess = true; model.scanAll() }
        } message: {
            Text("macOS will ask before Roomy looks in Desktop, Documents and Downloads, and in other apps' data, one question for each. Anything you don't allow is skipped. You can allow Full Disk Access later in Settings.")
        }
    }

    var headlineKey: String {
        if model.engineMissing { return "engine" }
        if showingAccess { return "access" }
        switch model.phase {
        case .idle: return "idle"
        case .scanning: return "scanning"
        case .done: return justCleaned ? "cleaned" : "done"
        }
    }

    // MARK: words

    var idle: some View {
        VStack(spacing: 10) {
            Text("Let's make some room").font(.system(size: 42, weight: .bold)).tracking(-0.9)
            Text("Checkup gathers caches, logs and leftovers into one bag, puts your own files back on the shelf, and shows Mole’s cleanup preview before you choose Clean.")
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var access: some View {
        VStack(spacing: 12) {
            Text("First, let Roomy look around").font(.system(size: 36, weight: .bold)).tracking(-0.7)
            Text("macOS asks before an app opens your Desktop, Documents and Downloads, or another app's data, once for each. Allow Full Disk Access and Roomy can look everywhere without a question for every folder. A scan only reads; nothing changes until you choose.")
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if openedSettings {
                Label("Switch on Roomy in the list, or add it with +. If Roomy doesn't notice, quit and reopen it.", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button { FullDiskAccess.openSettings(); openedSettings = true } label: { Text("Open Privacy & Security").padding(.horizontal, 6) }
                        .buttonStyle(.glassProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
                    Button("Scan Without It") { confirmNoAccess = true }
                        .buttonStyle(.glass).controlSize(.extraLarge)
                }
            }
            .padding(.top, 8)
        }
    }

    var engine: some View {
        VStack(spacing: 10) {
            Text("One thing first").font(.system(size: 36, weight: .bold)).tracking(-0.7)
            Text("Roomy cleans with Mole, a free, open-source cleaner with careful safety rules. It comes inside Roomy, but this copy of Roomy was built without it. Reinstall Roomy, or install Mole with Homebrew (brew install mole), then reopen Roomy.")
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var scanning: some View {
        // The same words as the tile that's open in the strip.
        let current = tiles.first { $0.phase == .active }
        return VStack(spacing: 8) {
            Text("Tidying up…").font(.system(size: 42, weight: .bold)).tracking(-0.9)
            Text(current.map { $0.verb + "…" } ?? "Finishing up").font(.system(size: 15)).foregroundStyle(.secondary)
                .contentTransition(.opacity).animation(.easeOut, value: current?.id)
        }
    }

    var headline: some View {
        VStack(spacing: 4) {
            if justCleaned, let r = model.lastResult {
                Text(r.simulated ? Fmt.bytes(r.bytes) : "Freed \(Fmt.bytes(r.bytes))").font(.system(size: 60, weight: .bold, design: .rounded)).monospacedDigit().tracking(-1)
                    .contentTransition(.numericText(value: Double(r.bytes)))
                Text(r.simulated ? (Demo.on ? "This is a demo, so nothing was removed. This is what Clean would free." : "Safe mode is on, so nothing was removed. This is what Clean would free.")
                     : ["\(r.items) items removed", r.trashed.map { "\(Fmt.bytes($0)) of it in the Trash" }, r.failures.map { "\($0.count) couldn't be removed" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                Button("See what was removed") { model.route = .history }.buttonStyle(.link).padding(.top, 4)
            } else {
                Text(Fmt.bytes(safeBytes)).font(.system(size: 60, weight: .bold, design: .rounded)).monospacedDigit().tracking(-1)
                    .contentTransition(.numericText(value: Double(safeBytes)))
                Text(model.awaitingClean && model.scanIsStale ? "found more than an hour ago. Scan again before cleaning."
                     : safeBytes > 0 ? "estimated by Mole’s preview" : "Mole found nothing more to clean")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                if model.awaitingClean && safeBytes > 0 && !model.scanIsStale {
                    Button { showReview = true } label: {
                        Label("Review what's in the bag", systemImage: "list.bullet").font(.system(size: 13, weight: .medium)).padding(.horizontal, 4)
                    }
                    .buttonStyle(.glass).tint(model.theme.accent ?? .accentColor).controlSize(.large).padding(.top, 10)
                    .help("See Mole’s grouped cleanup preview")
                    .disabled(cleaning)
                }
            }
        }
    }

    // MARK: the orb

    /// Everything the orb shows, so it updates only when one of these changes.
    var orbKey: String {
        [headlineKey, "\(model.finished.count)", "\(model.awaitingClean)", "\(model.scanIsStale)", "\(cleaning)", "\(showReview)",
         "\(safeBytes)", "\(model.canScan)", "\(model.isCleaning)"].joined(separator: "|")
    }

    func syncOrb() {
        let s = orb.state
        s.tint = Ground.tint(.checkup, model.theme)
        s.action = primary
        s.progress = nil; s.busy = false; s.enabled = true; s.help = ""
        guard !model.engineMissing, !showingAccess, !showReview else { orb.show(false); return }
        switch model.phase {
        case .idle:
            s.title = "Scan"; s.enabled = model.canScan; s.help = "Scan your Mac (⌘R). Nothing changes while it scans."
        case .scanning:
            // Stays lit while it works; pressing it does nothing until the scan is done.
            s.title = "\(Int(progress * 100))%"; s.progress = progress; s.help = "Scanning"
        case .done:
            if cleaning || model.isCleaning { s.busy = true; s.enabled = false; s.title = "" }
            else if model.awaitingClean && !model.scanIsStale {
                s.title = "Clean"; s.enabled = safeBytes > 0; s.help = "Clean \(Fmt.bytes(safeBytes))"
            } else {
                s.title = "Scan"; s.enabled = model.canScan
                s.help = model.scanIsStale ? "This scan is more than an hour old. Scan again so Clean works on what's on your Mac now." : "Scan again"
            }
        }
        orb.show(true)
    }

    /// The orb's action: scan, or clean what this scan bagged. One at a time.
    func primary() {
        switch model.phase {
        case .scanning: return
        case .done where model.awaitingClean && !model.scanIsStale: showReview = true
        default: model.scanAll()
        }
    }

    func clean() {
        guard !cleaning, !model.isCleaning else { return }
        cleaning = true
        room.throwAway()
        Task {
            await model.smartClean()
            // Let the bag land before the number changes.
            try? await Task.sleep(for: .milliseconds(2200))
            withAnimation(.smooth) { justCleaned = true; cleaning = false; model.awaitingClean = false }
        }
    }

    // MARK: the strip

    var broken: Int { model.snap.startup?.items.filter { $0.state == .broken }.count ?? 0 }

    var tiles: [ScanTile] {
        let s = model.snap
        let off = s.protection.filter { $0.on == false }.count
        let leftovers = s.leftovers.filter { !$0.review }.reduce(0) { $0 + $1.bytes }
        let state = { (steps: [String]) -> ScanTile.Phase in
            steps.allSatisfy { model.finished.contains($0) } ? .done : .waiting
        }
        var out: [ScanTile] = [
            ScanTile(id: "junk", route: .userCache, title: "Cleanup", steps: ["cleanup", "ai", "dev"], verb: "Gathering caches and leftovers",
                     value: Fmt.bytes(safeBytes), detail: "to clean", phase: state(["cleanup", "ai", "dev"])) {
                if model.awaitingClean && !model.scanIsStale { showReview = true } else { model.route = .userCache }
            },
            ScanTile(id: "files", route: .large, title: "Your files", steps: ["lens", "large", "dups"], verb: "Shelving big and duplicate files",
                     value: Fmt.bytes(reviewBytes), detail: "for you to review", phase: state(["lens", "large", "dups"])) { model.route = .large },
            ScanTile(id: "apps", route: .uninstaller, title: "Applications", steps: ["apps"], verb: "Checking apps and what they left behind",
                     value: s.outdated.isEmpty ? (leftovers > 0 ? Fmt.bytes(leftovers) : "Up to date") : "\(s.outdated.count) update\(s.outdated.count == 1 ? "" : "s")",
                     detail: s.outdated.isEmpty ? (leftovers > 0 ? "of leftovers" : "nothing to do") : "to install",
                     phase: state(["apps"])) { model.route = s.outdated.isEmpty ? .leftovers : .updates },
            ScanTile(id: "health", route: .protection, title: "Protection", steps: ["health"], verb: "Checking protection and upkeep",
                     value: off == 0 ? "All on" : "\(off) off", detail: off == 0 ? "macOS protections" : "worth a look",
                     phase: state(["health"])) { model.route = .protection },
        ]
        // While scanning, the first part still running is the one that opens up.
        if model.phase == .scanning, let i = out.firstIndex(where: { $0.phase != .done }) { out[i].phase = .active }
        if model.phase != .scanning, broken > 0 {
            out.append(ScanTile(id: "startup", route: .startup, title: "Startup", steps: [], verb: "", value: "\(broken) broken",
                                detail: "helpers whose app is gone", phase: .done) { model.route = .startup })
        }
        return out
    }
}

/// One part of the scan as a tile in the strip.
struct ScanTile: Identifiable {
    enum Phase { case waiting, active, done }
    var id: String
    var route: Route
    var title: String
    var steps: [String]
    var verb: String
    var value: String
    var detail: String
    var phase: Phase
    var action: () -> Void
}

/// The scan as a strip of glass tiles: the part being scanned opens wide and fills with its colour, finished parts
/// close up to show what they found, and parts still waiting stay quiet. When the scan is done the tiles are the
/// summary: each opens its module.
struct ScanStrip: View {
    var tiles: [ScanTile]
    var scanning: Bool
    @Namespace private var ns

    var body: some View {
        GeometryReader { geo in
            let total = min(geo.size.width, 1040)
            let weights = tiles.map { $0.phase == .active ? 2.6 : 1.0 }
            let gap: CGFloat = 10
            let unit = (total - gap * CGFloat(tiles.count - 1)) / CGFloat(weights.reduce(0, +))
            GlassEffectContainer(spacing: gap) {
                HStack(spacing: gap) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { i, t in
                        TileView(tile: t, scanning: scanning)
                            .frame(width: max(60, unit * weights[i]), height: 86)
                            .glassEffect(t.phase == .active ? .regular.tint(LiquidStyle.of(t.route).mid.opacity(0.26)).interactive()
                                         : .regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
                            .glassEffectID(t.id, in: ns)
                    }
                }
            }
            .frame(width: total)
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.62, dampingFraction: 0.78), value: tiles.map { "\($0.id)\($0.phase)" })
        }
        .frame(height: 86)
    }
}

struct TileView: View {
    var tile: ScanTile
    var scanning: Bool
    @State private var hover = false

    var body: some View {
        Button(action: tile.action) {
            Group {
                switch tile.phase {
                case .active:
                    HStack(spacing: 14) {
                        LiquidIcon(route: tile.route, size: 46, interactive: false)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tile.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Text(tile.verb + "…").font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                            ShimmerBar()
                        }
                        Spacer(minLength: 0)
                    }
                case .done:
                    HStack(spacing: 10) {
                        LiquidIcon(route: tile.route, size: 30, interactive: false)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(tile.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                            Text(tile.value).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                                .contentTransition(.numericText())
                            Text(tile.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if !scanning {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                                .opacity(hover ? 1 : 0.5)
                        }
                    }
                case .waiting:
                    HStack(spacing: 10) {
                        LiquidIcon(route: tile.route, size: 30, interactive: false).saturation(0.35).opacity(0.75)
                        Text(tile.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary.opacity(0.8)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .transition(AnyTransition(.blurReplace))
        }
        .buttonStyle(.plain)
        .disabled(scanning)
        .onHover { hover = $0 }
        .accessibilityLabel(tile.phase == .done ? "\(tile.title): \(tile.value) \(tile.detail)" : tile.phase == .active ? "\(tile.title): scanning" : "\(tile.title): waiting")
    }
}

/// An indeterminate progress line: a soft light sliding along a track.
struct ShimmerBar: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var x: CGFloat = -0.4
    var body: some View {
        GeometryReader { g in
            Capsule().fill(Color.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [.clear, Color.primary.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * 0.4)
                        .offset(x: g.size.width * x)
                }
                .clipShape(Capsule())
        }
        .frame(height: 3)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { x = 1.0 }
        }
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
