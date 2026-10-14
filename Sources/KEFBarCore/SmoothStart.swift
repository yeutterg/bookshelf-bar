import AppKit
import CoreAudio
import Foundation
import KEFAudio
import KEFKit
import Observation
import os

private let slog = Logger(subsystem: "com.github.yeutterg.kefbar", category: "smoothstart")

/// Prevents the loud start when a sleeping KEF begins playing over USB.
///
/// What happens without it (measured, see PLAN.md §5): audio starts → the speaker wakes itself
/// → about 3 s later it drops off USB → it re-arrives 1–4 s later as a new device, sometimes
/// at full USB gain (0 dB) before macOS restores the saved volume. macOS may also move output
/// to another device during the gap and not move it back.
///
/// What this does:
/// 1. **Pre-wake:** wakes the speaker over Wi-Fi as soon as playback is likely (KEF picked as
///    output, Mac wake or unlock, audio starting while the speaker sleeps), so the USB drop
///    happens early or before any audio.
/// 2. **Guard on re-arrival:** mutes the KEF the instant it reappears, restores the last good
///    USB volume, re-selects it as the default output if it was before, then fades back in.
@MainActor
@Observable
public final class SmoothStart {
    public enum Phase: Equatable { case idle, waking, settling }

    public var enabled: Bool { didSet { defaults.set(enabled, forKey: "smoothStart") } }
    public var wakeOnUnlock: Bool { didSet { defaults.set(wakeOnUnlock, forKey: "wakeOnUnlock") } }
    public private(set) var phase: Phase = .idle
    /// True while the KEF USB device is connected to this Mac.
    public private(set) var usbPresent = false
    /// Product name of the connected KEF USB device (e.g. "LSX II LT"), used to point out the
    /// matching pair during setup. USB exposes no serial number, so model is all we can match on.
    public var usbDeviceName: String? { usbPresent ? usb.name : nil }
    /// True while some app is playing to the KEF USB device.
    public private(set) var usbRunning = false

    private let speaker: SpeakerModel
    private let usb = KEFUSBMonitor()
    private let defaults = UserDefaults.standard
    private var kefWasDefault = false
    private var restoreDefault = false
    private var ignoreVolumeUntil = Date.distantPast
    private var guardTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Last USB volume the user chose (0…1), restored after every re-arrival.
    private var rememberedVolume: Float? {
        get { defaults.object(forKey: "kefUSBVolume") as? Float }
        set { defaults.set(newValue, forKey: "kefUSBVolume") }
    }

    public init(speaker: SpeakerModel) {
        self.speaker = speaker
        enabled = defaults.object(forKey: "smoothStart") as? Bool ?? true
        wakeOnUnlock = defaults.object(forKey: "wakeOnUnlock") as? Bool ?? true
    }

    public func start() {
        usb.onEvent = { [weak self] in self?.handle($0) }
        usb.start()
        usbPresent = usb.device != nil
        usbRunning = usb.isRunning
        speaker.usbStreamActive = usbRunning
        kefWasDefault = usb.isDefaultOutput
        liveVolume = usb.volume
        if rememberedVolume == nil { rememberedVolume = usb.volume }
        observeSystem()
        speaker.willChangePower = { [weak self] on in self?.prepareForPower(on: on) }
    }

    // MARK: Mac-side volume (what the macOS Sound control shows)

    /// The KEF USB output volume (0…1). While Smooth Start is holding or ramping this reports
    /// the user's target, not the transient level.
    public var macVolume: Float? {
        guard usbPresent else { return nil }
        return phase == .idle ? (liveVolume ?? rememberedVolume) : rememberedVolume
    }
    public var macMuted: Bool { usb.device.flatMap(AudioHardware.isMuted) ?? false }
    private var liveVolume: Float?

    public func setMacVolume(_ v: Float) {
        rememberedVolume = v
        liveVolume = v
        guard phase == .idle, !armedLow, let id = usb.device else { return }
        AudioHardware.setVolume(id, v)
    }

    public func toggleMacMute() {
        guard let id = usb.device else { return }
        AudioHardware.setMuted(id, !(AudioHardware.isMuted(id) ?? false))
        liveVolume = AudioHardware.volume(id)
    }

    // MARK: Events

    /// How far below the target to hold while the speaker wakes, in scalar units (about 20 dB
    /// on the KEF's curve).
    private let holdDrop: Float = 0.22
    private let volumeGuard = VolumeGuard()
    /// The device has been set to the hold level on purpose (pre-armed); don't mistake that for
    /// the user's choice, and ramp back up when the speaker returns.
    private var armedLow = false

    private func handle(_ event: KEFUSBMonitor.Event) {
        // No CoreAudio reads here: they can block on a device that's coming or going.
        slog.info("event \(String(describing: event), privacy: .public) phase=\(String(describing: self.phase), privacy: .public) on=\(self.speaker.isOn) armed=\(self.armedLow)")
        switch event {
        case .removed:
            usbPresent = false
            usbRunning = false
            speaker.usbStreamActive = false
            restoreDefault = kefWasDefault
            // A drop while the speaker is on (or being turned on) is the wake re-enumeration.
            // A drop because the user turned it off is just the USB powering down.
            if enabled, speaker.isOn {
                phase = .waking
                startWakeWatchdog()
            } else if phase == .waking {
                phase = .idle
            }

        case .arrived(let id):
            usbPresent = true
            if enabled { guardArrival(id) } else { phase = .idle }

        case .defaultOutputChanged(let isKEF):
            // Ignore the fallback macOS does while the KEF is gone; we restore it on arrival.
            if usb.device != nil { kefWasDefault = isKEF }
            if isKEF, enabled, !speaker.isOn { prepareForPower(on: true) }

        case .runningChanged(let running):
            usbRunning = running
            speaker.usbStreamActive = running
            guard running, enabled, usb.isDefaultOutput else { break }
            // Audio is starting. If the speaker is asleep, drop the level right now, before it
            // wakes, and hold it until the wake and USB reconnect are over.
            if !speaker.isOn, phase == .idle { prepareForPower(on: true) }

        case .volumeChanged(let v):
            // Track the user's choice, but not our own hold/ramp writes or re-arrival transients.
            if phase == .idle, !armedLow, Date() > ignoreVolumeUntil {
                rememberedVolume = v
                liveVolume = v
            }
        }
    }

    private var target: Float { rememberedVolume ?? 0.5 }
    private var holdLevel: Float { max(target - holdDrop, 0) }

    /// Called just before the speaker's power changes (KEF Bar's switch, a pre-wake, audio
    /// starting on a sleeping speaker). Sets the KEF to the hold level *before* it drops off
    /// USB: macOS restores the last level it saw when the device comes back, so it returns low
    /// instead of at full volume.
    func prepareForPower(on: Bool) {
        guard enabled else { return }
        if let id = usb.device {
            slog.info("pre-arm hold \(self.holdLevel) (turning \(on ? "on" : "off", privacy: .public))")
            armedLow = true
            volumeGuard.setLevel(id, holdLevel)
        }
        if on {
            phase = .waking
            startWakeWatchdog()
            Task { await speaker.wakeIfNeeded(notify: false) }
        }
    }

    /// Never stay in "waking" forever if the speaker doesn't come back on USB (e.g. it was
    /// already awake, so there's no re-enumeration). Then just ramp up where it is.
    private func startWakeWatchdog() {
        guardTask?.cancel()
        guardTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.phase == .waking else { return }
            slog.info("watchdog: no USB re-arrival")
            if let id = self.usb.device { self.runGuard(id) } else { self.finish() }
        }
    }

    /// The KEF just re-appeared after waking: mute and hold (it can come back at 0 dB, and
    /// macOS re-applies its saved level a moment later), put back the default output, then ramp.
    private func guardArrival(_ id: AudioObjectID) {
        guardTask?.cancel()
        if restoreDefault, !usb.isDefaultOutput { usb.makeDefaultOutput() }
        restoreDefault = false
        runGuard(id)
    }

    private func runGuard(_ id: AudioObjectID) {
        phase = .settling
        ignoreVolumeUntil = .distantFuture
        let plan = VolumeGuard.Plan(hold: holdLevel, target: target)
        slog.info("guard id=\(id) hold=\(plan.hold) target=\(plan.target)")
        volumeGuard.run(id, plan, log: { slog.info("\($0, privacy: .public)") }) { [weak self] completed in
            guard completed else { return }
            Task { @MainActor in
                self?.liveVolume = plan.target
                self?.finish()
            }
        }
    }

    private func finish() {
        armedLow = false
        ignoreVolumeUntil = .now + 0.5
        phase = .idle
        usbRunning = usb.isRunning
        speaker.usbStreamActive = usbRunning
    }

    /// On quit, don't leave the KEF parked at the hold level.
    public func prepareForQuit() {
        volumeGuard.cancel()
        if armedLow || phase != .idle, let id = usb.device, let v = rememberedVolume {
            AudioHardware.setVolume(id, v)
            AudioHardware.setMuted(id, false)
        }
    }

    // MARK: System triggers

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.preWakeForUser() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preWakeForUser() }
        })
    }

    private func preWakeForUser() {
        guard enabled, wakeOnUnlock, usb.isDefaultOutput, !speaker.isOn else { return }
        prepareForPower(on: true)
    }
}
