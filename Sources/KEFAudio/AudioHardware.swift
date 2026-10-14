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
        let values = volumeElements(id).compactMap { el -> Float? in
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
            var v: Float32 = 0
            var size = UInt32(4)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
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
}
