// Author: Timur Isaev

import Darwin
import Foundation
import Testing
@testable import AlloyTitleVolumes

@Suite struct LegacyTests {
    @Test func explicitAdoptionPreservesBytesAndTightensPermissions() throws {
        try fixture { root, store in
            let saves = root.appendingPathComponent("volumes/legacy/saves")
            try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
            let file = saves.appendingPathComponent("save.sav")
            let original = Data("valuable existing save".utf8)
            try original.write(to: file)
            #expect(throws: VolumeError.self) { try store.createTitle(gameID: "legacy") }
            _ = try store.adoptLegacySaves(gameID: "legacy")
            #expect(try store.read(gameID: "legacy", kind: .saves, path: "save.sav") == original)
            for (path, mode) in [(saves.path, mode_t(0o700)), (file.path, mode_t(0o600))] {
                var info = stat()
                #expect(lstat(path, &info) == 0)
                #expect(info.st_mode & 0o777 == mode)
            }
            #expect(try TitleVolumeStore(root: root).records(gameID: "legacy").count == 2)
        }
    }

    @Test func legacyHardLinkCannotChangeAnotherTitlesPermissions() throws {
        try fixture { root, store in
            let saves = root.appendingPathComponent("volumes/legacy/saves")
            try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
            let outside = root.appendingPathComponent("other-file")
            try Data([7]).write(to: outside)
            #expect(chmod(outside.path, 0o644) == 0)
            #expect(link(outside.path, saves.appendingPathComponent("linked").path) == 0)
            #expect(throws: VolumeError.unsafeFile) { try store.adoptLegacySaves(gameID: "legacy") }
            var info = stat()
            #expect(lstat(outside.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o644)
            #expect(try Data(contentsOf: outside) == Data([7]))
            #expect(unlink(saves.appendingPathComponent("linked").path) == 0)
            try Data([8]).write(to: saves.appendingPathComponent("clean"))
            _ = try store.adoptLegacySaves(gameID: "legacy")
            #expect(try store.read(gameID: "legacy", kind: .saves, path: "clean") == Data([8]))
        }
    }
}
