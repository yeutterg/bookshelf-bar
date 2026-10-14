import AppKit
import Foundation
import KEFKit
import Network
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

    /// Connected before, currently re-establishing (controls stay up; shown as "Reconnecting…").
    public private(set) var reconnecting = false

    public var lastError: String?
    /// macOS is blocking local network access (the app needs the Local Network permission).
    public private(set) var localNetworkDenied = false

    /// While the popover is visible the app always streams events; otherwise it stops once the
    /// speaker is in standby, so an idle Mac holds no connection at all.
    public var popoverVisible = false {
        didSet {
            updateEventStream()
            // Opening the popover after a quiet stretch: check the connection is still good.
            if popoverVisible, Date().timeIntervalSince(lastContact) > 15 { Task { await ensureConnected("popover") } }
        }
    }

    public var isOn: Bool { status == .powerOn }
    public var finish: KEFFinish { info?.finish ?? .unknown }

    private(set) var client: KEFClient?
    private var discoveryTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var volumeWrite: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var connectTask: Task<Bool, Never>?
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var lastContact = Date.distantPast
    private var lastInterfaces: [String] = []
    private var failingSince: Date?
    private var everConnected = false
    private static func hostKey(_ kefId: String) -> String { "host.\(kefId)" }
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
        // Connect straight away from the remembered address; don't wait for Bonjour.
        if !needsSetup { Task { await ensureConnected("launch") } }

        discoveryTask = Task { [weak self] in
            for await list in KEFDiscovery().speakers() {
                guard let self else { return }
                self.speakers = list
                // Only ever the speaker the user chose. Keep its TXT info fresh and use a
                // (re)appearance as a cue to reconnect if we're not healthy.
                if let saved = self.defaults.string(forKey: Self.savedSpeakerKey),
                   let match = list.first(where: { $0.kefId == saved }) {
                    self.info = match
                    if self.connection != .connected || self.reconnecting { await self.ensureConnected("discovered") }
                }
            }
        }
        startMonitoringNetwork()
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
        if let id = info?.kefId ?? defaults.string(forKey: Self.savedSpeakerKey) { defaults.removeObject(forKey: Self.hostKey(id)) }
        everConnected = false
        reconnecting = false
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
        await ensureConnected("selected")
    }

    /// Manual fallback when Bonjour is blocked (guest networks, VLANs).
    public func connect(host: String, remember: Bool = false) async {
        if remember {
            defaults.set(host, forKey: Self.savedHostKey)
            needsSetup = false
        }
        await ensureConnected("manual host")
    }

    // MARK: Connection management

    /// Makes sure we have a working connection, reconnecting if needed. Single-flight: concurrent
    /// callers share one attempt. Returns whether the speaker is reachable now.
    @discardableResult
    public func ensureConnected(_ reason: String) async -> Bool {
        if let running = connectTask { return await running.value }
        let task = Task { await self.attemptConnection(reason) }
        connectTask = task
        let ok = await task.value
        connectTask = nil
        return ok
    }

    private func attemptConnection(_ reason: String) async -> Bool {
        let kefId = info?.kefId ?? defaults.string(forKey: Self.savedSpeakerKey)
        let manual = defaults.string(forKey: Self.savedHostKey)
        if !everConnected, connection != .connected { connection = .connecting(info?.name ?? manual ?? "speakers") }
        log.info("connect (\(reason, privacy: .public)) cached=\(kefId.flatMap { self.defaults.string(forKey: Self.hostKey($0)) } ?? manual ?? "-", privacy: .public)")
        do {
            let found: String
            if let kefId {
                found = try await KEFLocator.locate(kefId: kefId,
                                                    cachedHost: defaults.string(forKey: Self.hostKey(kefId)) ?? manual,
                                                    bonjour: info)
            } else if let manual {
                _ = try await KEFClient(host: manual, timeout: 3).status()
                found = manual
            } else {
                return false
            }
            if found != host || client == nil {
                host = found
                client = KEFClient(host: found, password: SpeakerPassword.load(for: kefId) ?? "")
                eventTask?.cancel()
                eventTask = nil
            }
            try await refresh()
            markHealthy(found, kefId: kefId)
            return true
        } catch {
            markUnhealthy(error)
            return false
        }
    }

    private func markHealthy(_ host: String, kefId: String?) {
        if let kefId { defaults.set(host, forKey: Self.hostKey(kefId)) }
        let wasDown = connection != .connected || reconnecting
        connection = .connected
        reconnecting = false
        failingSince = nil
        lastContact = .now
        localNetworkDenied = false
        retryTask?.cancel()
        retryTask = nil
        if wasDown { log.info("connected to \(host, privacy: .public)") }
        if !everConnected { restorePendingWakeSource() }
        everConnected = true
        updateEventStream(force: true)
    }

    private func markUnhealthy(_ error: Error) {
        log.error("connection problem: \(error.localizedDescription, privacy: .public)")
        if (error as? KEFError) == .localNetworkDenied || (error as? URLError)?.code == .notConnectedToInternet {
            localNetworkDenied = true
        } else if let probeHost = host ?? info.flatMap({ defaults.string(forKey: Self.hostKey($0.kefId)) })
                    ?? defaults.string(forKey: Self.savedHostKey) {
            // Distinguish "permission off" from "speaker not answering" with a direct probe.
            Task {
                if await KEFDiscovery.probeLocalNetwork(host: probeHost) == .denied {
                    log.error("local network access denied for this app")
                    localNetworkDenied = true
                    connection = .unreachable("Local network access denied")
                }
            }
        }
        let since = failingSince ?? .now
        failingSince = since
        // Ride out short blips with the controls still up; only call it unreachable after a while.
        let grace: TimeInterval = everConnected ? 20 : 12
        if Date().timeIntervalSince(since) >= grace || localNetworkDenied {
            connection = .unreachable(error.localizedDescription)
            reconnecting = false
        } else if connection == .connected {
            reconnecting = true
        }
        scheduleRetry()
    }

    /// Network path changes (Wi‑Fi rejoin, interface switch) and Mac wake are the moments a
    /// connection most often goes stale; reconnect right away instead of waiting for a failure.
    private func startMonitoringNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = path.availableInterfaces.map(\.name)
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let changed = interfaces != self.lastInterfaces
                self.lastInterfaces = interfaces
                guard satisfied, changed, !self.needsSetup, self.everConnected else { return }
                await self.ensureConnected("network change")
            }
        }
        monitor.start(queue: DispatchQueue(label: "KEFBar.path"))
        pathMonitor = monitor
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5)) // let Wi‑Fi come back
                guard let self, !self.needsSetup else { return }
                await self.ensureConnected("mac wake")
            }
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
        if isOn { turnOff() } else {
            willChangePower?(true)
            setSource(.usb)
        }
    }

    /// Set by Smooth Start: called right before KEF Bar changes the speaker's power, so the USB
    /// volume can be parked low before the speaker drops off USB.
    public var willChangePower: ((_ on: Bool) -> Void)?

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
        willChangePower?(false)
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

    /// Wakes the speaker into `source` only if it's currently in standby. `notify: false` is
    /// for callers that already prepared (Smooth Start itself).
    public func wakeIfNeeded(into s: PhysicalSource = .usb, notify: Bool = true) async {
        guard client != nil else { return }
        if let live = try? await client?.status() { status = live }
        guard status == .standby else { return }
        if notify { willChangePower?(true) }
        source = s
        status = .powerOn
        await perform { try await $0.setSource(s) }
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

    public static let localNetworkSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    /// Retry now (e.g. after the user grants the Local Network permission).
    public func retry() {
        checkLocalNetworkAccess()
        Task { await ensureConnected("retry") }
    }

    /// Asks macOS for Local Network access (shows the system prompt the first time). A denial
    /// can't be re-prompted, so the UI then points at System Settings.
    public func checkLocalNetworkAccess() {
        Task {
            // Browsing triggers the system prompt on first run; a direct probe to the remembered
            // address is the definitive check once we have one.
            var access = await KEFDiscovery.requestLocalNetworkAccess()
            let known = info.flatMap { defaults.string(forKey: Self.hostKey($0.kefId)) }
                ?? defaults.string(forKey: Self.savedSpeakerKey).flatMap { defaults.string(forKey: Self.hostKey($0)) }
            if access != .denied, let known { access = await KEFDiscovery.probeLocalNetwork(host: known) }
            log.info("local network access: \(String(describing: access), privacy: .public)")
            if access == .denied {
                localNetworkDenied = true
                if !everConnected { connection = .unreachable("Local network access denied") }
            }
            if access == .granted, localNetworkDenied {
                localNetworkDenied = false
                retry()
            }
        }
    }

    /// While unhealthy, keep retrying with backoff (1 s up to 30 s) so the app recovers by
    /// itself. Stops as soon as a connection succeeds.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            var delay: Double = 1
            while !Task.isCancelled {
                // While blocked by the Local Network setting, check often so flipping the toggle
                // in System Settings reconnects within a few seconds.
                let wait = (self?.localNetworkDenied ?? false) ? 3 : delay
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                if self.connection == .connected, !self.reconnecting { break }
                if await self.ensureConnected("retry") { break }
                delay = min(delay * 2, 30)
            }
            self?.retryTask = nil
        }
    }

    private func write(_ path: KEFPath, _ value: KEFValue) {
        Task { await perform { try await $0.set(path, value) } }
    }

    /// Runs a command; on a connection failure, reconnects (possibly to a new address) and
    /// retries it once.
    private func perform(_ action: @Sendable (KEFClient) async throws -> Void) async {
        guard let client else { await ensureConnected("command without connection"); return }
        do {
            try await action(client)
            lastError = nil
            lastContact = .now
        } catch let error as KEFError where error == .unauthorized {
            lastError = error.localizedDescription
        } catch {
            guard await ensureConnected("command failed"), let fresh = self.client else {
                lastError = error.localizedDescription
                return
            }
            do {
                try await action(fresh)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
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
        // A failing long-poll is the earliest sign the connection went stale.
        let onFailure: @Sendable (Error) -> Void = { [weak self] _ in
            Task { @MainActor in await self?.ensureConnected("event stream") }
        }
        eventTask = Task { [weak self] in
            for await event in client.events(paths, onFailure: onFailure) {
                guard let self, let v = event.value else { continue }
                self.lastContact = .now
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
