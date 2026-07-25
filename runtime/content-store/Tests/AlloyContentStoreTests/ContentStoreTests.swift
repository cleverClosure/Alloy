// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-content-store-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func withStore(
    _ body: (URL, ContentStore) throws -> Void
) throws {
    let root = try temporaryRoot()
    defer {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
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

private func layer(
    _ value: String,
    name: String = "runtime",
    version: String = "1",
    role: LayerRole = .hostRuntime
) -> LayerInput {
    let data = Data(value.utf8)
    return LayerInput(
        descriptor: LayerDescriptor(
            name: name,
            version: version,
            digest: ContentStore.digest(data),
            mediaType: "application/vnd.alloy.test-layer",
            size: data.count,
            role: role,
            sourceRevision: version,
            licenseID: "LicenseRef-Test"
        ),
        contents: data
    )
}

@Test("successful multi-layer update preserves rollback and save")
func successfulUpdatePreservesRollbackAndSave() throws {
    try withStore { _, store in
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [
                layer("host-a", version: "a"),
                layer("wine-a", name: "wine", version: "a", role: .wineRuntime)
            ]
        )
        try store.writeSave(gameID: "game", name: "save.bin", data: Data("save-v1".utf8))

        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            layers: [
                layer("host-b", version: "b"),
                layer("wine-b", name: "wine", version: "b", role: .wineRuntime)
            ]
        )

        let inspection = try store.inspect(gameID: "game")
        #expect(inspection.active?.generationID == "generation-b")
        #expect(inspection.rollback?.generationID == "generation-a")
        #expect(inspection.candidate == nil)
        #expect(inspection.objectCount == 4)
        #expect(inspection.incompleteOperationCount == 0)
        #expect(try store.readSave(gameID: "game", name: "save.bin") == Data("save-v1".utf8))
    }
}

@Test("failed health window restores previous generation")
func failedHealthWindowRestoresPreviousGeneration() throws {
    try withStore { _, store in
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [layer("payload-a", version: "a")]
        )
        try store.writeSave(gameID: "game", name: "save.bin", data: Data("save-v1".utf8))

        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            layers: [layer("payload-b", version: "b")],
            healthOutcome: .fail
        )

        let inspection = try store.inspect(gameID: "game")
        #expect(inspection.active?.generationID == "generation-a")
        #expect(inspection.rollback?.generationID == "generation-a")
        #expect(inspection.candidate == nil)
        #expect(try store.readSave(gameID: "game", name: "save.bin") == Data("save-v1".utf8))
    }
}

@Test("duplicate payload shares one CAS object")
func duplicatePayloadSharesOneObject() throws {
    try withStore { _, store in
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [layer("shared-payload", version: "a")]
        )
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            layers: [layer("shared-payload", version: "b")]
        )

        let inspection = try store.inspect(gameID: "game")
        #expect(inspection.objectCount == 1)
        #expect(inspection.active?.generationID == "generation-b")
    }
}

@Test("digest mismatch cannot create a journal or activate")
func digestMismatchCannotActivate() throws {
    try withStore { _, store in
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [layer("payload-a", version: "a")]
        )
        let data = Data("payload-b".utf8)
        let invalid = LayerInput(
            descriptor: LayerDescriptor(
                name: "runtime",
                version: "b",
                digest: "sha256:\(String(repeating: "0", count: 64))",
                mediaType: "application/vnd.alloy.test-layer",
                size: data.count,
                role: .hostRuntime
            ),
            contents: data
        )

        #expect(throws: ContentStoreError.self) {
            _ = try store.activate(
                gameID: "game",
                generationID: "generation-b",
                layers: [invalid]
            )
        }
        #expect(try store.inspect(gameID: "game").active?.generationID == "generation-a")
    }
}

@Test("declared size mismatch cannot activate")
func sizeMismatchCannotActivate() throws {
    try withStore { _, store in
        let valid = layer("payload", version: "a")
        let invalid = LayerInput(
            descriptor: LayerDescriptor(
                name: valid.descriptor.name,
                version: valid.descriptor.version,
                digest: valid.descriptor.digest,
                mediaType: valid.descriptor.mediaType,
                size: valid.descriptor.size + 1,
                role: valid.descriptor.role
            ),
            contents: valid.contents
        )

        #expect(throws: ContentStoreError.sizeMismatch(
            expected: valid.contents.count + 1,
            actual: valid.contents.count
        )) {
            _ = try store.activate(
                gameID: "game",
                generationID: "generation-a",
                layers: [invalid]
            )
        }
    }
}

@Test("corrupt local object is quarantined before activation")
func corruptLocalObjectIsQuarantined() throws {
    try withStore { _, store in
        let input = layer("payload-b", version: "b")
        let corruptObject = try store.objectURL(input.descriptor.digest)
        try store.createDirectory(corruptObject.deletingLastPathComponent())
        try Data("corrupt".utf8).write(to: corruptObject)

        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            layers: [input]
        )

        let quarantine = try store.fileManager.contentsOfDirectory(
            at: store.quarantineDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(quarantine.count == 1)
        #expect(try store.inspect(gameID: "game").active?.generationID == "generation-b")
    }
}

@Test("CAS symlink is quarantined without following its target")
func casSymlinkIsQuarantinedWithoutFollowingTarget() throws {
    try withStore { root, store in
        let input = layer("payload-b", version: "b")
        let externalTarget = root.appendingPathComponent("external-target")
        let sentinel = Data("do-not-touch".utf8)
        try sentinel.write(to: externalTarget)
        let object = try store.objectURL(input.descriptor.digest)
        try store.createDirectory(object.deletingLastPathComponent())
        try store.fileManager.createSymbolicLink(
            atPath: object.path,
            withDestinationPath: externalTarget.path
        )

        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            layers: [input]
        )

        #expect(try Data(contentsOf: externalTarget) == sentinel)
        #expect(store.isRegularFile(object))
        #expect(try Data(contentsOf: object) == input.contents)
        #expect(try store.fileManager.contentsOfDirectory(
            at: store.quarantineDirectory,
            includingPropertiesForKeys: nil
        ).count == 1)
    }
}

@Test(
    "recovery is idempotent at every lifecycle boundary",
    arguments: ContentStore.faultPoints
)
func recoveryIsIdempotent(faultPoint: String) throws {
    try withStore { root, store in
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [layer("payload-a", version: "a")]
        )
        try store.writeSave(gameID: "game", name: "save.bin", data: Data("save-v1".utf8))

        #expect(throws: ContentStoreError.injectedTermination(faultPoint)) {
            _ = try store.activate(
                gameID: "game",
                generationID: "generation-b",
                layers: [layer("payload-b", version: "b")],
                faultInjector: { point in
                    if point == faultPoint {
                        throw ContentStoreError.injectedTermination(point)
                    }
                }
            )
        }

        let recovered = try ContentStore(root: root)
        try recovered.recoverAll()
        try recovered.recoverAll()
        let inspection = try recovered.inspect(gameID: "game")
        #expect(inspection.active?.generationID == "generation-b")
        #expect(inspection.rollback?.generationID == "generation-a")
        #expect(inspection.candidate == nil)
        #expect(inspection.incompleteOperationCount == 0)
        #expect(try recovered.readSave(gameID: "game", name: "save.bin") == Data("save-v1".utf8))
    }
}

@Test("path traversal identifiers are rejected")
func pathTraversalIdentifiersAreRejected() throws {
    try withStore { _, store in
        #expect(throws: ContentStoreError.invalidIdentifier("../escape")) {
            _ = try store.activate(
                gameID: "../escape",
                generationID: "generation-a",
                layers: [layer("payload-a")]
            )
        }
        #expect(throws: ContentStoreError.invalidIdentifier("gáme")) {
            _ = try store.activate(
                gameID: "gáme",
                generationID: "generation-a",
                layers: [layer("payload-a")]
            )
        }
    }
}

@Test("generation manifest is canonical and versioned")
func generationManifestIsCanonicalAndVersioned() throws {
    try withStore { _, store in
        let layers = [
            layer("host", version: "1"),
            layer("wine", name: "wine", version: "2", role: .wineRuntime)
        ]
        let reference = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: layers
        )
        let manifestURL = store.generationURL(
            gameID: "game",
            generationID: "generation-a"
        ).appendingPathComponent("manifest.json")
        let generationURL = manifestURL.deletingLastPathComponent()
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(GenerationManifest.self, from: data)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: generationURL.path)[.posixPermissions]
                as? NSNumber
        )
        let encodedManifest = try #require(String(data: data, encoding: .utf8))

        #expect(manifest.schemaVersion == "1.0")
        #expect(manifest.layers == layers.map(\.descriptor))
        #expect(reference.manifestDigest == ContentStore.digest(data))
        #expect(encodedManifest.hasPrefix("{\"gameId\""))
        #expect(permissions.intValue == 0o555)
    }
}

@Test("unsupported activation journal version is refused")
func unsupportedActivationJournalVersionIsRefused() throws {
    try withStore { root, store in
        #expect(throws: ContentStoreError.injectedTermination("after-download")) {
            _ = try store.activate(
                gameID: "game",
                generationID: "generation-a",
                layers: [layer("payload-a")],
                faultInjector: { point in
                    if point == "after-download" {
                        throw ContentStoreError.injectedTermination(point)
                    }
                }
            )
        }
        let journalURL = try #require(store.fileManager.contentsOfDirectory(
            at: store.journalsDirectory,
            includingPropertiesForKeys: nil
        ).first)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        )
        object["schemaVersion"] = "2.0"
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try store.writeAtomic(data, to: journalURL)

        let recovered = try ContentStore(root: root)
        #expect(throws: ContentStoreError.unsupportedSchema(
            kind: "activation journal",
            version: "2.0"
        )) {
            try recovered.recoverAll()
        }
    }
}
