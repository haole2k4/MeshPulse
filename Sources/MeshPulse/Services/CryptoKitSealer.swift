#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Foundation
import MeshCore
import Security
import os

/// Production end-to-end encryption sealer backed by `Curve25519` ECDH + `HKDF-SHA256` + `ChaChaPoly`,
/// persisting the local 32-byte private key in the iOS Keychain (`AfterFirstUnlockThisDeviceOnly`).
public struct CryptoKitSealer: EnvelopeSealer, Sendable {
    private static let keychainService = "com.haole2k4.MeshPulse.e2ee"
    private static let hkdfSalt = Data("MeshPulse-HKDF-Salt-v1".utf8)
    private static let contextPrefix = Data("MeshPulse-E2EE-v1:".utf8)
    private static let contextArrow = Data("->".utf8)

    private let privateKeyRaw: Data
    private let publicKeyRaw: Data
    public let publicKeyBase64: String

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) {
        let privBytes = privateKey.rawRepresentation
        let pubBytes = privateKey.publicKey.rawRepresentation
        self.privateKeyRaw = privBytes
        self.publicKeyRaw = pubBytes
        self.publicKeyBase64 = pubBytes.base64EncodedString()
    }

    /// Loads the device's `Curve25519` private key from Keychain, or generates and stores a new one.
    /// Falls back cleanly to an ephemeral in-memory key if Keychain access is unavailable.
    public static func loadOrCreate(account: String = "local-node-curve25519") -> CryptoKitSealer {
        let logger = Logger(subsystem: "com.haole2k4.MeshPulse", category: "CryptoKitSealer")

        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &item)
        if readStatus == errSecSuccess,
           let rawData = item as? Data,
           let existingKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawData)
        {
            return CryptoKitSealer(privateKey: existingKey)
        }

        let freshKey = Curve25519.KeyAgreement.PrivateKey()
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: freshKey.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let saveStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        if saveStatus != errSecSuccess {
            logger.warning("Keychain SecItemAdd returned OSStatus \(saveStatus); using in-memory Curve25519 key.")
        }

        return CryptoKitSealer(privateKey: freshKey)
    }

    // MARK: - EnvelopeSealer

    public func seal(plaintext: Data, recipientPublicKeyBase64: String) throws -> Data {
        guard !recipientPublicKeyBase64.isEmpty else {
            throw MeshCryptoError.missingRecipientKey
        }
        guard let recipientRaw = Data(base64Encoded: recipientPublicKeyBase64) else {
            throw MeshCryptoError.invalidKeyMaterial
        }

        let remotePublicKey: Curve25519.KeyAgreement.PublicKey
        let localPrivateKey: Curve25519.KeyAgreement.PrivateKey
        do {
            remotePublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientRaw)
            localPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw)
        } catch {
            throw MeshCryptoError.invalidKeyMaterial
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        } catch {
            throw MeshCryptoError.invalidKeyMaterial
        }

        let directionalContext = Self.makeDirectionalContext(
            senderPublicKeyRaw: publicKeyRaw,
            recipientPublicKeyRaw: recipientRaw
        )
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.hkdfSalt,
            sharedInfo: directionalContext,
            outputByteCount: 32
        )

        do {
            let sealedBox = try ChaChaPoly.seal(
                plaintext,
                using: symmetricKey,
                authenticating: directionalContext
            )
            return sealedBox.combined
        } catch {
            throw MeshCryptoError.decryptionFailed
        }
    }

    public func open(ciphertext: Data, senderPublicKeyBase64: String) throws -> Data {
        guard !senderPublicKeyBase64.isEmpty else {
            throw MeshCryptoError.missingSenderKey
        }
        guard let senderRaw = Data(base64Encoded: senderPublicKeyBase64) else {
            throw MeshCryptoError.invalidKeyMaterial
        }

        let remotePublicKey: Curve25519.KeyAgreement.PublicKey
        let localPrivateKey: Curve25519.KeyAgreement.PrivateKey
        do {
            remotePublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderRaw)
            localPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw)
        } catch {
            throw MeshCryptoError.invalidKeyMaterial
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        } catch {
            throw MeshCryptoError.invalidKeyMaterial
        }

        let directionalContext = Self.makeDirectionalContext(
            senderPublicKeyRaw: senderRaw,
            recipientPublicKeyRaw: publicKeyRaw
        )
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.hkdfSalt,
            sharedInfo: directionalContext,
            outputByteCount: 32
        )

        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: ciphertext)
            return try ChaChaPoly.open(
                sealedBox,
                using: symmetricKey,
                authenticating: directionalContext
            )
        } catch {
            throw MeshCryptoError.authenticationFailed
        }
    }

    private static func makeDirectionalContext(
        senderPublicKeyRaw: Data,
        recipientPublicKeyRaw: Data
    ) -> Data {
        var context = Data()
        context.reserveCapacity(
            contextPrefix.count + senderPublicKeyRaw.count + contextArrow.count + recipientPublicKeyRaw.count
        )
        context.append(contextPrefix)
        context.append(senderPublicKeyRaw)
        context.append(contextArrow)
        context.append(recipientPublicKeyRaw)
        return context
    }
}
#endif
