import CoreAudio
import Foundation
import Testing
@testable import KEFAudio

@Suite struct VolumeGuardTests {
    @Test func failsClosedWhenSafeHoldCannotBeVerified() async {
        let audio = MockVolumeDevice(volume: nil, muted: nil, acceptsWrites: false)
        let guarder = VolumeGuard(audio: audio)
        var plan = VolumeGuard.Plan(hold: 0.1)
        plan.settleFor = 0
        plan.settleTimeout = 0.06
        plan.holdFor = 0
        plan.rampFor = 0.01

        let completed = await run(guarder, audio: audio, plan: plan,
                                  intent: VolumeIntent(target: 0.7, muted: false))

        #expect(!completed)
        #expect(audio.muteWrites.last == true)
        #expect(!audio.muteWrites.contains(false))
    }

    /// The real KEF rounds to whole-dB steps, so the exact hold level is never read back.
    /// The guard must accept the nearest step and finish unmuted at the target.
    @Test func acceptsAQuantizedHoldLevel() async {
        let audio = MockVolumeDevice(volume: 0.6, muted: false, step: 0.0125)
        let guarder = VolumeGuard(audio: audio)
        var plan = VolumeGuard.Plan(hold: 0.4067)
        plan.settleFor = 0.05
        plan.settleTimeout = 0.5
        plan.holdFor = 0.02
        plan.rampFor = 0.02

        let completed = await run(guarder, audio: audio, plan: plan,
                                  intent: VolumeIntent(target: 0.6267, muted: false))

        #expect(completed)
        #expect(audio.currentMuted == false)
        #expect(abs((audio.currentVolume ?? 0) - 0.6267) < 0.0125)
    }

    @Test func preservesAnInitiallyMutedUserIntent() async {
        let audio = MockVolumeDevice(volume: 0.1, muted: true)
        let guarder = VolumeGuard(audio: audio)
        var plan = VolumeGuard.Plan(hold: 0.1)
        plan.settleFor = 0
        plan.settleTimeout = 0.1
        plan.holdFor = 0
        plan.rampFor = 0.01

        let completed = await run(guarder, audio: audio, plan: plan,
                                  intent: VolumeIntent(target: 0.6, muted: true))

        #expect(completed)
        #expect(audio.currentMuted == true)
        #expect(abs((audio.currentVolume ?? 0) - 0.6) < 0.001)
    }

    @Test func finishesAtTheLatestTarget() async {
        let audio = MockVolumeDevice(volume: 0.1, muted: true)
        let guarder = VolumeGuard(audio: audio)
        let intent = VolumeIntent(target: 0.8, muted: false)
        var plan = VolumeGuard.Plan(hold: 0.1)
        plan.settleFor = 0
        plan.settleTimeout = 0.1
        plan.holdFor = 0.08
        plan.rampFor = 0.04

        Task {
            try? await Task.sleep(for: .milliseconds(25))
            intent.setTarget(0.32)
            intent.setMuted(true)
        }
        let completed = await run(guarder, audio: audio, plan: plan, intent: intent)

        #expect(completed)
        #expect(abs((audio.currentVolume ?? 0) - 0.32) < 0.001)
        #expect(audio.currentMuted == true)
    }

    /// Starts from silence, unmutes only there, then rises in bounded whole-dB steps.
    @Test func fadesInFromSilenceInWholeDecibels() async {
        let audio = MockVolumeDevice(volume: 0.9, muted: false, decibelRange: -120...0)
        let guarder = VolumeGuard(audio: audio)
        var plan = VolumeGuard.Plan(hold: 0.02)
        plan.settleFor = 0.02
        plan.settleTimeout = 0.5
        plan.holdFor = 0.02
        plan.rampFor = 0.3
        plan.rampInterval = 0.005

        let completed = await run(guarder, audio: audio, plan: plan,
                                  intent: VolumeIntent(target: 0.75, muted: false))

        #expect(completed)
        #expect(audio.currentMuted == false)
        #expect(abs((audio.currentVolume ?? 0) - 0.75) < 0.001)
        let fade = audio.decibelWrites
        #expect(fade.first == -120)
        #expect(audio.decibelsWhenUnmuted == -120)
        #expect(zip(fade, fade.dropFirst()).allSatisfy { $1 - $0 >= 1 && $1 - $0 <= 8 && $1 == $1.rounded() })
        #expect(fade.last == -16)           // −120 + 120·√0.75, rounded
    }

    /// The old fade wrote the full target while "muted" to learn its dB; a late mute on the
    /// real KEF made that an audible burst before the fade. Nothing may go above the parked
    /// level until the output is unmuted at silence.
    @Test func neverRaisesTheLevelWhileMuted() async {
        let audio = MockVolumeDevice(volume: 0.9, muted: false, decibelRange: -120...0, staleReads: 3)
        let guarder = VolumeGuard(audio: audio)
        var plan = VolumeGuard.Plan(hold: 0.02)
        plan.settleFor = 0.02
        plan.settleTimeout = 1
        plan.rampFor = 0.2
        plan.rampInterval = 0.005

        let completed = await run(guarder, audio: audio, plan: plan,
                                  intent: VolumeIntent(target: 0.75, muted: false))

        #expect(completed)
        #expect(audio.maxLevelWrittenWhileMuted.map { $0 <= 0.02 + plan.holdTolerance } ?? true)
        #expect(audio.decibelWrites.last == -16)
    }

    /// A device with an unknown taper falls back to a scalar ramp, still only upward from hold.
    @Test func rampsInScalarWhenTheCurveIsUnknown() async {
        let audio = MockVolumeDevice(volume: 0.9, muted: false, decibelRange: -120...0, linearDecibels: true)
        let guarder = VolumeGuard(audio: audio)
        var plan = VolumeGuard.Plan(hold: 0.02)
        plan.settleFor = 0.02
        plan.settleTimeout = 0.5
        plan.rampFor = 0.1
        plan.rampInterval = 0.005

        let completed = await run(guarder, audio: audio, plan: plan,
                                  intent: VolumeIntent(target: 0.75, muted: false))

        #expect(completed)
        #expect(audio.decibelWrites.isEmpty)
        #expect(audio.maxLevelWrittenWhileMuted.map { $0 <= 0.02 + plan.holdTolerance } ?? true)
        #expect(abs((audio.currentVolume ?? 0) - 0.75) < 0.001)
    }

    private func run(_ guarder: VolumeGuard, audio: MockVolumeDevice, plan: VolumeGuard.Plan,
                     intent: VolumeIntent) async -> Bool {
        await withCheckedContinuation { continuation in
            guarder.run(1, plan, intent: intent, log: { _ in }) {
                continuation.resume(returning: $0)
            }
        }
    }
}

private final class MockVolumeDevice: VolumeDeviceIO, @unchecked Sendable {
    private let lock = NSLock()
    private var storedVolume: Float?
    private var storedMuted: Bool?
    private let acceptsWrites: Bool
    private let step: Float?
    private let range: ClosedRange<Float>?
    private let staleReads: Int
    private let linear: Bool
    private var storedMaxWhileMuted: Float?
    private var staleVolume: Float?
    private var staleLeft = 0
    private var storedMuteWrites: [Bool] = []
    private var storedDecibelWrites: [Float] = []
    private var storedDecibelsWhenUnmuted: Float?

    init(volume: Float?, muted: Bool?, acceptsWrites: Bool = true, step: Float? = nil,
         decibelRange: ClosedRange<Float>? = nil, staleReads: Int = 0, linearDecibels: Bool = false) {
        storedVolume = volume
        storedMuted = muted
        self.acceptsWrites = acceptsWrites
        self.step = step
        range = decibelRange
        self.staleReads = staleReads
        linear = linearDecibels
    }

    var maxLevelWrittenWhileMuted: Float? { lock.withLock { storedMaxWhileMuted } }

    /// Call with the lock held.
    private func noteWrite(_ level: Float) {
        if storedMuted == true { storedMaxWhileMuted = max(storedMaxWhileMuted ?? 0, level) }
    }

    /// macOS's USB Audio taper (dB = min + span·√scalar), or a linear one for the fallback test.
    private func db(_ v: Float, _ r: ClosedRange<Float>) -> Float {
        r.lowerBound + (r.upperBound - r.lowerBound) * (linear ? v : v.squareRoot())
    }
    private func scalar(_ db: Float, _ r: ClosedRange<Float>) -> Float {
        let x = (db - r.lowerBound) / (r.upperBound - r.lowerBound)
        return linear ? x : x * x
    }

    var decibelWrites: [Float] { lock.withLock { storedDecibelWrites } }
    var decibelsWhenUnmuted: Float? { lock.withLock { storedDecibelsWhenUnmuted } }

    func decibelRange(_ id: AudioObjectID) -> ClosedRange<Float>? { range }
    func decibels(_ id: AudioObjectID) -> Float? {
        lock.withLock {
            let v = staleLeft > 0 ? staleVolume : storedVolume
            return range.flatMap { r in v.map { db($0, r) } }
        }
    }
    func setDecibels(_ id: AudioObjectID, _ db: Float) -> Bool {
        lock.withLock {
            guard let range else { return false }
            storedDecibelWrites.append(db)
            storedVolume = scalar(db, range)
            noteWrite(storedVolume ?? 0)
            return true
        }
    }

    var currentVolume: Float? { lock.withLock { storedVolume } }
    var currentMuted: Bool? { lock.withLock { storedMuted } }
    var muteWrites: [Bool] { lock.withLock { storedMuteWrites } }

    /// After a write, the first `staleReads` reads still return the previous level.
    func volume(_ id: AudioObjectID) -> Float? {
        lock.withLock {
            if staleLeft > 0 { staleLeft -= 1; return staleVolume }
            return storedVolume
        }
    }
    func isMuted(_ id: AudioObjectID) -> Bool? { currentMuted }

    func setVolume(_ id: AudioObjectID, _ scalar: Float) -> Bool {
        lock.withLock {
            if acceptsWrites {
                if staleReads > 0 { staleVolume = storedVolume; staleLeft = staleReads }
                storedVolume = step.map { (scalar / $0).rounded() * $0 } ?? scalar
                noteWrite(storedVolume ?? 0)
            }
            return acceptsWrites
        }
    }

    func setMuted(_ id: AudioObjectID, _ muted: Bool) -> Bool {
        lock.withLock {
            storedMuteWrites.append(muted)
            if acceptsWrites {
                if storedMuted == true, !muted, storedDecibelsWhenUnmuted == nil, let range, let v = storedVolume {
                    storedDecibelsWhenUnmuted = db(v, range)
                }
                storedMuted = muted
            }
            return acceptsWrites
        }
    }
}
