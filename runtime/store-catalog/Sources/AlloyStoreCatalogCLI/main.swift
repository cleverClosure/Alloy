// Author: Timur Isaev
import AlloyStoreCatalog
import Foundation

@main
struct CatalogCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 2 else {
                throw CatalogError.invalidInput("usage: alloy-store-catalog list|discover|get|fingerprint LIBRARY [ID]")
            }
            let catalog = try StoreCatalog(libraryRoots: [URL(fileURLWithPath: args[1])])
            switch args[0] {
            case "list": try printJSON(catalog.listGames())
            case "discover": try printJSON(catalog.discoverInstallations())
            case "get" where args.count == 3: try printJSON(catalog.getGame(args[2]))
            case "fingerprint" where args.count == 3: try printJSON(catalog.refreshBuildFingerprint(args[2]))
            default: throw CatalogError.invalidInput("unknown command or wrong argument count")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value) + Data("\n".utf8))
    }
}
