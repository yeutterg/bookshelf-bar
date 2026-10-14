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
    private var storedMuteWrites: [Bool] = []

    init(volume: Float?, muted: Bool?, acceptsWrites: Bool = true) {
        storedVolume = volume
        storedMuted = muted
        self.acceptsWrites = acceptsWrites
    }

    var currentVolume: Float? { lock.withLock { storedVolume } }
    var currentMuted: Bool? { lock.withLock { storedMuted } }
    var muteWrites: [Bool] { lock.withLock { storedMuteWrites } }

    func volume(_ id: AudioObjectID) -> Float? { currentVolume }
    func isMuted(_ id: AudioObjectID) -> Bool? { currentMuted }

    func setVolume(_ id: AudioObjectID, _ scalar: Float) -> Bool {
        lock.withLock {
            if acceptsWrites { storedVolume = scalar }
            return acceptsWrites
        }
    }

    func setMuted(_ id: AudioObjectID, _ muted: Bool) -> Bool {
        lock.withLock {
            storedMuteWrites.append(muted)
            if acceptsWrites { storedMuted = muted }
            return acceptsWrites
        }
    }
}
