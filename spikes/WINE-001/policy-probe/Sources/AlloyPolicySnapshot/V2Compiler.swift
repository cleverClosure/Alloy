// Author: Timur Isaev

import CryptoKit
import Foundation

public enum PolicySnapshotV2 {
    public static func compile(source: Data) throws -> Data {
        try encode(V2Validation.source(source))
    }

    /// Expected digest is the complete file SHA-256 from the trusted launch plan.
    public static func inspect(snapshot: Data, expectedDigest: String? = nil) throws -> PolicySnapshotV2Inspection {
        if snapshot.prefix(8) == Data("ALLOYP01".utf8) { throw PolicySnapshotV2Error.legacyVersion }
        guard snapshot.count >= V2Format.header, snapshot.count <= V2Format.maxBytes else {
            throw PolicySnapshotV2Error.layout
        }
        if let expectedDigest, expectedDigest != PolicySnapshotCompiler.sha256(snapshot) {
            throw PolicySnapshotV2Error.expectedDigest
        }
        var checked = snapshot
        let contentDigest = snapshot.subdata(in: 64..<96)
        checked.replaceSubrange(64..<96, with: Data(repeating: 0, count: 32))
        guard Data(SHA256.hash(data: checked)) == contentDigest else { throw PolicySnapshotV2Error.integrity }
        let decoded = try V2Decoder.source(snapshot)
        // Re-encoding checks every padding byte, optional presence, sort order and
        // normalized source digest; permissive readers cannot create aliases.
        let canonical = try V2Validation.source(canonicalJSON(decoded))
        guard try encode(canonical) == snapshot else { throw PolicySnapshotV2Error.noncanonical }
        let policies = [canonical.defaultPolicy] + canonical.processPolicies.map(\.policy)
        return PolicySnapshotV2Inspection(
            version: 2, sourceDigest: encodeHex(snapshot.subdata(in: 32..<64)),
            contentDigest: encodeHex(contentDigest), entries: policies.enumerated().map { index, policy in
                PolicySnapshotV2Entry(
                    imageSHA256: index == 0 ? nil : canonical.processPolicies[index - 1].imageSHA256,
                    policyID: policy.id, defaultPolicy: index == 0, graphicsProvider: policy.graphicsProvider,
                    providerDirectory: policy.providerDirectory, cpuProvider: policy.cpuProvider,
                    environment: policy.environment, workingDirectory: policy.workingDirectory,
                    dllRoutes: policy.dllRoutes?.map {
                        PolicySnapshotRouteInspection(module: $0.module, loadOrder: $0.loadOrder.rawValue)
                    }
                )
            }
        )
    }

    static func canonicalJSON(_ value: V2Source) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func encode(_ source: V2Source) throws -> Data {
        var bytes = V2Format.magic
        for value in [2, 0x0102_0304, V2Format.header, V2Format.entry, source.processPolicies.count + 1, 0] {
            bytes.v2UInt(UInt32(value))
        }
        bytes.append(Data(repeating: 0, count: 32))
        bytes.append(Data(repeating: 0, count: 32))
        append(source.defaultPolicy, digest: Data(repeating: 0, count: 32), to: &bytes)
        for process in source.processPolicies {
            append(process.policy, digest: try decodeHex(process.imageSHA256), to: &bytes)
        }
        bytes.replaceSubrange(32..<64, with: Data(SHA256.hash(data: bytes.dropFirst(V2Format.header))))
        let digest = Data(SHA256.hash(data: bytes))
        bytes.replaceSubrange(64..<96, with: digest)
        return bytes
    }

    private static func append(_ policy: V2Policy, digest: Data, to bytes: inout Data) {
        bytes.append(digest)
        bytes.v2Text(policy.id, size: 64)
        bytes.v2Text(policy.graphicsProvider ?? "", size: 64)
        bytes.v2Text(policy.providerDirectory ?? "", size: 512)
        bytes.v2UInt(policy.presence)
        bytes.v2UInt(policy.cpuProvider?.code ?? 0)
        let routes = policy.dllRoutes ?? []
        let environment = (policy.environment ?? [:]).sorted { $0.key < $1.key }
        bytes.v2UInt(UInt32(routes.count))
        bytes.v2UInt(UInt32(environment.count))
        bytes.v2Text(policy.workingDirectory ?? "", size: 512)
        for index in 0..<V2Format.maxRoutes {
            bytes.v2Text(index < routes.count ? routes[index].module : "", size: 32)
            bytes.v2UInt(index < routes.count ? routes[index].loadOrder.binaryValue : 0)
        }
        for index in 0..<V2Format.maxEnvironment {
            bytes.v2Text(index < environment.count ? environment[index].key : "", size: 64)
            bytes.v2Text(index < environment.count ? environment[index].value : "", size: 256)
        }
    }
}

private extension Data {
    mutating func v2UInt(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    mutating func v2Text(_ value: String, size: Int) {
        append(contentsOf: value.utf8)
        append(Data(repeating: 0, count: size - value.utf8.count))
    }
}
