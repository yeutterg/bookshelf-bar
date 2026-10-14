import CoreAudio
import Foundation

/// Watches the KEF USB audio device. When a KEF wakes into USB it drops off the bus for 1–4 s
/// and comes back as a *new* AudioObjectID, so everything here is keyed on "the KEF device that
/// exists right now" rather than a fixed ID.
@MainActor
public final class KEFUSBMonitor {
    public enum Event: Sendable, Equatable {
        case initialState(device: AudioObjectID?, name: String?, isDefault: Bool,
                          running: Bool, volume: Float?, muted: Bool)
        case arrived(AudioObjectID)
        case removed
        case defaultOutputChanged(isKEF: Bool)
        case runningChanged(Bool)
        case volumeChanged(Float)
        case muteChanged(Bool)
    }

    /// UID prefix for any KEF USB audio device, e.g. `AppleUSBAudioEngine:KEF:LSX II LT:20120000:2`.
    public nonisolated static let uidPrefix = "AppleUSBAudioEngine:KEF:"

    public private(set) var device: AudioObjectID?
    public private(set) var isDefaultOutput = false
    public private(set) var isRunning = false
    public private(set) var volume: Float?
    public private(set) var muted = false
    public private(set) var name: String?
    public var onEvent: ((Event) -> Void)?

    private let callbackQueue = DispatchQueue(label: "BookshelfBar.CoreAudioCallbacks", qos: .userInitiated)
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var volumeByElement: [UInt32: Float] = [:]
    private var hasAppliedSnapshot = false

    public init() {}

    public nonisolated static func findKEF() -> AudioObjectID? {
        AudioHardware.devices().first { AudioHardware.uid($0)?.hasPrefix(uidPrefix) == true }
    }

    public func start() {
        guard systemListeners.isEmpty else { return }
        hasAppliedSnapshot = false
        addSystemListener(kAudioHardwarePropertyDevices) { [weak self] in
            guard let self else { return }
            let snapshot = Self.snapshot()
            Task { @MainActor in self.apply(snapshot, initial: false) }
        }
        addSystemListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            guard let self else { return }
            let current = AudioHardware.defaultOutput()
            Task { @MainActor in
                let isKEF = current == self.device
                self.isDefaultOutput = isKEF
                self.onEvent?(.defaultOutputChanged(isKEF: isKEF))
            }
        }
        // Serialize the initial read with later CoreAudio callbacks so an older detached
        // snapshot cannot arrive after a real device-change notification.
        callbackQueue.async { [weak self] in
            let snapshot = Self.snapshot()
            Task { @MainActor in self?.apply(snapshot, initial: true) }
        }
    }

    public func stop() {
        for (a, block) in systemListeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(AudioHardware.system, &a, callbackQueue, block)
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

    private struct Snapshot: Sendable {
        let device: AudioObjectID?
        let name: String?
        let isDefault: Bool
        let running: Bool
        let volumeByElement: [UInt32: Float]
        let muted: Bool
        var volume: Float? {
            volumeByElement.isEmpty ? nil : volumeByElement.values.reduce(0, +) / Float(volumeByElement.count)
        }
    }

    private nonisolated static func snapshot() -> Snapshot {
        let device = findKEF()
        let elements = device.map(AudioHardware.volumeElements) ?? []
        let volumeByElement = Dictionary(uniqueKeysWithValues: elements.compactMap { element in
            device.flatMap { AudioHardware.volume($0, element: element) }.map { (element, $0) }
        })
        return Snapshot(device: device,
                        name: device.flatMap(AudioHardware.name),
                        isDefault: device != nil && AudioHardware.defaultOutput() == device,
                        running: device.map(AudioHardware.isRunningSomewhere) ?? false,
                        volumeByElement: volumeByElement,
                        muted: device.flatMap(AudioHardware.isMuted) ?? false)
    }

    private func apply(_ snapshot: Snapshot, initial: Bool) {
        // A device callback can reach the main actor before the queued initial read. In that
        // case the callback is already the authoritative initial state; discard the older read.
        if initial, hasAppliedSnapshot { return }
        let changedDevice = snapshot.device != device
        guard initial || changedDevice else { return }
        hasAppliedSnapshot = true
        detachDeviceListeners()
        device = snapshot.device
        name = snapshot.name
        isDefaultOutput = snapshot.isDefault
        isRunning = snapshot.running
        volume = snapshot.volume
        volumeByElement = snapshot.volumeByElement
        muted = snapshot.muted
        if initial {
            onEvent?(.initialState(device: snapshot.device, name: snapshot.name,
                                   isDefault: snapshot.isDefault, running: snapshot.running,
                                   volume: snapshot.volume, muted: snapshot.muted))
        } else {
            onEvent?(snapshot.device.map { .arrived($0) } ?? .removed)
        }
        attachDeviceListeners(elements: Array(snapshot.volumeByElement.keys))
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector, _ handler: @escaping @Sendable () -> Void) {
        var a = AudioHardware.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(AudioHardware.system, &a, callbackQueue, block)
        systemListeners.append((a, block))
    }

    private func attachDeviceListeners(elements: [UInt32]) {
        guard let id = device else { return }
        addDeviceListener(id, AudioHardware.address(kAudioDevicePropertyDeviceIsRunningSomewhere)) { [weak self] in
            let running = AudioHardware.isRunningSomewhere(id)
            Task { @MainActor in
                guard let self, self.device == id else { return }
                self.isRunning = running
                self.onEvent?(.runningChanged(running))
            }
        }
        for el in elements {
            addDeviceListener(id, AudioHardware.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)) { [weak self] in
                guard let value = AudioHardware.volume(id, element: el) else { return }
                Task { @MainActor in
                    guard let self, self.device == id else { return }
                    self.volumeByElement[el] = value
                    let average = self.volumeByElement.values.reduce(0, +) / Float(self.volumeByElement.count)
                    self.volume = average
                    self.onEvent?(.volumeChanged(average))
                }
            }
        }
        addDeviceListener(id, AudioHardware.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)) { [weak self] in
            guard let muted = AudioHardware.isMuted(id) else { return }
            Task { @MainActor in
                guard let self, self.device == id else { return }
                self.muted = muted
                self.onEvent?(.muteChanged(muted))
            }
        }
    }

    private func addDeviceListener(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress,
                                   _ handler: @escaping @Sendable () -> Void) {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(id, &a, callbackQueue, block) == noErr {
            deviceListeners.append((id, a, block))
        }
    }

    private func detachDeviceListeners() {
        for (id, a, block) in deviceListeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(id, &a, callbackQueue, block)
        }
        deviceListeners.removeAll()
    }
}
