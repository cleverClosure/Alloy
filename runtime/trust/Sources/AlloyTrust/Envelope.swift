// Author: Timur Isaev

import CryptoKit
import Foundation

public enum TrustError: Error, Equatable, Sendable {
    case malformed(String)
    case wrongRole
    case belowThreshold
    case expired(String)
    case rollback(String)
    case freeze
    case mixAndMatch
    case revokedKey
    case revokedTarget
    case unauthorizedTarget
    case invalidRoot
    case state(String)
}

public struct TrustSignature: Codable, Sendable {
    public let keyId: String
    public let signature: String

    public init(keyId: String, signature: String) {
        self.keyId = keyId
        self.signature = signature
    }
}

/// Alloy envelope v1: DSSE PAE, with the field names required by doc 05 §5.
public struct SignedEnvelope: Codable, Sendable {
    public let payloadType: String
    public let payload: String
    public let signatures: [TrustSignature]

    public init(payloadType: String, payload: String, signatures: [TrustSignature]) {
        self.payloadType = payloadType
        self.payload = payload
        self.signatures = signatures
    }

    public static func keyID(_ publicKey: Data) -> String { TrustCanonicalJSON.digest(publicKey) }

    public static func preAuthenticationEncoding(type: String, payload: Data) -> Data {
        Data("DSSEv1 \(type.utf8.count) \(type) \(payload.count) ".utf8) + payload
    }

    public static func sign(
        _ payload: Data, type: String, keys: [Curve25519.Signing.PrivateKey]
    ) throws -> Self {
        let canonical = try TrustCanonicalJSON.encode(payload)
        guard canonical.count <= 1024 * 1024, !type.isEmpty, type.utf8.count <= 256,
              (1...32).contains(keys.count) else { throw TrustError.malformed("envelope bounds") }
        let message = preAuthenticationEncoding(type: type, payload: canonical)
        return try Self(payloadType: type, payload: canonical.base64EncodedString(), signatures: keys.map {
            TrustSignature(keyId: keyID($0.publicKey.rawRepresentation),
                           signature: try $0.signature(for: message).base64EncodedString())
        }.sorted { $0.keyId < $1.keyId })
    }

    public static func decode(_ data: Data) throws -> Self {
        let canonical = try TrustCanonicalJSON.encode(data)
        let envelope = try JSONDecoder().decode(Self.self, from: canonical)
        guard try TrustCanonicalJSON.encode(envelope) == canonical else {
            throw TrustError.malformed("unknown envelope fields")
        }
        return envelope
    }

    public func decodedPayload() throws -> Data {
        guard !payloadType.isEmpty, payloadType.utf8.count <= 256,
              (1...32).contains(signatures.count),
              let bytes = Data(base64Encoded: payload), bytes.count <= 1024 * 1024,
              bytes.base64EncodedString() == payload,
              try TrustCanonicalJSON.encode(bytes) == bytes else {
            throw TrustError.malformed("noncanonical or oversized envelope payload")
        }
        return bytes
    }

    /// Trust comes exclusively from this caller-supplied authorized key set.
    public func verify(type: String, keys: [String: Data], threshold: Int) throws -> Data {
        guard payloadType == type else { throw TrustError.wrongRole }
        guard (1...32).contains(threshold), threshold <= keys.count, keys.count <= 32,
              keys.allSatisfy({ $0.value.count == 32 && Self.keyID($0.value) == $0.key }) else {
            throw TrustError.invalidRoot
        }
        let bytes = try decodedPayload()
        let message = Self.preAuthenticationEncoding(type: type, payload: bytes)
        var accepted = Set<String>()
        for entry in signatures {
            guard let keyData = keys[entry.keyId], let signature = Data(base64Encoded: entry.signature),
                  signature.count == 64, signature.base64EncodedString() == entry.signature else { continue }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            if key.isValidSignature(signature, for: message) { accepted.insert(entry.keyId) }
        }
        guard accepted.count >= threshold else { throw TrustError.belowThreshold }
        return bytes
    }
}
