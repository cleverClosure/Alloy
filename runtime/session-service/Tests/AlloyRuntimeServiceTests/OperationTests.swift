// Author: Timur Isaev
import AlloyRuntimeAPI
import AlloyRuntimeService
import Darwin
import Foundation
import Testing

@Test func privateStoreAdoptionAndExclusiveServiceOwner() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["state", "content"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    let configuration = ServiceConfiguration(
        serviceName: "com.alloy.development.unit", credential: String(repeating: "a", count: 64),
        stateRoot: root.appendingPathComponent("state").path,
        contentRoot: root.appendingPathComponent("content").path)
    let unrelated = root.appendingPathComponent("content/user-file")
    let bytes = Data("do not adopt or mutate this directory".utf8)
    try bytes.write(to: unrelated)
    #expect(throws: RuntimeFailure.invalidConfiguration) { try OperationService(configuration: configuration) }
    #expect(try Data(contentsOf: unrelated) == bytes)
    try FileManager.default.removeItem(at: unrelated)
    let service = try OperationService(configuration: configuration)
    #expect(throws: RuntimeFailure.status(.conflict)) { try OperationService(configuration: configuration) }
    withExtendedLifetime(service) {}
}
