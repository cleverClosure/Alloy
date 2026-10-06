// Author: Timur Isaev

import AlloyTrust
import CryptoKit
import Foundation

public enum PayloadType: String, Codable, Sendable {
    case gameProfile = "application/vnd.alloy.game-profile+json;version=1"
    case runtimeManifest = "application/vnd.alloy.runtime-manifest+json;version=1"
    case releaseMetadata = "application/vnd.alloy.local-release-metadata+json;version=1"
    case launchEvidence = "application/vnd.alloy.local-launch-evidence+json;version=1"
}

/// There is deliberately no production trust mode or bundled trust root.
public enum VerificationMode: Sendable {
    case testOnly(keys: [String: Data])
    case development
    case trustChain(store: TrustStore)
}

public struct VerifiedPayload: Sendable {
    public let bytes: Data
    public let digest: String
    public let type: PayloadType
    public let verification: String
    public let expiresAt: String
}

public struct EnvelopeClaims: Codable, Sendable {
    public let canonicalization: String
    public let payloadType: PayloadType
    public let payload: String
    public let expiresAt: String

    enum CodingKeys: String, CodingKey, CaseIterable { case canonicalization, payloadType, payload, expiresAt }

    public init(payload: Data, type: PayloadType, expiresAt: String) throws {
        canonicalization = CanonicalJSON.version
        payloadType = type
        self.payload = try CanonicalJSON.encode(payload).base64EncodedString()
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Set(CodingKeys.allCases))
        canonicalization = try container.decode(String.self, forKey: .canonicalization)
        payloadType = try container.decode(PayloadType.self, forKey: .payloadType)
        payload = try container.decode(String.self, forKey: .payload)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
    }
}

public struct TestEnvelope: Codable, Sendable {
    public let claims: EnvelopeClaims
    public let keyId: String?
    public let signature: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case claims, keyId, signature }

    public init(claims: EnvelopeClaims, keyId: String? = nil, signature: String? = nil) {
        self.claims = claims
        self.keyId = keyId
        self.signature = signature
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: [.claims])
        claims = try container.decode(EnvelopeClaims.self, forKey: .claims)
        keyId = try container.decodeIfPresent(String.self, forKey: .keyId)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
    }

    public static func verify(
        _ envelope: Data, type: PayloadType, mode: VerificationMode, now: Date
    ) throws -> VerifiedPayload {
        if case .trustChain(let store) = mode {
            return try verifiedTrustPayload(store.verify(envelope, type: type.rawValue, now: now), type: type)
        }
        let decoded = try JSONDecoder().decode(Self.self, from: CanonicalJSON.encode(envelope))
        let claims = decoded.claims
        guard claims.canonicalization == CanonicalJSON.version, claims.payloadType == type else {
            throw CompilerFailure.rejected("envelope type or canonicalization mismatch")
        }
        guard let expiry = parseTimestamp(claims.expiresAt), expiry > now else {
            throw CompilerFailure.rejected("expired or invalid envelope expiry")
        }
        guard let payload = Data(base64Encoded: claims.payload), try CanonicalJSON.encode(payload) == payload else {
            throw CompilerFailure.rejected("envelope payload is not canonical JSON")
        }
        let verification: String
        switch mode {
        case .testOnly(let keys):
            guard let keyId = decoded.keyId, let keyData = keys[keyId],
                  let signatureText = decoded.signature, let signature = Data(base64Encoded: signatureText) else {
                throw CompilerFailure.rejected("unsigned envelope or unknown test key")
            }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            guard try key.isValidSignature(signature, for: CanonicalJSON.encode(claims)) else {
                throw CompilerFailure.rejected("invalid test signature")
            }
            verification = "test-only"
        case .trustChain:
            throw CompilerFailure.rejected("trust verification requires the trust-chain path")
        case .development:
            guard decoded.keyId == nil && decoded.signature == nil else {
                throw CompilerFailure.rejected("signed envelopes require explicit test-key verification")
            }
            verification = "unsigned-development"
        }
        return VerifiedPayload(
            bytes: payload, digest: CanonicalJSON.digest(payload), type: type,
            verification: verification, expiresAt: claims.expiresAt
        )
    }
}

func parseTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}

func verifiedTrustPayload(_ trusted: TrustedPayload, type: PayloadType) throws -> VerifiedPayload {
    guard try CanonicalJSON.encode(trusted.bytes) == trusted.bytes else {
        throw CompilerFailure.rejected("trust and compiler canonicalization mismatch")
    }
    return VerifiedPayload(bytes: trusted.bytes, digest: CanonicalJSON.digest(trusted.bytes), type: type,
                           verification: "trust-chain-" + trusted.scope.rawValue, expiresAt: trusted.expiresAt)
}

func verifyCompilerEnvelope(
    _ bytes: Data, type: PayloadType, mode: VerificationMode, now: Date, verifier: TrustVerifier?
) throws -> VerifiedPayload {
    if let verifier { return try verifiedTrustPayload(verifier.verify(bytes, type: type.rawValue), type: type) }
    return try TestEnvelope.verify(bytes, type: type, mode: mode, now: now)
}
