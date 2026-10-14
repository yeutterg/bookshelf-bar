import AppKit
import Foundation
import KEFKit
import Observation

/// "Keep Awake While Screen Is On": the speakers follow the display instead of their own
/// silence timer.
///
/// - Screen on: wake the speakers into USB and set their auto-standby to Never, so they don't
///   doze off during quiet stretches while you're at the Mac.
/// - Screen off: restore the user's auto-standby setting and, if nothing is playing to the KEF
///   over USB, put the speakers in standby.
///
/// The user's own standby mode is saved before it's changed and restored on screen-off, when
/// the feature is turned off, and on next launch if the app quit in between.
@MainActor
@Observable
public final class KeepAwake {
    public var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "keepAwakeWithScreen")
            if enabled { screenOn() } else { Task { await restoreStandbyMode() } }
        }
    }

    private let speaker: SpeakerModel
    private let smoothStart: SmoothStart
    private let defaults = UserDefaults.standard
    private var observers: [NSObjectProtocol] = []
    private static let legacySavedModeKey = "keepAwakeSavedStandbyMode"
    private static func savedModeKey(_ identity: String) -> String { "keepAwakeSavedStandbyMode.\(identity)" }

    public init(speaker: SpeakerModel, smoothStart: SmoothStart) {
        self.speaker = speaker
        self.smoothStart = smoothStart
        enabled = defaults.bool(forKey: "keepAwakeWithScreen")
    }

    public func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenOn() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenOff() }
        })
        // Leftover from a previous run that quit while the screen was on: put things back in
        // order once the speaker is reachable.
        Task {
            for _ in 0..<20 where speaker.connection != .connected { try? await Task.sleep(for: .seconds(1)) }
            if enabled { screenOn() } else { await restoreStandbyMode() }
        }
    }

    private func screenOn() {
        guard !speaker.isUpdatingFirmware else { return }
        guard enabled, speaker.connection == .connected, let identity = speaker.restorationIdentity else { return }
        Task {
            let key = Self.savedModeKey(identity)
            if defaults.string(forKey: key) == nil, let mode = await speaker.liveStandbyMode(), mode != .never {
                guard enabled, speaker.restorationIdentity == identity else { return }
                defaults.set(mode.rawValue, forKey: key)
            }
            guard enabled, speaker.restorationIdentity == identity,
                  await speaker.setStandbyModeAndWait(.never) else { return }
            guard enabled, speaker.restorationIdentity == identity else { return }
            await speaker.wakeIfNeeded()
        }
    }

    private func screenOff() {
        guard !speaker.isUpdatingFirmware else { return }
        guard enabled, speaker.connection == .connected else { return }
        Task {
            await restoreStandbyMode()
            // Screen automation owns only a quiet USB session. Never interrupt Wi-Fi, TV,
            // Bluetooth, optical or AUX playback just because the Mac display slept.
            if speaker.source == .usb, !smoothStart.usbRunning { speaker.turnOff(force: true) }
        }
    }

    private func restoreStandbyMode() async {
        guard let identity = speaker.restorationIdentity else { return }
        let key = Self.savedModeKey(identity)
        if defaults.string(forKey: key) == nil,
           let legacy = defaults.string(forKey: Self.legacySavedModeKey) {
            defaults.set(legacy, forKey: key)
            defaults.removeObject(forKey: Self.legacySavedModeKey)
        }
        guard let raw = defaults.string(forKey: key), let mode = StandbyMode(rawValue: raw) else { return }
        if await speaker.setStandbyModeAndWait(mode) {
            defaults.removeObject(forKey: key)
        }
    }
}
