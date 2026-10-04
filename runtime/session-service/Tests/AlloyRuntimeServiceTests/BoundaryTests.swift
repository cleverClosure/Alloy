// Author: Timur Isaev
import AlloyRuntimeAPI
import AlloyRuntimeService
import Darwin
import Foundation
import Testing

private let credential = String(repeating: "a", count: 64)

private func router() -> RequestRouter {
    RequestRouter(configuration: ServiceConfiguration(
        serviceName: "com.alloy.development.unit", credential: credential,
        stateRoot: "/unused/state", contentRoot: "/unused/content"))
}

private func send(_ request: RuntimeRequest, uid: UInt32 = getuid()) throws -> RuntimeResponse {
    try JSONDecoder().decode(RuntimeResponse.self,
                             from: router().exchange(RuntimeEncoding.encode(request), peerUID: uid, now: 100))
}

@Test func authenticatedBoundaryAndControls() throws {
    var request = RuntimeRequest(method: "info", credential: credential, deadline: 110)
    let accepted = try send(request)
    let info = try accepted.decode(ServiceInfo.self)
    #expect(accepted.requestID == request.requestID)
    #expect(info.developmentOnly && !info.gameLaunchAvailable)
    #expect(info.processID == getpid())
    #expect(try send(request, uid: getuid() + 1).status.code == .unauthorized)
    request.credential = String(repeating: "b", count: 64)
    #expect(try send(request).status.code == .unauthorized)
    request.credential = credential
    request.apiVersion = 2
    #expect(try send(request).status.code == .unsupportedVersion)
    request.apiVersion = 1
    request.deadline = 99
    #expect(try send(request).status.code == .expired)
    request.deadline = 132
    #expect(try send(request).status.code == .expired)
    request.deadline = 110
    request.method = "arbitrary-command"
    #expect(try send(request).status.code == .malformed)
    request.method = "info"
    #expect(try send(request).status.code == .ok)
}

@Test func malformedAndOversizedMessages() throws {
    for (data, expected) in [(Data("not-json".utf8), RuntimeCode.malformed),
                             (Data(repeating: 0, count: RuntimeLimits.messageBytes + 1), .oversized)] {
        let response = try JSONDecoder().decode(RuntimeResponse.self,
                                               from: router().exchange(data, peerUID: getuid()))
        #expect(response.status.code == expected)
        #expect(response.payload == Data("{}".utf8))
    }
}

@Test func configurationRequiresPrivateRegularFileAndSeparateRoots() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["state", "content"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    let file = root.appendingPathComponent("endpoint.json")
    let configuration = ServiceConfiguration(serviceName: "com.alloy.development.unit", credential: credential,
                                             stateRoot: root.appendingPathComponent("state").path,
                                             contentRoot: root.appendingPathComponent("content").path)
    try RuntimeEncoding.encode(configuration).write(to: file)
    chmod(file.path, 0o600)
    #expect(try ServiceConfiguration.read(file.path).serviceName == configuration.serviceName)
    chmod(file.path, 0o644)
    #expect(throws: RuntimeFailure.invalidConfiguration) { try ServiceConfiguration.read(file.path) }
    chmod(file.path, 0o600)
    let link = root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: RuntimeFailure.invalidConfiguration) { try ServiceConfiguration.read(link.path) }
}
