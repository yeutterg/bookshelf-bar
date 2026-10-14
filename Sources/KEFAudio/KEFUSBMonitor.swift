import CoreAudio
import Foundation

/// Watches the KEF USB audio device. When a KEF wakes into USB it drops off the bus for 1–4 s
/// and comes back as a *new* AudioObjectID, so everything here is keyed on "the KEF device that
/// exists right now" rather than a fixed ID.
@MainActor
public final class KEFUSBMonitor {
    public enum Event: Sendable, Equatable {
        case arrived(AudioObjectID)
        case removed
        case defaultOutputChanged(isKEF: Bool)
        case runningChanged(Bool)
        case volumeChanged(Float)
    }

    /// UID prefix for any KEF USB audio device, e.g. `AppleUSBAudioEngine:KEF:LSX II LT:20120000:2`.
    public nonisolated static let uidPrefix = "AppleUSBAudioEngine:KEF:"

    public private(set) var device: AudioObjectID?
    public var onEvent: ((Event) -> Void)?

    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init() {}

    public nonisolated static func findKEF() -> AudioObjectID? {
        AudioHardware.devices().first { AudioHardware.uid($0)?.hasPrefix(uidPrefix) == true }
    }

    public var isDefaultOutput: Bool {
        guard let device else { return false }
        return AudioHardware.defaultOutput() == device
    }

    public var isRunning: Bool { device.map(AudioHardware.isRunningSomewhere) ?? false }
    public var volume: Float? { device.flatMap(AudioHardware.volume) }
    public var name: String? { device.flatMap(AudioHardware.name) }

    public func start() {
        guard systemListeners.isEmpty else { return }
        device = Self.findKEF()
        attachDeviceListeners()
        addSystemListener(kAudioHardwarePropertyDevices) { [weak self] in self?.devicesChanged() }
        addSystemListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            guard let self else { return }
            self.onEvent?(.defaultOutputChanged(isKEF: self.isDefaultOutput))
        }
    }

    public func stop() {
        for (a, block) in systemListeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(AudioHardware.system, &a, .main, block)
        }
        systemListeners.removeAll()
        detachDeviceListeners()
    }

    @discardableResult
    public func makeDefaultOutput() -> Bool {
        guard let device else { return false }
        return AudioHardware.setDefaultOutput(device)
    }

    // MARK: Private

    private func devicesChanged() {
        let now = Self.findKEF()
        guard now != device else { return }
        detachDeviceListeners()
        device = now
        attachDeviceListeners()
        onEvent?(now.map { .arrived($0) } ?? .removed)
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor () -> Void) {
        var a = AudioHardware.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { handler() } }
        AudioObjectAddPropertyListenerBlock(AudioHardware.system, &a, .main, block)
        systemListeners.append((a, block))
    }

    private func attachDeviceListeners() {
        guard let id = device else { return }
        addDeviceListener(id, AudioHardware.address(kAudioDevicePropertyDeviceIsRunningSomewhere)) { [weak self] in
            self?.onEvent?(.runningChanged(AudioHardware.isRunningSomewhere(id)))
        }
        for el in AudioHardware.volumeElements(id) {
            addDeviceListener(id, AudioHardware.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)) { [weak self] in
                if let v = AudioHardware.volume(id) { self?.onEvent?(.volumeChanged(v)) }
            }
        }
    }

    private func addDeviceListener(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ handler: @escaping @MainActor () -> Void) {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { handler() } }
        if AudioObjectAddPropertyListenerBlock(id, &a, .main, block) == noErr {
            deviceListeners.append((id, a, block))
        }
    }

    private func detachDeviceListeners() {
        for (id, a, block) in deviceListeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
        deviceListeners.removeAll()
    }
}
