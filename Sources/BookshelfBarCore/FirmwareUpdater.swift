import Foundation
import KEFKit
import Observation
import os

private let flog = Logger(subsystem: "com.github.yeutterg.bookshelfbar", category: "firmware")

/// Checks for and installs speaker firmware through the speaker's own updater (the same one
/// KEF Connect uses: the image comes from KEF and is verified by the speaker).
///
/// Safety model: from the moment an install starts until the speaker reports success, the
/// speaker model is locked (`isUpdatingFirmware`): no BookshelfBar command, automation, Smooth Start
/// volume write or wake request can reach the speaker. Only the update commands below and
/// read-only status polling are sent. The lock is persisted, survives relaunches, and is also
/// taken if an update started elsewhere (e.g. KEF Connect) is seen in progress.
@MainActor
@Observable
public final class FirmwareUpdater {
    public enum Phase: Equatable {
        case unknown
        case checking
        case upToDate
        case available(version: String)
        case downloading(progress: Int)
        case installing(progress: Int)
        case finished(version: String)
        case failed(String)
    }

    public private(set) var phase: Phase = .unknown
    public private(set) var currentVersion: String?
    /// When the lock started; after a long time without a result the user may unlock manually.
    public private(set) var lockedSince: Date?

    private let speaker: SpeakerModel
    private var monitorTask: Task<Void, Never>?

    public init(speaker: SpeakerModel) {
        self.speaker = speaker
    }

    /// Unlocking by hand is offered only after a failure, or if the speaker hasn't reported a
    /// result for 45 minutes.
    public var canForceUnlock: Bool {
        if case .failed = phase { return true }
        guard let lockedSince else { return false }
        return Date().timeIntervalSince(lockedSince) > 45 * 60
    }

    /// Called on connect and when the popover opens: picks up a persisted lock, or an update
    /// in progress that someone else started.
    public func refresh() async {
        guard let client = speaker.statusClient else { return }
        currentVersion = (try? await client.get(.firmwareVersion).string).map(Self.shortVersion)
        if speaker.isUpdatingFirmware {
            startMonitoring()
            return
        }
        guard let status = try? await client.firmwareStatus() else { return }
        let install = try? await client.firmwareInstallInfo()
        if status.isInstalling || (install.map { !$0.isFinished && !$0.status.isEmpty } ?? false) {
            flog.info("update in progress detected (\(status.state, privacy: .public)); locking")
            speaker.beginFirmwareLock(fromVersion: currentVersion ?? "unknown")
            startMonitoring()
        } else if status.isAvailable, let v = status.availableVersion {
            phase = .available(version: Self.shortVersion(v))
        } else if status.isDownloaded {
            phase = .available(version: status.availableVersion.map(Self.shortVersion) ?? "new version")
        } else if phase == .unknown, status.state == "idle" {
            phase = .unknown
        }
    }

    public func check() async {
        guard !speaker.isUpdatingFirmware, let client = speaker.statusClient else { return }
        phase = .checking
        do {
            try await client.checkForFirmwareUpdate()
            // The check talks to KEF's server; poll briefly for the answer.
            for _ in 0..<20 {
                try await Task.sleep(for: .seconds(1))
                let status = try await client.firmwareStatus()
                if status.isChecking { continue }
                if (status.isAvailable || status.isDownloaded), let v = status.availableVersion {
                    phase = .available(version: Self.shortVersion(v))
                } else {
                    phase = .upToDate
                }
                return
            }
            phase = .upToDate
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Downloads (if needed) and installs. The caller must have shown the warning and got
    /// confirmation. Locks the speaker before the first update command is sent.
    public func install() async {
        guard !speaker.isUpdatingFirmware, let client = speaker.statusClient else { return }
        let from = currentVersion ?? "unknown"
        speaker.beginFirmwareLock(fromVersion: from)
        lockedSince = .now
        do {
            var status = try await client.firmwareStatus()
            if !status.isDownloaded {
                if !status.isDownloading {
                    flog.info("download start")
                    try await client.downloadFirmwareUpdate()
                }
                // Wait for the download (up to 30 min), showing progress.
                let deadline = Date().addingTimeInterval(30 * 60)
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                    status = try await client.firmwareStatus()
                    if status.isDownloaded { break }
                    if status.isDownloading { phase = .downloading(progress: status.downloadProgress); continue }
                    if status.isInstalling { break }
                    // Back to idle/available without a download: nothing was installed, so it's
                    // safe to release the lock.
                    if !status.isChecking {
                        speaker.endFirmwareLock()
                        lockedSince = nil
                        phase = .failed("The download didn't complete. Nothing was installed.")
                        return
                    }
                }
            }
            if !status.isInstalling {
                flog.info("install start")
                try await client.installFirmwareUpdate()
            }
            phase = .installing(progress: 0)
            startMonitoring()
        } catch {
            // We may not know whether the install began, so stay locked and keep monitoring.
            flog.error("install request error: \(error.localizedDescription, privacy: .public)")
            phase = .installing(progress: 0)
            startMonitoring()
        }
    }

    /// Manual release, offered only via `canForceUnlock`.
    public func forceUnlock() {
        guard canForceUnlock else { return }
        flog.info("lock released by user")
        monitorTask?.cancel()
        monitorTask = nil
        speaker.endFirmwareLock()
        lockedSince = nil
        phase = .unknown
    }

    /// Polls read-only status until the speaker reports a clean finish on a new version. The
    /// speaker restarts during the install, so failed polls are expected and ignored.
    private func startMonitoring() {
        guard monitorTask == nil else { return }
        if lockedSince == nil { lockedSince = .now }
        let from = speaker.firmwareLockFromVersion ?? currentVersion ?? "unknown"
        monitorTask = Task { [weak self] in
            var cleanFinishes = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                guard let client = self.speaker.statusClient else { continue }
                guard let install = try? await client.firmwareInstallInfo(),
                      let status = try? await client.firmwareStatus() else { continue }
                let version = (try? await client.get(.firmwareVersion).string).map(Self.shortVersion)
                if let version { self.currentVersion = version }

                if !install.isClean {
                    self.phase = .failed("The speakers reported \(install.error). Don't unplug them; check KEF Connect.")
                    continue
                }
                if status.isDownloading { self.phase = .downloading(progress: status.downloadProgress); continue }
                if status.isInstalling || !install.isFinished {
                    self.phase = .installing(progress: install.overall)
                    cleanFinishes = 0
                    continue
                }
                // Finished cleanly. Require a new version, seen twice in a row, before unlocking.
                if let version, version != from {
                    cleanFinishes += 1
                    if cleanFinishes >= 2 {
                        flog.info("update finished: \(from, privacy: .public) -> \(version, privacy: .public)")
                        self.speaker.endFirmwareLock()
                        self.lockedSince = nil
                        self.phase = .finished(version: version)
                        self.monitorTask = nil
                        return
                    }
                }
            }
        }
    }

    /// "2.1.86.0xdc74e88" → "2.1.86".
    static func shortVersion(_ v: String) -> String {
        v.components(separatedBy: ".0x").first ?? v
    }
}
