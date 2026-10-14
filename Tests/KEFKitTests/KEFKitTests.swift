import CryptoKit
import Foundation
import Testing
@testable import KEFKit

@Suite struct KEFValueTests {
    @Test func decodesTypedValues() throws {
        let json = #"[{"type":"i32_","i32_":89},{"type":"kefPhysicalSource","kefPhysicalSource":"usb"},{"bool_":false,"type":"bool_"},{"type":"double_","double_":-1.25}]"#
        let values = try JSONDecoder().decode([KEFValue].self, from: Data(json.utf8))
        #expect(values[0].int == 89)
        #expect(values[1].string == "usb")
        #expect(values[2].bool == false)
        #expect(values[3].double == -1.25)
    }

    @Test func decodesObjectPayload() throws {
        let json = #"{"powerTarget":{"target":"networkStandby"},"type":"powerTarget"}"#
        let v = try JSONDecoder().decode(KEFValue.self, from: Data(json.utf8))
        #expect(v.payload["target"]?.string == "networkStandby")
    }

    @Test func encodesTypedEnvelope() throws {
        let data = try KEFSigner.encoder.encode(PhysicalSource.usb.value)
        #expect(String(decoding: data, as: UTF8.self) == #"{"kefPhysicalSource":"usb","type":"kefPhysicalSource"}"#)
    }
}

@Suite struct KEFSignerTests {
    let url = URL(string: "http://speaker.local/api/setData")!
    let salt = Data([0x10, 0x11, 0x12, 0x13, 0x14, 0x15])
    let iv = Data((0..<16).map(UInt8.init))

    @Test func encryptsValueAndSignsBody() throws {
        let request = try KEFSigner.signedWrite(
            url: url, path: .standbyMode, value: StandbyMode.never.value, password: "",
            seed: .init(salt: salt, iv: iv, timestampMilliseconds: "1776598287367"))

        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(object["path"] == "settings:/kef/host/standbyMode")
        #expect(object["role"] == "value")

        // The value decrypts back to the typed envelope.
        let valueString = try #require(object["value"])
        let combined = try #require(Data(base64Encoded: valueString))
        #expect(combined.prefix(16) == iv)
        let key = KEFSigner.deriveKey(salt: salt, password: "")
        let plain = try KEFSigner.decrypt(combined.dropFirst(16), key: key, iv: iv)
        let decoded = try JSONDecoder().decode(KEFValue.self, from: plain)
        #expect(decoded == StandbyMode.never.value)

        // Header: HMAC_SHA256_AES256 b64(user).b64(salt).ts.signature, signature over user.salt.ts.url.body
        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let parts = auth.replacingOccurrences(of: "HMAC_SHA256_AES256 ", with: "").split(separator: ".").map(String.init)
        #expect(parts.count == 4)
        #expect(parts[0] == Data("user".utf8).base64EncodedString())
        #expect(parts[1] == salt.base64EncodedString())
        #expect(parts[2] == "1776598287367")
        let message = "user.\(parts[1]).\(parts[2]).\(url.absoluteString).\(String(decoding: body, as: UTF8.self))"
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
        #expect(parts[3] == expected.base64EncodedString())
    }

    @Test func bodyDoesNotEscapeSlashes() throws {
        let request = try KEFSigner.signedWrite(url: url, path: .deskMode, value: .bool(true), password: "")
        #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("settings:/kef/dsp/v2/deskMode"))
    }

    @Test func passwordChangesKey() {
        #expect(KEFSigner.deriveKey(salt: salt, password: "") != KEFSigner.deriveKey(salt: salt, password: "x"))
    }
}

@Suite struct KEFFinishTests {
    @Test(arguments: [
        ("LSXLT00000AS29M2GR", "Graphite Grey"),
        ("LSXLT00000AS29M2GL", "Graphite Grey"),
        ("LSXLT00000AS29A2GR", "Stone White"),
        ("LSXLT00000AS29J2GR", "Sage Green"),
        ("LSXLT00000AS29Z9GR", "Unknown"),
    ])
    func decodesLTSerials(serial: String, name: String) {
        #expect(KEFFinish.decode(serial: serial, modelName: "LSX II LT").name == name)
    }

    @Test(arguments: [
        ("LSX2G41102R32R1G", "", "Carbon Black"),
        ("", "SP4041AA", "Mineral White"),
        ("", "SP4041CA", "Cobalt Blue"),
        ("", "SP4041KA", "Lava Red"),
        ("", "SP4041JB", "Olive Green"),
        ("", "SP4041DA", "Soundwave"),
        ("", "SP4041A5AA", "Cotton White"),
        ("", "SP4041L0AA", "Amber Haze"),
    ])
    func decodesLSXIIFinishes(serial: String, modelCode: String, name: String) {
        #expect(KEFFinish.decode(serial: serial, modelName: "LSX II", modelCode: modelCode).name == name)
    }

    @Test func unknownModelIsNeutral() {
        #expect(KEFFinish.decode(serial: "LSXII0000M2GR", modelName: "LS60") == .unknown)
    }
}

@Suite struct KEFPathTests {
    @Test func defaultVolumePaths() {
        #expect(KEFPath.defaultVolume(.usb).rawValue == "settings:/kef/host/defaultVolumeUSB")
        #expect(KEFPath.defaultVolume(nil).rawValue == "settings:/kef/host/defaultVolumeGlobal")
    }

    @Test func modelSpecificInputs() {
        #expect(!PhysicalSource.inputs(forModel: "LSX II LT").contains(.analog))
        #expect(PhysicalSource.inputs(forModel: "LSX II").contains(.analog))
    }
}

@Suite struct KEFClientSafetyTests {
    @Test(arguments: ["", "speaker.local/path", "speaker.local?x=1", "user@speaker.local", "http://speaker.local"])
    func rejectsMalformedHosts(host: String) {
        #expect(KEFClient.normalizedHost(host) == nil)
    }

    @Test(arguments: [
        (" 192.168.1.20 ", "192.168.1.20"),
        ("speaker.local", "speaker.local"),
        ("[fe80::1]", "[fe80::1]"),
    ])
    func normalizesValidHosts(raw: String, expected: String) {
        #expect(KEFClient.normalizedHost(raw) == expected)
    }

    @Test func transientAuthReadIsNotCachedAsUnsigned() async throws {
        let state = RequestState()
        StubURLProtocol.handler = { request in
            let number = state.next()
            let path = request.url?.path ?? ""
            if number == 1 {
                return Self.response(request, status: 503, body: "temporarily unavailable")
            }
            if path.hasSuffix("/getData") {
                return Self.response(request, body: #"[{"type":"string_","string_":"password"}]"#)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("HMAC_SHA256_AES256 ") == true)
            return Self.response(request, body: "{}")
        }
        defer { StubURLProtocol.handler = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = KEFClient(host: "speaker.local", session: URLSession(configuration: config))

        await #expect(throws: KEFError.self) { try await client.set(.mute, .bool(false)) }
        try await client.set(.mute, .bool(false))
        #expect(state.count == 3)
    }

    private static func response(_ request: URLRequest, status: Int = 200, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
}

private final class RequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
