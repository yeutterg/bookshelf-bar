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

    /// Starts silent, unmutes only at the inaudible floor, then rises in bounded whole-dB steps.
    @Test func fadesInFromSilenceInWholeDecibels() async {
        let audio = MockVolumeDevice(volume: 0.9, muted: false, decibelRange: -120...0)
        let guarder = VolumeGuard(audio: audio)
        var plan = VolumeGuard.Plan(hold: 0.4)
        plan.settleFor = 0.02
        plan.settleTimeout = 0.5
        plan.holdFor = 0.02
        plan.rampFor = 0.3
        plan.rampInterval = 0.005
        plan.fadeFromBelow = 50

        let completed = await run(guarder, audio: audio, plan: plan,
                                  intent: VolumeIntent(target: 0.75, muted: false))

        #expect(completed)
        #expect(audio.currentMuted == false)
        #expect(abs((audio.currentVolume ?? 0) - 0.75) < 0.001)
        let fade = audio.decibelWrites
        #expect(fade.first == -80)          // target −30 dB, 50 below
        #expect(audio.decibelsWhenUnmuted == -80)
        #expect(zip(fade, fade.dropFirst()).allSatisfy { $1 - $0 >= 1 && $1 - $0 <= 8 && $1 == $1.rounded() })
        #expect(fade.last == -30)
    }

    /// The real KEF reports a write late. Measuring the target too early read the parked level
    /// (−103 dB), so the fade stayed inaudible and then jumped to full volume.
    @Test func waitsForTheTargetBeforeMeasuringItsLevel() async {
        let audio = MockVolumeDevice(volume: 0.9, muted: false, decibelRange: -120...0, staleReads: 3)
        let guarder = VolumeGuard(audio: audio)
        var plan = VolumeGuard.Plan(hold: 0.1)
        plan.settleFor = 0.02
        plan.settleTimeout = 1
        plan.holdFor = 0
        plan.rampFor = 0.2
        plan.rampInterval = 0.005
        plan.fadeFromBelow = 50

        let completed = await run(guarder, audio: audio, plan: plan,
                                  intent: VolumeIntent(target: 0.75, muted: false))

        #expect(completed)
        #expect(audio.decibelWrites.first == -80)
        #expect(audio.decibelWrites.last == -30)
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
    private var staleVolume: Float?
    private var staleLeft = 0
    private var storedMuteWrites: [Bool] = []
    private var storedDecibelWrites: [Float] = []
    private var storedDecibelsWhenUnmuted: Float?

    init(volume: Float?, muted: Bool?, acceptsWrites: Bool = true, step: Float? = nil,
         decibelRange: ClosedRange<Float>? = nil, staleReads: Int = 0) {
        storedVolume = volume
        storedMuted = muted
        self.acceptsWrites = acceptsWrites
        self.step = step
        range = decibelRange
        self.staleReads = staleReads
    }

    var decibelWrites: [Float] { lock.withLock { storedDecibelWrites } }
    var decibelsWhenUnmuted: Float? { lock.withLock { storedDecibelsWhenUnmuted } }

    // A linear dB scale is enough to check the fade's shape.
    func decibelRange(_ id: AudioObjectID) -> ClosedRange<Float>? { range }
    func decibels(_ id: AudioObjectID) -> Float? {
        lock.withLock {
            let v = staleLeft > 0 ? staleVolume : storedVolume
            return range.flatMap { r in v.map { r.lowerBound + (r.upperBound - r.lowerBound) * $0 } }
        }
    }
    func setDecibels(_ id: AudioObjectID, _ db: Float) -> Bool {
        lock.withLock {
            guard let range else { return false }
            storedDecibelWrites.append(db)
            storedVolume = (db - range.lowerBound) / (range.upperBound - range.lowerBound)
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
            }
            return acceptsWrites
        }
    }

    func setMuted(_ id: AudioObjectID, _ muted: Bool) -> Bool {
        lock.withLock {
            storedMuteWrites.append(muted)
            if acceptsWrites {
                if storedMuted == true, !muted, storedDecibelsWhenUnmuted == nil, let range, let v = storedVolume {
                    storedDecibelsWhenUnmuted = range.lowerBound + (range.upperBound - range.lowerBound) * v
                }
                storedMuted = muted
            }
            return acceptsWrites
        }
    }
}
