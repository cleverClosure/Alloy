// Author: Timur Isaev

import CryptoKit
import Darwin
import Foundation

struct DecodedLayer {
    let entries: [LayerFileEntry]
    let treeDigest: String
    let tar: Data
    let members: [String: LayerTarMember]
}

struct LayerTarMember {
    let kind: Int
    let mode: Int
    let target: String
    let range: Range<Int>
}

enum LayerArchive {
    static func decode(_ archive: URL, descriptor: LayerDescriptor, scratch: URL) throws -> DecodedLayer {
        guard descriptor.mediaType == LayerFormat.mediaType,
            descriptor.size <= LayerFormat.maximumBytes + 65536
        else {
            throw LayerFormat.reject("unsupported or oversized layer archive")
        }
        let tarURL = scratch.appendingPathComponent("decoded.tar")
        try decodeRawZstandard(archive, to: tarURL)
        let tar = try Data(contentsOf: tarURL, options: .mappedIfSafe)
        let members = try parseTar(tar)
        guard let layerMember = members["layer.json"], let tableMember = members["metadata/file-table.cbor"],
            layerMember.range.count <= LayerFormat.maximumMetadata,
            tableMember.range.count <= LayerFormat.maximumMetadata,
            let manifest = try JSONSerialization.jsonObject(with: tar.subdata(in: layerMember.range))
                as? [String: Any]
        else { throw LayerFormat.reject("missing layer metadata") }
        let table = tar.subdata(in: tableMember.range)
        let canonicalManifest = try JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard canonicalManifest == tar.subdata(in: layerMember.range) else {
            throw LayerFormat.reject("noncanonical or duplicate-key layer manifest")
        }
        try validateManifest(manifest, descriptor: descriptor, table: table)
        let entries = try LayerFormat.decodeTable(table)
        var expected = try metadataMembers(manifest, tar: tar, members: members)
        for entry in entries {
            let name = "files/" + entry.path
            expected.insert(name)
            guard let member = members[name], member.kind == entry.kind, member.mode == entry.mode,
                member.target == entry.target,
                member.range.count == (entry.kind == 0 ? entry.size : 0)
            else {
                throw LayerFormat.reject("archive and file table disagree")
            }
            if entry.kind == 0 && hash(tar, range: member.range) != entry.digest {
                throw LayerFormat.reject("archive file digest mismatch")
            }
        }
        guard expected == Set(members.keys) else { throw LayerFormat.reject("undeclared archive member") }
        return DecodedLayer(entries: entries, treeDigest: ContentStore.digest(table), tar: tar, members: members)
    }

    private static func metadataMembers(
        _ manifest: [String: Any], tar: Data, members: [String: LayerTarMember]
    ) throws -> Set<String> {
        var expected = Set(["layer.json", "metadata/file-table.cbor"])
        for (key, name) in [
            ("licenseSpdxDigest", "metadata/license.spdx.json"),
            ("provenanceDigest", "metadata/provenance.dsse.json"), ("symbolsDigest", "metadata/symbols.ref")
        ] where manifest[key] != nil {
            guard let sha = manifest[key] as? String, LayerFormat.validDigest(sha),
                let member = members[name], member.kind == 0,
                member.range.count <= LayerFormat.maximumMetadata,
                ContentStore.digest(tar.subdata(in: member.range)) == sha
            else {
                throw LayerFormat.reject("metadata digest mismatch")
            }
            expected.insert(name)
        }
        return expected
    }

    private static func validateManifest(_ manifest: [String: Any], descriptor: LayerDescriptor, table: Data) throws {
        let required: Set<String> = [
            "schemaVersion", "name", "version", "mediaType", "targetArchitecture",
            "minimumHostCapability", "fileTreeDigest", "sourceRevision",
            "buildRecipeDigest", "allowedCompositionRoles", "requiredFeatures"
        ]
        let optional: Set<String> = ["licenseSpdxDigest", "provenanceDigest", "symbolsDigest"]
        guard required.isSubset(of: Set(manifest.keys)), Set(manifest.keys).isSubset(of: required.union(optional)),
            manifest["schemaVersion"] as? String == "1.0",
            manifest["name"] as? String == descriptor.name, manifest["version"] as? String == descriptor.version,
            manifest["sourceRevision"] as? String == descriptor.sourceRevision,
            !(manifest["sourceRevision"] as? String ?? "").isEmpty,
            manifest["mediaType"] as? String == LayerFormat.mediaType,
            ["arm64", "arm64ec", "x86_64", "any"].contains(manifest["targetArchitecture"] as? String ?? ""),
            !(manifest["minimumHostCapability"] as? String ?? "").isEmpty,
            LayerFormat.validDigest(manifest["buildRecipeDigest"] as? String ?? ""),
            manifest["fileTreeDigest"] as? String == ContentStore.digest(table),
            manifest["allowedCompositionRoles"] as? [String] == [descriptor.role.rawValue],
            manifest["requiredFeatures"] as? [String] == LayerFormat.features
        else {
            throw LayerFormat.reject("unsupported or inconsistent layer manifest")
        }
    }

    static func hash(_ data: Data, range: Range<Int>) -> String {
        var hasher = SHA256()
        var offset = range.lowerBound
        while offset < range.upperBound {
            let end = min(offset + 65536, range.upperBound)
            hasher.update(data: data[offset..<end])
            offset = end
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeRawZstandard(_ source: URL, to target: URL) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        guard
            FileManager.default.createFile(
                atPath: target.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        else {
            throw LayerFormat.reject("cannot create decoded archive")
        }
        let writer = try FileHandle(forWritingTo: target)
        defer { try? writer.close() }
        func read(_ count: Int) throws -> Data {
            let bytes = try reader.read(upToCount: count) ?? Data()
            guard bytes.count == count else { throw LayerFormat.reject("truncated Zstandard frame") }
            return bytes
        }
        guard try read(5) == Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0]) else {
            throw LayerFormat.reject("unsupported Zstandard profile; raw-zstd-v1 required")
        }
        let size = try read(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard size <= LayerFormat.maximumBytes else { throw LayerFormat.reject("expanded archive limit") }
        var written = 0
        while true {
            let header = try read(3).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
            let count = header >> 3
            guard header & 6 == 0, count <= 131072, count <= size - written else {
                throw LayerFormat.reject("invalid or unsupported Zstandard block")
            }
            try writer.write(contentsOf: read(count))
            written += count
            if header & 1 != 0 { break }
            guard count > 0 else { throw LayerFormat.reject("empty intermediate Zstandard block") }
        }
        guard written == size, try reader.read(upToCount: 1)?.isEmpty ?? true else {
            throw LayerFormat.reject("Zstandard size mismatch or trailing frame")
        }
        try writer.synchronize()
    }

    private static func parseTar(_ data: Data) throws -> [String: LayerTarMember] {
        var members: [String: LayerTarMember] = [:]
        var offset = 0
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) {
                guard data.count - offset >= 1024, data[offset...].allSatisfy({ $0 == 0 }) else {
                    throw LayerFormat.reject("invalid tar end marker")
                }
                return members
            }
            let parsed = try parseMember(header, offset: offset, data: data)
            guard members[parsed.0] == nil else { throw LayerFormat.reject("duplicate tar member") }
            members[parsed.0] = parsed.1
            guard members.count <= 50010 else { throw LayerFormat.reject("tar entry limit") }
            offset = ((parsed.1.range.upperBound + 511) / 512) * 512
        }
        throw LayerFormat.reject("missing tar end marker")
    }
    private static func parseMember(
        _ header: Data, offset: Int, data: Data
    ) throws -> (String, LayerTarMember) {
        func text(_ start: Int, _ count: Int) throws -> String { try tarText(header, start, count) }
        func octal(_ start: Int, _ count: Int) throws -> Int { try tarOctal(header, start, count) }
        let checksum = header.enumerated().reduce(0) { result, byte in
            result + ((148..<156).contains(byte.offset) ? 32 : Int(byte.element))
        }
        guard try octal(148, 8) == checksum, header[257..<263] == Data("ustar\0".utf8),
            header[263..<265] == Data("00".utf8), try octal(108, 8) == 0,
            try octal(116, 8) == 0, try octal(136, 12) == 0,
            try text(265, 32).isEmpty, try text(297, 32).isEmpty
        else {
            throw LayerFormat.reject("noncanonical tar header")
        }
        let prefix = try text(345, 155)
        var name = try (prefix.isEmpty ? "" : prefix + "/") + text(0, 100)
        let kind: Int
        switch header[156] {
        case 48: kind = 0
        case 53:
            kind = 1
            if name.hasSuffix("/") { name.removeLast() }
        case 50: kind = 2
        default: throw LayerFormat.reject("unsupported tar member type")
        }
        try LayerFormat.path(name)
        let size = try octal(124, 12)
        let mode = try octal(100, 8)
        guard size <= LayerFormat.maximumBytes, size <= data.count - offset - 512,
            kind == 0 || size == 0,
            mode & 0o7000 == 0
        else { throw LayerFormat.reject("unsafe tar member") }
        let start = offset + 512
        let end = start + size
        let paddedEnd = start + ((size + 511) / 512) * 512
        guard paddedEnd <= data.count, data[end..<paddedEnd].allSatisfy({ $0 == 0 }) else {
            throw LayerFormat.reject("nonzero tar padding")
        }
        let target = try text(157, 100)
        guard kind == 2 || target.isEmpty else { throw LayerFormat.reject("unexpected tar link") }
        if !name.hasPrefix("files/") && (kind != 0 || mode != 0o444) {
            throw LayerFormat.reject("invalid metadata entry")
        }
        return (name, LayerTarMember(kind: kind, mode: mode, target: target, range: start..<end))
    }

    private static func tarText(_ header: Data, _ start: Int, _ count: Int) throws -> String {
        let slice = header[start..<(start + count)]
        let bytes = slice.prefix(while: { $0 != 0 })
        guard let value = String(data: Data(bytes), encoding: .utf8),
            slice.dropFirst(bytes.count).allSatisfy({ $0 == 0 })
        else {
            throw LayerFormat.reject("invalid tar text")
        }
        return value
    }
    private static func tarOctal(_ header: Data, _ start: Int, _ count: Int) throws -> Int {
        guard let raw = String(bytes: header[start..<(start + count)], encoding: .utf8) else {
            throw LayerFormat.reject("invalid tar number encoding")
        }
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard value.allSatisfy({ "01234567".contains($0) }),
            let number = Int(value.isEmpty ? "0" : value, radix: 8)
        else {
            throw LayerFormat.reject("invalid tar number")
        }
        return number
    }

}
