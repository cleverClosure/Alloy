// Author: Timur Isaev

import Foundation
import Testing
import AlloyStoreIdentity

@Suite("Synthetic multi-title selector identity")
struct MultiTitleSelectorTests {
    @Test("each selector uses its own exact installed executable path")
    func distinctTitleImages() throws {
        for path in ["Orchard.exe", "bin/港の旅.exe", "engine/Atlas-Win64.exe"] {
            let fingerprint = try makeFingerprint(path: path)
            let selector = try makeSelector(path: path, fingerprint: fingerprint)
            #expect(selector.matches(fingerprint))
            let registry = try SelectorRegistry(selectors: [selector])
            let decoded = try SelectorRegistry.decode(registry.canonicalJSON())
            #expect(decoded.matchingSelectors(for: fingerprint) == [selector])

            let wrongPath = try makeSelector(path: "elsewhere.exe", fingerprint: fingerprint)
            #expect(!wrongPath.matches(fingerprint))
            let wrongDigest = try makeSelector(
                path: path, fingerprint: fingerprint, imageDigest: String(repeating: "b", count: 64)
            )
            #expect(!wrongDigest.matches(fingerprint))
        }
    }

    @Test("launch aliases bind exactly one installed image and keep equal digests")
    func launchAliases() throws {
        let fingerprint = try makeFingerprint(path: "bin/港の旅.exe")
        let digest = String(repeating: "a", count: 64)
        let good = ["bin/港の旅.exe": digest, "executableSHA256": digest,
                    "processPolicies[].imageSHA256": digest]
        #expect(try makeSelector(fingerprint: fingerprint, kind: "launch-policy", hashes: good)
            .matches(fingerprint))
        var missingAlias = good
        missingAlias.removeValue(forKey: "executableSHA256")
        var mismatchedAlias = good
        mismatchedAlias["executableSHA256"] = String(repeating: "b", count: 64)
        for hashes in [missingAlias, mismatchedAlias, ["bin/港の旅.exe": digest]] {
            #expect(throws: SelectorRegistryError.invalidField("image_hashes")) {
                try makeSelector(fingerprint: fingerprint, kind: "launch-policy", hashes: hashes)
            }
        }
    }

    @Test("unsafe, alias-only, and multiple installed image keys are refused exactly")
    func malformedImageKeys() throws {
        let fingerprint = try makeFingerprint(path: "Orchard.exe")
        let digest = String(repeating: "a", count: 64)
        for path in ["../game.exe", "/game.exe", "bin//game.exe", "./game.exe",
                     "bin/../game.exe", "bad\nname.exe", "executableSHA256",
                     "processPolicies[].imageSHA256"] {
            #expect(throws: SelectorRegistryError.invalidField("image_hashes")) {
                try makeSelector(path: path, fingerprint: fingerprint)
            }
        }
        for hashes in [[:], ["Orchard.exe": digest, "Other.exe": digest],
                       ["Orchard.exe": digest, "executableSHA256": digest]] {
            #expect(throws: SelectorRegistryError.invalidField("image_hashes")) {
                try makeSelector(fingerprint: fingerprint, kind: "fingerprint", hashes: hashes)
            }
        }
    }

    @Test("missing DLC depot, changed manifest, and different title cannot match")
    func exactDepotAndTitleIdentity() throws {
        let anchor = try makeFingerprint(path: "Orchard.exe")
        let selector = try makeSelector(path: "Orchard.exe", fingerprint: anchor)
        let firstDepot = try #require(anchor.depots["910011"])
        let variants = [
            try FingerprintIdentity(appID: "910001", name: anchor.name, buildID: anchor.buildID,
                                    depots: ["910011": firstDepot]),
            try FingerprintIdentity(appID: "910001", name: anchor.name, buildID: anchor.buildID,
                                    depots: ["910011": firstDepot,
                                             "910012": FingerprintDepotRecord(manifest: "3", size: "1")]),
            try FingerprintIdentity(appID: "910002", name: anchor.name, buildID: anchor.buildID,
                                    depots: anchor.depots)
        ]
        for identity in variants {
            #expect(!selector.matches(try FingerprintRecord(identity: identity, files: anchor.files)))
        }
        #expect(selector.matches(anchor))
    }

    private func makeFingerprint(path: String) throws -> FingerprintRecord {
        let identity = try FingerprintIdentity(
            appID: "910001", name: "Synthetic Orchard", buildID: "10000001",
            depots: ["910011": FingerprintDepotRecord(manifest: "1", size: "1"),
                     "910012": FingerprintDepotRecord(manifest: "2", size: "1")]
        )
        return try FingerprintRecord(identity: identity, files: [
            FingerprintFileRecord(path: path, size: 1, sha256: String(repeating: "a", count: 64))
        ])
    }

    private func makeSelector(
        path: String, fingerprint: FingerprintRecord, imageDigest: String = String(repeating: "a", count: 64)
    ) throws -> BuildSelector {
        try makeSelector(fingerprint: fingerprint, kind: "fingerprint", hashes: [path: imageDigest])
    }

    private func makeSelector(
        fingerprint: FingerprintRecord, kind: String, hashes: [String: String]
    ) throws -> BuildSelector {
        try BuildSelector(
            selectorID: "synthetic.breadth.910001",
            artifact: EvidenceArtifact(
                kind: kind, path: "synthetic/anchor.json", sha256: String(repeating: "c", count: 64)
            ),
            storefront: "steam", gameID: fingerprint.appID, storeBuildID: fingerprint.buildID,
            manifestIDs: fingerprint.depots.mapValues(\.manifest),
            aggregateSHA256: fingerprint.aggregateSHA256, imageHashes: hashes
        )
    }
}
