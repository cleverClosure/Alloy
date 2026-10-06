// Author: Timur Isaev

import AlloyContentStore
import AlloyProfileCompiler
import AlloyRuntimeAPI
import AlloyTitleVolumes
import Foundation

struct StoredSyntheticPreview: Codable {
    let request: SyntheticResolveRequest
    let source: Data
    let sessionID: String
    let preview: LaunchPreview
    let plan: DriveMappingPlan
    let cache: CacheIdentity
}

final class SyntheticPreviewStore {
    let configuration: ServiceConfiguration
    let root: URL

    init(configuration: ServiceConfiguration) throws {
        self.configuration = configuration
        root = URL(fileURLWithPath: configuration.stateRoot).appendingPathComponent("wine-previews")
        try privateDirectory(root)
    }

    func resolve(_ request: SyntheticResolveRequest) throws -> LaunchPreview {
        guard configuration.fixtureMode == true, configuration.syntheticPayloadRoot != nil,
              !request.key.isEmpty, request.key.utf8.count <= 256, (1...120).contains(request.maximumSeconds),
              try FileManager.default.contentsOfDirectory(atPath: root.path).count < 128 else {
            throw RuntimeFailure.status(.notReady)
        }
        let sessionID = "wine-" + ContentStore.digest(Data(request.key.utf8)).dropFirst(7)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let host = try HostCapabilities.current()
        let canonical = try CanonicalJSON.encode(request.source)
        guard var object = try JSONSerialization.jsonObject(with: canonical) as? [String: Any],
              ["host", "volumes", "createdAt"].allSatisfy({ object[$0] == nil }),
              let game = object["gameID"] as? String else { throw RuntimeFailure.status(.malformed) }
        let store = try ContentStore(root: URL(fileURLWithPath: configuration.contentRoot))
        guard let generation = try store.referenceSnapshot(gameID: game).active,
              object["runtimeGenerationID"] as? String == generation.generationID else {
            throw RuntimeFailure.status(.conflict)
        }
        try store.validateReference(generation, gameID: game)
        let cache = CacheIdentity(runtimeIdentity: generation.manifestDigest,
                                  providers: ["runtime": generation.manifestDigest],
                                  compatibilityInputs: ["source": ContentStore.digest(canonical),
                                                        "host": try host.localClassId()])
        let plan = try volumes(game: game, session: sessionID, cache: cache, now: Int64(now.timeIntervalSince1970))
        object["host"] = try JSONSerialization.jsonObject(with: RuntimeEncoding.encode(host))
        object["volumes"] = plan.volumeIDs
        object["createdAt"] = ISO8601DateFormatter().string(from: now)
        let source = try CanonicalJSON.encode(JSONSerialization.data(withJSONObject: object))
        let compiled = try DevelopmentSessionCompiler.compile(source)
        guard compiled.specification.processes.contains(where: { $0.identity.path == request.entryPath }) else {
            throw RuntimeFailure.status(.malformed)
        }
        let identifier = "wine-preview-" + UUID().uuidString.lowercased()
        let preview = LaunchPreview(previewID: identifier, expiresAt: now.timeIntervalSince1970 + 120,
                                    specification: compiled.specification, canonicalExport: compiled.canonicalJSON,
                                    generation: generation)
        try PrivateRecords.write(StoredSyntheticPreview(request: request, source: source, sessionID: sessionID,
                                                        preview: preview, plan: plan, cache: cache),
                                 to: path(identifier))
        return preview
    }

    func verify(_ identifier: String) throws -> StoredSyntheticPreview {
        let stored = try PrivateRecords.read(StoredSyntheticPreview.self, from: path(identifier))
        guard stored.preview.previewID == identifier,
              stored.preview.expiresAt > Date().timeIntervalSince1970 else { throw RuntimeFailure.status(.expired) }
        let specification = try DevelopmentSessionCompiler.verifyExport(stored.preview.canonicalExport,
                                                                        input: stored.source)
        guard specification == stored.preview.specification, specification.runtimeReady,
              !specification.productionEligible else { throw RuntimeFailure.status(.notReady) }
        guard try specification.hostClassId == HostCapabilities.current().localClassId() else {
            throw RuntimeFailure.status(.conflict)
        }
        let store = try ContentStore(root: URL(fileURLWithPath: configuration.contentRoot))
        guard try store.referenceSnapshot(gameID: specification.gameId).active == stored.preview.generation else {
            throw RuntimeFailure.status(.conflict)
        }
        return stored
    }

    private func volumes(game: String, session: String, cache: CacheIdentity, now: Int64) throws -> DriveMappingPlan {
        let content = URL(fileURLWithPath: configuration.contentRoot)
        let store = try TitleVolumeStore(root: content)
        if FileManager.default.fileExists(atPath: content.appendingPathComponent("volumes/" + game).path) {
            _ = try store.adoptLegacySaves(gameID: game)
        } else { _ = try store.createTitle(gameID: game) }
        _ = try store.activateCache(gameID: game, identity: cache)
        _ = try store.createScratch(gameID: game, sessionID: session, now: now)
        return try store.drivePlan(SessionVolumeRequest(gameID: game, sessionID: session,
                                                        runtimeVolumeID: "runtime", payloadVolumeID: "payload"),
                                  expectedCacheIdentity: cache, now: now)
    }

    private func path(_ identifier: String) throws -> URL {
        guard identifier.hasPrefix("wine-preview-"), UUID(uuidString: String(identifier.dropFirst(13))) != nil else {
            throw RuntimeFailure.status(.malformed)
        }
        return root.appendingPathComponent(identifier + ".json")
    }
}
