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
        if rememberedVolume == nil { rememberedVolume = usb.volume }
        observeSystem()
    }

    // MARK: Events

    private func handle(_ event: KEFUSBMonitor.Event) {
        switch event {
        case .removed:
            usbPresent = false
            usbRunning = false
            restoreDefault = kefWasDefault
            if enabled { phase = .waking }

        case .arrived(let id):
            usbPresent = true
            if enabled { guardArrival(id) } else { phase = .idle }

        case .defaultOutputChanged(let isKEF):
            // Ignore the fallback macOS does while the KEF is gone; we restore it on arrival.
            if usb.device != nil { kefWasDefault = isKEF }
            if isKEF, enabled { Task { await speaker.wakeIfNeeded() } }

        case .runningChanged(let running):
            usbRunning = running
            // Audio just started on a sleeping KEF: it would wake itself in ~2 s; asking now saves time.
            if running, enabled, usb.isDefaultOutput { Task { await speaker.wakeIfNeeded() } }

        case .volumeChanged(let v):
            // Track the user's choice, but not the transient values around a re-arrival.
            if Date() > ignoreVolumeUntil, phase == .idle { rememberedVolume = v }
        }
    }

    private func guardArrival(_ id: AudioObjectID) {
        phase = .settling
        ignoreVolumeUntil = .now + 3
        AudioHardware.setMuted(id, true)
        if restoreDefault, !usb.isDefaultOutput { usb.makeDefaultOutput() }
        restoreDefault = false
        let target = rememberedVolume

        guardTask?.cancel()
        guardTask = Task { [weak self] in
            // macOS writes its saved volume shortly after arrival; re-assert ours over ~0.6 s.
            for _ in 0..<4 {
                if let target, let v = AudioHardware.volume(id), abs(v - target) > 0.005 {
                    AudioHardware.setVolume(id, target)
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            await self?.fadeIn(id, to: target ?? AudioHardware.volume(id) ?? 0.5)
        }
    }

    private func fadeIn(_ id: AudioObjectID, to target: Float) async {
        let steps = 8
        AudioHardware.setVolume(id, target * 0.2)
        AudioHardware.setMuted(id, false)
        for i in 1...steps {
            try? await Task.sleep(for: .milliseconds(50))
            AudioHardware.setVolume(id, target * (0.2 + 0.8 * Float(i) / Float(steps)))
        }
        AudioHardware.setVolume(id, target)
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
