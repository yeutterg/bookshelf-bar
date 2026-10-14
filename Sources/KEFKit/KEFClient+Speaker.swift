import Foundation

/// Typed convenience API on top of the raw paths.
public extension KEFClient {
    func status() async throws -> SpeakerStatus {
        SpeakerStatus(rawValue: try await get(.speakerStatus).string ?? "") ?? .standby
    }

    func source() async throws -> PhysicalSource {
        PhysicalSource(rawValue: try await get(.physicalSource).string ?? "") ?? .standby
    }

    /// Switching to any input wakes the speaker; `.standby` turns it off.
    func setSource(_ source: PhysicalSource) async throws {
        try await set(.physicalSource, source.value)
    }

    func volume() async throws -> Int { try await get(.volume).int ?? 0 }

    func setVolume(_ volume: Int) async throws {
        try await set(.volume, .i32(min(max(volume, 0), 100)))
    }

    func isMuted() async throws -> Bool { try await get(.mute).bool ?? false }

    func setMuted(_ muted: Bool) async throws { try await set(.mute, .bool(muted)) }

    func deviceName() async throws -> String { try await get(.deviceName).string ?? host }

    /// `online` while the streamer is awake, `networkStandby` once it has gone to sleep
    /// (about 20 s after the speaker enters standby).
    func powerTarget() async throws -> String {
        try await get(.powerTarget).payload["target"]?.string ?? "unknown"
    }

    /// The speaker's own 0–100 → dB table.
    func volumeMap() async throws -> [Double] {
        guard case .array(let a) = try await get("settings:/mediaPlayer/volumeMap").payload else { return [] }
        return a.compactMap(\.double)
    }

    func control(_ action: String) async throws {
        // `player:player/control` uses the "activate" role with a plain object value.
        var r = URLRequest(url: try endpoint("api/setData"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object(["path": .string(KEFPath.playerControl.rawValue), "role": .string("activate"),
                                       "value": .object(["control": .string(action)])])
        r.httpBody = try JSONEncoder().encode(body)
        _ = try await send(r)
    }

    /// Runs an `activate`-role action, signed when the speaker requires it.
    func activate(_ path: KEFPath, _ value: JSONValue = .object([:])) async throws {
        let url = try endpoint("api/setData")
        let request: URLRequest
        if try await shouldSign() {
            request = try KEFSigner.signedActivate(url: url, path: path, value: value, password: password)
        } else {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: JSONValue = .object(["path": .string(path.rawValue), "role": .string("activate"), "value": value])
            r.httpBody = try JSONEncoder().encode(body)
            request = r
        }
        _ = try await send(request)
    }

    // MARK: Firmware

    /// `idle`, `checking`, `updateAvailable`, `downloading`, `downloaded`, `installing`, … plus
    /// the available version when the speaker knows of one.
    func firmwareStatus() async throws -> FirmwareStatus {
        FirmwareStatus(try await get("firmwareupdate:updateStatus").payload)
    }

    func checkForFirmwareUpdate() async throws { try await activate("firmwareupdate:checkForUpdate") }
    func downloadFirmwareUpdate() async throws { try await activate("firmwareupdate:downloadNewUpdate") }
    func installFirmwareUpdate() async throws { try await activate("firmwareupdate:installUpdate") }
}

public struct FirmwareStatus: Sendable, Equatable {
    public let state: String
    public let downloadProgress: Int
    public let availableVersion: String?
    public let forced: Bool

    init(_ payload: JSONValue) {
        state = payload["state"]?.string ?? "unknown"
        downloadProgress = payload["downloadProgress"]?.int ?? 0
        let image = payload["imageDescription"]
        availableVersion = image?["version"]?.string
        forced = image?["forcedUpdate"]?.bool ?? false
    }

    // State names as reported by W2-platform firmware (see EvotecIT/homeassistant-kef).
    public var isChecking: Bool { ["checkingForUpdate", "checkingForUpdates"].contains(state) }
    public var isAvailable: Bool { ["newUpdateAvailable", "updateAvailable"].contains(state) }
    public var isDownloading: Bool { ["downloading", "downloadInProgress", "downloadingUpdate"].contains(state) }
    public var isDownloaded: Bool { state == "downloaded" }
    public var isInstalling: Bool { ["installing", "updateInProgress"].contains(state) }
}

/// Per-component install progress (`kef:fwupgrade/info`): main MCU, the second speaker, USB.
public struct FirmwareInstallInfo: Sendable, Equatable {
    public let status: String
    public let error: String
    public let progress: [String: Int]

    init(_ payload: JSONValue) {
        status = payload["firmwareUpgradeStatus"]?.string ?? ""
        error = payload["firmwareUpgradeError"]?.string ?? ""
        if case .object(let p)? = payload["firmwareUpgradeProgress"] {
            progress = p.compactMapValues(\.int)
        } else {
            progress = [:]
        }
    }

    public var isFinished: Bool { status == "finish" }
    public var isClean: Bool { error.isEmpty || error == "noError" }
    /// Lowest component progress, a fair overall figure for display.
    public var overall: Int { progress.values.min() ?? 0 }
}

public extension KEFClient {
    func firmwareInstallInfo() async throws -> FirmwareInstallInfo {
        FirmwareInstallInfo(try await get("kef:fwupgrade/info").payload)
    }
}
