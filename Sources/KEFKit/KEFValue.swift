import Foundation

/// A typed speaker value. On the wire it's `{"type": T, T: payload}`, e.g.
/// `{"type":"i32_","i32_":30}` or `{"type":"kefPhysicalSource","kefPhysicalSource":"usb"}`.
public struct KEFValue: Sendable, Hashable, Codable {
    public var type: String
    public var payload: JSONValue

    public init(type: String, payload: JSONValue) {
        self.type = type
        self.payload = payload
    }

    public static func bool(_ v: Bool) -> KEFValue { .init(type: "bool_", payload: .bool(v)) }
    public static func i16(_ v: Int) -> KEFValue { .init(type: "i16_", payload: .int(v)) }
    public static func i32(_ v: Int) -> KEFValue { .init(type: "i32_", payload: .int(v)) }
    public static func double(_ v: Double) -> KEFValue { .init(type: "double_", payload: .double(v)) }
    public static func string(_ v: String) -> KEFValue { .init(type: "string_", payload: .string(v)) }
    public static func enumeration(_ type: String, _ v: String) -> KEFValue { .init(type: type, payload: .string(v)) }

    public var bool: Bool? { payload.bool }
    public var int: Int? { payload.int }
    public var double: Double? { payload.double }
    public var string: String? { payload.string }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        type = try c.decode(String.self, forKey: Key("type"))
        payload = try c.decodeIfPresent(JSONValue.self, forKey: Key(type)) ?? .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(type, forKey: Key("type"))
        try c.encode(payload, forKey: Key(type))
    }
}
