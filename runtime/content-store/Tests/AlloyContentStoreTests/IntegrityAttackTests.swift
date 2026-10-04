// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

@Suite("adversarial generation, ingest and lease integrity")
struct IntegrityAttackTests {
    enum IngestAttack: String, CaseIterable, Sendable {
        case symlink
        case substitutedBytes
        case changedSize
    }

    @Test("post-verification ingest attacks cannot publish a CAS object", arguments: IngestAttack.allCases)
    func ingestSwap(attack: IngestAttack) throws {
        try withIntegrityStore { root, store in
            let input = integrityLayer("trusted payload", version: "1")
            let replacement = Data((attack == .changedSize ? "longer hostile payload" : "hostile payload").utf8)
            let operationID = "ingest-attack"
            let source = store.downloadsDirectory.appendingPathComponent(operationID)
                .appendingPathComponent("000-\(try store.rawSHA256(input.descriptor.digest)).part")
            let external = root.appendingPathComponent("external-sentinel")
            try replacement.write(to: external)
            let externalBefore = try FileManager.default.attributesOfItem(atPath: external.path)
            let expected: ContentStoreError = attack == .symlink
                ? .missingDownload(try store.objectURL(input.descriptor.digest).lastPathComponent)
                : attack == .changedSize
                    ? .sizeMismatch(expected: input.contents.count, actual: replacement.count)
                    : .digestMismatch(expected: input.descriptor.digest, actual: ContentStore.digest(replacement))
            #expect(throws: expected) {
                try store.activate(gameID: "game", generationID: "attack", layers: [input],
                                   operationID: operationID) { point in
                    guard point == "after-verify" else { return }
                    try FileManager.default.removeItem(at: source)
                    if attack == .symlink {
                        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: external)
                    } else {
                        try replacement.write(to: source)
                    }
                }
            }
            #expect(!store.pathEntryExists(try store.objectURL(input.descriptor.digest)))
            #expect(try store.inspect(gameID: "game").active == nil)
            #expect(try Data(contentsOf: external) == replacement)
            let externalAfter = try FileManager.default.attributesOfItem(atPath: external.path)
            #expect(externalBefore[.posixPermissions] as? Int == externalAfter[.posixPermissions] as? Int)
            // Repair the SAME journal's staged input, then recover twice.
            try FileManager.default.removeItem(at: source)
            try input.contents.write(to: source)
            try store.recoverAll()
            try store.recoverAll()
            let generation = try #require(store.inspect(gameID: "game").active)
            #expect(generation.generationID == "attack")
            try store.validateReference(generation, gameID: "game")
            #expect(try Data(contentsOf: store.objectURL(input.descriptor.digest)) == input.contents)
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.downloadsDirectory.path).isEmpty)
        }
    }

    @Test("a retained writable ingest descriptor cannot mutate published CAS")
    func writableIngestAlias() throws {
        try withIntegrityStore { _, store in
            let input = integrityLayer("trusted payload", version: "1")
            let replacement = Data("hostile payload".utf8)
            let source = store.downloadsDirectory.appendingPathComponent("alias-attack")
                .appendingPathComponent("000-\(try store.rawSHA256(input.descriptor.digest)).part")
            let writer = IngestWriter()
            let generation = try store.activate(gameID: "game", generationID: "safe", layers: [input],
                                                 operationID: "alias-attack") { point in
                if point == "after-verify" {
                    writer.descriptor = open(source.path, O_WRONLY)
                    #expect(writer.descriptor >= 0)
                } else if point == "after-publish-cas-action" {
                    let written = replacement.withUnsafeBytes { bytes in
                        Darwin.write(writer.descriptor, bytes.baseAddress, bytes.count)
                    }
                    #expect(written == replacement.count)
                }
            }
            try store.validateReference(generation, gameID: "game")
            #expect(try Data(contentsOf: store.objectURL(input.descriptor.digest)) == input.contents)
        }
    }

    @Test("empty verified ingest publishes the known empty digest without scratch bytes")
    func emptyIngest() throws {
        try withIntegrityStore { _, store in
            let input = integrityLayer("", version: "empty")
            let emptyDigest = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            #expect(input.descriptor.digest == emptyDigest)
            let plan = try store.preflightDiskSpace(for: [input.descriptor])
            #expect(plan.activationPeakBytesRequired == 0)
            let generation = try store.activate(gameID: "game", generationID: "empty", layers: [input])
            try store.validateReference(generation, gameID: "game")
            #expect(try Data(contentsOf: store.objectURL(input.descriptor.digest)).isEmpty)
        }
    }

    @Test("claimed digest substitution is rejected before any operation or CAS write")
    func claimedDigestMismatch() throws {
        try withIntegrityStore { _, store in
            let valid = integrityLayer("trusted payload", version: "1")
            let substitute = Data("hostile payload".utf8)
            let invalid = LayerInput(descriptor: valid.descriptor, contents: substitute)
            #expect(throws: ContentStoreError.digestMismatch(
                expected: valid.descriptor.digest, actual: ContentStore.digest(substitute))) {
                try store.activate(gameID: "game", generationID: "invalid", layers: [invalid])
            }
            #expect(try store.allObjectURLs().isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.journalsDirectory.path).isEmpty)
            let generation = try store.activate(gameID: "game", generationID: "valid", layers: [valid])
            try store.validateReference(generation, gameID: "game")
        }
    }

    @Test("a lease for A rejects a B identity and cannot release B's lease")
    func leaseIdentityConfusion() throws {
        try withIntegrityStore { _, store in
            let first = try store.activate(gameID: "game", generationID: "generation-a",
                                           layers: [integrityLayer("payload-a", version: "a")])
            let second = try store.activate(gameID: "game", generationID: "generation-b",
                                            layers: [integrityLayer("payload-b", version: "b")])
            let leaseA = try store.acquireLease(gameID: "game", generation: first)
            let leaseB = try store.acquireLease(gameID: "game", generation: second)
            let beforeA = try Data(contentsOf: store.leaseURL(leaseA.leaseID))
            let beforeB = try Data(contentsOf: store.leaseURL(leaseB.leaseID))
            let confusedReference = GenerationReference(generationID: second.generationID,
                                                        manifestDigest: first.manifestDigest)
            #expect(throws: ContentStoreError.digestMismatch(
                expected: first.manifestDigest, actual: second.manifestDigest)) {
                try store.acquireLease(gameID: "game", generation: confusedReference)
            }
            let confusedRelease = GenerationLease(leaseID: leaseB.leaseID, gameID: "game", generation: first,
                                                  objectDigests: leaseA.objectDigests, holder: leaseA.holder,
                                                  createdAtUnixSeconds: leaseA.createdAtUnixSeconds)
            #expect(throws: ContentStoreError.invalidLease(leaseB.leaseID)) {
                try store.releaseLease(confusedRelease)
            }
            #expect(try Data(contentsOf: store.leaseURL(leaseA.leaseID)) == beforeA)
            #expect(try Data(contentsOf: store.leaseURL(leaseB.leaseID)) == beforeB)
            #expect(Set(try store.liveLeases().map(\.generationID)) == [first.generationID, second.generationID])
            try store.releaseLease(leaseA)
            #expect(try store.liveLeases() == [leaseB])
            try store.releaseLease(leaseB)
            #expect(try store.liveLeases().isEmpty)
        }
    }

    @Test("hand-edited lease generation cannot become a collection root for another generation")
    func forgedLeaseOnDisk() throws {
        try withIntegrityStore { _, store in
            let first = try store.activate(gameID: "game", generationID: "generation-a",
                                           layers: [integrityLayer("payload-a", version: "a")])
            let second = try store.activate(gameID: "game", generationID: "generation-b",
                                            layers: [integrityLayer("payload-b", version: "b")])
            let lease = try store.acquireLease(gameID: "game", generation: first)
            let url = store.leaseURL(lease.leaseID)
            let original = try Data(contentsOf: url)
            var document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            document["generationId"] = second.generationID
            try store.writeAtomic(JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), to: url)
            #expect(throws: ContentStoreError.digestMismatch(
                expected: first.manifestDigest, actual: second.manifestDigest)) {
                try store.collectGarbage()
            }
            try store.writeAtomic(original, to: url)
            #expect(try store.collectGarbage() == .zero)
            #expect(try store.liveLeases() == [lease])
            try store.releaseLease(lease)
        }
    }
}

private func integrityLayer(_ value: String, version: String) -> LayerInput {
    let data = Data(value.utf8)
    return LayerInput(descriptor: LayerDescriptor(name: "runtime", version: version,
        digest: ContentStore.digest(data), mediaType: "application/octet-stream", size: data.count,
        role: .hostRuntime), contents: data)
}

private func withIntegrityStore(_ body: (URL, ContentStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-integrity-\(UUID())")
    defer {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var information = stat()
            if lstat(url.path, &information) == 0, information.st_mode & S_IFMT != S_IFLNK {
                chmod(url.path, S_IRWXU)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
    try body(root, ContentStore(root: root.appendingPathComponent("store")))
}

private final class IngestWriter: @unchecked Sendable {
    // The synchronous activation hook owns this descriptor for the test.
    var descriptor: Int32 = -1
    deinit { if descriptor >= 0 { close(descriptor) } }
}
