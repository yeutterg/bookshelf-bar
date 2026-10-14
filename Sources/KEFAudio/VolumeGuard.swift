import CoreAudio
import Foundation

public protocol VolumeDeviceIO: Sendable {
    func volume(_ id: AudioObjectID) -> Float?
    func isMuted(_ id: AudioObjectID) -> Bool?
    @discardableResult func setVolume(_ id: AudioObjectID, _ scalar: Float) -> Bool
    @discardableResult func setMuted(_ id: AudioObjectID, _ muted: Bool) -> Bool
}

private struct SystemVolumeDevice: VolumeDeviceIO {
    func volume(_ id: AudioObjectID) -> Float? { AudioHardware.volume(id) }
    func isMuted(_ id: AudioObjectID) -> Bool? { AudioHardware.isMuted(id) }
    func setVolume(_ id: AudioObjectID, _ scalar: Float) -> Bool { AudioHardware.setVolume(id, scalar) }
    func setMuted(_ id: AudioObjectID, _ muted: Bool) -> Bool { AudioHardware.setMuted(id, muted) }
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
        /// Hold low after the speaker reconnects. The speaker's output still settles for a few
        /// seconds after waking (heard as stutter with a 1.5 s hold), so stay low through that.
        /// The KEF's USB volume moves in whole-dB steps, so an exact scalar can't always be
        /// hit; anything within this distance of the hold level counts (≈1–2 dB).
        public var holdTolerance: Float = 0.04
        public var holdFor: Double = 5
        /// Long, gentle S-curve back up to the user's volume.
        public var rampFor: Double = 4.5
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

    /// One-off write of the hold level, e.g. just before a wake so macOS saves the low value.
    public func setLevel(_ id: AudioObjectID, _ level: Float) {
        let audio = self.audio
        queue.async { _ = audio.setVolume(id, level) }
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

    /// Full guard for a freshly re-arrived device: mute + hold until stable, restore the user's
    /// current mute intent, then ease to their live target along an S-curve.
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

            // 2. Hold low (audible, quiet) while the speaker finishes waking. Keep re-asserting.
            let holdEnd = Date().addingTimeInterval(plan.holdFor)
            while alive(), Date() < holdEnd {
                if audio.volume(id).map({ abs($0 - plan.hold) > plan.holdTolerance }) != false {
                    _ = audio.setVolume(id, plan.hold)
                }
                let desiredMute = intent.snapshot.muted
                if audio.isMuted(id) != desiredMute { _ = audio.setMuted(id, desiredMute) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard alive() else { return done(false) }

            // 3. Ramp, timed against the clock so it takes `rampFor` regardless of write latency.
            log("ramp from \(plan.hold)")
            let rampStart = Date()
            while alive() {
                let t = Float(min(Date().timeIntervalSince(rampStart) / plan.rampFor, 1))
                let eased = t * t * (3 - 2 * t)
                let desired = intent.snapshot
                _ = audio.setVolume(id, plan.hold + (desired.target - plan.hold) * eased)
                if audio.isMuted(id) != desired.muted { _ = audio.setMuted(id, desired.muted) }
                if t >= 1 { break }
                Thread.sleep(forTimeInterval: 0.03)
            }
            guard alive() else { return done(false) }
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
}
