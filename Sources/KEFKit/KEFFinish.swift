import Foundation

/// Cabinet finish, decoded from the code embedded near the end of the serial number
/// (e.g. `LSXLT…M2GR` → `M2` = Graphite Grey). Neither the API nor mDNS exposes the finish
/// directly. The table is data, so new codes can be added without touching callers.
public struct KEFFinish: Sendable, Hashable, Codable {
    public let code: String
    public let name: String
    /// Asset name for the matching speaker artwork.
    public let artwork: String

    public static let unknown = KEFFinish(code: "", name: "Unknown", artwork: "speakers-neutral")

    /// Known codes per model family. The LSX II supports more finishes; extend as they're confirmed.
    static let table: [String: [String: (String, String)]] = [
        "LSX II LT": [
            "M2": ("Graphite Grey", "speakers-graphite-grey"),
            "A2": ("Stone White", "speakers-stone-white"),
            "J2": ("Sage Green", "speakers-sage-green"),
        ],
    ]

    /// Serials end in `<finish code><variant><side>`, with side R (primary) or L (secondary).
    public static func decode(serial: String, modelName: String) -> KEFFinish {
        guard let codes = table[modelName], serial.count > 4 else { return .unknown }
        let body = serial.dropLast(2)
        for (code, (name, artwork)) in codes where body.hasSuffix(code) {
            return KEFFinish(code: code, name: name, artwork: artwork)
        }
        return .unknown
    }
}

public extension KEFSpeakerInfo {
    var finish: KEFFinish { KEFFinish.decode(serial: serialNumber, modelName: modelName) }
}
