import Foundation
import AppKit
import Sparkle
import os

/// Roomy updates itself with Sparkle (MIT). Once a day it checks Roomy's releases on GitHub. When there's a newer
/// version, a download button appears in the sidebar above the disk. One click downloads it, checks its EdDSA signature
/// against the key built into Roomy (so only an update signed by Roomy's maintainer can install), then quits Roomy,
/// installs it and reopens it. No windows, no banners, and nothing downloads until you click.
@MainActor @Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    enum State: Equatable { case off, idle, checking, available(String), downloading(String), ready(String), failed(String) }
    var state: State = .off
    /// How much of the update has downloaded, 0...1, while that's known.
    var progress: Double?
    var lastChecked: Date?
    /// Checking once a day on its own (Settings). Off means Roomy only looks when you ask.
    var automatic = true {
        didSet { updater?.automaticallyChecksForUpdates = automatic }
    }

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var installNow: (() -> Void)?
    /// Sparkle's question "download and install this update?", answered when the button is clicked.
    @ObservationIgnored private var startDownload: (() -> Void)?
    @ObservationIgnored private var pendingVersion = ""
    @ObservationIgnored private var expectedBytes: UInt64 = 0
    @ObservationIgnored private var receivedBytes: UInt64 = 0
    nonisolated static let log = Logger(subsystem: "app.roomy", category: "update")

    var isReady: Bool { if case .ready = state { true } else { false } }
    /// An update has been found, is downloading or is ready: the sidebar shows the update button.
    var hasUpdate: Bool {
        switch state { case .available, .downloading, .ready: true; default: false }
    }

    /// Starts the daily check. Off in demo mode and in builds without an update key (development builds).
    func start() {
        guard updater == nil, !Demo.on,
              (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else { return }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do { try u.start() } catch {
            Self.log.error("updater didn't start: \(error.localizedDescription, privacy: .public)")
            return
        }
        // A first launch turns checking on; after that it's whatever was chosen in Settings.
        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil { u.automaticallyChecksForUpdates = true }
        // Nothing downloads on its own: a found update waits for the button.
        u.automaticallyDownloadsUpdates = false
        updater = u
        automatic = u.automaticallyChecksForUpdates
        state = .idle
        lastChecked = u.lastUpdateCheckDate
        if automatic, lastChecked.map({ Date().timeIntervalSince($0) > 20 * 3600 }) ?? true { checkNow() }
    }

    /// Looks for an update now, still without any windows: if there's a newer version, the update button appears.
    func checkNow() {
        guard let updater, !hasUpdate, updater.canCheckForUpdates else { return }
        state = .checking
        updater.checkForUpdatesInBackground()
    }

    /// The update button: downloads the update if it isn't yet, then quits Roomy, installs it and reopens Roomy.
    func update() {
        switch state {
        case .available(let v):
            guard let startDownload else { return }
            Self.log.info("downloading \(v, privacy: .public)")
            self.startDownload = nil
            progress = nil; expectedBytes = 0; receivedBytes = 0
            state = .downloading(v)
            startDownload()
        case .ready: installAndRelaunch()
        default: break
        }
    }

    private func installAndRelaunch() {
        guard let installNow else { return }
        Self.log.info("installing \(self.pendingVersion, privacy: .public) and relaunching")
        self.installNow = nil
        installNow()
    }

    private func available(_ version: String, download: @escaping () -> Void) {
        startDownload = download
        pendingVersion = version
        state = .available(version)
        Self.log.info("update \(version, privacy: .public) is available")
        // Testing aid: `-RoomyInstallUpdateWhenReady YES` downloads and installs at once, the same as clicking the button.
        if UserDefaults.standard.bool(forKey: "RoomyInstallUpdateWhenReady") { update() }
    }

    /// Downloaded and verified. Clicking already asked for it, so it installs straight away.
    private func ready(_ version: String, install: @escaping () -> Void) {
        installNow = install
        pendingVersion = version
        state = .ready(version)
        progress = 1
        Self.log.info("update \(version, privacy: .public) is ready; installing")
        installAndRelaunch()
    }

    private func settle(_ error: Error? = nil) {
        lastChecked = updater?.lastUpdateCheckDate ?? Date()
        guard !hasUpdate else { return }
        if let error, (error as NSError).code != Int(SUError.noUpdateError.rawValue) {
            Self.log.error("update check failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        } else {
            state = .idle
        }
    }
}

// MARK: - Sparkle's delegate: the silent, automatic path

extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        pendingVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { settle() }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) { settle(error) }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { settle(error) }

    /// An update Roomy 0.0.x downloaded on its own is waiting for Roomy to quit: the button installs it now.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        pendingVersion = item.displayVersionString
        state = .ready(item.displayVersionString)
        return true
    }
}

// MARK: - Sparkle's user driver: every screen it could show, answered without a window

extension AppUpdater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Checking is on by default (and can be switched off in Settings); nothing about this Mac is ever sent.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { state = .checking }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Not downloaded yet: the button downloads it. Already downloaded (or installing): the button installs it.
        // Either way the same reply goes back to Sparkle when it's clicked, and Sparkle comes back with showReady.
        available(appcastItem.displayVersionString) { reply(.install) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { settle(); acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { settle(error); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { if !isReady { state = .downloading(pendingVersion) } }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expectedBytes = expectedContentLength; receivedBytes = 0 }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        if expectedBytes > 0 { progress = min(0.95, Double(receivedBytes) / Double(expectedBytes) * 0.95) }
    }
    func showDownloadDidStartExtractingUpdate() { progress = 0.95 }
    func showExtractionReceivedProgress(_ progress: Double) { self.progress = 0.95 + progress * 0.05 }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { ready(pendingVersion) { reply(.install) } }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { state = .idle; acknowledgement() }
    func dismissUpdateInstallation() {
        // Sparkle closes the session it asked about. A found update keeps its button until it's clicked.
        if case .available = state { return }
        if !isReady, state != .off { state = .idle; progress = nil }
    }
}
