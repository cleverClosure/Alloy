// Author: Timur Isaev

import Foundation

public struct ObservedFile: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
    public var size: Int?
    public var peTimestamp: Int?

    public init(path: String, sha256: String, size: Int? = nil, peTimestamp: Int? = nil) {
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.peTimestamp = peTimestamp
    }
}

public struct BuildIdentity: Codable, Equatable, Sendable {
    public var id: String
    public var version: String?
    public var manifestId: String?
    public var files: [ObservedFile]

    public init(id: String, version: String? = nil, manifestId: String? = nil, files: [ObservedFile] = []) {
        self.id = id
        self.version = version
        self.manifestId = manifestId
        self.files = files
    }

    public func normalized() throws -> Self {
        var copy = self
        var seen = Set<String>()
        copy.files = try files.map {
            var file = $0
            file.path = try windowsPath(file.path)
            guard seen.insert(file.path).inserted, isHexDigest(file.sha256),
                  file.size.map({ $0 >= 0 }) ?? true, file.peTimestamp.map({ $0 >= 0 }) ?? true else {
                throw CompilerFailure.rejected("ambiguous or invalid observed file")
            }
            return file
        }.sorted { $0.path < $1.path }
        guard !id.isEmpty else { throw CompilerFailure.rejected("empty build identity") }
        return copy
    }

    public func digest() throws -> String { try CanonicalJSON.digest(CanonicalJSON.encode(normalized())) }

    func matches(_ selector: BuildSelector) throws -> Bool {
        let actual = try normalized()
        guard selector.version?.isEmpty != true, selector.manifestId?.isEmpty != true,
              selector.version != nil || selector.manifestId != nil || !(selector.requiredFiles ?? []).isEmpty else {
            throw CompilerFailure.rejected("build selector has no discriminating identity")
        }
        if let version = selector.version, version != actual.version { return false }
        if let manifest = selector.manifestId, manifest != actual.manifestId { return false }
        var seen = Set<String>()
        for required in selector.requiredFiles ?? [] {
            let path = try windowsPath(required.path)
            guard seen.insert(path).inserted else { throw CompilerFailure.rejected("duplicate build file selector") }
            guard let file = actual.files.first(where: { $0.path == path }), file.sha256 == required.sha256,
                  required.size == nil || file.size == required.size,
                  required.peTimestamp == nil || file.peTimestamp == required.peTimestamp else { return false }
        }
        return true
    }
}

/// Local release metadata is independently signed and bound to canonical profile bytes.
/// Alias entries are digests of the complete normalized observed build, not labels or paths.
public struct CandidateMetadata: Codable, Equatable, Sendable {
    public var profileDigest: String
    public var releaseRing: ReleaseRing
    public var approvedCertification: CertificationLevel
    public var gameAliases: [String]
    public var launcherAliases: [String]
    public var deniedMacOSBuilds: [String]
    public var requiredFeatures: [String]
    public var eligibleClientIds: [String]?
    public var minimumClientVersion: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case profileDigest, releaseRing, approvedCertification, gameAliases, launcherAliases
        case deniedMacOSBuilds, requiredFeatures, eligibleClientIds, minimumClientVersion
    }

    public init(profileDigest: String, releaseRing: ReleaseRing, approvedCertification: CertificationLevel) {
        self.profileDigest = profileDigest
        self.releaseRing = releaseRing
        self.approvedCertification = approvedCertification
        gameAliases = []
        launcherAliases = []
        deniedMacOSBuilds = []
        requiredFeatures = []
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: [
            .profileDigest, .releaseRing, .approvedCertification, .gameAliases, .launcherAliases,
            .deniedMacOSBuilds, .requiredFeatures
        ])
        profileDigest = try container.decode(String.self, forKey: .profileDigest)
        releaseRing = try container.decode(ReleaseRing.self, forKey: .releaseRing)
        approvedCertification = try container.decode(CertificationLevel.self, forKey: .approvedCertification)
        gameAliases = try container.decode([String].self, forKey: .gameAliases)
        launcherAliases = try container.decode([String].self, forKey: .launcherAliases)
        deniedMacOSBuilds = try container.decode([String].self, forKey: .deniedMacOSBuilds)
        requiredFeatures = try container.decode([String].self, forKey: .requiredFeatures)
        eligibleClientIds = try container.decodeIfPresent([String].self, forKey: .eligibleClientIds)
        minimumClientVersion = try container.decodeIfPresent(String.self, forKey: .minimumClientVersion)
    }
}

public struct ProfileCandidate: Sendable {
    public let profile: GameProfileDocument
    public let manifest: RuntimeManifestDocument
    public let metadata: CandidateMetadata
    public let profilePayload: VerifiedPayload
    public let manifestPayload: VerifiedPayload
    public let metadataPayload: VerifiedPayload

    public init(profile: Data, manifest: Data, metadata: Data, mode: VerificationMode, now: Date) throws {
        profilePayload = try TestEnvelope.verify(profile, type: .gameProfile, mode: mode, now: now)
        manifestPayload = try TestEnvelope.verify(manifest, type: .runtimeManifest, mode: mode, now: now)
        metadataPayload = try TestEnvelope.verify(metadata, type: .releaseMetadata, mode: mode, now: now)
        self.profile = try GameProfileValidator.validate(profilePayload.bytes)
        self.manifest = try RuntimeManifestValidator.validate(manifestPayload.bytes)
        self.metadata = try JSONDecoder().decode(CandidateMetadata.self, from: metadataPayload.bytes)
        guard self.metadata.profileDigest == profilePayload.digest,
              self.metadata.approvedCertification == self.profile.certification.level else {
            throw CompilerFailure.rejected("release metadata does not approve this exact profile and certification")
        }
        guard self.profile.runtime.generation == self.manifest.generationId else {
            throw CompilerFailure.rejected("profile/manifest runtime generation mismatch")
        }
        if let expiry = self.profile.certification.expiresAt,
           parseTimestamp(expiry).map({ $0 <= now }) ?? true {
            throw CompilerFailure.rejected("expired certification")
        }
    }
}

public struct ClientEligibility: Sendable {
    public var id: String
    public var version: String
    public var allowedRings: Set<ReleaseRing>
    public var canaryClient: Bool

    public init(id: String, version: String, allowedRings: Set<ReleaseRing>, canaryClient: Bool = false) {
        self.id = id
        self.version = version
        self.allowedRings = allowedRings
        self.canaryClient = canaryClient
    }
}

public struct SelectionInput: Sendable {
    public var gameId: String
    public var storefront: StorefrontKind
    public var appId: String
    public var branch: String?
    public var gameBuild: BuildIdentity
    public var launcherBuild: BuildIdentity?
    public var host: HostCapabilities
    public var client: ClientEligibility
    public var previouslyMatchedDigests: Set<String>
    public var now: Date

    public init(
        gameId: String, storefront: StorefrontKind, appId: String, branch: String? = nil,
        gameBuild: BuildIdentity, launcherBuild: BuildIdentity? = nil, host: HostCapabilities,
        client: ClientEligibility, now: Date, previouslyMatchedDigests: Set<String> = []
    ) {
        self.gameId = gameId
        self.storefront = storefront
        self.appId = appId
        self.branch = branch
        self.gameBuild = gameBuild
        self.launcherBuild = launcherBuild
        self.host = host
        self.client = client
        self.previouslyMatchedDigests = previouslyMatchedDigests
        self.now = now
    }
}

func isHexDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

func windowsPath(_ input: String) throws -> String {
    guard !input.isEmpty, input.utf8.count <= 4096,
          !input.unicodeScalars.contains(where: { $0.value < 32 }) else {
        throw CompilerFailure.rejected("invalid Windows path")
    }
    let components = input.replacingOccurrences(of: "\\", with: "/").lowercased().split(separator: "/")
    guard !components.contains("..") else { throw CompilerFailure.rejected("path traversal is not an identity") }
    return components.filter { $0 != "." }.joined(separator: "/")
}
