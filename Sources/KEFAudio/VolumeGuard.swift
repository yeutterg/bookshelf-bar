import CoreAudio
import Foundation

public protocol VolumeDeviceIO: Sendable {
    func volume(_ id: AudioObjectID) -> Float?
    func isMuted(_ id: AudioObjectID) -> Bool?
    @discardableResult func setVolume(_ id: AudioObjectID, _ scalar: Float) -> Bool
    @discardableResult func setMuted(_ id: AudioObjectID, _ muted: Bool) -> Bool
    /// Volume in dB, for devices that expose it. Without these the guard ramps in scalar.
    func decibels(_ id: AudioObjectID) -> Float?
    func decibelRange(_ id: AudioObjectID) -> ClosedRange<Float>?
    @discardableResult func setDecibels(_ id: AudioObjectID, _ db: Float) -> Bool
}

public extension VolumeDeviceIO {
    func decibels(_ id: AudioObjectID) -> Float? { nil }
    func decibelRange(_ id: AudioObjectID) -> ClosedRange<Float>? { nil }
    func setDecibels(_ id: AudioObjectID, _ db: Float) -> Bool { false }
}

private struct SystemVolumeDevice: VolumeDeviceIO {
    func volume(_ id: AudioObjectID) -> Float? { AudioHardware.volume(id) }
    func isMuted(_ id: AudioObjectID) -> Bool? { AudioHardware.isMuted(id) }
    func setVolume(_ id: AudioObjectID, _ scalar: Float) -> Bool { AudioHardware.setVolume(id, scalar) }
    func setMuted(_ id: AudioObjectID, _ muted: Bool) -> Bool { AudioHardware.setMuted(id, muted) }
    func decibels(_ id: AudioObjectID) -> Float? { AudioHardware.volumeDecibels(id) }
    func decibelRange(_ id: AudioObjectID) -> ClosedRange<Float>? { AudioHardware.volumeDecibelRange(id) }
    func setDecibels(_ id: AudioObjectID, _ db: Float) -> Bool { AudioHardware.setVolumeDecibels(id, db) }
}

/// Thread-safe user intent shared with the background guard. Slider and mute changes update this
/// while a guard is running, so the ramp always ends at the user's latest choices.
public final class VolumeIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (target: Float, muted: Bool)

    public init(target: Float, muted: Bool) { state = (target, muted) }

    public var snapshot: (target: Float, muted: Bool) { lock.withLock { state } }
    public func setTarget(_ target: Float) { lock.withLock { state.target = target } }
    public func setMuted(_ muted: Bool) { lock.withLock { state.muted = muted } }
}

/// Runs Smooth Start's volume work on its own serial queue. CoreAudio property calls on a
/// device that has just re-appeared can block for seconds; doing them on the main thread made
/// the guard late and the ramp uneven (measured: a 2 s stall, then macOS's saved volume won).
public final class VolumeGuard: @unchecked Sendable {
    public struct Plan: Sendable {
        public var hold: Float
        /// Keep re-asserting mute + hold until both have stuck for this long.
        public var settleFor: Double = 0.5
        /// Fail closed if mute + hold cannot be verified within this time.
        public var settleTimeout: Double = 3
        /// The KEF's USB volume moves in whole-dB steps, so an exact scalar can't always be
        /// hit; anything within this distance of the hold level counts (≈1–2 dB).
        public var holdTolerance: Float = 0.04
        /// Extra time to stay muted once the hold has settled, before fading in.
        public var holdFor: Double = 0
        /// Fade in from this far below the user's volume (just above silence) …
        public var fadeFromBelow: Float = 35
        /// … over this long, in even whole-dB steps.
        public var rampFor: Double = 3
        /// Time between ramp writes. The KEF applies USB volume in whole-dB steps (≈0.006
        /// scalar) and falls behind if written every few ms, then catches up in bursts (heard as
        /// jitter at the low end). One whole-dB step per write keeps them evenly spaced.
        public var rampInterval: Double = 0.07
        /// Skip ramp writes smaller than this; they'd round to the step already playing.
        public var rampMinStep: Float = 0.003
        public init(hold: Float) {
            self.hold = hold
        }
    }

    private let queue = DispatchQueue(label: "BookshelfBar.VolumeGuard", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0
    private let audio: any VolumeDeviceIO

    public init() { audio = SystemVolumeDevice() }
    public init(audio: any VolumeDeviceIO) { self.audio = audio }

    /// Cancels whatever is running (the next step checks and stops).
    public func cancel() {
        lock.withLock { generation += 1 }
    }

    private var pendingLevel: (id: AudioObjectID, level: Float)?
    private var levelWriterRunning = false

    /// Writes a volume level, latest value wins. Slider drags produce far more values than
    /// CoreAudio writes can keep up with; queuing each one made the volume keep "following"
    /// after the user let go. Only the newest pending value is written.
    public func setLevel(_ id: AudioObjectID, _ level: Float) {
        let startWriter = lock.withLock { () -> Bool in
            pendingLevel = (id, level)
            if levelWriterRunning { return false }
            levelWriterRunning = true
            return true
        }
        guard startWriter else { return }
        let audio = self.audio
        queue.async { [weak self] in
            while let next = self?.takePendingLevel() {
                _ = audio.setVolume(next.id, next.level)
            }
        }
    }

    private func takePendingLevel() -> (id: AudioObjectID, level: Float)? {
        lock.withLock {
            guard let next = pendingLevel else {
                levelWriterRunning = false
                return nil
            }
            pendingLevel = nil
            return next
        }
    }

    public func setMuted(_ id: AudioObjectID, _ muted: Bool) {
        let audio = self.audio
        queue.async { _ = audio.setMuted(id, muted) }
    }

    /// Restores an explicit user state off the main thread.
    public func setState(_ id: AudioObjectID, target: Float, muted: Bool) {
        let audio = self.audio
        queue.async {
            _ = audio.setVolume(id, target)
            _ = audio.setMuted(id, muted)
        }
    }

    /// Full guard for a freshly re-arrived device: mute + hold until stable, stay silent while
    /// the speaker settles, then fade in from inaudible to the user's live target.
    public func run(_ id: AudioObjectID, _ plan: Plan, intent: VolumeIntent,
                    log: @escaping @Sendable (String) -> Void,
                    done: @escaping @Sendable (_ completed: Bool) -> Void) {
        let gen = lock.withLock { generation += 1; return generation }
        let alive: @Sendable () -> Bool = { [weak self] in
            self?.lock.withLock { self?.generation == gen } ?? false
        }
        let audio = self.audio

        queue.async {
            // 1. Protect: macOS applies its saved volume (and clears mute) around the default-output
            //    switch, a few hundred ms after arrival. Keep winning until it's stable.
            let start = Date()
            var stableSince: Date?
            var settled = false
            var writable = false
            let near: (Float?) -> Bool = { v in v.map { abs($0 - plan.hold) <= plan.holdTolerance } ?? false }
            while alive(), Date().timeIntervalSince(start) < plan.settleTimeout {
                let muted = audio.isMuted(id)
                let volume = audio.volume(id)
                if muted != true { _ = audio.setMuted(id, true) }
                if !near(volume) { if audio.setVolume(id, plan.hold) { writable = true } } else { writable = true }
                if muted == true, near(volume) {
                    if stableSince == nil { stableSince = Date() }
                    if Date().timeIntervalSince(stableSince!) >= plan.settleFor {
                        settled = true
                        break
                    }
                } else {
                    stableSince = nil
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard alive() else { return done(false) }
            if !settled {
                // Only stay muted if we can't control the device at all. Silently leaving the
                // user's output muted is worse than starting a step away from the hold level.
                guard writable else {
                    log("device rejects volume writes; leaving output muted")
                    _ = audio.setMuted(id, true)
                    return done(false)
                }
                _ = audio.setVolume(id, plan.hold)
                log("hold not stable within \(plan.settleTimeout)s; continuing at hold")
            }
            log("settled at hold \(plan.hold) after \(String(format: "%.2f", Date().timeIntervalSince(start)))s")

            // 2. Stay muted at the hold level while the speaker finishes waking.
            let holdEnd = Date().addingTimeInterval(plan.holdFor)
            while alive(), Date() < holdEnd {
                if audio.volume(id).map({ abs($0 - plan.hold) > plan.holdTolerance }) != false {
                    _ = audio.setVolume(id, plan.hold)
                }
                if audio.isMuted(id) != true { _ = audio.setMuted(id, true) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard alive() else { return done(false) }

            // 3. Fade in, evenly in dB, timed against the clock.
            if !intent.snapshot.muted, Self.fadeIn(id, plan, intent: intent, audio: audio, alive: alive, log: log) {
                return Self.finish(id, intent: intent, audio: audio, log: log, done: done)
            }
            guard alive() else { return done(false) }

            // Fallback for devices without dB control: scalar ramp up from the hold level.
            log("ramp from \(plan.hold)")
            let rampStart = Date()
            var written = plan.hold
            while alive() {
                let t = Float(min(Date().timeIntervalSince(rampStart) / plan.rampFor, 1))
                // Half S-curve, half linear: soft ends without a near-flat start, where a full
                // smoothstep leaves only a few sparse, uneven steps.
                let eased = 0.5 * t + 0.5 * t * t * (3 - 2 * t)
                let desired = intent.snapshot
                let level = plan.hold + (desired.target - plan.hold) * eased
                if abs(level - written) >= plan.rampMinStep, audio.setVolume(id, level) { written = level }
                if audio.isMuted(id) != desired.muted { _ = audio.setMuted(id, desired.muted) }
                if t >= 1 { break }
                Thread.sleep(forTimeInterval: plan.rampInterval)
            }
            guard alive() else { return done(false) }
            Self.finish(id, intent: intent, audio: audio, log: log, done: done)
        }
    }

    /// Learns the target's dB while still muted, unmutes at `fadeFromBelow` under it and steps up
    /// one whole dB at a time. Returns false (still muted) if the device has no dB control.
    /// Stops early, at the user's level, if they move the volume meanwhile.
    private static func fadeIn(_ id: AudioObjectID, _ plan: Plan, intent: VolumeIntent, audio: any VolumeDeviceIO,
                               alive: () -> Bool, log: (String) -> Void) -> Bool {
        let target = intent.snapshot.target
        // Measuring means briefly setting the full target level: only while verifiably muted.
        guard audio.isMuted(id) == true, let range = audio.decibelRange(id), audio.setVolume(id, target) else { return false }
        Thread.sleep(forTimeInterval: 0.1)
        guard let targetDB = audio.decibels(id) else { return false }
        let floorDB = max(range.lowerBound, (targetDB - plan.fadeFromBelow).rounded(.down))
        guard audio.setDecibels(id, floorDB) else { return false }
        Thread.sleep(forTimeInterval: 0.1)
        log("fade \(floorDB) → \(targetDB) dB")
        _ = audio.setMuted(id, false)
        let start = Date()
        var written = floorDB
        while alive() {
            let desired = intent.snapshot
            if abs(desired.target - target) > 0.001 { log("volume changed during fade"); break }
            if audio.isMuted(id) != desired.muted { _ = audio.setMuted(id, desired.muted) }
            let t = Float(min(Date().timeIntervalSince(start) / plan.rampFor, 1))
            // Even in dB with soft ends: each step is the same loudness change.
            let eased = 0.5 * t + 0.5 * t * t * (3 - 2 * t)
            // Never more than one step per write: if this thread stalls, the fade runs a
            // little long instead of jumping.
            let db = min((floorDB + (targetDB - floorDB) * eased).rounded(), written + 1)
            if db != written, audio.setDecibels(id, db) { written = db }
            if t >= 1, written >= targetDB || Date().timeIntervalSince(start) > plan.rampFor * 2 + 1 { break }
            Thread.sleep(forTimeInterval: plan.rampInterval)
        }
        return true
    }

    private static func finish(_ id: AudioObjectID, intent: VolumeIntent, audio: any VolumeDeviceIO,
                               log: (String) -> Void, done: (Bool) -> Void) {
        let final = intent.snapshot
        guard audio.setVolume(id, final.target) else {
            log("final volume write failed")
            return done(false)
        }
        guard audio.setMuted(id, final.muted), audio.isMuted(id) == final.muted else {
            log("final mute write failed; leaving output muted")
            _ = audio.setMuted(id, true)
            return done(false)
        }
        log("ramp done")
        done(true)
    }
}
