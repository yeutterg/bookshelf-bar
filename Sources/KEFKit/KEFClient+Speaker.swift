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
        var r = URLRequest(url: base.appending(path: "api/setData"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object(["path": .string(KEFPath.playerControl.rawValue), "role": .string("activate"),
                                       "value": .object(["control": .string(action)])])
        r.httpBody = try JSONEncoder().encode(body)
        _ = try await send(r)
    }
}
