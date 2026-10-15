import AppKit
import Darwin
import CoreAudio
import Foundation
import KEFAudio
import KEFKit
import Observation
import os

private let slog = Logger(subsystem: "com.github.yeutterg.bookshelfbar", category: "smoothstart")

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

    public var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "smoothStart")
            if !enabled { disableRunningGuard() }
        }
    }
    public var wakeOnUnlock: Bool { didSet { defaults.set(wakeOnUnlock, forKey: "wakeOnUnlock") } }
    public private(set) var phase: Phase = .idle
    public private(set) var safetyFailure = false
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
    /// BookshelfBar moved Mac output off the KEF to put it in standby; put it back when the
    /// speaker is turned on again, unless the user picks an output themselves meanwhile.
    private var movedOutputForStandby = false
    private var ignoreDefaultChangeUntil = Date.distantPast
    private var ignoreVolumeUntil = Date.distantPast
    private var guardTask: Task<Void, Never>?
    /// Invalidates callbacks from a cancelled guard so an old USB device cannot finish a
    /// newer wake cycle after re-enumeration.
    private var guardGeneration = 0
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
        observeSystem()
        speaker.willChangePower = { [weak self] on in self?.prepareForPower(on: on) }
        speaker.streamHolders = { [weak self] in self?.streamHolderNames() ?? [] }
        speaker.releaseUSBStream = { [weak self] in await self?.moveOutputOffKEF() ?? false }
    }

    // MARK: Mac-side volume (what the macOS Sound control shows)

    /// The KEF USB output volume (0…1). While Smooth Start is holding or ramping this reports
    /// the user's target, not the transient level.
    public var macVolume: Float? {
        guard usbPresent else { return nil }
        return phase == .idle ? (liveVolume ?? rememberedVolume) : rememberedVolume
    }
    public var macMuted: Bool { phase == .idle ? liveMuted : (intent?.snapshot.muted ?? liveMuted) }
    private var liveVolume: Float?
    private var liveMuted = false
    private var intent: VolumeIntent?

    /// While the user is dragging, the device echoes back whole-dB-rounded values; applying them
    /// would move the slider under the user's hand.
    private var userAdjustingUntil = Date.distantPast

    public func setMacVolume(_ v: Float) {
        userAdjustingUntil = .now + 0.8
        rememberedVolume = v
        liveVolume = v
        intent?.setTarget(v)
        guard phase == .idle, !armedLow, let id = usb.device else { return }
        volumeGuard.setLevel(id, v)
    }

    public func toggleMacMute() {
        guard let id = usb.device else { return }
        let newValue = !macMuted
        liveMuted = newValue
        intent?.setMuted(newValue)
        // Muting is always safe immediately. Unmuting during a guard waits until the verified
        // hold stage; the guard observes the updated intent itself.
        if newValue { volumeGuard.setMuted(id, true) }
        else if phase == .idle { volumeGuard.setMuted(id, false) }
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
        // During a firmware update the USB interface itself may be reflashed: no volume writes,
        // no wake requests, no default-output changes.
        if speaker.isUpdatingFirmware {
            if case .removed = event { usbPresent = false; usbRunning = false }
            if case .arrived = event { usbPresent = true }
            return
        }
        // No CoreAudio reads here: they can block on a device that's coming or going.
        slog.info("event \(String(describing: event), privacy: .public) phase=\(String(describing: self.phase), privacy: .public) on=\(self.speaker.isOn) armed=\(self.armedLow)")
        switch event {
        case .initialState(let device, _, let isDefault, let running, let volume, let muted):
            usbPresent = device != nil
            usbRunning = running
            speaker.usbStreamActive = running
            kefWasDefault = isDefault
            liveVolume = volume
            liveMuted = muted
            if rememberedVolume == nil { rememberedVolume = volume }

        case .removed:
            guardGeneration += 1
            volumeGuard.cancel()
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
            if movedOutputForStandby, speaker.isOn {
                movedOutputForStandby = false
                restoreDefault = true
            }
            if enabled {
                guardArrival(id)
            } else {
                restoreDefaultOutputIfNeeded()
                if armedLow { volumeGuard.setState(id, target: target, muted: liveMuted) }
                finish()
            }

        case .defaultOutputChanged(let isKEF):
            // Ignore the fallback macOS does while the KEF is gone; we restore it on arrival.
            if usb.device != nil { kefWasDefault = isKEF }
            if isKEF || Date() > ignoreDefaultChangeUntil { movedOutputForStandby = false }
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
            if phase == .idle, !armedLow, Date() > ignoreVolumeUntil, Date() > userAdjustingUntil {
                rememberedVolume = v
                liveVolume = v
            }

        case .muteChanged(let muted):
            // During the guard this notification is usually an echo of our own protective mute.
            // Treating it as user intent would leave an originally-unmuted speaker muted. App
            // button changes update `intent` directly; resume observing hardware when idle.
            if phase == .idle { liveMuted = muted }
        }
    }

    private var target: Float { rememberedVolume ?? 0.5 }
    private var holdLevel: Float { max(target - holdDrop, 0) }

    /// Called just before the speaker's power changes (BookshelfBar's switch, a pre-wake, audio
    /// starting on a sleeping speaker). Sets the KEF to the hold level *before* it drops off
    /// USB: macOS restores the last level it saw when the device comes back, so it returns low
    /// instead of at full volume.
    func prepareForPower(on: Bool) {
        guard !speaker.isUpdatingFirmware else { return }
        guard enabled else { return }
        if !on {
            guardGeneration += 1
            guardTask?.cancel()
            volumeGuard.cancel()
            phase = .idle
        }
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
        restoreDefaultOutputIfNeeded()
        runGuard(id)
    }

    private func restoreDefaultOutputIfNeeded() {
        if restoreDefault, !usb.isDefaultOutput { usb.makeDefaultOutput() }
        restoreDefault = false
    }

    /// Standby with Wake On = USB Audio re-wakes ~3 s later while any app streams to the KEF
    /// (Spotify does even when paused). Moving the Mac's output elsewhere makes apps close
    /// those streams, so the speaker can sleep normally and stays in the Sound menu; choosing
    /// it there wakes it. Returns false if a stream is still open afterwards.
    func moveOutputOffKEF() async -> Bool {
        guard let kef = usb.device, usbRunning else { return true }
        if usb.isDefaultOutput {
            let preferred = usb.lastOtherOutputUID
            let other = await Task.detached { AudioHardware.otherOutputs(excluding: kef, preferredUID: preferred).first }.value
            guard let other else { return false }
            ignoreDefaultChangeUntil = Date().addingTimeInterval(2)
            guard await Task.detached(operation: { AudioHardware.setDefaultOutput(other) }).value else { return false }
            movedOutputForStandby = true
            slog.info("moved output off the KEF for standby")
        }
        for _ in 0..<20 where usbRunning { try? await Task.sleep(for: .milliseconds(100)) }
        return !usbRunning
    }

    private func runGuard(_ id: AudioObjectID) {
        guardGeneration += 1
        let generation = guardGeneration
        phase = .settling
        safetyFailure = false
        ignoreVolumeUntil = .distantFuture
        let intent = VolumeIntent(target: target, muted: liveMuted)
        self.intent = intent
        let plan = VolumeGuard.Plan(hold: holdLevel)
        slog.info("guard id=\(id) hold=\(plan.hold) target=\(self.target)")
        volumeGuard.run(id, plan, intent: intent, log: { slog.info("\($0, privacy: .public)") }) { [weak self] completed in
            Task { @MainActor in
                guard let self, self.guardGeneration == generation else { return }
                self.liveVolume = intent.snapshot.target
                self.liveMuted = completed ? intent.snapshot.muted : true
                self.safetyFailure = !completed
                self.finish()
            }
        }
    }

    private func finish() {
        armedLow = false
        intent = nil
        ignoreVolumeUntil = .now + 0.5
        phase = .idle
        usbRunning = usb.isRunning
        speaker.usbStreamActive = usbRunning
    }

    private func disableRunningGuard() {
        guardGeneration += 1
        guardTask?.cancel()
        volumeGuard.cancel()
        if let id = usb.device, armedLow || phase != .idle {
            volumeGuard.setState(id, target: target, muted: liveMuted)
        }
        finish()
    }

    /// On quit, don't leave the KEF parked at the hold level.
    public func prepareForQuit() {
        guardGeneration += 1
        volumeGuard.cancel()
        if armedLow || phase != .idle, let id = usb.device, let v = rememberedVolume {
            volumeGuard.setState(id, target: v, muted: liveMuted)
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

    /// Friendly names of the processes holding an audio stream open to the KEF.
    func streamHolderNames() -> [String] {
        guard let id = usb.device else { return [] }
        return AudioHardware.processesPlaying(to: id).map { pid in
            if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
            var buffer = [CChar](repeating: 0, count: 4096)
            let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
                ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                : ""
            if path.contains("CoreSimulator") { return "iOS Simulator" }
            return URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "pid \(pid)" : URL(fileURLWithPath: path).lastPathComponent
        }
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}
