// Author: Timur Isaev

import Foundation

enum FixtureKind: String {
    case gameProfile = "GameProfile"
    case runtimeManifest = "RuntimeManifest"
}

/// `Tests/<Kind>/{valid,invalid}/<fixture>.json`, resolved from this source
/// file's own location the same way the store-identity and content-store
/// test suites locate their fixtures — no SPM resource bundle involved.
private let fixturesRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures", isDirectory: true)

func fixtureURL(_ kind: FixtureKind, _ subpath: String) -> URL {
    fixturesRoot
        .appendingPathComponent(kind.rawValue, isDirectory: true)
        .appendingPathComponent(subpath, isDirectory: false)
}

func fixtureData(_ kind: FixtureKind, _ subpath: String) throws -> Data {
    try Data(contentsOf: fixtureURL(kind, subpath))
}

/// Every `.json` file directly inside `<kind>/<bucket>/`, sorted for a
/// deterministic test order. Used so a fixture dropped into one of these
/// directories is swept automatically instead of waiting for someone to list
/// it by hand.
func fixtureNames(_ kind: FixtureKind, bucket: String) throws -> [String] {
    let directory = fixturesRoot
        .appendingPathComponent(kind.rawValue, isDirectory: true)
        .appendingPathComponent(bucket, isDirectory: true)
    return try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()
}
