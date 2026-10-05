// Author: Timur Isaev

import Foundation

struct LayerFileEntry: Equatable {
    let path: String
    let kind: Int
    let mode: Int
    let size: Int
    let digest: String
    let target: String
}

enum LayerFormat {
    static let mediaType = "application/vnd.alloy.layer.v1+tar+zstd"
    static let features = ["canonical-table-v1", "raw-zstd-v1", "development-adhoc-v1"]
    static let maximumBytes = 1_073_741_824
    static let maximumMetadata = 16_777_216

    static func reject(_ reason: String) -> ContentStoreError { .invalidLayer(reason) }

    static func path(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 240,
            value.utf8.elementsEqual(value.precomposedStringWithCanonicalMapping.utf8),
            !value.contains("\\"), !value.contains(":"),
            !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
            value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
        else {
            throw reject("unsafe layer path")
        }
    }

    static func linkTarget(_ entry: LayerFileEntry) throws -> String {
        guard !entry.target.isEmpty, !entry.target.hasPrefix("/"),
            !entry.target.contains("\\"), !entry.target.contains(":")
        else {
            throw reject("unsafe layer symlink")
        }
        var parts = entry.path.split(separator: "/").dropLast().map(String.init)
        for part in entry.target.split(separator: "/", omittingEmptySubsequences: false) {
            if part == ".." {
                guard !parts.isEmpty else { throw reject("layer symlink escapes files") }
                parts.removeLast()
            } else if part != "." && !part.isEmpty {
                parts.append(String(part))
            }
        }
        let result = parts.joined(separator: "/")
        try path(result)
        return result
    }

    static func encodeTable(_ entries: [LayerFileEntry]) -> Data {
        var data = Data()
        func head(_ kind: UInt8, _ value: Int) {
            if value < 24 {
                data.append(kind << 5 | UInt8(value))
                return
            }
            let width = value <= 255 ? 1 : value <= 65535 ? 2 : value <= 4_294_967_295 ? 4 : 8
            data.append(kind << 5 | (width == 1 ? 24 : width == 2 ? 25 : width == 4 ? 26 : 27))
            for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
                data.append(UInt8((UInt64(value) >> shift) & 255))
            }
        }
        func text(_ value: String) {
            head(3, value.utf8.count)
            data.append(contentsOf: value.utf8)
        }
        head(4, entries.count)
        for entry in entries {
            head(4, 6)
            text(entry.path)
            head(0, entry.kind)
            head(0, entry.mode)
            head(0, entry.size)
            text(entry.digest)
            text(entry.target)
        }
        return data
    }

    static func decodeTable(_ data: Data) throws -> [LayerFileEntry] {
        guard data.count <= maximumMetadata else { throw reject("file table too large") }
        var reader = LayerCBORReader(data: data)
        let count = try reader.head(kind: 4)
        guard count > 0, count <= 50_000 else { throw reject("file table entry limit") }
        var entries: [LayerFileEntry] = []
        var folded = Set<String>()
        var total = 0
        for _ in 0..<count {
            guard try reader.head(kind: 4) == 6 else { throw reject("file table row shape") }
            let entry = try LayerFileEntry(
                path: reader.text(), kind: reader.head(kind: 0), mode: reader.head(kind: 0),
                size: reader.head(kind: 0), digest: reader.text(), target: reader.text()
            )
            try path(entry.path)
            let key = entry.path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard folded.insert(key).inserted,
                entries.last.map({ $0.path.utf8.lexicographicallyPrecedes(entry.path.utf8) }) ?? true
            else {
                throw reject("duplicate, unsorted or case-folded layer path")
            }
            guard entry.size <= maximumBytes - total else { throw reject("expanded layer limit") }
            total += entry.size
            try validateEntry(entry)
            entries.append(entry)
        }
        guard reader.offset == data.count, encodeTable(entries) == data else {
            throw reject("noncanonical file table")
        }
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        for entry in entries {
            var parts = entry.path.split(separator: "/").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                guard byPath[parts.joined(separator: "/")]?.kind == 1 else {
                    throw reject("missing or nondirectory ancestor")
                }
            }
        }
        return entries
    }

    private static func validateEntry(_ entry: LayerFileEntry) throws {
        switch entry.kind {
        case 0:
            guard [0o444, 0o555].contains(entry.mode), entry.target.isEmpty,
                validDigest(entry.digest)
            else { throw reject("invalid file table regular file") }
        case 1:
            guard entry.mode == 0o555, entry.size == 0, entry.digest.isEmpty,
                entry.target.isEmpty
            else { throw reject("invalid file table directory") }
        case 2:
            guard entry.mode == 0o777, entry.size == entry.target.utf8.count,
                entry.digest == ContentStore.digest(Data(entry.target.utf8))
            else {
                throw reject("invalid file table symlink")
            }
            _ = try linkTarget(entry)
        default: throw reject("unsupported file table entry")
        }
    }

    static func validDigest(_ value: String) -> Bool {
        value.hasPrefix("sha256:") && value.utf8.count == 71
            && value.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
    }
}

private struct LayerCBORReader {
    let data: Data
    var offset = 0

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw LayerFormat.reject("truncated CBOR") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func head(kind: UInt8) throws -> Int {
        let first = try byte()
        guard first >> 5 == kind else { throw LayerFormat.reject("unsupported CBOR type") }
        let small = first & 31
        if small < 24 { return Int(small) }
        guard small <= 27 else { throw LayerFormat.reject("indefinite CBOR is unsupported") }
        var value: UInt64 = 0
        for _ in 0..<(1 << (small - 24)) { value = try value << 8 | UInt64(byte()) }
        guard value <= UInt64(Int.max) else { throw LayerFormat.reject("CBOR integer overflow") }
        return Int(value)
    }

    mutating func text() throws -> String {
        let length = try head(kind: 3)
        guard length <= 4096, length <= data.count - offset,
            let result = String(data: data[offset..<(offset + length)], encoding: .utf8)
        else {
            throw LayerFormat.reject("invalid CBOR text")
        }
        offset += length
        return result
    }
}
