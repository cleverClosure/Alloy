// Author: Timur Isaev
import AlloyContentStore
import AlloyRuntimeAPI
import Darwin
import Foundation
import Testing

@Test func recordPrivacyAndAtomicReplacement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let record = root.appendingPathComponent("record.json")
    try PrivateRecords.write(["revision": 1], to: record)
    try PrivateRecords.write(["revision": 2], to: record)
    #expect(try PrivateRecords.read([String: Int].self, from: record) == ["revision": 2])
    let alias = root.appendingPathComponent("alias.json")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: record)
    #expect(throws: RuntimeFailure.status(.notFound)) { try PrivateRecords.read([String: Int].self, from: alias) }
    #expect(chmod(record.path, 0o644) == 0)
    #expect(throws: RuntimeFailure.status(.malformed)) { try PrivateRecords.read([String: Int].self, from: record) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["alias.json", "record.json"])
}

@Test func processIdentityRejectsPIDReuse() throws {
    let actual = try #require(NativeProcessIdentity.current(getpid()))
    let wrongStart = LeaseProcessIdentity(processID: actual.processID,
                                          startTimeSeconds: actual.startTimeSeconds + 1,
                                          startTimeMicroseconds: actual.startTimeMicroseconds)
    #expect(NativeProcessIdentity.isLive(actual))
    #expect(NativeProcessIdentity.mayStillBeLive(actual))
    #expect(!NativeProcessIdentity.isLive(wrongStart))
    #expect(!NativeProcessIdentity.mayStillBeLive(wrongStart))
    #expect(NativeProcessIdentity.current(-1) == nil)
}
