// Author: Timur Isaev

import Foundation

private struct DecodedSnapshotHeader {
    let version: UInt32
    let sourceDigest: String
    let entryCount: Int
}

enum SnapshotDecoder {
    static func decode(_ data: Data) throws -> PolicySnapshotInspection {
        var cursor = DataCursor(data)
        let header = try decodeHeader(data: data, cursor: &cursor)
        let entries = try decodeEntries(count: header.entryCount, cursor: &cursor)
        guard cursor.atEnd else {
            throw PolicySnapshotError.invalid("trailing bytes")
        }
        return PolicySnapshotInspection(
            version: Int(header.version),
            sourceDigest: header.sourceDigest,
            entries: entries
        )
    }

    private static func decodeHeader(
        data: Data,
        cursor: inout DataCursor
    ) throws -> DecodedSnapshotHeader {
        guard try cursor.read(SnapshotFormat.magic.count) == SnapshotFormat.magic else {
            throw PolicySnapshotError.invalid("bad magic")
        }
        let version = try cursor.readUInt32()
        guard version == SnapshotFormat.version else {
            throw PolicySnapshotError.invalid("unsupported binary version \(version)")
        }
        guard try cursor.readUInt32() == SnapshotFormat.byteOrder,
              try cursor.readUInt32() == SnapshotFormat.headerSize,
              try cursor.readUInt32() == SnapshotFormat.entrySize else {
            throw PolicySnapshotError.invalid("incompatible binary layout")
        }
        let entryCount = Int(try cursor.readUInt32())
        guard entryCount > 0, entryCount <= SnapshotFormat.maximumProcessPolicies + 1 else {
            throw PolicySnapshotError.invalid("invalid entry count")
        }
        guard try cursor.readUInt32() == 0 else {
            throw PolicySnapshotError.invalid("default policy is not entry zero")
        }
        let sourceDigest = encodeHex(try cursor.read(SnapshotFormat.digestByteSize))
        guard data.count == SnapshotFormat.headerSize + entryCount * SnapshotFormat.entrySize else {
            throw PolicySnapshotError.invalid("file size does not match header")
        }
        return DecodedSnapshotHeader(
            version: version,
            sourceDigest: sourceDigest,
            entryCount: entryCount
        )
    }

    private static func decodeEntries(
        count: Int,
        cursor: inout DataCursor
    ) throws -> [PolicySnapshotEntryInspection] {
        var entries: [PolicySnapshotEntryInspection] = []
        var previousDigest: Data?
        for index in 0..<count {
            let digest = try cursor.read(SnapshotFormat.digestByteSize)
            if index == 0 {
                guard digest.allSatisfy({ $0 == 0 }) else {
                    throw PolicySnapshotError.invalid("default entry has a digest")
                }
            } else {
                guard digest.contains(where: { $0 != 0 }) else {
                    throw PolicySnapshotError.invalid("exact entry has a zero digest")
                }
                if let previousDigest, !previousDigest.lexicographicallyPrecedes(digest) {
                    throw PolicySnapshotError.invalid("exact entries are not strictly sorted")
                }
                previousDigest = digest
            }
            entries.append(
                try decodeEntry(
                    digest: digest,
                    defaultPolicy: index == 0,
                    cursor: &cursor
                )
            )
        }
        return entries
    }

    private static func decodeEntry(
        digest: Data,
        defaultPolicy: Bool,
        cursor: inout DataCursor
    ) throws -> PolicySnapshotEntryInspection {
        let policyID = try cursor.readFixedUTF8(size: SnapshotFormat.policyIDSize)
        let graphicsProvider = try cursor.readFixedUTF8(size: SnapshotFormat.graphicsProviderSize)
        let providerDirectory = try cursor.readFixedUTF8(size: SnapshotFormat.providerPathSize)
        let routeCount = Int(try cursor.readUInt32())
        guard try cursor.readUInt32() == 0,
              routeCount > 0,
              routeCount <= SnapshotFormat.maximumRoutes else {
            throw PolicySnapshotError.invalid("invalid route table")
        }

        var routes: [PolicySnapshotRouteInspection] = []
        for index in 0..<SnapshotFormat.maximumRoutes {
            let module = try cursor.readFixedUTF8(size: SnapshotFormat.moduleSize)
            let loadOrder = try cursor.readUInt32()
            if index < routeCount {
                guard let value = loadOrderName(loadOrder), !module.isEmpty else {
                    throw PolicySnapshotError.invalid("invalid active route")
                }
                routes.append(PolicySnapshotRouteInspection(module: module, loadOrder: value))
            } else if !module.isEmpty || loadOrder != 0 {
                throw PolicySnapshotError.invalid("nonzero unused route")
            }
        }
        return PolicySnapshotEntryInspection(
            imageSHA256: defaultPolicy ? nil : encodeHex(digest),
            policyID: policyID,
            graphicsProvider: graphicsProvider,
            providerDirectory: providerDirectory,
            defaultPolicy: defaultPolicy,
            dllRoutes: routes
        )
    }

    private static func loadOrderName(_ value: UInt32) -> String? {
        switch value {
        case 1: "disabled"
        case 2: "native"
        case 3: "builtin"
        case 4: "native,builtin"
        case 5: "builtin,native"
        default: nil
        }
    }
}

struct DataCursor {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var atEnd: Bool {
        offset == data.count
    }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw PolicySnapshotError.invalid("truncated data")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try read(4)
        return bytes.enumerated().reduce(0) { result, item in
            result | UInt32(item.element) << UInt32(item.offset * 8)
        }
    }

    mutating func readFixedUTF8(size: Int) throws -> String {
        let field = try read(size)
        guard let terminator = field.firstIndex(of: 0),
              field[terminator...].allSatisfy({ $0 == 0 }),
              let value = String(data: field[..<terminator], encoding: .utf8) else {
            throw PolicySnapshotError.invalid("malformed fixed UTF-8 field")
        }
        return value
    }
}
