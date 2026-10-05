// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

struct RuntimeLayerTests {
    private func fixture() throws -> (URL, LayerDescriptor) {
        let directory = try #require(Bundle.module.url(forResource: "LayerFixtures", withExtension: nil))
        let descriptor = try JSONDecoder().decode(
            LayerDescriptor.self, from: Data(contentsOf: directory.appendingPathComponent("descriptor.json"))
        )
        return (directory.appendingPathComponent("known.layer.tar.zst"), descriptor)
    }

    private func exercise(_ body: (ContentStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ContentStore(root: root)
        defer { try? store.removeLayerScratch(root) }
        try body(store, root)
    }

    @Test func goldenArchiveImportsActivatesAndReopens() throws {
        try exercise { store, root in
            let (archive, descriptor) = try fixture()
            try store.importDevelopmentLayer(from: archive, descriptor: descriptor)
            let reference = try store.activateImportedLayers(
                gameID: "game", generationID: "rtg_test", layers: [descriptor]
            )
            #expect(throws: (any Error).self) { try store.verifyDevelopmentRuntime(gameID: "game") }
            let materialized = try store.materializeDevelopmentRuntime(gameID: "game")
            #expect(materialized.reference == reference)
            #expect(
                try String(contentsOf: materialized.url.appendingPathComponent("bin/tool"), encoding: .utf8)
                    == "known runtime bytes\n")
            #expect(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath:
                        materialized.url.appendingPathComponent("alias").path) == "bin/tool")
            let reopened = try ContentStore(root: root)
            #expect(try reopened.verifyDevelopmentRuntime(gameID: "game").treeDigest == materialized.treeDigest)
        }
    }

    @Test(arguments: ["modified", "missing", "extra", "writable", "link"])
    func runtimeTamperingIsRejected(kind: String) throws {
        try exercise { store, _ in
            let (archive, descriptor) = try fixture()
            try store.importDevelopmentLayer(from: archive, descriptor: descriptor)
            _ = try store.activateImportedLayers(gameID: "game", generationID: "rtg_test", layers: [descriptor])
            let runtime = try store.materializeDevelopmentRuntime(gameID: "game")
            let file = runtime.url.appendingPathComponent("bin/tool")
            switch kind {
            case "modified":
                chmod(file.path, 0o755)
                try Data("wrong runtime bytes\n".utf8).write(to: file)
                chmod(file.path, 0o555)
            case "missing":
                chmod(file.deletingLastPathComponent().path, 0o755)
                try FileManager.default.removeItem(at: file)
                chmod(file.deletingLastPathComponent().path, 0o555)
            case "extra":
                chmod(runtime.url.path, 0o755)
                try Data().write(to: runtime.url.appendingPathComponent("extra"))
                chmod(runtime.url.path, 0o555)
            case "writable": chmod(file.path, 0o755)
            default:
                chmod(runtime.url.path, 0o755)
                let link = runtime.url.appendingPathComponent("alias")
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../outside")
                chmod(runtime.url.path, 0o555)
            }
            #expect(throws: (any Error).self) { try store.verifyDevelopmentRuntime(gameID: "game") }
        }
    }

    @Test func wrongArchiveDigestPublishesNothing() throws {
        try exercise { store, _ in
            let (archive, descriptor) = try fixture()
            let wrong = LayerDescriptor(
                name: descriptor.name, version: descriptor.version,
                digest: "sha256:" + String(repeating: "0", count: 64),
                mediaType: descriptor.mediaType, size: descriptor.size,
                role: descriptor.role, sourceRevision: descriptor.sourceRevision)
            #expect(throws: (any Error).self) { try store.importDevelopmentLayer(from: archive, descriptor: wrong) }
            #expect(try store.inspect(gameID: "game").objectCount == 0)
        }
    }

    @Test func traversalAndUnsupportedCBORRejected() throws {
        let cases = ["../escape", "/absolute", "a//b", "a/./b", "a\\b", "a:b", "cafe\u{301}"]
        for path in cases { #expect(throws: (any Error).self) { try LayerFormat.path(path) } }
        try LayerFormat.path("caf\u{e9}")
        #expect(throws: (any Error).self) { try LayerFormat.decodeTable(Data([0x9f, 0xff])) }
        let entry = LayerFileEntry(path: "same", kind: 1, mode: 0o555, size: 0, digest: "", target: "")
        #expect(throws: (any Error).self) { try LayerFormat.decodeTable(LayerFormat.encodeTable([entry, entry])) }
    }
}
