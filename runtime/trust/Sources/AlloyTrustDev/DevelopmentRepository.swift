// Author: Timur Isaev

import AlloyTrust
import CryptoKit
import Darwin
import Foundation

struct DevelopmentRepository {
    let directory: URL

    init(_ path: String) throws {
        directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var ancestor = directory
        while ancestor.path != "/" {
            guard !FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) else {
                throw TrustError.state("private keys must be outside every Git checkout")
            }
            ancestor.deleteLastPathComponent()
        }
    }

    func initialize(scope: TrustScope, now: Date) throws -> String {
        guard mkdir(directory.path, 0o700) == 0 else { throw TrustError.state("init requires new directory") }
        guard mkdir(directory.appendingPathComponent("keys").path, 0o700) == 0 else {
            throw TrustError.state("key directory")
        }
        var keys: [String: String] = [:]
        var roles: [String: RoleRule] = [:]
        for role in TrustRole.allCases {
            let generated = try generateKeys()
            var identifiers: [String] = []
            for key in generated {
                let identifier = SignedEnvelope.keyID(key.publicKey.rawRepresentation)
                identifiers.append(identifier)
                keys[identifier] = key.publicKey.rawRepresentation.base64EncodedString()
            }
            roles[role.rawValue] = RoleRule(keyIds: identifiers.sorted(), threshold: 2)
        }
        let root = TrustMetadata(role: .root, version: 1, expiresAt: expiry(now, days: 365),
                                 scope: scope, keys: keys, roles: roles)
        let bytes = try sign(root, keys: signingKeys(.root, root: root))
        try write(bytes, name: "root.json")
        try write(bytes, name: "1.root.json")
        try write(sign(TrustMetadata(role: .targets, version: 1, expiresAt: expiry(now, days: 7),
                                    scope: scope, targets: [:]), root: root), name: "targets.json")
        try write(sign(TrustMetadata(role: .revocation, version: 1, expiresAt: expiry(now, days: 7),
                                    scope: scope, revokedKeys: [], revokedProfiles: [], revokedDigests: []),
                       root: root),
                  name: "revocation.json")
        try timestamp(now: now)
        return TrustCanonicalJSON.digest(bytes)
    }

    func metadata(_ name: String) throws -> TrustMetadata {
        let envelope = try SignedEnvelope.decode(read(name))
        return try JSONDecoder().decode(TrustMetadata.self, from: envelope.decodedPayload())
    }

    func signingKeys(_ role: TrustRole, root: TrustMetadata) throws -> [Curve25519.Signing.PrivateKey] {
        guard let rule = root.roles?[role.rawValue] else { throw TrustError.invalidRoot }
        return try rule.keyIds.map { identifier in
            let path = directory.appendingPathComponent("keys/\(identifier.dropFirst(7)).key")
            let bytes = try privateRead(path)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
            guard SignedEnvelope.keyID(key.publicKey.rawRepresentation) == identifier else {
                throw TrustError.invalidRoot
            }
            return key
        }
    }

    func sign(_ metadata: TrustMetadata, keys: [Curve25519.Signing.PrivateKey]) throws -> Data {
        try TrustCanonicalJSON.encode(SignedEnvelope.sign(
            TrustCanonicalJSON.encode(metadata), type: metadata.role.payloadType, keys: keys
        ))
    }

    func sign(_ metadata: TrustMetadata, root: TrustMetadata) throws -> Data {
        try sign(metadata, keys: signingKeys(metadata.role, root: root))
    }

    func timestamp(now: Date) throws {
        let root = try metadata("root.json")
        let targets = try read("targets.json")
        let revocation = try read("revocation.json")
        let snapshot = try TrustMetadata(
            role: .snapshot, version: nextVersion("snapshot.json"), expiresAt: expiry(now, days: 7), scope: root.scope,
            references: ["targets": .init(version: metadata("targets.json").version, bytes: targets),
                         "revocation": .init(version: metadata("revocation.json").version, bytes: revocation)]
        )
        let snapshotBytes = try sign(snapshot, root: root)
        let timestamp = try TrustMetadata(
            role: .timestamp, version: nextVersion("timestamp.json"),
            expiresAt: expiry(now, days: 1), scope: root.scope,
            references: ["snapshot": .init(version: snapshot.version, bytes: snapshotBytes)]
        )
        try write(snapshotBytes, name: "snapshot.json")
        try write(sign(timestamp, root: root), name: "timestamp.json")
    }

    func signArtifact(type: String, input: URL, output: String, now: Date) throws {
        let reserved = ["root.json", "targets.json", "snapshot.json", "timestamp.json", "revocation.json"]
        guard !reserved.contains(output), !output.hasSuffix(".root.json"), output.hasSuffix(".json") else {
            throw TrustError.state("artifact output collides with metadata")
        }
        let root = try metadata("root.json")
        let role = try TrustRole.artifact(type)
        let payload = try Data(contentsOf: input)
        let envelope = try TrustCanonicalJSON.encode(SignedEnvelope.sign(payload, type: type,
                                                                         keys: signingKeys(role, root: root)))
        var targets = try metadata("targets.json")
        let target = try TargetRecord(envelope: envelope, expiresAt: expiry(now, days: 7))
        targets.targets?[target.payloadDigest] = target
        targets.version += 1
        targets.expiresAt = expiry(now, days: 7)
        try write(envelope, name: output)
        try write(sign(targets, root: root), name: "targets.json")
        try timestamp(now: now)
    }

    func nextVersion(_ name: String) throws -> Int {
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { return 1 }
        return try metadata(name).version + 1
    }

    func read(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    func write(_ bytes: Data, name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw TrustError.state("output must be a repository basename")
        }
        try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func generateKeys() throws -> [Curve25519.Signing.PrivateKey] {
        try (0..<2).map { _ in
            let key = Curve25519.Signing.PrivateKey()
            let identifier = SignedEnvelope.keyID(key.publicKey.rawRepresentation)
            let path = directory.appendingPathComponent("keys/\(identifier.dropFirst(7)).key")
            let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw TrustError.state("private key create") }
            defer { close(fd) }
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: key.rawRepresentation)
            guard fsync(fd) == 0 else { throw TrustError.state("private key sync") }
            return key
        }
    }

    private func privateRead(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TrustError.state("private key missing") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_uid == getuid(), info.st_size == 32 else { throw TrustError.state("private key permissions") }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }
}

func expiry(_ now: Date, days: Double) -> String {
    ISO8601DateFormatter().string(from: now.addingTimeInterval(days * 86400))
}
