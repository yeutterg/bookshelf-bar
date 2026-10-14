import AppKit
import Foundation
import KEFKit
import Network
import Observation
import os

let log = Logger(subsystem: "com.github.yeutterg.bookshelfbar", category: "speaker")

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
    public var restorationIdentity: String? {
        info?.kefId ?? defaults.string(forKey: Self.savedSpeakerKey) ?? host
    }

    private(set) var client: KEFClient?
    private var discoveryTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var volumeWrite: Task<Void, Never>?
    private var localVolumeUntil = Date.distantPast
    private var retryTask: Task<Void, Never>?
    private var connectTask: Task<Bool, Never>?
    private var connectTaskGeneration: Int?
    private var connectionGeneration = 0
    private var oneShotManualHost: String?
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
    private static let legacyPendingWakeRestoreKey = "pendingWakeRestore"
    private static func pendingWakeRestoreKey(_ identity: String) -> String { "pendingWakeRestore.\(identity)" }

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
        advanceConnectionGeneration()
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
        guard !isUpdatingFirmware else { return }
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
        advanceConnectionGeneration()
        info = speaker
        defaults.set(speaker.kefId, forKey: Self.savedSpeakerKey)
        await ensureConnected("selected")
    }

    /// Manual fallback when Bonjour is blocked (guest networks, VLANs).
    public func connect(host: String, remember: Bool = false) async {
        guard let normalized = KEFClient.normalizedHost(host) else {
            lastError = KEFError.invalidHost(host).localizedDescription
            connection = .unreachable(lastError ?? "Invalid speaker address")
            return
        }
        advanceConnectionGeneration()
        oneShotManualHost = normalized
        if remember {
            defaults.set(normalized, forKey: Self.savedHostKey)
            needsSetup = false
        }
        await ensureConnected("manual host")
    }

    // MARK: Connection management

    /// Makes sure we have a working connection, reconnecting if needed. Single-flight: concurrent
    /// callers share one attempt. Returns whether the speaker is reachable now.
    @discardableResult
    public func ensureConnected(_ reason: String) async -> Bool {
        let generation = connectionGeneration
        if let running = connectTask, connectTaskGeneration == generation { return await running.value }
        connectTask?.cancel()
        // Hard cap per attempt so one stuck attempt can never block every later reconnect.
        let task = Task {
            (try? await withDeadline(12, label: "connect") { await self.attemptConnection(reason, generation: generation) })
                ?? self.timedOutAttempt(generation: generation)
        }
        connectTask = task
        connectTaskGeneration = generation
        let ok = await task.value
        if connectionGeneration == generation {
            connectTask = nil
            connectTaskGeneration = nil
        }
        return ok
    }

    private func timedOutAttempt(generation: Int) -> Bool {
        guard connectionGeneration == generation else { return false }
        markUnhealthy(KEFError.timedOut("speaker"), generation: generation)
        return false
    }

    private func attemptConnection(_ reason: String, generation: Int) async -> Bool {
        guard connectionGeneration == generation else { return false }
        let kefId = info?.kefId ?? defaults.string(forKey: Self.savedSpeakerKey)
        let manual = oneShotManualHost ?? defaults.string(forKey: Self.savedHostKey)
        let bonjour = info?.kefId == kefId ? info : nil
        if oneShotManualHost == manual { oneShotManualHost = nil }
        if !everConnected, connection != .connected { connection = .connecting(info?.name ?? manual ?? "speakers") }
        log.info("connect (\(reason, privacy: .public)) candidate=\(manual ?? kefId.flatMap { self.defaults.string(forKey: Self.hostKey($0)) } ?? "-", privacy: .public)")
        do {
            let found: String
            if let kefId {
                found = try await KEFLocator.locate(kefId: kefId,
                                                    cachedHost: manual ?? defaults.string(forKey: Self.hostKey(kefId)),
                                                    bonjour: bonjour)
            } else if let manual {
                _ = try await withDeadline(4, label: manual) { try await KEFClient(host: manual, timeout: 3).status() }
                found = manual
            } else {
                return false
            }
            guard connectionGeneration == generation, !Task.isCancelled else { return false }
            let candidate = (found == host ? client : nil)
                ?? KEFClient(host: found, password: SpeakerPassword.load(for: kefId) ?? "")
            let live = try await withDeadline(5, label: "refresh") { try await Self.readLiveState(candidate) }
            guard connectionGeneration == generation, !Task.isCancelled else { return false }
            host = found
            if client !== candidate {
                client = candidate
                eventTask?.cancel()
                eventTask = nil
            }
            (status, source, volume, muted, powerTarget) = live
            markHealthy(found, kefId: kefId)
            return true
        } catch {
            guard connectionGeneration == generation, !Task.isCancelled else { return false }
            markUnhealthy(error, generation: generation)
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

    private func markUnhealthy(_ error: Error, generation: Int? = nil) {
        if let generation, generation != connectionGeneration { return }
        log.error("connection problem: \(error.localizedDescription, privacy: .public)")
        if (error as? KEFError) == .localNetworkDenied || (error as? URLError)?.code == .notConnectedToInternet {
            localNetworkDenied = true
        } else if let probeHost = host ?? info.flatMap({ defaults.string(forKey: Self.hostKey($0.kefId)) })
                    ?? defaults.string(forKey: Self.savedHostKey) {
            // Distinguish "permission off" from "speaker not answering" with a direct probe.
            let activeGeneration = connectionGeneration
            Task {
                if await KEFDiscovery.probeLocalNetwork(host: probeHost) == .denied,
                   self.connectionGeneration == activeGeneration {
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
        monitor.start(queue: DispatchQueue(label: "BookshelfBar.path"))
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
        let generation = connectionGeneration
        guard let c = client else { return }
        let live = try await Self.readLiveState(c)
        guard generation == connectionGeneration, client === c else { return }
        (status, source, volume, muted, powerTarget) = live
    }

    private static func readLiveState(_ client: KEFClient) async throws
        -> (SpeakerStatus, PhysicalSource, Int, Bool, String) {
        async let s = client.status()
        async let src = client.source()
        async let v = client.volume()
        async let m = client.isMuted()
        async let p = client.powerTarget()
        return try await (s, src, v, m, p)
    }

    public func refreshSettings() async {
        let generation = connectionGeneration
        guard let c = client else { return }
        async let desk = try? c.get(.deskMode).bool
        async let wall = try? c.get(.wallMode).bool
        async let bass = try? c.get(.bassExtension).string
        async let trebleValue = try? c.get(.trebleAmount).double
        async let balanceValue = try? c.get(.balance).int
        async let standby = try? c.get(.standbyMode).string
        async let wake = try? c.get(.wakeUpSource).string
        async let maximum = try? c.get(.maximumVolume).int
        async let profile = try? c.get(.profileName).string
        let values = await (desk, wall, bass, trebleValue, balanceValue, standby, wake, maximum, profile)
        guard generation == connectionGeneration, client === c else { return }
        deskMode = values.0 ?? deskMode
        wallMode = values.1 ?? wallMode
        bassExtension = values.2.flatMap(BassExtension.init) ?? bassExtension
        treble = values.3 ?? treble
        balance = values.4 ?? balance
        standbyMode = values.5.flatMap(StandbyMode.init) ?? standbyMode
        wakeUpSource = values.6.flatMap(WakeUpSource.init) ?? wakeUpSource
        maximumVolume = values.7 ?? maximumVolume
        profileName = values.8 ?? profileName
    }

    // MARK: Firmware update lockout

    /// A firmware update is in progress. While true, BookshelfBar sends the speaker no commands at
    /// all (only read-only status checks), and Smooth Start / Keep Awake stand down, so nothing
    /// we do can interrupt the update. Persisted, so a relaunch mid-update stays locked.
    public private(set) var isUpdatingFirmware = UserDefaults.standard.string(forKey: "firmwareLockFromVersion") != nil
    /// Firmware version when the lock began; the update counts as done only once it changes.
    public var firmwareLockFromVersion: String? { defaults.string(forKey: "firmwareLockFromVersion") }

    public func beginFirmwareLock(fromVersion: String) {
        log.info("firmware lock on (from \(fromVersion, privacy: .public))")
        defaults.set(fromVersion, forKey: "firmwareLockFromVersion")
        isUpdatingFirmware = true
        volumeWrite?.cancel()
    }

    public func endFirmwareLock() {
        log.info("firmware lock off")
        defaults.removeObject(forKey: "firmwareLockFromVersion")
        isUpdatingFirmware = false
    }

    /// Read-only client for the updater (status polling is allowed during the lock).
    public var statusClient: KEFClient? { client }

    // MARK: Actions

    public func setVolume(_ value: Int) {
        guard !isUpdatingFirmware else { return }
        volume = min(max(value, 0), 100)
        localVolumeUntil = .now + 1
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
        guard !isUpdatingFirmware else { return }
        muted.toggle()
        let m = muted
        Task { await perform { try await $0.setMuted(m) } }
    }

    public func setSource(_ s: PhysicalSource) {
        guard !isUpdatingFirmware else { return }
        if s == .standby { turnOff(); return }
        source = s
        status = .powerOn
        Task { await perform { try await $0.setSource(s) } }
    }

    public func togglePower() {
        guard !isUpdatingFirmware else { return }
        rewokenBy = nil
        if isOn { turnOff() } else {
            willChangePower?(true)
            setSource(.usb)
        }
    }

    /// Set by Smooth Start: called right before BookshelfBar changes the speaker's power, so the USB
    /// volume can be parked low before the speaker drops off USB.
    public var willChangePower: ((_ on: Bool) -> Void)?

    /// Set by Smooth Start: some app on this Mac has an audio stream open to the KEF.
    public var usbStreamActive = false

    /// Set by Smooth Start: names of the apps currently holding an audio stream open to the KEF.
    public var streamHolders: () -> [String] = { [] }

    /// The speaker woke straight back up after being turned off, because these apps hold an
    /// audio stream open to it. The UI offers "Turn Off Anyway".
    public private(set) var rewokenBy: [String]?

    /// Normal standby keeps the speaker in the macOS Sound menu, and playing audio wakes it.
    /// But with Wake On = USB Audio, the firmware wakes straight back up if an app holds an audio
    /// stream open to it at that moment (the iOS Simulator, a paused browser tab…).
    ///
    /// `force: true` makes standby stick anyway: switch the wake source off, enter standby, and
    /// restore it a few seconds later (restoring doesn't wake it). Measured side effect: the
    /// speaker also powers down its USB interface until its next wake, so it leaves the Sound
    /// menu and Mac audio can't wake it. Hence only on request, or from Keep Awake at screen-off.
    public func turnOff(force: Bool = false) {
        guard !isUpdatingFirmware else { return }
        rewokenBy = nil
        willChangePower?(false)
        status = .standby
        source = .standby
        guard let client else { return }
        let generation = connectionGeneration
        let streamHeld = force && usbStreamActive
        let identity = restorationIdentity ?? client.host
        let restoreKey = Self.pendingWakeRestoreKey(identity)
        Task {
            let wake = streamHeld ? ((try? await client.get(.wakeUpSource).string).flatMap(WakeUpSource.init) ?? .none) : .none
            if wake != .none {
                defaults.set(wake.rawValue, forKey: restoreKey)
                do { try await client.set(.wakeUpSource, WakeUpSource.none.value) }
                catch {
                    if generation == connectionGeneration { lastError = error.localizedDescription }
                    return
                }
            }
            do { try await client.setSource(.standby) }
            catch { if generation == connectionGeneration { lastError = error.localizedDescription } }
            if !force, generation == connectionGeneration, self.client === client, usbStreamActive {
                // The firmware re-wakes ~3 s later if a held stream is the cause; check once.
                try? await Task.sleep(for: .seconds(6))
                if generation == connectionGeneration, self.client === client,
                   (try? await client.status()) == .powerOn {
                    status = .powerOn
                    source = (try? await client.source()) ?? source
                    let names = streamHolders()
                    let holders = names.isEmpty ? ["another app"] : names
                    rewokenBy = holders
                    log.info("re-woken after standby by \(holders.joined(separator: ", "), privacy: .public)")
                }
            }
            if wake != .none {
                try? await Task.sleep(for: .seconds(6))
                do {
                    try await client.set(.wakeUpSource, wake.value)
                    defaults.removeObject(forKey: restoreKey)
                } catch {
                    if generation == connectionGeneration { lastError = error.localizedDescription }
                }
            }
        }
    }

    /// If the app quit during `turnOff`'s window, put the wake source back.
    private func restorePendingWakeSource() {
        guard !isUpdatingFirmware else { return }
        guard let identity = restorationIdentity, let client else { return }
        let key = Self.pendingWakeRestoreKey(identity)
        if defaults.string(forKey: key) == nil,
           let legacy = defaults.string(forKey: Self.legacyPendingWakeRestoreKey) {
            defaults.set(legacy, forKey: key)
            defaults.removeObject(forKey: Self.legacyPendingWakeRestoreKey)
        }
        guard let raw = defaults.string(forKey: key), let wake = WakeUpSource(rawValue: raw) else { return }
        Task {
            do {
                try await client.set(.wakeUpSource, wake.value)
                defaults.removeObject(forKey: key)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Reads the speaker's auto-standby mode live (used by Keep Awake).
    public func liveStandbyMode() async -> StandbyMode? {
        (try? await client?.get(.standbyMode).string).flatMap(StandbyMode.init)
    }

    /// Wakes the speaker into `source` only if it's currently in standby. `notify: false` is
    /// for callers that already prepared (Smooth Start itself).
    public func wakeIfNeeded(into s: PhysicalSource = .usb, notify: Bool = true) async {
        guard !isUpdatingFirmware else { return }
        let generation = connectionGeneration
        guard let client else { return }
        if let live = try? await client.status() {
            guard generation == connectionGeneration, self.client === client else { return }
            status = live
        }
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
    @discardableResult
    public func setStandbyModeAndWait(_ mode: StandbyMode) async -> Bool {
        let old = standbyMode
        standbyMode = mode
        let succeeded = await perform { try await $0.set(.standbyMode, mode.value) }
        if !succeeded { standbyMode = old }
        return succeeded
    }
    public func setWakeUpSource(_ w: WakeUpSource) { wakeUpSource = w; write(.wakeUpSource, w.value) }
    public func setMaximumVolume(_ v: Int) { maximumVolume = v; write(.maximumVolume, .i32(v)) }

    public func setPassword(_ password: String) {
        SpeakerPassword.save(password, for: info?.kefId)
        if let host {
            advanceConnectionGeneration()
            client = KEFClient(host: host, password: password)
            Task { await ensureConnected("password changed") }
        }
    }

    // MARK: Private

    /// Opens System Settings directly on Privacy & Security › Local Network (anchor found in the
    /// Settings extension's Info.plist; the older `Privacy_LocalNetwork` anchor only reaches the
    /// Privacy & Security root on current macOS).
    public static let localNetworkSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?privacy-localnetwork")!

    /// Retry now (e.g. after the user grants the Local Network permission).
    public func retry() {
        checkLocalNetworkAccess()
        Task { await ensureConnected("retry") }
    }

    /// Asks macOS for Local Network access (shows the system prompt the first time). A denial
    /// can't be re-prompted, so the UI then points at System Settings.
    public func checkLocalNetworkAccess() {
        let generation = connectionGeneration
        Task {
            // Browsing triggers the system prompt on first run; a direct probe to the remembered
            // address is the definitive check once we have one.
            var access = await KEFDiscovery.requestLocalNetworkAccess()
            let known = info.flatMap { defaults.string(forKey: Self.hostKey($0.kefId)) }
                ?? defaults.string(forKey: Self.savedSpeakerKey).flatMap { defaults.string(forKey: Self.hostKey($0)) }
            if access != .denied, let known { access = await KEFDiscovery.probeLocalNetwork(host: known) }
            guard generation == connectionGeneration else { return }
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
    @discardableResult
    private func perform(_ action: @Sendable (KEFClient) async throws -> Void) async -> Bool {
        // Hard stop during a firmware update: no command may reach the speaker.
        guard !isUpdatingFirmware else {
            log.info("command blocked: firmware update in progress")
            return false
        }
        let generation = connectionGeneration
        if client == nil { _ = await ensureConnected("command without connection") }
        guard generation == connectionGeneration, let client else { return false }
        do {
            try await action(client)
            guard generation == connectionGeneration else { return false }
            lastError = nil
            lastContact = .now
            return true
        } catch let error as KEFError where error == .unauthorized {
            lastError = error.localizedDescription
            return false
        } catch {
            guard generation == connectionGeneration,
                  await ensureConnected("command failed"),
                  generation == connectionGeneration,
                  let fresh = self.client else {
                lastError = error.localizedDescription
                return false
            }
            do {
                try await action(fresh)
                guard generation == connectionGeneration else { return false }
                lastError = nil
                lastContact = .now
                return true
            } catch {
                lastError = error.localizedDescription
                return false
            }
        }
    }

    private func advanceConnectionGeneration() {
        connectionGeneration += 1
        connectTask?.cancel()
        connectTask = nil
        connectTaskGeneration = nil
        eventTask?.cancel()
        eventTask = nil
        retryTask?.cancel()
        retryTask = nil
        volumeWrite?.cancel()
        volumeWrite = nil
        oneShotManualHost = nil
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
        let generation = connectionGeneration
        let paths: [KEFPath] = [.physicalSource, .speakerStatus, .volume, .mute, .powerTarget]
        // A failing long-poll is the earliest sign the connection went stale.
        let onFailure: @Sendable (Error) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }
                await self.ensureConnected("event stream")
            }
        }
        eventTask = Task { [weak self] in
            for await event in client.events(paths, onFailure: onFailure) {
                guard let self, self.connectionGeneration == generation, let v = event.value else { continue }
                self.lastContact = .now
                self.apply(event.path, v)
            }
        }
    }

    private func apply(_ path: KEFPath, _ v: KEFValue) {
        switch path {
        // Ignore echoes (often of older values) while the user is moving the slider.
        case .volume: if Date() > localVolumeUntil { volume = v.int ?? volume }
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
