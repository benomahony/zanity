import CryptoKit
import CryptoSwift
import Foundation
import Security

let apiKey = "sk-live-123"
let apiKeyName = "STRIPE_API_KEY"
let password = ProcessInfo.processInfo.environment["DB_PASSWORD"]

func encrypt(_ key: [UInt8], _ iv: [UInt8], _ plain: [UInt8]) throws -> [UInt8] {
    _ = try AES(key: key, blockMode: CBC(iv: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f]), padding: .pkcs7).encrypt(plain)
    return try AES(key: key, blockMode: CBC(iv: iv), padding: .pkcs7).encrypt(plain)
}

func seal(_ data: Data, _ key: SymmetricKey) throws -> AES.GCM.SealedBox {
    _ = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce(data: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
    return try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce())
}

func wrap(_ key: SecKey, _ data: CFData) -> CFData? {
    _ = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, data, nil)
    return SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA256, data, nil)
}

func derive(_ secret: [UInt8], _ salt: [UInt8]) throws -> [UInt8] {
    _ = try PKCS5.PBKDF2(password: secret, salt: [0x73, 0x61, 0x6c, 0x74], iterations: 4096, variant: .sha2(.sha256)).calculate()
    return try PKCS5.PBKDF2(password: secret, salt: salt, iterations: 4096, variant: .sha2(.sha256)).calculate()
}

func patterns(_ format: String) throws {
    _ = try NSRegularExpression(pattern: "(a+)+$")
    _ = try NSRegularExpression(pattern: "^[a-z]+$")
    NSLog(format)
    NSLog("%@", format)
}

func sealText(_ data: Data, _ key: SymmetricKey, _ seed: String) throws {
    _ = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce(data: Data("fixed-nonce!".utf8)))
    _ = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce(data: derive("label".utf8, seed)))
}
