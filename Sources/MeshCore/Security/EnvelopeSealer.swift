import Foundation

public enum MeshCryptoError: Error, Sendable, Equatable {
    case missingRecipientKey
    case missingSenderKey
    case invalidKeyMaterial
    case authenticationFailed
    case decryptionFailed
}

/// Seam for End-to-End Encryption of 1-to-1 Direct Messages across untrusted relay nodes.
///
/// Satisfied by `SimulatedEnvelopeSealer` in Linux tests / Mock Mode and by `CryptoKitSealer`
/// (`Curve25519` + `HKDF-SHA256` + `ChaChaPoly`) on iOS hardware.
public protocol EnvelopeSealer: Sendable {
    var publicKeyBase64: String { get }
    func seal(plaintext: Data, recipientPublicKeyBase64: String) throws -> Data
    func open(ciphertext: Data, senderPublicKeyBase64: String) throws -> Data
}

/// Deterministic, dependency-free E2EE adapter for multi-node simulation on Linux and iOS Mock Mode.
///
/// Ciphertext wire layout: `[16-byte nonce][N-byte keystream-encrypted body][16-byte SHA-256 auth tag]`.
/// Both the keystream and authentication tag bind `(senderPublicKey, recipientPublicKey, nonce)`,
/// guaranteeing that any intermediate relay node (whose local public key differs from `recipientPublicKey`)
/// or any 1-byte tampering fails with `MeshCryptoError.authenticationFailed`.
public struct SimulatedEnvelopeSealer: EnvelopeSealer, Sendable, Equatable {
    private static let nonceLength = 16
    private static let tagLength = 16
    private static let keyLength = 32
    private static let domainTag = Array("MeshPulse-SimE2EE-v1".utf8)

    private let publicKeyData: Data
    public let publicKeyBase64: String

    public init(seed: String = UUID().uuidString) {
        let derived = Data(CoreSHA256.digest(Array(("MeshPulse-SimPubKey:" + seed).utf8)))
        self.publicKeyData = derived
        self.publicKeyBase64 = derived.base64EncodedString()
    }

    public func seal(plaintext: Data, recipientPublicKeyBase64: String) throws -> Data {
        guard !recipientPublicKeyBase64.isEmpty else {
            throw MeshCryptoError.missingRecipientKey
        }
        guard let recipientKeyData = Data(base64Encoded: recipientPublicKeyBase64),
              recipientKeyData.count == Self.keyLength
        else {
            throw MeshCryptoError.invalidKeyMaterial
        }

        let nonce = Self.randomNonce()
        let senderBytes = Array(publicKeyData)
        let recipientBytes = Array(recipientKeyData)
        let encryptedBody = Self.xorKeystream(
            input: Array(plaintext),
            senderKey: senderBytes,
            recipientKey: recipientBytes,
            nonce: nonce
        )
        let tag = Self.computeTag(
            senderKey: senderBytes,
            recipientKey: recipientBytes,
            nonce: nonce,
            ciphertextBody: encryptedBody
        )

        var envelope = Data()
        envelope.reserveCapacity(Self.nonceLength + encryptedBody.count + Self.tagLength)
        envelope.append(contentsOf: nonce)
        envelope.append(contentsOf: encryptedBody)
        envelope.append(contentsOf: tag)
        return envelope
    }

    public func open(ciphertext: Data, senderPublicKeyBase64: String) throws -> Data {
        guard !senderPublicKeyBase64.isEmpty else {
            throw MeshCryptoError.missingSenderKey
        }
        guard let senderKeyData = Data(base64Encoded: senderPublicKeyBase64),
              senderKeyData.count == Self.keyLength
        else {
            throw MeshCryptoError.invalidKeyMaterial
        }
        guard ciphertext.count >= Self.nonceLength + Self.tagLength else {
            throw MeshCryptoError.authenticationFailed
        }

        let raw = Array(ciphertext)
        let nonce = Array(raw[0..<Self.nonceLength])
        let bodyEnd = raw.count - Self.tagLength
        let encryptedBody = Array(raw[Self.nonceLength..<bodyEnd])
        let providedTag = Array(raw[bodyEnd..<raw.count])

        let senderBytes = Array(senderKeyData)
        let localRecipientBytes = Array(publicKeyData)
        let expectedTag = Self.computeTag(
            senderKey: senderBytes,
            recipientKey: localRecipientBytes,
            nonce: nonce,
            ciphertextBody: encryptedBody
        )

        var diff: UInt8 = 0
        for index in 0..<Self.tagLength {
            diff |= expectedTag[index] ^ providedTag[index]
        }
        guard diff == 0 else {
            throw MeshCryptoError.authenticationFailed
        }

        let plaintextBytes = Self.xorKeystream(
            input: encryptedBody,
            senderKey: senderBytes,
            recipientKey: localRecipientBytes,
            nonce: nonce
        )
        return Data(plaintextBytes)
    }

    private static func randomNonce() -> [UInt8] {
        let uuid = UUID().uuid
        return [
            uuid.0, uuid.1, uuid.2, uuid.3,
            uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11,
            uuid.12, uuid.13, uuid.14, uuid.15,
        ]
    }

    private static func xorKeystream(
        input: [UInt8],
        senderKey: [UInt8],
        recipientKey: [UInt8],
        nonce: [UInt8]
    ) -> [UInt8] {
        guard !input.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: input.count)
        var counter: UInt32 = 0
        var offset = 0

        while offset < input.count {
            var blockInput: [UInt8] = []
            blockInput.reserveCapacity(domainTag.count + 1 + senderKey.count + recipientKey.count + nonce.count + 4)
            blockInput.append(contentsOf: domainTag)
            blockInput.append(0x01) // stream separation byte
            blockInput.append(contentsOf: senderKey)
            blockInput.append(contentsOf: recipientKey)
            blockInput.append(contentsOf: nonce)
            blockInput.append(UInt8(truncatingIfNeeded: counter >> 24))
            blockInput.append(UInt8(truncatingIfNeeded: counter >> 16))
            blockInput.append(UInt8(truncatingIfNeeded: counter >> 8))
            blockInput.append(UInt8(truncatingIfNeeded: counter))

            let keystreamBlock = CoreSHA256.digest(blockInput)
            let chunkCount = min(keystreamBlock.count, input.count - offset)
            for idx in 0..<chunkCount {
                output[offset + idx] = input[offset + idx] ^ keystreamBlock[idx]
            }
            offset += chunkCount
            counter &+= 1
        }
        return output
    }

    private static func computeTag(
        senderKey: [UInt8],
        recipientKey: [UInt8],
        nonce: [UInt8],
        ciphertextBody: [UInt8]
    ) -> [UInt8] {
        var authMaterial: [UInt8] = []
        authMaterial.reserveCapacity(
            domainTag.count + 1 + senderKey.count + recipientKey.count + nonce.count + ciphertextBody.count
        )
        authMaterial.append(contentsOf: domainTag)
        authMaterial.append(0x02) // MAC separation byte
        authMaterial.append(contentsOf: senderKey)
        authMaterial.append(contentsOf: recipientKey)
        authMaterial.append(contentsOf: nonce)
        authMaterial.append(contentsOf: ciphertextBody)

        let fullDigest = CoreSHA256.digest(authMaterial)
        return Array(fullDigest.prefix(tagLength))
    }
}

enum CoreSHA256 {
    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    static func fingerprint64HexGrouped(_ data: Data) -> String {
        let hash = digest(Array(data))
        var chars: [Character] = []
        chars.reserveCapacity(19)
        for index in 0..<8 {
            if index > 0, index % 2 == 0 {
                chars.append("-")
            }
            let byte = hash[index]
            chars.append(hexDigits[Int(byte >> 4)])
            chars.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(chars)
    }

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    static func digest(_ bytes: [UInt8]) -> [UInt8] {
        var padded = bytes
        let bitLength = UInt64(padded.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19

        var words = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let base = chunkStart + i * 4
                words[i] =
                    (UInt32(padded[base]) << 24)
                    | (UInt32(padded[base + 1]) << 16)
                    | (UInt32(padded[base + 2]) << 8)
                    | UInt32(padded[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(words[i - 15], by: 7) ^ rotateRight(words[i - 15], by: 18) ^ (words[i - 15] >> 3)
                let s1 = rotateRight(words[i - 2], by: 17) ^ rotateRight(words[i - 2], by: 19) ^ (words[i - 2] >> 10)
                words[i] = words[i - 16] &+ s0 &+ words[i - 7] &+ s1
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            var f = h5
            var g = h6
            var h = h7

            for i in 0..<64 {
                let bigS1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = h &+ bigS1 &+ ch &+ roundConstants[i] &+ words[i]
                let bigS0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = bigS0 &+ maj

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            h5 = h5 &+ f
            h6 = h6 &+ g
            h7 = h7 &+ h
        }

        let state = [h0, h1, h2, h3, h4, h5, h6, h7]
        var result: [UInt8] = []
        result.reserveCapacity(32)
        for word in state {
            result.append(UInt8(truncatingIfNeeded: word >> 24))
            result.append(UInt8(truncatingIfNeeded: word >> 16))
            result.append(UInt8(truncatingIfNeeded: word >> 8))
            result.append(UInt8(truncatingIfNeeded: word))
        }
        return result
    }
}
