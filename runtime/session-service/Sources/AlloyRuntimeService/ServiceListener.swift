// Author: Timur Isaev
import AlloyRuntimeAPI
import Darwin
import Foundation

public final class ServiceListener: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let router: RequestRouter
    public init(configuration: ServiceConfiguration, fixtureExecutable: URL) throws {
        listener = NSXPCListener(machServiceName: configuration.serviceName)
        let operations = try OperationService(configuration: configuration)
        let launches = try LaunchService(configuration: configuration)
        let sessions = try SessionSupervisor(configuration: configuration, launches: launches,
                                             executable: fixtureExecutable)
        router = RequestRouter(configuration: configuration,
                               methods: OperationService.methods + LaunchService.methods + SessionSupervisor.methods) {
            if LaunchService.methods.contains($0.method) { return try launches.handle($0) }
            if SessionSupervisor.methods.contains($0.method) { return try sessions.handle($0) }
            return try operations.handle($0)
        }
        super.init()
        listener.delegate = self
    }

    public func resume() { listener.resume() }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(), connection.processIdentifier > 0 else { return false }
        connection.exportedInterface = NSXPCInterface(with: RuntimeWire.self)
        connection.exportedObject = PeerConnection(router: router, uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

private final class PeerConnection: NSObject, RuntimeWire, @unchecked Sendable {
    private let router: RequestRouter
    private let uid: UInt32
    init(router: RequestRouter, uid: UInt32) { self.router = router; self.uid = uid }

    func exchange(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        reply(router.exchange(data, peerUID: uid))
    }
}
