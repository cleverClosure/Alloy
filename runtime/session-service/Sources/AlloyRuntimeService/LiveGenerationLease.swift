// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import Foundation

/// A lease already issued by ContentStore is checked by exact private record and
/// kernel identity. Issuance and initial runtime verification use ContentStore;
/// its catalog-rebuilding API is deliberately outside the supervision loop.
enum LiveGenerationLease {
    static func require(_ lease: GenerationLease, contentRoot: String) throws {
        let path = URL(fileURLWithPath: contentRoot).appendingPathComponent("metadata/leases")
            .appendingPathComponent(lease.leaseID + ".json")
        guard NativeProcessIdentity.isLive(lease.holder),
              let persisted = try? PrivateRecords.read(GenerationLease.self, from: path), persisted == lease else {
            throw RuntimeFailure.status(.leaseMissing)
        }
    }
}
