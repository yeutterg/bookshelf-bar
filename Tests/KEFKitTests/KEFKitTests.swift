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

    @Test func unknownModelIsNeutral() {
        #expect(KEFFinish.decode(serial: "LSXII0000M2GR", modelName: "LS60") == .unknown)
    }
}

@Suite struct KEFPathTests {
    @Test func defaultVolumePaths() {
        #expect(KEFPath.defaultVolume(.usb).rawValue == "settings:/kef/host/defaultVolumeUSB")
        #expect(KEFPath.defaultVolume(nil).rawValue == "settings:/kef/host/defaultVolumeGlobal")
    }
}
