import AudioToolbox
import CoreAudio
import Foundation

/// Tells whether anything audible is actually going to a device. An open stream isn't enough:
/// Spotify and others keep streaming silence while paused. This taps the device's output with
/// a private Core Audio process tap (macOS asks once for System Audio Recording permission;
/// if it's denied the tap only delivers silence, so nothing reads as audible). Nothing is
/// recorded: each buffer is reduced to its peak and dropped.
public final class OutputLevelMeter: @unchecked Sendable {
    /// Peaks above this (≈ −60 dBFS) count as sound.
    private let threshold: Float = 0.001
    /// Stay "audible" this long after the last loud buffer, so quiet passages don't flicker.
    private let hangover: TimeInterval = 0.8

    private let queue = DispatchQueue(label: "BookshelfBar.OutputLevelMeter", qos: .utility)
    private let lock = NSLock()
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var lastLoud = Date.distantPast
    private var audible = false
    private var onChange: (@Sendable (Bool) -> Void)?

    public init() {}

    /// Starts metering `deviceUID`'s output. A tap has no clock of its own, so the aggregate
    /// runs on `clockUID`, another output (nothing is played to it). Clocking from the metered
    /// device itself would make the meter an open stream to it, keeping it awake. `onChange`
    /// is called on a background queue.
    @discardableResult
    public func start(deviceUID: String, clockUID: String, onChange: @escaping @Sendable (Bool) -> Void) -> Bool {
        stop()
        let description = CATapDescription(__excludingProcesses: [], andDeviceUID: deviceUID, withStream: 0)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return false }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BookshelfBar Level",
            kAudioAggregateDeviceUIDKey: "com.github.yeutterg.bookshelfbar.level.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                              kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.measure(input)
        }
        guard created == noErr, let procID, AudioDeviceStart(aggregateID, procID) == noErr else {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        lock.withLock {
            tap = tapID
            aggregate = aggregateID
            proc = procID
            lastLoud = .distantPast
            audible = false
            self.onChange = onChange
        }
        return true
    }

    public func stop() {
        let (tapID, aggregateID, procID) = lock.withLock {
            defer {
                tap = AudioObjectID(kAudioObjectUnknown)
                aggregate = AudioObjectID(kAudioObjectUnknown)
                proc = nil
                onChange = nil
                audible = false
            }
            return (tap, aggregate, proc)
        }
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }

    private func measure(_ input: UnsafePointer<AudioBufferList>) {
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float32.self)
            for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size {
                peak = max(peak, abs(samples[i]))
            }
        }
        let now = Date()
        let (changed, callback): (Bool?, (@Sendable (Bool) -> Void)?) = lock.withLock {
            if peak > threshold { lastLoud = now }
            let isAudible = now.timeIntervalSince(lastLoud) < hangover
            guard isAudible != audible else { return (nil, nil) }
            audible = isAudible
            return (isAudible, onChange)
        }
        if let changed { callback?(changed) }
    }
}
