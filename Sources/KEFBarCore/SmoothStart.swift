import AppKit
import CoreAudio
import Foundation
import KEFAudio
import KEFKit
import Observation

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
        kefWasDefault = usb.isDefaultOutput
        liveVolume = usb.volume
        if rememberedVolume == nil { rememberedVolume = usb.volume }
        observeSystem()
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
        guard phase == .idle, let id = usb.device else { return }
        AudioHardware.setVolume(id, v)
    }

    public func toggleMacMute() {
        guard let id = usb.device else { return }
        AudioHardware.setMuted(id, !(AudioHardware.isMuted(id) ?? false))
        liveVolume = AudioHardware.volume(id)
    }

    // MARK: Events

    /// How far below the target to hold while the speaker wakes, in scalar units (about 20 dB
    /// on the KEF's curve), and how long to hold and ramp.
    private let holdDrop: Float = 0.22
    private let holdDuration: Duration = .milliseconds(1500)
    private let rampDuration: Double = 2.0

    private func handle(_ event: KEFUSBMonitor.Event) {
        switch event {
        case .removed:
            usbPresent = false
            usbRunning = false
            restoreDefault = kefWasDefault
            if enabled { phase = .waking }

        case .arrived(let id):
            usbPresent = true
            liveVolume = AudioHardware.volume(id)
            if enabled { guardArrival(id) } else { phase = .idle }

        case .defaultOutputChanged(let isKEF):
            // Ignore the fallback macOS does while the KEF is gone; we restore it on arrival.
            if usb.device != nil { kefWasDefault = isKEF }
            if isKEF, enabled { Task { await speaker.wakeIfNeeded() } }

        case .runningChanged(let running):
            usbRunning = running
            guard running, enabled, usb.isDefaultOutput else { break }
            // Audio is starting. If the speaker is asleep, drop the level right now, before it
            // wakes, and hold it until the wake and USB reconnect are over.
            if !speaker.isOn, phase == .idle, let id = usb.device { beginHold(id) }
            Task { await speaker.wakeIfNeeded() }

        case .volumeChanged(let v):
            // Track the user's choice, but not our own hold/ramp writes or re-arrival transients.
            if Date() > ignoreVolumeUntil, phase == .idle {
                rememberedVolume = v
                liveVolume = v
            }
        }
    }

    private var target: Float { rememberedVolume ?? 0.5 }
    private var holdLevel: Float { max(target - holdDrop, 0) }

    /// Called the moment audio starts on a sleeping speaker.
    private func beginHold(_ id: AudioObjectID) {
        phase = .waking
        ignoreVolumeUntil = .distantFuture
        AudioHardware.setVolume(id, holdLevel)
        // Watchdog: if the speaker never drops off USB (already awake), release anyway.
        guardTask?.cancel()
        guardTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.phase == .waking, let id = self.usb.device else { return }
            await self.ramp(id)
        }
    }

    /// The KEF just re-appeared after waking: mute instantly (it can come back at 0 dB), put
    /// back the default output, hold low, then ramp up.
    private func guardArrival(_ id: AudioObjectID) {
        phase = .settling
        ignoreVolumeUntil = .distantFuture
        AudioHardware.setMuted(id, true)
        AudioHardware.setVolume(id, holdLevel)
        if restoreDefault, !usb.isDefaultOutput { usb.makeDefaultOutput() }
        restoreDefault = false

        guardTask?.cancel()
        guardTask = Task { [weak self] in
            guard let self else { return }
            // macOS writes its saved volume shortly after arrival; keep re-asserting the hold level.
            for _ in 0..<4 {
                if let v = AudioHardware.volume(id), abs(v - self.holdLevel) > 0.005 { AudioHardware.setVolume(id, self.holdLevel) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            AudioHardware.setMuted(id, false)
            try? await Task.sleep(for: self.holdDuration)
            guard !Task.isCancelled else { return }
            await self.ramp(id)
        }
    }

    /// Eases from the hold level to the target along an S-curve.
    private func ramp(_ id: AudioObjectID) async {
        let from = AudioHardware.volume(id) ?? holdLevel
        let to = target
        let steps = Int(rampDuration / 0.04)
        for i in 1...steps {
            if Task.isCancelled { return }
            let t = Float(i) / Float(steps)
            let eased = t * t * (3 - 2 * t)
            AudioHardware.setVolume(id, from + (to - from) * eased)
            try? await Task.sleep(for: .milliseconds(40))
        }
        AudioHardware.setMuted(id, false)
        AudioHardware.setVolume(id, to)
        liveVolume = to
        ignoreVolumeUntil = .now + 0.5
        phase = .idle
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
        guard enabled, wakeOnUnlock, usb.isDefaultOutput else { return }
        Task { await speaker.wakeIfNeeded() }
    }
}
