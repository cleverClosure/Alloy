// Author: Timur Isaev

import AlloyContentStore
import Foundation

enum RuntimeCLIError: Error { case usage, invalidManifest, hostRequirement }

func loadManifest(_ package: URL) throws -> (String, [LayerDescriptor]) {
    let bytes = try Data(contentsOf: package.appendingPathComponent("runtime-manifest.json"))
    guard bytes.count <= 16_777_216,
        let manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        manifest["schemaVersion"] as? String == "1.0",
        let generation = manifest["generationId"] as? String, generation.hasPrefix("rtg_"),
        (20...100).contains(generation.count),
        let components = manifest["components"] as? [[String: Any]], !components.isEmpty,
        let activation = manifest["activation"] as? [String: Any],
        activation["releaseRing"] as? String == "development",
        let host = manifest["hostRequirements"] as? [String: Any], host["architecture"] as? String == "arm64",
        let minimum = host["minimumMacOS"] as? String,
        let provenance = manifest["provenance"] as? [String: Any]
    else { throw RuntimeCLIError.invalidManifest }
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let current = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    guard current.compare(minimum, options: .numeric) != .orderedAscending else {
        throw RuntimeCLIError.hostRequirement
    }
    for (field, name) in [("buildRecipeDigest", "build-recipe.json"), ("attestationDigest", "provenance.json")] {
        let contents = try Data(contentsOf: package.appendingPathComponent(name))
        guard provenance[field] as? String == ContentStore.digest(contents) else {
            throw RuntimeCLIError.invalidManifest
        }
    }
    let sbom = ContentStore.digest(try Data(contentsOf: package.appendingPathComponent("sbom.json")))
    var descriptors: [LayerDescriptor] = []
    var names = Set<String>()
    for component in components {
        guard let name = component["name"] as? String, let role = LayerRole(rawValue: name),
            names.insert(name).inserted, component["sbomDigest"] as? String == sbom
        else {
            throw RuntimeCLIError.invalidManifest
        }
        var withRole = component
        withRole["role"] = role.rawValue
        let data = try JSONSerialization.data(withJSONObject: withRole)
        descriptors.append(try JSONDecoder().decode(LayerDescriptor.self, from: data))
    }
    return (generation, descriptors)
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    let runtime: MaterializedRuntime
    if args.count == 4 && args[0] == "import-development" {
        let package = URL(fileURLWithPath: args[1], isDirectory: true)
        let store = try ContentStore(root: URL(fileURLWithPath: args[2], isDirectory: true))
        let (generation, layers) = try loadManifest(package)
        for descriptor in layers {
            try store.importDevelopmentLayer(
                from: package.appendingPathComponent(descriptor.name + ".layer.tar.zst"), descriptor: descriptor
            )
        }
        _ = try store.activateImportedLayers(gameID: args[3], generationID: generation, layers: layers)
        runtime = try store.materializeDevelopmentRuntime(gameID: args[3])
    } else if args.count == 3 && args[0] == "verify" {
        let store = try ContentStore(root: URL(fileURLWithPath: args[1], isDirectory: true))
        runtime = try store.verifyDevelopmentRuntime(gameID: args[2])
    } else {
        throw RuntimeCLIError.usage
    }
    let result = [
        "path": runtime.url.path, "treeDigest": runtime.treeDigest,
        "generationId": runtime.reference.generationID, "manifestDigest": runtime.reference.manifestDigest
    ]
    let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    guard let text = String(bytes: output, encoding: .utf8) else { throw RuntimeCLIError.invalidManifest }
    print(text)
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
