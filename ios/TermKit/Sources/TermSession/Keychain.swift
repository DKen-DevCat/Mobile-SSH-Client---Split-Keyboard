import CryptoKit
import Foundation
import NIOSSH
import Security
import TermCore

/// キーチェーンの項目（この端末だけ。iCloud に同期しない。docs/design.md「セキュリティ要件」）
enum Keychain {
    static func read(service: String, account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func write(_ data: Data, service: String, account: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        // ロック中（画面を消している間）も再接続で鍵を使えるよう「最初のロック解除の後」。この端末だけ
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(service: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

public struct KeychainError: LocalizedError {
    public var status: OSStatus
    public var errorDescription: String? {
        "キーチェーンに書けませんでした（\(status)）"
    }
}

/// 接続に使う鍵。既定は Secure Enclave で作った P-256 の鍵（端末から取り出せない）
public enum SSHAuthKey {
    case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
    /// Secure Enclave の無い環境（シミュレータ）だけで使う
    case software(P256.Signing.PrivateKey)

    var nio: NIOSSHPrivateKey {
        switch self {
        case .secureEnclave(let k): return NIOSSHPrivateKey(secureEnclaveP256Key: k)
        case .software(let k): return NIOSSHPrivateKey(p256Key: k)
        }
    }

    /// `authorized_keys` に書く 1 行（`ecdsa-sha2-nistp256 AAAA... splitterm`）
    public var authorizedKeysLine: String {
        String(openSSHPublicKey: nio.publicKey) + " splitterm"
    }

    public var isHardwareBacked: Bool {
        if case .secureEnclave = self { return true }
        return false
    }
}

public enum DeviceKeyStore {
    static let service = "io.github.dken-devcat.splitterm.ssh-key"
    static let account = "default"

    /// 鍵を読む。無ければ作って保存する
    public static func loadOrCreate() throws -> SSHAuthKey {
        if let data = Keychain.read(service: service, account: account) {
            if SecureEnclave.isAvailable,
               let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
                return .secureEnclave(k)
            }
            if let k = try? P256.Signing.PrivateKey(rawRepresentation: data) {
                return .software(k)
            }
        }
        if SecureEnclave.isAvailable {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error)
            else { throw error!.takeRetainedValue() as Error }
            let k = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            // 保存するのは Secure Enclave の外では使えない包みだけ
            try Keychain.write(k.dataRepresentation, service: service, account: account)
            return .secureEnclave(k)
        }
        let k = P256.Signing.PrivateKey()
        try Keychain.write(k.rawRepresentation, service: service, account: account)
        return .software(k)
    }
}

/// 接続先のホスト鍵（初回に確かめて保存し、次からは照合する）
public enum HostKeyStore {
    static let service = "io.github.dken-devcat.splitterm.host-keys"

    public static func stored(for endpoint: String) -> String? {
        Keychain.read(service: service, account: endpoint).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func save(_ openSSHKey: String, for endpoint: String) throws {
        try Keychain.write(Data(openSSHKey.utf8), service: service, account: endpoint)
    }

    public static func forget(_ endpoint: String) {
        Keychain.delete(service: service, account: endpoint)
    }

    public static func verdict(for endpoint: String, presented: String) -> HostKeyVerdict {
        HostKeyVerdict.judge(stored: stored(for: endpoint), presented: presented)
    }
}
