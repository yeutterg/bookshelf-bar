import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Signs `setData` requests the way the speaker's own `/jsapi/kef-api.js` does (fw 2.0+,
/// `settings:/webserver/authMode = setData`). Adapted from tkelkermans/KefSleepSync (0BSD).
///
/// - key = SHA256(salt + password); password is "" unless set on the speaker's web page
/// - value = base64(iv + AES-256-CBC-PKCS7(key, iv, json(typedValue)))
/// - Authorization: `HMAC_SHA256_AES256 b64("user").b64(salt).ts.b64(HMAC(key, "user.salt.ts.url.body"))`
public enum KEFSigner {
    public struct Seed: Sendable {
        public var salt: Data?
        public var iv: Data?
        public var timestampMilliseconds: String?
        public init(salt: Data? = nil, iv: Data? = nil, timestampMilliseconds: String? = nil) {
            self.salt = salt
            self.iv = iv
            self.timestampMilliseconds = timestampMilliseconds
        }
    }

    public enum Failure: Error {
        case randomBytes(OSStatus)
        case encryption(CCCryptorStatus)
    }

    static let username = "user"

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func signedWrite(url: URL, path: KEFPath, value: KEFValue, password: String,
                                   seed: Seed = Seed()) throws -> URLRequest {
        let salt = try seed.salt ?? randomBytes(6)
        let iv = try seed.iv ?? randomBytes(kCCBlockSizeAES128)
        let timestamp = seed.timestampMilliseconds ?? String(Int(Date().timeIntervalSince1970 * 1000))
        let key = deriveKey(salt: salt, password: password)

        let ciphertext = try encrypt(try encoder.encode(value), key: key, iv: iv)
        let body: [String: String] = ["path": path.rawValue, "role": "value", "value": (iv + ciphertext).base64EncodedString()]
        let bodyData = try encoder.encode(body)
        let bodyString = String(decoding: bodyData, as: UTF8.self)

        let saltB64 = salt.base64EncodedString()
        let message = "\(username).\(saltB64).\(timestamp).\(url.absoluteString).\(bodyString)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("HMAC_SHA256_AES256 \(Data(username.utf8).base64EncodedString()).\(saltB64).\(timestamp).\(Data(mac).base64EncodedString())",
                         forHTTPHeaderField: "Authorization")
        return request
    }

    public static func deriveKey(salt: Data, password: String) -> Data {
        Data(SHA256.hash(data: salt + Data(password.utf8)))
    }

    static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCEncrypt), plaintext, key: key, iv: iv)
    }

    /// Exposed for tests.
    public static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCDecrypt), ciphertext, key: key, iv: iv)
    }

    private static func crypt(_ op: CCOperation, _ input: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                inp.baseAddress, input.count, out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.encryption(status) }
        return output.prefix(moved)
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.randomBytes(status) }
        return data
    }
}
