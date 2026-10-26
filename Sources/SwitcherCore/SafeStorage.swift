import CommonCrypto
public import Foundation
import Security
import Synchronization

/// Claude encrypts its sign-in with Chromium's macOS scheme: a password in the
/// login keychain ("Claude Safe Storage"), stretched with PBKDF2-SHA1, and
/// values prefixed "v10" encrypted with AES-128-CBC. macOS asks once whether
/// this app may read that keychain item.
public final class SafeStorage: Sendable {
    public static let shared = SafeStorage()

    private let key = Mutex<Data?>(nil)

    public init() {}

    public func decrypt(_ value: Data) throws(SafeStorageError) -> Data {
        guard value.count > 3 + kCCBlockSizeAES128, value.prefix(3) == Data("v10".utf8) else {
            throw .unexpectedFormat
        }
        return try Self.aesCBC(kCCDecrypt, value.dropFirst(3), key: appKey())
    }

    /// The inverse of `decrypt`: a "v10" value Claude reads back.
    public func encrypt(_ plain: Data) throws(SafeStorageError) -> Data {
        try Data("v10".utf8) + Self.aesCBC(kCCEncrypt, plain, key: appKey())
    }

    private func appKey() throws(SafeStorageError) -> Data {
        if let cached = key.withLock({ $0 }) { return cached }
        let derived = try Self.derive(password: Self.readPassword())
        key.withLock { $0 = derived }
        return derived
    }

    static func readPassword() throws(SafeStorageError) -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Safe Storage",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw .keychain(status)
        }
        return data
    }

    static func derive(password: Data) throws(SafeStorageError) -> Data {
        let salt = Array("saltysalt".utf8)
        var out = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = password.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: CChar.self), pw.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &out, out.count)
        }
        guard status == kCCSuccess else { throw .crypto(status) }
        return Data(out)
    }

    static func aesCBC(_ operation: Int, _ ciphertext: Data, key: Data) throws(SafeStorageError) -> Data {
        let iv = [UInt8](repeating: UInt8(ascii: " "), count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = ciphertext.withUnsafeBytes { ct in
            key.withUnsafeBytes { k in
                CCCrypt(
                    CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, k.count, iv, ct.baseAddress, ct.count, &out, out.count, &moved)
            }
        }
        guard status == kCCSuccess else { throw .crypto(status) }
        return Data(out.prefix(moved))
    }
}

public enum SafeStorageError: LocalizedError {
    case keychain(OSStatus)
    case crypto(Int32)
    case unexpectedFormat

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            if status == errSecUserCanceled || status == errSecAuthFailed {
                String(localized: "Access to \u{201C}Claude Safe Storage\u{201D} in the keychain was denied.")
            } else {
                String(localized: "Could not read \u{201C}Claude Safe Storage\u{201D} from the keychain (\(status)).")
            }
        case .crypto: String(localized: "Could not decrypt Claude\u{2019}s sign-in.")
        case .unexpectedFormat: String(localized: "Claude stores its sign-in in a format this app does not know.")
        }
    }
}
