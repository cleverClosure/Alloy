// Author: Timur Isaev

import Darwin
import Foundation
import Testing
import AlloyStoreIdentity

@Suite("Scanner raw Unicode filename identity")
struct UnicodeFilenameTests {
    @Test("NFC and NFD filenames retain their exact UTF-8 bytes in the aggregate")
    func preservesDirectoryEntryBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alloy-unicode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["nfc/caf\u{e9}.txt", "nfd/cafe\u{301}.txt"]
        for (index, path) in paths.enumerated() {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(index == 0 ? "nfc" : "nfd"),
                withIntermediateDirectories: false
            )
            // URL.appendingPathComponent also normalizes; create known raw directory-entry bytes via POSIX.
            let descriptor = (root.path + "/" + path).withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            }
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { return }
            var byte: UInt8 = 0x78
            #expect(Darwin.write(descriptor, &byte, 1) == 1)
            #expect(Darwin.close(descriptor) == 0)
        }
        let identity = try FingerprintIdentity(
            appID: "910004", name: "Unicode", buildID: "1",
            depots: ["910041": FingerprintDepotRecord(manifest: "1", size: "2")]
        )
        let record = try FingerprintScanner.scan(installRoot: root, identity: identity)
        #expect(record.files.map { Array($0.path.utf8) } == paths.map { Array($0.utf8) })
        // Python hashlib over §5 records for both paths, each containing the one byte 0x78.
        #expect(record.aggregateSHA256 == "73befc77760e2c267e9be1953e5717fbaab489d4bd33919084399f82b88ffcfd")
        #expect(try FingerprintScanner.scan(installRoot: root, identity: identity).canonicalJSON()
            == record.canonicalJSON())
    }
}
