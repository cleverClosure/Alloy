// Author: Timur Isaev

import AlloyTrust
import Darwin
import Foundation

let usage = """
Development/lab only. Keys stay outside Git in a private directory.
alloy-trust-dev init DIR [development|lab]
alloy-trust-dev sign DIR TYPE INPUT OUTPUT-BASENAME
alloy-trust-dev timestamp DIR
alloy-trust-dev rotate DIR ROLE
alloy-trust-dev revoke DIR profile ID REVISION
alloy-trust-dev revoke DIR key KEY-ID
alloy-trust-dev revoke DIR digest PAYLOAD-DIGEST
"""

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else { throw TrustError.malformed(usage) }
    let repository = try DevelopmentRepository(arguments[1])
    let now = Date()
    switch arguments[0] {
    case "init" where arguments.count == 2 || arguments.count == 3:
        guard let scope = TrustScope(rawValue: arguments.count == 3 ? arguments[2] : "development") else {
            throw TrustError.malformed("development or lab scope required")
        }
        let pin = try repository.initialize(scope: scope, now: now)
        print("Development root initialized; pin the exact 1.root.json out of band: \(pin)")
    case "sign" where arguments.count == 5:
        try repository.signArtifact(type: arguments[2], input: URL(fileURLWithPath: arguments[3]),
                                    output: arguments[4], now: now)
        print("Signed development artifact and refreshed metadata")
    case "timestamp" where arguments.count == 2:
        try repository.timestamp(now: now)
        print("Refreshed snapshot and timestamp")
    case "rotate" where arguments.count == 3:
        guard let role = TrustRole(rawValue: arguments[2]) else { throw TrustError.wrongRole }
        try repository.rotate(role: role, now: now)
        print("Published cross-signed development root successor")
    case "revoke" where arguments.count == 4 || arguments.count == 5:
        try repository.revoke(kind: arguments[2], value: arguments[3],
                              revision: arguments.count == 5 ? Int(arguments[4]) : nil, now: now)
        print("Published development revocation and refreshed metadata")
    default: throw TrustError.malformed(usage)
    }
} catch {
    fputs("alloy-trust-dev: \(error)\n", stderr)
    exit(1)
}
