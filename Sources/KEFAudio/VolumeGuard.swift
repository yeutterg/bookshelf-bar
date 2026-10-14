import CoreAudio
import Foundation

/// Runs Smooth Start's volume work on its own serial queue. CoreAudio property calls on a
/// device that has just re-appeared can block for seconds; doing them on the main thread made
/// the guard late and the ramp uneven (measured: a 2 s stall, then macOS's saved volume won).
public final class VolumeGuard: @unchecked Sendable {
    public struct Plan: Sendable {
        public var hold: Float
        public var target: Float
        /// Keep re-asserting mute + hold until both have stuck for this long.
        public var settleFor: Double = 0.5
        /// Give up waiting to settle after this long (then proceed anyway).
        public var settleTimeout: Double = 3
        public var holdFor: Double = 1.5
        public var rampFor: Double = 2
        public init(hold: Float, target: Float) {
            self.hold = hold
            self.target = target
        }
    }

    private let queue = DispatchQueue(label: "KEFBar.VolumeGuard", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    public init() {}

    /// Cancels whatever is running (the next step checks and stops).
    public func cancel() {
        lock.withLock { generation += 1 }
    }

    /// One-off write of the hold level, e.g. just before a wake so macOS saves the low value.
    public func setLevel(_ id: AudioObjectID, _ level: Float) {
        queue.async { AudioHardware.setVolume(id, level) }
    }

    /// Full guard for a freshly re-arrived device: mute + hold until stable, unmute at hold,
    /// hold, then ease up to the target along an S-curve. `log` and `done` are called on the
    /// guard queue.
    public func run(_ id: AudioObjectID, _ plan: Plan, log: @escaping @Sendable (String) -> Void,
                    done: @escaping @Sendable (_ completed: Bool) -> Void) {
        let gen = lock.withLock { generation += 1; return generation }
        let alive = { [weak self] in self?.lock.withLock { self?.generation == gen } ?? false }

        queue.async {
            // 1. Protect: macOS applies its saved volume (and clears mute) around the default-output
            //    switch, a few hundred ms after arrival. Keep winning until it's stable.
            let start = Date()
            var stableSince: Date?
            while alive(), Date().timeIntervalSince(start) < plan.settleTimeout {
                let muted = AudioHardware.isMuted(id) ?? true
                let v = AudioHardware.volume(id) ?? plan.hold
                if !muted { AudioHardware.setMuted(id, true) }
                if abs(v - plan.hold) > 0.005 { AudioHardware.setVolume(id, plan.hold) }
                if muted, abs(v - plan.hold) <= 0.005 {
                    if stableSince == nil { stableSince = Date() }
                    if Date().timeIntervalSince(stableSince!) >= plan.settleFor { break }
                } else {
                    stableSince = nil
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard alive() else { return done(false) }
            log("settled at hold \(plan.hold) after \(String(format: "%.2f", Date().timeIntervalSince(start)))s")

            // 2. Hold low (audible, quiet) while the speaker finishes waking. Keep re-asserting.
            AudioHardware.setMuted(id, false)
            let holdEnd = Date().addingTimeInterval(plan.holdFor)
            while alive(), Date() < holdEnd {
                if let v = AudioHardware.volume(id), abs(v - plan.hold) > 0.005 { AudioHardware.setVolume(id, plan.hold) }
                if AudioHardware.isMuted(id) == true { AudioHardware.setMuted(id, false) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard alive() else { return done(false) }

            // 3. Ramp, timed against the clock so it takes `rampFor` regardless of write latency.
            log("ramp \(plan.hold) -> \(plan.target)")
            let rampStart = Date()
            while alive() {
                let t = Float(min(Date().timeIntervalSince(rampStart) / plan.rampFor, 1))
                let eased = t * t * (3 - 2 * t)
                AudioHardware.setVolume(id, plan.hold + (plan.target - plan.hold) * eased)
                if t >= 1 { break }
                Thread.sleep(forTimeInterval: 0.03)
            }
            guard alive() else { return done(false) }
            AudioHardware.setVolume(id, plan.target)
            log("ramp done")
            done(true)
        }
    }
}
