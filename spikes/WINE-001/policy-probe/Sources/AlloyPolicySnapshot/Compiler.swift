// Author: Timur Isaev

import CryptoKit
import Foundation

enum SnapshotFormat {
    static let magic = Data("ALLOYP01".utf8)
    static let version: UInt32 = 1
    static let byteOrder: UInt32 = 0x0102_0304
    static let headerSize = 64
    static let entrySize = 968
    static let digestByteSize = 32
    static let digestSize = digestByteSize * 2
    static let policyIDSize = 64
    static let graphicsProviderSize = 64
    static let providerPathSize = 512
    static let moduleSize = 32
    static let maximumRoutes = 8
    static let routeSize = 36
    static let maximumProcessPolicies = 4_095
}

public enum PolicySnapshotCompiler {
    public static func compile(source data: Data) throws -> Data {
        try SourceValidator.validateKeys(data)
        let decoded = try JSONDecoder().decode(PolicySource.self, from: data)
        let normalized = try SemanticValidator.normalize(decoded)

        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonicalSource = try canonicalEncoder.encode(normalized)
        let sourceDigest = Data(SHA256.hash(data: canonicalSource))

        var result = Data()
        result.append(SnapshotFormat.magic)
        result.appendLittleEndian(SnapshotFormat.version)
        result.appendLittleEndian(SnapshotFormat.byteOrder)
        result.appendLittleEndian(UInt32(SnapshotFormat.headerSize))
        result.appendLittleEndian(UInt32(SnapshotFormat.entrySize))
        result.appendLittleEndian(UInt32(normalized.processPolicies.count + 1))
        result.appendLittleEndian(0)
        result.append(sourceDigest)
        appendEntry(policy: normalized.defaultPolicy, digest: Data(repeating: 0, count: 32), to: &result)
        for process in normalized.processPolicies {
            appendEntry(
                policy: process.policy,
                digest: try decodeHex(process.imageSHA256),
                to: &result
            )
        }
        return result
    }

    public static func inspect(snapshot data: Data) throws -> PolicySnapshotInspection {
        try SnapshotDecoder.decode(data)
    }

    public static func sha256(_ data: Data) -> String {
        encodeHex(Data(SHA256.hash(data: data)))
    }

    private static func appendEntry(
        policy: NormalizedPolicy,
        digest: Data,
        to result: inout Data
    ) {
        result.append(digest)
        result.appendFixedUTF8(policy.id, size: SnapshotFormat.policyIDSize)
        result.appendFixedUTF8(policy.graphicsProvider, size: SnapshotFormat.graphicsProviderSize)
        result.appendFixedUTF8(policy.providerDirectory, size: SnapshotFormat.providerPathSize)
        result.appendLittleEndian(UInt32(policy.dllRoutes.count))
        result.appendLittleEndian(0)
        for route in policy.dllRoutes {
            result.appendFixedUTF8(route.module, size: SnapshotFormat.moduleSize)
            result.appendLittleEndian(route.loadOrder.binaryValue)
        }
        for _ in policy.dllRoutes.count..<SnapshotFormat.maximumRoutes {
            result.append(Data(repeating: 0, count: SnapshotFormat.routeSize))
        }
    }
}

func decodeHex(_ value: String) throws -> Data {
    guard value.count.isMultiple(of: 2) else {
        throw PolicySnapshotError.invalid("hexadecimal value has odd length")
    }
    var result = Data()
    result.reserveCapacity(value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else {
            throw PolicySnapshotError.invalid("malformed hexadecimal value")
        }
        result.append(byte)
        index = next
    }
    return result
}

func encodeHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendFixedUTF8(_ value: String, size: Int) {
        let bytes = Data(value.utf8)
        append(bytes)
        append(Data(repeating: 0, count: size - bytes.count))
    }
}
