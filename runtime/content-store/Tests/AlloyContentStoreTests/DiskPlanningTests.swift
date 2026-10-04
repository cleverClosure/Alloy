// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private func planningTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-content-store-planning-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func withPlanningStore(
    _ body: (URL, ContentStore) throws -> Void
) throws {
    let root = try planningTestRoot()
    defer {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            var information = stat()
            if lstat(url.path, &information) == 0,
               information.st_mode & S_IFMT != S_IFLNK {
                chmod(url.path, S_IRWXU)
            }
        }
        chmod(root.path, S_IRWXU)
        try? FileManager.default.removeItem(at: root)
    }
    try body(root, ContentStore(root: root))
}

private func planningLayer(_ value: String, version: String) -> LayerInput {
    let data = Data(value.utf8)
    return LayerInput(
        descriptor: LayerDescriptor(
            name: "planning-runtime",
            version: version,
            digest: ContentStore.digest(data),
            mediaType: "application/vnd.alloy.test-layer",
            size: data.count,
            role: .hostRuntime
        ),
        contents: data
    )
}

private func interruptPlanningActivation(
    _ store: ContentStore,
    generationID: String,
    input: LayerInput,
    healthOutcome: HealthOutcome = .pass,
    faultPoint: String
) throws {
    #expect(throws: ContentStoreError.injectedTermination(faultPoint)) {
        _ = try store.activate(
            gameID: "game",
            generationID: generationID,
            layers: [input],
            healthOutcome: healthOutcome,
            faultInjector: { point in
                if point == faultPoint {
                    throw ContentStoreError.injectedTermination(point)
                }
            }
        )
    }
}

private func seedProtectedInFlightOperations(_ store: ContentStore) throws {
    try interruptPlanningActivation(
        store,
        generationID: "generation-b",
        input: planningLayer("resumable-download", version: "interrupted"),
        faultPoint: "after-download"
    )
    try interruptPlanningActivation(
        store,
        generationID: "generation-c",
        input: planningLayer("published-before-reference", version: "published"),
        faultPoint: "after-publish-cas-action"
    )
    try interruptPlanningActivation(
        store,
        generationID: "generation-d",
        input: planningLayer("materialized-before-reference", version: "materialized"),
        healthOutcome: .fail,
        faultPoint: "after-materialize-action"
    )
}

@Test("disk preflight counts each missing digest once and present objects as zero")
func diskPreflightIsDedupAware() throws {
    try withPlanningStore { _, store in
        let first = planningLayer("shared-layer", version: "1")
        let second = planningLayer("another-layer", version: "2")
        let descriptors = [
            first.descriptor,
            first.descriptor,
            second.descriptor,
            second.descriptor
        ]

        let emptyStorePlan = try store.preflightDiskSpace(for: descriptors)
        #expect(emptyStorePlan.inputObjectCount == 4)
        #expect(emptyStorePlan.uniqueObjectCount == 2)
        #expect(emptyStorePlan.presentObjectCount == 0)
        #expect(emptyStorePlan.missingObjectCount == 2)
        #expect(emptyStorePlan.additionalBytesRequired == UInt64(
            first.contents.count + second.contents.count
        ))

        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [first]
        )
        let partiallyPresentPlan = try store.preflightDiskSpace(for: descriptors)
        #expect(partiallyPresentPlan.presentObjectCount == 1)
        #expect(partiallyPresentPlan.missingObjectCount == 1)
        #expect(partiallyPresentPlan.additionalBytesRequired == UInt64(second.contents.count))
        #expect(partiallyPresentPlan.publicationScratchBytes == UInt64(second.contents.count))
        #expect(partiallyPresentPlan.activationPeakBytesRequired == UInt64(second.contents.count * 2))

        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            layers: [first, second]
        )
        let reinstallPlan = try store.preflightDiskSpace(for: descriptors)
        #expect(reinstallPlan.presentObjectCount == 2)
        #expect(reinstallPlan.missingObjectCount == 0)
        #expect(reinstallPlan.additionalBytesRequired == 0)
        #expect(reinstallPlan.publicationScratchBytes == 0)
        #expect(reinstallPlan.activationPeakBytesRequired == 0)
    }
}

@Test("disk preflight refuses one byte short and accepts the exact requirement")
func diskPreflightRefusesInsufficientSpace() throws {
    try withPlanningStore { _, store in
        let input = planningLayer("requires-space", version: "1")
        let requiredBytes = UInt64(input.contents.count)

        #expect(throws: InsufficientDiskSpaceError(
            requiredBytes: requiredBytes,
            availableBytes: requiredBytes - 1
        )) {
            _ = try store.preflightDiskSpace(
                for: [input.descriptor, input.descriptor],
                availableBytes: requiredBytes - 1
            )
        }

        let accepted = try store.preflightDiskSpace(
            for: [input.descriptor, input.descriptor],
            availableBytes: requiredBytes
        )
        #expect(accepted.additionalBytesRequired == requiredBytes)
        #expect(accepted.uniqueObjectCount == 1)
    }
}

@Test("activation refuses insufficient capacity before creating its journal")
func activationRefusesBeforeStarting() throws {
    try withPlanningStore { _, store in
        let input = planningLayer("activation-space", version: "1")
        let requiredBytes = UInt64(input.contents.count * 2)

        #expect(throws: InsufficientDiskSpaceError(
            requiredBytes: requiredBytes,
            availableBytes: requiredBytes - 1
        )) {
            _ = try store.activate(
                gameID: "game",
                generationID: "generation-a",
                layers: [input],
                availableBytes: requiredBytes - 1
            )
        }
        #expect(try store.inspect(gameID: "game").incompleteOperationCount == 0)
        #expect(try store.inspect(gameID: "game").active == nil)

        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [input],
            availableBytes: requiredBytes
        )
        #expect(try store.inspect(gameID: "game").active?.generationID == "generation-a")
    }
}

@Test("activation stages one payload for duplicate missing digests at exact capacity")
func activationDeduplicatesMissingDownloads() throws {
    try withPlanningStore { _, store in
        let input = planningLayer("one-staged-payload", version: "1")
        let requiredBytes = UInt64(input.contents.count * 2)

        #expect(throws: ContentStoreError.injectedTermination("after-download-action")) {
            _ = try store.activate(
                gameID: "game",
                generationID: "generation-a",
                layers: [input, input],
                availableBytes: requiredBytes,
                faultInjector: { point in
                    if point == "after-download-action" {
                        throw ContentStoreError.injectedTermination(point)
                    }
                }
            )
        }

        let operationDirectory = try #require(
            FileManager.default.contentsOfDirectory(
                at: store.downloadsDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        let stagedFiles = try FileManager.default.contentsOfDirectory(
            at: operationDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(stagedFiles.count == 1)
        #expect(try Data(contentsOf: stagedFiles[0]) == input.contents)

        try store.recoverAll()
        #expect(try store.inspect(gameID: "game").active?.generationID == "generation-a")
        #expect(try store.inspect(gameID: "game").objectCount == 1)
    }
}

@Test("zero-byte reinstall creates no download payload and recovers")
func activationReusesPresentObjectsWithoutStaging() throws {
    try withPlanningStore { _, store in
        let input = planningLayer("already-present", version: "1")
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [input]
        )
        #expect(
            try store.preflightDiskSpace(for: [input.descriptor, input.descriptor])
                .additionalBytesRequired == 0
        )

        #expect(throws: ContentStoreError.injectedTermination("after-download-action")) {
            _ = try store.activate(
                gameID: "game",
                generationID: "generation-b",
                layers: [input, input],
                availableBytes: 0,
                faultInjector: { point in
                    if point == "after-download-action" {
                        throw ContentStoreError.injectedTermination(point)
                    }
                }
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(
            at: store.downloadsDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)

        try store.recoverAll()
        #expect(try store.inspect(gameID: "game").active?.generationID == "generation-b")
        #expect(try store.inspect(gameID: "game").objectCount == 1)
    }
}

@Test("GC reclaim estimate reports every sweep category and protects operation downloads")
func reclaimEstimateReportsSweepTargets() throws {
    try withPlanningStore { _, store in
        let reachable = planningLayer("reachable", version: "1")
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [reachable]
        )

        let orphan = planningLayer("orphan-object", version: "orphan")
        let orphanURL = try store.objectURL(orphan.descriptor.digest)
        try store.createDirectory(orphanURL.deletingLastPathComponent())
        try orphan.contents.write(to: orphanURL)

        let abandoned = Data("abandoned-download".utf8)
        let abandonedDirectory = store.downloadsDirectory
            .appendingPathComponent("abandoned-operation", isDirectory: true)
        try store.createDirectory(abandonedDirectory)
        try abandoned.write(to: abandonedDirectory.appendingPathComponent("layer.part"))

        let quarantined = Data("quarantine-leftover".utf8)
        try quarantined.write(
            to: store.quarantineDirectory.appendingPathComponent("orphan.quarantine")
        )

        try seedProtectedInFlightOperations(store)

        let estimate = try store.estimateGarbageCollectionReclaim()
        #expect(!estimate.isExact)
        #expect(estimate.deferredOperationCount == 3)
        #expect(estimate.generationBytes == 0)
        #expect(estimate.generationCount == 0)
        #expect(estimate.casObjectBytes == UInt64(orphan.contents.count))
        #expect(estimate.abandonedDownloadBytes == UInt64(abandoned.count))
        #expect(estimate.quarantineBytes == UInt64(quarantined.count))
        #expect(estimate.totalBytes == UInt64(
            orphan.contents.count + abandoned.count + quarantined.count
        ))
        #expect(estimate.casObjectCount == 1)
        #expect(estimate.abandonedDownloadFileCount == 1)
        #expect(estimate.quarantineFileCount == 1)

        let leaseHookEstimate = try store.estimateGarbageCollectionReclaim(
            additionalReachableDigests: [orphan.descriptor.digest]
        )
        #expect(leaseHookEstimate.casObjectBytes == 0)
        #expect(leaseHookEstimate.totalBytes == UInt64(abandoned.count + quarantined.count))

        try store.recoverAll()
        let exactEstimate = try store.estimateGarbageCollectionReclaim()
        #expect(exactEstimate.isExact)
        #expect(exactEstimate.deferredOperationCount == 0)
        #expect(exactEstimate.totalBytes > estimate.totalBytes)
        #expect(try store.collectGarbage().bytesReclaimed == exactEstimate.totalBytes)
        #expect(try store.estimateGarbageCollectionReclaim().totalBytes == 0)
    }
}

@Test("reclaim estimate and collection both reject an unreadable journal")
func reclaimEstimateRejectsUnreadableJournal() throws {
    try withPlanningStore { _, store in
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [planningLayer("reachable", version: "1")]
        )
        let journalURL = try #require(
            FileManager.default.contentsOfDirectory(
                at: store.journalsDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        let operationID = journalURL.deletingPathExtension().lastPathComponent
        try store.writeAtomic(Data("{".utf8), to: journalURL)

        #expect(throws: ContentStoreError.invalidJournal(operationID)) {
            _ = try store.estimateGarbageCollectionReclaim()
        }
        #expect(throws: ContentStoreError.invalidJournal(operationID)) {
            _ = try store.collectGarbage()
        }
    }
}

@Test("GC reclaim estimate keeps a live lease root and exposes it after release")
func reclaimEstimateIncludesLiveLeaseRoots() throws {
    try withPlanningStore { _, store in
        let leasedInput = planningLayer("leased-generation", version: "leased")
        let leasedGeneration = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [leasedInput]
        )
        let lease = try store.acquireLease(
            gameID: "game",
            generation: leasedGeneration
        )
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            layers: [planningLayer("rollback-generation", version: "rollback")]
        )
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-c",
            layers: [planningLayer("active-generation", version: "active")]
        )

        let protectedEstimate = try store.estimateGarbageCollectionReclaim()
        #expect(protectedEstimate.isExact)
        #expect(protectedEstimate.generationBytes == 0)
        #expect(protectedEstimate.generationCount == 0)
        #expect(protectedEstimate.casObjectBytes == 0)
        #expect(protectedEstimate.casObjectCount == 0)

        try store.releaseLease(lease)
        let releasedEstimate = try store.estimateGarbageCollectionReclaim()
        #expect(releasedEstimate.generationBytes > 0)
        #expect(releasedEstimate.generationCount == 1)
        #expect(releasedEstimate.casObjectBytes == UInt64(leasedInput.contents.count))
        #expect(releasedEstimate.casObjectCount == 1)
    }
}
