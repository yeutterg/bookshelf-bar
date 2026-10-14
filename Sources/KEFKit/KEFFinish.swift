import Foundation

/// Cabinet finish decoded from the manufacturing token near the end of the serial number. The
/// Bonjour model/SKU is used as a second signal on LSX II, whose serial layout changed between
/// finish generations.
public struct KEFFinish: Sendable, Hashable, Codable {
    public let code: String
    public let name: String
    /// Asset name for the matching speaker artwork.
    public let artwork: String

    public static let unknown = KEFFinish(code: "", name: "Unknown", artwork: "speakers-neutral")

    struct Entry: Sendable {
        let serialTokens: [String]
        let skuSuffixes: [String]
        let name: String
        let artwork: String
    }

    static let table: [String: [Entry]] = [
        "LSX II LT": [
            Entry(serialTokens: ["M2"], skuSuffixes: ["M2AA"], name: "Graphite Grey", artwork: "speakers-graphite-grey"),
            Entry(serialTokens: ["A2"], skuSuffixes: ["A2AA"], name: "Stone White", artwork: "speakers-stone-white"),
            Entry(serialTokens: ["J2"], skuSuffixes: ["J2AA"], name: "Sage Green", artwork: "speakers-sage-green"),
        ],
        "LSX II": [
            Entry(serialTokens: ["R3", "B3"], skuSuffixes: ["BA", "BB", "BC"], name: "Carbon Black", artwork: "speakers-carbon-black"),
            Entry(serialTokens: ["A3"], skuSuffixes: ["AA"], name: "Mineral White", artwork: "speakers-mineral-white"),
            Entry(serialTokens: ["C3"], skuSuffixes: ["CA"], name: "Cobalt Blue", artwork: "speakers-cobalt-blue"),
            Entry(serialTokens: ["K3"], skuSuffixes: ["KA"], name: "Lava Red", artwork: "speakers-lava-red"),
            Entry(serialTokens: ["J3"], skuSuffixes: ["JA", "JB"], name: "Olive Green", artwork: "speakers-lsxii-green"),
            Entry(serialTokens: ["D3"], skuSuffixes: ["DA", "DB"], name: "Soundwave", artwork: "speakers-soundwave"),
            Entry(serialTokens: ["A5"], skuSuffixes: ["A5AA"], name: "Cotton White", artwork: "speakers-cotton-white"),
            Entry(serialTokens: ["L0"], skuSuffixes: ["L0AA"], name: "Amber Haze", artwork: "speakers-amber-haze"),
        ],
    ]

    public static func decode(serial: String, modelName: String, modelCode: String = "") -> KEFFinish {
        guard let entries = table[modelName] else { return .unknown }
        let serialTail = String(serial.uppercased().suffix(10))
        let sku = modelCode.uppercased()
        for entry in entries {
            if let token = entry.serialTokens.first(where: {
                guard let range = serialTail.range(of: $0, options: .backwards) else { return false }
                return serialTail.distance(from: range.upperBound, to: serialTail.endIndex) <= 5
            }) {
                return KEFFinish(code: token, name: entry.name, artwork: entry.artwork)
            }
        }
        // Some newer SKUs also end in an older two-character code (A5AA and L0AA both end in
        // AA). Prefer the most specific matching suffix instead of relying on table order.
        let skuMatch = entries.flatMap { entry in entry.skuSuffixes.map { (entry, $0) } }
            .filter { sku.hasSuffix($0.1) }
            .max { $0.1.count < $1.1.count }
        if let (entry, suffix) = skuMatch {
            return KEFFinish(code: suffix, name: entry.name, artwork: entry.artwork)
        }
        return .unknown
    }
}

public extension KEFSpeakerInfo {
    var finish: KEFFinish { KEFFinish.decode(serial: serialNumber, modelName: modelName, modelCode: model) }
}
