// Author: Timur Isaev

import CryptoKit
import Foundation

public enum PayloadType: String, Codable, Sendable {
    case gameProfile = "application/vnd.alloy.game-profile+json;version=1"
    case runtimeManifest = "application/vnd.alloy.runtime-manifest+json;version=1"
    case releaseMetadata = "application/vnd.alloy.local-release-metadata+json;version=1"
}

/// There is deliberately no production trust mode or bundled trust root.
public enum VerificationMode: Sendable {
    case testOnly(keys: [String: Data])
    case development
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
