// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

private func sessionSource() throws -> [String: Any] {
    func policy(_ id: String, cpu: String) -> [String: Any] {
        ["id": id, "providerDirectory": "C:\\alloy\\providers\\" + id,
         "resolved": ["ruleIds": [id], "cpuProvider": cpu, "graphicsProvider": id,
                      "syncProvider": "conservative", "dllOverrides": ["alloyblocked": "disabled"],
                      "environment": ["LANG": id], "workingDirectory": "G:\\cwd-" + id,
                      "networkPolicy": "allow", "debugPolicy": "off", "services": [:]]]
    }
    return ["schemaVersion": DevelopmentSessionCompiler.format, "syntheticOnly": true,
            "filesystem": "title-volumes-namespace-v1", "gameID": "synthetic", "buildID": "build-one",
            "runtimeGenerationID": "rtg_one", "runtimeTreeDigest": "sha256:" + String(repeating: "a", count: 64),
            "host": try JSONSerialization.jsonObject(with: CanonicalJSON.encode(HostCapabilities.current())),
            "createdAt": "2026-10-06T00:00:00Z",
            "volumes": Dictionary(uniqueKeysWithValues: ["runtime", "game", "saves", "settings", "cache", "temp"]
                .map { ($0, "vol-" + $0) }),
            "defaultPolicy": policy("unknown", cpu: "native-arm64ec"),
            "processes": [["path": "G:\\launcher.exe", "imageSHA256": String(repeating: "b", count: 64),
                           "machine": "arm64", "policy": policy("launcher", cpu: "native-arm64ec")],
                          ["path": "G:\\game.exe", "imageSHA256": String(repeating: "c", count: 64),
                           "machine": "x64", "policy": policy("game", cpu: "fex-arm64ec")]]]
}

private func compileSession(_ source: [String: Any]) throws -> CompiledLaunch {
    try DevelopmentSessionCompiler.compile(JSONSerialization.data(withJSONObject: source))
}

@Suite("Explicit synthetic development sessions")
struct DevelopmentSessionTests {
    @Test func readySpecificationReproducesAndBindsEveryInput() throws {
        let source = try sessionSource()
        let compiled = try compileSession(source)
        #expect(compiled.specification.runtimeReady)
        #expect(compiled.specification.notYetLowered.isEmpty)
        #expect(!compiled.specification.productionEligible)
        #expect(compiled.specification.localFormatVersion == DevelopmentSessionCompiler.format)
        #expect(compiled.specification.policyCompiler.snapshotDigest == CanonicalJSON.digest(compiled.snapshot.bytes))
        let bytes = try JSONSerialization.data(withJSONObject: source)
        #expect(try DevelopmentSessionCompiler.verifyExport(compiled.canonicalJSON, input: bytes)
            == compiled.specification)
        #expect(try compileSession(source).canonicalJSON == compiled.canonicalJSON)
        #expect(try compileSession(source).snapshot.bytes == compiled.snapshot.bytes)
        for field in ["gameID", "buildID", "runtimeGenerationID"] {
            var changed = source
            changed[field] = "different"
            #expect(try compileSession(changed).specification.launchSpecId != compiled.specification.launchSpecId)
        }
        var forged = try #require(JSONSerialization.jsonObject(with: compiled.canonicalJSON) as? [String: Any])
        forged["productionEligible"] = true
        #expect(throws: (any Error).self) {
            try DevelopmentSessionCompiler.verifyExport(JSONSerialization.data(withJSONObject: forged), input: bytes)
        }
    }

    @Test func unsupportedRestrictionsRemainVisible() throws {
        let source = try sessionSource()
        for (field, value) in [("networkPolicy", "deny"), ("debugPolicy", "crash-only"),
                               ("syncProvider", "fast"), ("cpuProvider", "other"), ("featureMask", "unlowered")] {
            var changed = source
            var processes = try #require(changed["processes"] as? [[String: Any]])
            var policy = try #require(processes[0]["policy"] as? [String: Any])
            var resolved = try #require(policy["resolved"] as? [String: Any])
            resolved[field] = value
            policy["resolved"] = resolved
            processes[0]["policy"] = policy
            changed["processes"] = processes
            let compiled = try compileSession(changed)
            #expect(!compiled.specification.runtimeReady)
            #expect(compiled.specification.notYetLowered.contains { $0.field == field })
        }
        var changed = source
        var fallback = try #require(changed["defaultPolicy"] as? [String: Any])
        var resolved = try #require(fallback["resolved"] as? [String: Any])
        resolved["networkPolicy"] = "deny"
        fallback["resolved"] = resolved
        changed["defaultPolicy"] = fallback
        #expect(try !compileSession(changed).specification.runtimeReady)
    }

    @Test func invalidBindingsAndUnknownRequirementsReject() throws {
        let source = try sessionSource()
        for (field, value) in [("filesystem", "sandbox"), ("gameID", "../escape"),
                               ("runtimeTreeDigest", "sha256:broken"), ("createdAt", "invalid")] {
            var changed = source
            changed[field] = value
            #expect(throws: (any Error).self) { try compileSession(changed) }
        }
        for field in ["syntheticOnly", "productionEligible", "networkAuthorization"] {
            var changed = source
            changed[field] = false
            #expect(throws: (any Error).self) { try compileSession(changed) }
        }
        for invalidPath in ["Z:\\escape.exe", "G:\\..\\escape.exe", "G:\\a/escape.exe", "G:\\game.exe:stream"] {
            var changed = source
            var processes = try #require(changed["processes"] as? [[String: Any]])
            processes[0]["path"] = invalidPath
            changed["processes"] = processes
            #expect(throws: (any Error).self) { try compileSession(changed) }
        }
        var changed = source
        let processes = try #require(changed["processes"] as? [[String: Any]])
        changed["processes"] = [processes[0], processes[0]]
        #expect(throws: (any Error).self) { try compileSession(changed) }
        changed = source
        changed["volumes"] = ["game": "/tmp/arbitrary"]
        #expect(throws: (any Error).self) { try compileSession(changed) }
    }
}
