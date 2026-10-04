// Author: Timur Isaev

import Foundation

private enum FixtureGeneratorError: Error {
    case usage
}

private func fixtureLayer(
    name: String,
    version: String,
    payload: String,
    role: LayerRole
) -> LayerInput {
    let data = Data(payload.utf8)
    return LayerInput(
        descriptor: LayerDescriptor(
            name: name,
            version: version,
            digest: ContentStore.digest(data),
            mediaType: "application/vnd.alloy.compatibility-fixture",
            size: data.count,
            role: role,
            sourceRevision: "main-21136e4",
            licenseID: "LicenseRef-Fixture"
        ),
        contents: data
    )
}

@main
private enum Main21136e4FixtureGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw FixtureGeneratorError.usage
        }
        let root = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        let store = try ContentStore(root: root)
        let shared = fixtureLayer(
            name: "runtime",
            version: "1",
            payload: "shared-runtime-payload-v1",
            role: .hostRuntime
        )
        _ = try store.activate(
            gameID: "fixture-game",
            generationID: "generation-a",
            layers: [
                shared,
                fixtureLayer(
                    name: "profile",
                    version: "a",
                    payload: "generation-a-profile",
                    role: .profile
                )
            ]
        )
        try store.writeSave(
            gameID: "fixture-game",
            name: "compatibility.sav",
            data: Data("save-sentinel-main-21136e4".utf8)
        )
        _ = try store.activate(
            gameID: "fixture-game",
            generationID: "generation-b",
            layers: [
                shared,
                fixtureLayer(
                    name: "profile",
                    version: "b",
                    payload: "generation-b-profile",
                    role: .profile
                )
            ]
        )
    }
}
