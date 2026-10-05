// Author: Timur Isaev
import AlloyContentStore
import AlloyDiagnostics
import AlloyRuntimeAPI
import Foundation

public struct FailureCapture: Codable, Equatable, Sendable {
    public let version: Int
    public let outcome: String
    public let complete: Bool
    public let observations: [Observation]
    public let artifacts: [StructuredEvent]
    public let elapsedSeconds: Double

    public init(outcome: String, complete: Bool, observations: [Observation],
                artifacts: [StructuredEvent], elapsedSeconds: Double) {
        version = 1
        self.outcome = outcome
        self.complete = complete
        self.observations = observations
        self.artifacts = artifacts
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct CaptureSession {
    public let connection: DiagnosticConnection
    public let budgetSeconds: Double

    public init(connection: DiagnosticConnection, budgetSeconds: Double = 30) throws {
        guard budgetSeconds.isFinite, budgetSeconds >= 0.1, budgetSeconds <= 35 else {
            throw IntegrationError.invalidInput
        }
        self.connection = connection
        self.budgetSeconds = budgetSeconds
    }

    public func capture(kind: String, identifier: String, sampleHang: Bool = false) throws -> FailureCapture {
        let start = ProcessInfo.processInfo.systemUptime
        var observations: [Observation] = []
        var artifacts: [StructuredEvent] = []
        while ProcessInfo.processInfo.systemUptime - start < budgetSeconds {
            let observed: Observation
            do {
                observed = try connection.observe(kind: kind, identifier: identifier, deadline: start + budgetSeconds)
            } catch IntegrationError.budgetExceeded {
                return result("budget-exceeded", false, observations, artifacts, start)
            } catch RuntimeFailure.transport, IntegrationError.incompleteCapture {
                guard !observations.isEmpty else { throw IntegrationError.unavailable }
                return result("service-interruption", false, observations, artifacts, start)
            }
            if changedService(observations.last, observed) || observed.state == "INTERRUPTED" {
                observations.append(observed)
                return result("service-interruption", false, observations, artifacts, start)
            }
            if observations.last?.state != observed.state { observations.append(observed) }
            if shouldSample(kind, sampleHang, artifacts, observed) {
                do {
                    let artifact = try sample(identifier: identifier, observation: observed,
                                              deadline: start + budgetSeconds)
                    artifacts.append(artifact)
                } catch {
                    return result("native-capture-incomplete", false, observations, artifacts, start)
                }
            }
            if ["FAILED", "SUCCEEDED", "STOPPED", "CANCELLED"].contains(observed.state) {
                if ProcessInfo.processInfo.systemUptime - start >= budgetSeconds {
                    return result("budget-exceeded", false, observations, artifacts, start)
                }
                return try terminal(observed, observations, artifacts, start)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return result("budget-exceeded", false, observations, artifacts, start)
    }

    private func shouldSample(_ kind: String, _ enabled: Bool, _ artifacts: [StructuredEvent],
                              _ observed: Observation) -> Bool {
        kind == "session" && enabled && artifacts.isEmpty && observed.state == "RUNNING"
    }

    private func terminal(_ observed: Observation, _ observations: [Observation],
                          _ initialArtifacts: [StructuredEvent], _ start: Double) throws -> FailureCapture {
        var artifacts = initialArtifacts
        let outcome = try classify(observed, artifacts: artifacts)
        if outcome == "native-fixture-signal-abort", let identity = observed.events.first?.correlation {
            artifacts.append(try DiagnosticIdentity.event("runtime.native.exit", identity, [
                DiagnosticIdentity.field("exit_code", "6"),
                DiagnosticIdentity.field("evidence", "service-recorded-native-exit; no-crash-stack")
            ]))
        }
        return result(outcome, true, observations, artifacts, start)
    }

    private func changedService(_ before: Observation?, _ after: Observation) -> Bool {
        before.map { $0.serviceInstanceID != after.serviceInstanceID } ?? false
    }

    private func sample(identifier: String, observation: Observation, deadline: Double) throws -> StructuredEvent {
        guard connection.client.configuration.fixtureMode == true else { throw IntegrationError.invalidInput }
        let (_, session) = try connection.read("session.get",
            payload: RuntimeEncoding.encode(IdentifierRequest(identifier)), as: SessionSnapshot.self,
            timeout: min(5, max(0.01, deadline - ProcessInfo.processInfo.systemUptime)))
        _ = try SessionAdapter.observe(session, expectedID: identifier, requestID: "ownership-read",
                                        instanceID: observation.serviceInstanceID)
        guard session.record.request.scenario == .hang, session.liveNodes.count == 3,
              let agent = session.nodes.first(where: { $0.name == "agent" }),
              NativeProcessIdentity.isLive(agent.lease.holder),
              let identity = observation.events.first?.correlation else { throw IntegrationError.incompleteCapture }
        let holder = agent.lease.holder
        let report = try NativeCapture.sampleOwned(processID: holder.processID,
            startedSeconds: holder.startTimeSeconds, startedMicroseconds: UInt64(holder.startTimeMicroseconds),
            correlation: identity, timeoutSeconds: min(5, deadline - ProcessInfo.processInfo.systemUptime))
        guard report.symbolicatedText.contains("FixtureMain.run"), report.symbolicatedText.contains("poll") else {
            throw IntegrationError.incompleteCapture
        }
        // Raw stacks exist only in bounded memory and the capture helper's private scratch directory.
        return try DiagnosticIdentity.event("runtime.native.sample", identity, [
            DiagnosticIdentity.field("artifact", "owned-native-stack"),
            DiagnosticIdentity.field("sampled_site", "FixtureMain.run:poll"),
            DiagnosticIdentity.field("owned_agent", "\(holder.processID):\(holder.startTimeSeconds):"
                + "\(holder.startTimeMicroseconds)"),
            DiagnosticIdentity.field("raw_stack", report.symbolicatedText, .moduleProcessFileInventory)
        ])
    }

    private func classify(_ observation: Observation, artifacts: [StructuredEvent]) throws -> String {
        guard observation.state == "FAILED" else { return "clean" }
        if observation.source == "runtime.operation" { return "operation-failed" }
        let fields = observation.events.last?.fields ?? []
        let code = fields.first(where: { $0.name == "exit_code" })?.value
        if code == "43" {
            guard artifacts.contains(where: { $0.eventCode == "runtime.native.sample" }) else {
                throw IntegrationError.incompleteCapture
            }
            return "native-fixture-watchdog-hang"
        }
        if code == "6" { return "native-fixture-signal-abort" }
        return "native-fixture-failed"
    }

    private func result(_ outcome: String, _ complete: Bool, _ observations: [Observation],
                        _ artifacts: [StructuredEvent], _ started: Double) -> FailureCapture {
        FailureCapture(outcome: outcome, complete: complete, observations: observations,
                       artifacts: artifacts, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
    }
}
