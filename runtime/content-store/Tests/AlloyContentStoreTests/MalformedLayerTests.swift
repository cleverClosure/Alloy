// Author: Timur Isaev

import Foundation
import Testing

@testable import AlloyContentStore

struct MalformedLayerTests {
    @Test(arguments: ["traversal", "hardlink", "setid", "payload", "feature", "trailing", "bomb"])
    func malformedArchivePublishesNothing(kind: String) throws {
        let fixture = try #require(Bundle.module.url(forResource: "LayerFixtures", withExtension: nil))
        let original = try JSONDecoder().decode(
            LayerDescriptor.self,
            from: Data(contentsOf: fixture.appendingPathComponent("descriptor.json")))
        var archive = try Data(contentsOf: fixture.appendingPathComponent("known.layer.tar.zst"))
        // Independent one-block fixture layout: 9-byte frame header, 3-byte block header, USTAR bytes.
        var tar = archive.subdata(in: 12..<archive.count)
        let header = try #require(memberHeader("files/bin/tool", in: tar))
        switch kind {
        case "traversal": replaceField(&tar, at: header, width: 100, text: "files/../escape")
        case "hardlink": tar[header + 156] = 49
        case "setid": replaceField(&tar, at: header + 100, width: 8, text: "0004555")
        case "payload": tar[header + 512] ^= 1
        case "feature":
            let range = try #require(tar.range(of: Data("raw-zstd-v1".utf8)))
            tar.replaceSubrange(range, with: Data("bad-zstd-v1".utf8))
        case "trailing": archive.append(contentsOf: [0x28, 0xb5, 0x2f, 0xfd])
        default: archive[8] = 0x7f
        }
        if ["traversal", "hardlink", "setid"].contains(kind) {
            tar.replaceSubrange((header + 148)..<(header + 156), with: Data(repeating: 32, count: 8))
            let checksum = tar[header..<(header + 512)].reduce(0) { $0 + Int($1) }
            let checksumField = String(format: "%06o", checksum) + "\0 "
            tar.replaceSubrange((header + 148)..<(header + 156), with: Data(checksumField.utf8))
        }
        if !["trailing", "bomb"].contains(kind) { archive.replaceSubrange(12..<archive.count, with: tar) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ContentStore(root: root.appendingPathComponent("store"))
        defer { try? store.removeLayerScratch(root) }
        let input = root.appendingPathComponent("input.zst")
        try archive.write(to: input)
        let descriptor = LayerDescriptor(
            name: original.name, version: original.version,
            digest: ContentStore.digest(archive), mediaType: original.mediaType, size: archive.count,
            role: original.role, sourceRevision: original.sourceRevision)
        #expect(throws: (any Error).self) { try store.importDevelopmentLayer(from: input, descriptor: descriptor) }
        #expect(try store.inspect(gameID: "game").objectCount == 0)
    }

    private func replaceField(_ data: inout Data, at offset: Int, width: Int, text: String) {
        var bytes = Data(text.utf8)
        bytes.append(Data(repeating: 0, count: width - bytes.count))
        data.replaceSubrange(offset..<(offset + width), with: bytes)
    }

    private func memberHeader(_ name: String, in tar: Data) -> Int? {
        for offset in stride(from: 0, to: tar.count - 512, by: 512) {
            if tar[offset..<(offset + name.utf8.count)] == Data(name.utf8), tar[offset + name.utf8.count] == 0 {
                return offset
            }
        }
        return nil
    }
}
