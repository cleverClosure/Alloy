// Author: Timur Isaev
import AlloyContentStore
import AlloyProfileCompiler
import AlloyRuntimeAPI
import Foundation

private struct StoredPreview: Codable {
    let input: DevelopmentLaunchInput
    let compilationTime: TimeInterval
    let host: HostCapabilities
    let preview: LaunchPreview
}

/// Development resolution is explicit and never turns into a game execution authority.
public final class LaunchService: @unchecked Sendable {
    public static let methods = ["host.info", "launch.resolve", "launch.verify", "launch.game"]
    private let configuration: ServiceConfiguration
    private let root: URL
    private let resolutionLock = NSLock()

    public init(configuration: ServiceConfiguration) throws {
        self.configuration = configuration
        root = URL(fileURLWithPath: configuration.stateRoot).appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func handle(_ request: RuntimeRequest) throws -> Data {
        if request.method == "host.info" { return try RuntimeEncoding.encode(HostCapabilities.current()) }
        guard configuration.fixtureMode == true else { throw RuntimeFailure.status(.notReady) }
        do {
            switch request.method {
            case "launch.resolve":
                return try RuntimeEncoding.encode(resolve(JSONDecoder().decode(
                    DevelopmentLaunchInput.self, from: request.payload)))
            case "launch.verify":
                let identifier = try JSONDecoder().decode(IdentifierRequest.self, from: request.payload).identifier
                return try RuntimeEncoding.encode(verify(identifier))
            case "launch.game":
                let identifier = try JSONDecoder().decode(IdentifierRequest.self, from: request.payload).identifier
                _ = try verify(identifier)
                // This service has no Wine execution driver, even if a future compiler
                // changes its coverage flag. Test fixture execution is a separate API.
                throw RuntimeFailure.status(.notReady)
            default: throw RuntimeFailure.status(.malformed)
            }
        } catch is CompilerFailure { throw RuntimeFailure.status(.conflict) } catch is ValidationFailure {
            throw RuntimeFailure.status(.malformed)
        }
    }

    public func verify(_ identifier: String, now: Date = Date()) throws -> LaunchPreview {
        let stored = try PrivateRecords.read(StoredPreview.self, from: path(identifier))
        guard stored.preview.previewID == identifier, now.timeIntervalSince1970 < stored.preview.expiresAt,
              now.timeIntervalSince1970 >= stored.compilationTime else { throw RuntimeFailure.status(.expired) }
        guard try HostCapabilities.current() == stored.host else { throw RuntimeFailure.status(.conflict) }
        let input = try compilationInput(stored.input, host: stored.host,
                                         now: Date(timeIntervalSince1970: stored.compilationTime))
        let specification = try LaunchCompiler.verifyExport(stored.preview.canonicalExport, input: input)
        guard specification == stored.preview.specification,
              try generation(for: specification.gameId) == stored.preview.generation else {
            throw RuntimeFailure.status(.conflict)
        }
        return stored.preview
    }

    private func resolve(_ input: DevelopmentLaunchInput) throws -> LaunchPreview {
        resolutionLock.lock()
        defer { resolutionLock.unlock() }
        guard (1...120).contains(input.validForSeconds),
              try FileManager.default.contentsOfDirectory(atPath: root.path).count < 256 else {
            throw RuntimeFailure.status(.malformed)
        }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let host = try HostCapabilities.current()
        let compiled = try LaunchCompiler.compile(compilationInput(input, host: host, now: now))
        let reference = try generation(for: compiled.specification.gameId)
        guard reference.generationID == compiled.specification.runtimeGenerationId,
              !compiled.specification.runtimeReady, !compiled.specification.productionEligible else {
            throw RuntimeFailure.status(.notReady)
        }
        let identifier = "preview-" + UUID().uuidString.lowercased()
        let preview = LaunchPreview(previewID: identifier,
                                    expiresAt: now.timeIntervalSince1970 + Double(input.validForSeconds),
                                    specification: compiled.specification, canonicalExport: compiled.canonicalJSON,
                                    generation: reference)
        try PrivateRecords.write(StoredPreview(input: input, compilationTime: now.timeIntervalSince1970,
                                                host: host, preview: preview), to: path(identifier))
        return preview
    }

    private func compilationInput(_ input: DevelopmentLaunchInput, host: HostCapabilities,
                                  now: Date) throws -> LaunchCompilationInput {
        let profile = try GameProfileValidator.validate(input.profile)
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(input.validForSeconds)))
        func envelope(_ bytes: Data, _ type: PayloadType) throws -> Data {
            try CanonicalJSON.encode(TestEnvelope(
                claims: EnvelopeClaims(payload: bytes, type: type, expiresAt: expiry)))
        }
        let candidate = try CandidateEnvelopes(profile: envelope(input.profile, .gameProfile),
                                                manifest: envelope(input.manifest, .runtimeManifest),
                                                metadata: envelope(input.metadata, .releaseMetadata))
        guard let binding = profile.game.storefronts.first else { throw RuntimeFailure.status(.malformed) }
        let selection = SelectionInput(gameId: profile.game.canonicalId, storefront: binding.kind,
                                       appId: binding.appId, branch: binding.branch, gameBuild: input.build, host: host,
                                       client: ClientEligibility(id: "local-development", version: "1.0.0",
                                                                 allowedRings: [.development, .lab]), now: now)
        return try LaunchCompilationInput(candidates: [candidate], selection: selection,
                                           evidenceEnvelope: envelope(input.evidence, .launchEvidence),
                                           verificationMode: .development, processes: input.processes,
                                           volumes: input.volumes)
    }

    private func generation(for gameID: String) throws -> GenerationReference {
        let store = try ContentStore(root: URL(fileURLWithPath: configuration.contentRoot))
        guard let active = try store.referenceSnapshot(gameID: gameID).active else {
            throw RuntimeFailure.status(.notFound)
        }
        try store.validateReference(active, gameID: gameID)
        return active
    }

    private func path(_ identifier: String) throws -> URL {
        guard identifier.hasPrefix("preview-"), UUID(uuidString: String(identifier.dropFirst(8))) != nil else {
            throw RuntimeFailure.status(.malformed)
        }
        return root.appendingPathComponent(identifier + ".json")
    }
}
