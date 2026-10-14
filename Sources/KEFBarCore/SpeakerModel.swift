import Foundation
import KEFKit
import Observation
import os

let log = Logger(subsystem: "com.github.yeutterg.kefbar", category: "speaker")

/// Everything the UI shows about the speaker, kept live from the speaker's event queue.
@MainActor
@Observable
public final class SpeakerModel {
    public enum Connection: Equatable {
        case searching
        case connecting(String)
        case connected
        case unreachable(String)
    }

    // Discovery and identity
    public private(set) var speakers: [KEFSpeakerInfo] = []
    public private(set) var info: KEFSpeakerInfo?
    public private(set) var connection: Connection = .searching
    public private(set) var host: String?

    // Live state
    public private(set) var status: SpeakerStatus = .standby
    public private(set) var source: PhysicalSource = .standby
    public private(set) var volume: Int = 0
    public private(set) var muted = false
    public private(set) var powerTarget = "unknown"

    // Settings (read on connect and when the Sound & Power page opens)
    public private(set) var deskMode = false
    public private(set) var wallMode = false
    public private(set) var bassExtension: BassExtension = .standard
    public private(set) var treble: Double = 0
    public private(set) var balance: Int = 0
    public private(set) var standbyMode: StandbyMode = .thirtyMinutes
    public private(set) var wakeUpSource: WakeUpSource = .none
    public private(set) var maximumVolume = 100
    public private(set) var profileName = ""

    public var lastError: String?
    /// macOS is blocking local network access (the app needs the Local Network permission).
    public private(set) var localNetworkDenied = false

    /// While the popover is visible the app always streams events; otherwise it stops once the
    /// speaker is in standby, so an idle Mac holds no connection at all.
    public var popoverVisible = false { didSet { updateEventStream() } }

    public var isOn: Bool { status == .powerOn }
    public var finish: KEFFinish { info?.finish ?? .unknown }

    private(set) var client: KEFClient?
    private var discoveryTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var volumeWrite: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private static let savedSpeakerKey = "selectedKefId"
    private static let savedHostKey = "manualHost"
    private static let pendingWakeRestoreKey = "pendingWakeRestore"

    public init() {}

    // MARK: Lifecycle

    /// No speaker has been chosen yet: the UI shows the setup step instead of controls.
    public private(set) var needsSetup = true

    public func start() {
        guard discoveryTask == nil else { return }
        checkLocalNetworkAccess()
        let savedId = defaults.string(forKey: Self.savedSpeakerKey)
        needsSetup = savedId == nil && defaults.string(forKey: Self.savedHostKey) == nil
        if let manual = defaults.string(forKey: Self.savedHostKey) {
            Task { await connect(host: manual) }
        }
        discoveryTask = Task { [weak self] in
            for await list in KEFDiscovery().speakers() {
                guard let self else { return }
                self.speakers = list
                // Reconnect only to the speaker the user chose; never pick one on our own.
                // Also retry a failed connection when the speaker (re)appears, e.g. right after the
                // Local Network permission is granted.
                let failed = if case .unreachable = self.connection { true } else { false }
                if self.info == nil || failed, let saved = self.defaults.string(forKey: Self.savedSpeakerKey),
                   let match = list.first(where: { $0.kefId == saved }) {
                    await self.select(match)
                }
            }
        }
    }

    /// Setup: remember `speaker` (by its permanent kefId) and connect to it.
    public func pair(_ speaker: KEFSpeakerInfo) async {
        defaults.removeObject(forKey: Self.savedHostKey)
        needsSetup = false
        await select(speaker)
    }

    /// Back to the setup step, e.g. to switch to another pair.
    public func forget() {
        eventTask?.cancel()
        eventTask = nil
        defaults.removeObject(forKey: Self.savedSpeakerKey)
        defaults.removeObject(forKey: Self.savedHostKey)
        client = nil
        info = nil
        host = nil
        connection = .searching
        needsSetup = true
    }

    /// Makes a pair identifiable during setup: wakes it for a few seconds (relays click, the
    /// status light comes on), then restores its previous state. Speakers that are already on
    /// get a brief mute instead.
    public func identify(_ speaker: KEFSpeakerInfo) async {
        guard let host = try? await KEFDiscovery.resolveHost(for: speaker) else { return }
        let c = KEFClient(host: host)
        guard let status = try? await c.status() else { return }
        if status == .standby {
            try? await c.setSource(.powerOn)
            try? await Task.sleep(for: .seconds(5))
            try? await c.setSource(.standby)
        } else {
            let wasMuted = (try? await c.isMuted()) ?? false
            for _ in 0..<2 {
                try? await c.setMuted(!wasMuted)
                try? await Task.sleep(for: .milliseconds(500))
                try? await c.setMuted(wasMuted)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func select(_ speaker: KEFSpeakerInfo) async {
        info = speaker
        defaults.set(speaker.kefId, forKey: Self.savedSpeakerKey)
        connection = .connecting(speaker.name)
        log.info("resolving \(speaker.name, privacy: .public)")
        do {
            await connect(host: try await KEFDiscovery.resolveHost(for: speaker))
        } catch {
            log.error("resolve failed: \(error.localizedDescription, privacy: .public)")
            noteFailure(error)
        }
    }

    /// Manual fallback when Bonjour is blocked (guest networks, VLANs).
    public func connect(host: String, remember: Bool = false) async {
        if remember {
            defaults.set(host, forKey: Self.savedHostKey)
            needsSetup = false
        }
        self.host = host
        client = KEFClient(host: host, password: SpeakerPassword.load(for: info?.kefId) ?? "")
        connection = .connecting(info?.name ?? host)
        do {
            try await refresh()
            connection = .connected
            localNetworkDenied = false
            restorePendingWakeSource()
            log.info("connected to \(host, privacy: .public)")
            updateEventStream(force: true)
        } catch {
            log.error("connect to \(host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            noteFailure(error)
        }
    }

    public func refresh() async throws {
        guard let c = client else { return }
        async let s = c.status()
        async let src = c.source()
        async let v = c.volume()
        async let m = c.isMuted()
        async let p = c.powerTarget()
        (status, source, volume, muted, powerTarget) = try await (s, src, v, m, p)
    }

    public func refreshSettings() async {
        guard let c = client else { return }
        deskMode = (try? await c.get(.deskMode).bool) ?? deskMode
        wallMode = (try? await c.get(.wallMode).bool) ?? wallMode
        bassExtension = (try? await c.get(.bassExtension).string).flatMap(BassExtension.init) ?? bassExtension
        treble = (try? await c.get(.trebleAmount).double) ?? treble
        balance = (try? await c.get(.balance).int) ?? balance
        standbyMode = (try? await c.get(.standbyMode).string).flatMap(StandbyMode.init) ?? standbyMode
        wakeUpSource = (try? await c.get(.wakeUpSource).string).flatMap(WakeUpSource.init) ?? wakeUpSource
        maximumVolume = (try? await c.get(.maximumVolume).int) ?? maximumVolume
        profileName = (try? await c.get(.profileName).string) ?? profileName
    }

    // MARK: Actions

    public func setVolume(_ value: Int) {
        volume = min(max(value, 0), 100)
        // Coalesce slider drags: only the latest value is sent.
        volumeWrite?.cancel()
        let target = volume
        volumeWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await self?.perform { try await $0.setVolume(target) }
        }
    }

    public func toggleMute() {
        muted.toggle()
        let m = muted
        Task { await perform { try await $0.setMuted(m) } }
    }

    public func setSource(_ s: PhysicalSource) {
        if s == .standby { turnOff(); return }
        source = s
        status = .powerOn
        Task { await perform { try await $0.setSource(s) } }
    }

    public func togglePower() {
        if isOn { turnOff() } else { setSource(.usb) }
    }

    /// Set by Smooth Start: some app on this Mac has an audio stream open to the KEF.
    public var usbStreamActive = false

    /// Standby that sticks. With Wake On set to USB Audio, the firmware wakes straight back up
    /// if an app is holding an audio stream open to it when it enters standby (the iOS
    /// Simulator, a paused browser tab…). In that case only: switch the wake source off, enter
    /// standby, and restore it a few seconds later (restoring doesn't wake it).
    ///
    /// Side effect, measured: entering standby with USB wake off also powers down the speaker's
    /// USB interface until its next wake, so Mac audio can't wake it. That's why this is limited
    /// to the stream-held case, where it would otherwise never stay off at all.
    public func turnOff() {
        status = .standby
        source = .standby
        guard let client else { return }
        let streamHeld = usbStreamActive
        Task {
            let wake = streamHeld ? ((try? await client.get(.wakeUpSource).string).flatMap(WakeUpSource.init) ?? .none) : .none
            if wake != .none {
                defaults.set(wake.rawValue, forKey: Self.pendingWakeRestoreKey)
                try? await client.set(.wakeUpSource, WakeUpSource.none.value)
            }
            await perform { try await $0.setSource(.standby) }
            if wake != .none {
                try? await Task.sleep(for: .seconds(6))
                try? await client.set(.wakeUpSource, wake.value)
                defaults.removeObject(forKey: Self.pendingWakeRestoreKey)
            }
        }
    }

    /// If the app quit during `turnOff`'s window, put the wake source back.
    private func restorePendingWakeSource() {
        guard let raw = defaults.string(forKey: Self.pendingWakeRestoreKey), let wake = WakeUpSource(rawValue: raw),
              let client else { return }
        Task {
            try? await client.set(.wakeUpSource, wake.value)
            defaults.removeObject(forKey: Self.pendingWakeRestoreKey)
        }
    }

    /// Reads the speaker's auto-standby mode live (used by Keep Awake).
    public func liveStandbyMode() async -> StandbyMode? {
        (try? await client?.get(.standbyMode).string).flatMap(StandbyMode.init)
    }

    /// Wakes the speaker into `source` only if it's currently in standby. Used by Smooth Start.
    public func wakeIfNeeded(into s: PhysicalSource = .usb) async {
        guard client != nil else { return }
        if let live = try? await client?.status() { status = live }
        guard status == .standby else { return }
        setSource(s)
        updateEventStream(force: true)
    }

    public func setDeskMode(_ on: Bool) { deskMode = on; write(.deskMode, .bool(on)) }
    public func setWallMode(_ on: Bool) { wallMode = on; write(.wallMode, .bool(on)) }
    public func setBassExtension(_ b: BassExtension) { bassExtension = b; write(.bassExtension, b.value) }
    public func setTreble(_ db: Double) { treble = (db * 4).rounded() / 4; write(.trebleAmount, .double(treble)) }
    public func setBalance(_ v: Int) { balance = v; write(.balance, .i32(v)) }
    public func setStandbyMode(_ m: StandbyMode) { standbyMode = m; write(.standbyMode, m.value) }
    public func setWakeUpSource(_ w: WakeUpSource) { wakeUpSource = w; write(.wakeUpSource, w.value) }
    public func setMaximumVolume(_ v: Int) { maximumVolume = v; write(.maximumVolume, .i32(v)) }

    public func setPassword(_ password: String) {
        SpeakerPassword.save(password, for: info?.kefId)
        if let host { client = KEFClient(host: host, password: password) }
    }

    // MARK: Private

    private func noteFailure(_ error: Error) {
        // A blocked local network surfaces either from Network.framework or, for HTTP, as
        // URLSession's "not connected to the internet".
        // A timeout while resolving is how a missing permission usually looks, so treat it the same.
        let kef = error as? KEFError
        localNetworkDenied = kef == .localNetworkDenied
            || { if case .timedOut = kef { true } else { false } }()
            || (error as? URLError)?.code == .notConnectedToInternet
        connection = .unreachable(error.localizedDescription)
        scheduleRetry()
    }

    /// Retry now (e.g. after the user grants the Local Network permission).
    public func retry() {
        checkLocalNetworkAccess()
        guard let info else { return }
        Task { await select(info) }
    }

    /// Asks macOS for Local Network access (shows the system prompt the first time). A denial
    /// can't be re-prompted, so the UI then points at System Settings.
    public func checkLocalNetworkAccess() {
        Task {
            let access = await KEFDiscovery.requestLocalNetworkAccess()
            log.info("local network access: \(String(describing: access), privacy: .public)")
            if access == .denied { localNetworkDenied = true }
            if access == .granted, localNetworkDenied {
                localNetworkDenied = false
                retry()
            }
        }
    }

    /// While unreachable, retry with backoff so the app recovers by itself once the network or
    /// permission comes back. Stops as soon as a connection succeeds.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            var delay: Double = 2
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, case .unreachable = self.connection, let info = self.info else { break }
                await self.select(info)
                delay = min(delay * 2, 30)
            }
            self?.retryTask = nil
        }
    }

    private func write(_ path: KEFPath, _ value: KEFValue) {
        Task { await perform { try await $0.set(path, value) } }
    }

    private func perform(_ action: @Sendable (KEFClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await action(client)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            try? await refresh()
        }
    }

    private func updateEventStream(force: Bool = false) {
        let wanted = client != nil && (popoverVisible || status == .powerOn || force)
        if wanted, eventTask == nil {
            startEvents()
        } else if !wanted, let t = eventTask {
            t.cancel()
            eventTask = nil
        }
    }

    private func startEvents() {
        guard let client else { return }
        let paths: [KEFPath] = [.physicalSource, .speakerStatus, .volume, .mute, .powerTarget]
        eventTask = Task { [weak self] in
            for await event in client.events(paths) {
                guard let self, let v = event.value else { continue }
                self.apply(event.path, v)
            }
        }
    }

    private func apply(_ path: KEFPath, _ v: KEFValue) {
        switch path {
        case .volume: volume = v.int ?? volume
        case .mute: muted = v.bool ?? muted
        case .physicalSource: source = v.string.flatMap(PhysicalSource.init) ?? source
        case .speakerStatus:
            status = v.string.flatMap(SpeakerStatus.init) ?? status
            if status == .standby, !popoverVisible {
                eventTask?.cancel()
                eventTask = nil
            }
        case .powerTarget: powerTarget = v.payload["target"]?.string ?? powerTarget
        default: break
        }
    }
}
