import CoreAudio
import Foundation

/// Thin wrappers over the CoreAudio HAL property API.
public enum AudioHardware {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func devices() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    public static func uid(_ id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }
    public static func name(_ id: AudioObjectID) -> String? { string(id, kAudioObjectPropertyName) }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func uint32(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> UInt32? {
        var a = a
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(4)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    static func setUInt32(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
        var a = a
        var v = value
        guard AudioObjectHasProperty(id, &a) else { return false }
        return AudioObjectSetPropertyData(id, &a, 0, nil, 4, &v) == noErr
    }

    // MARK: Default output

    public static func defaultOutput() -> AudioObjectID? {
        uint32(system, address(kAudioHardwarePropertyDefaultOutputDevice))
    }

    @discardableResult
    public static func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        setUInt32(system, address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    /// Visible output devices other than `excluded`, with `preferredUID` first, then the
    /// built-in output.
    public static func otherOutputs(excluding excluded: AudioObjectID, preferredUID: String?) -> [AudioObjectID] {
        let outputs = devices().filter { id in
            guard id != excluded, uint32(id, address(kAudioDevicePropertyIsHidden)) != 1 else { return false }
            var a = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
        }
        func rank(_ id: AudioObjectID) -> Int {
            if let preferredUID, uid(id) == preferredUID { return 0 }
            return uint32(id, address(kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeBuiltIn ? 1 : 2
        }
        return outputs.sorted { rank($0) < rank($1) }
    }

    // MARK: Device state

    public static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        uint32(id, address(kAudioDevicePropertyDeviceIsRunningSomewhere)) == 1
    }

    /// Volume elements that exist on the output side. The KEF has per-channel elements 1 and 2,
    /// no master (element 0).
    public static func volumeElements(_ id: AudioObjectID) -> [UInt32] {
        (0...2).compactMap { el in
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, UInt32(el))
            return AudioObjectHasProperty(id, &a) ? UInt32(el) : nil
        }
    }

    /// Average scalar volume (0…1) across the device's output elements.
    public static func volume(_ id: AudioObjectID) -> Float? {
        let values = volumeElements(id).compactMap { volume(id, element: $0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    /// Reads one channel. Listener callbacks use this instead of rescanning every channel for
    /// each per-channel notification.
    static func volume(_ id: AudioObjectID, element: UInt32) -> Float? {
        var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
        var v: Float32 = 0
        var size = UInt32(4)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    public static func setVolume(_ id: AudioObjectID, _ scalar: Float) -> Bool {
        var ok = true
        for el in volumeElements(id) {
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
            var v = Float32(min(max(scalar, 0), 1))
            ok = AudioObjectSetPropertyData(id, &a, 0, nil, 4, &v) == noErr && ok
        }
        return ok
    }

    /// dB for one element (first available), for display and diagnostics.
    public static func volumeDecibels(_ id: AudioObjectID) -> Float? {
        guard let el = volumeElements(id).first else { return nil }
        var a = address(kAudioDevicePropertyVolumeDecibels, kAudioDevicePropertyScopeOutput, el)
        var v: Float32 = 0
        var size = UInt32(4)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    public static func isMuted(_ id: AudioObjectID) -> Bool? {
        uint32(id, address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)).map { $0 == 1 }
    }

    @discardableResult
    public static func setMuted(_ id: AudioObjectID, _ muted: Bool) -> Bool {
        setUInt32(id, address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), muted ? 1 : 0)
    }

    // MARK: Who is playing

    /// Apps currently running audio output to `device` (macOS 14+ process objects). Used to name
    /// the app that keeps an audio stream open to the KEF, e.g. the iOS Simulator.
    public static func processesPlaying(to device: AudioObjectID) -> [pid_t] {
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { process -> pid_t? in
            guard uint32(process, address(kAudioProcessPropertyIsRunningOutput)) == 1 else { return nil }
            var d = address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
            var dSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(process, &d, 0, nil, &dSize) == noErr, dSize > 0 else { return nil }
            var devices = [AudioObjectID](repeating: 0, count: Int(dSize) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(process, &d, 0, nil, &dSize, &devices) == noErr, devices.contains(device) else { return nil }
            var pid: pid_t = 0
            var pSize = UInt32(MemoryLayout<pid_t>.size)
            var p = address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(process, &p, 0, nil, &pSize, &pid) == noErr else { return nil }
            return pid
        }
    }

    // MARK: dB ↔ scalar (the device's own curve, as macOS uses it)

    public static func decibels(_ id: AudioObjectID, forScalar scalar: Float) -> Float? {
        translate(id, kAudioDevicePropertyVolumeScalarToDecibels, scalar)
    }

    public static func scalar(_ id: AudioObjectID, forDecibels db: Float) -> Float? {
        translate(id, kAudioDevicePropertyVolumeDecibelsToScalar, db)
    }

    private static func translate(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: Float) -> Float? {
        guard let el = volumeElements(id).first else { return nil }
        var a = address(selector, kAudioDevicePropertyScopeOutput, el)
        var v = Float32(value)
        var size = UInt32(4)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
}
