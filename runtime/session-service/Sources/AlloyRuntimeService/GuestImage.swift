// Author: Timur Isaev

import AlloyContentStore
import AlloyProfileCompiler
import AlloyRuntimeAPI
import Foundation

enum GuestImage {
    static func verify(_ bytes: Data, machine: PEMachine, digest: String) throws {
        guard bytes.count >= 64, bytes[0] == 0x4d, bytes[1] == 0x5a else {
            throw RuntimeFailure.status(.payloadIntegrity)
        }
        let offset = (0..<4).reduce(0) { $0 | (Int(bytes[0x3c + $1]) << ($1 * 8)) }
        guard offset >= 64, offset <= bytes.count - 24,
              Array(bytes[offset..<(offset + 4)]) == [0x50, 0x45, 0, 0] else {
            throw RuntimeFailure.status(.payloadIntegrity)
        }
        let observed = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
        let flags = Int(bytes[offset + 22]) | Int(bytes[offset + 23]) << 8
        guard observed == (machine == .arm64 ? 0xaa64 : 0x8664),
              [.arm64, .x64].contains(machine), flags & 0x2000 == 0, flags & 2 != 0,
              ContentStore.digest(bytes) == "sha256:" + digest else {
            throw RuntimeFailure.status(.payloadIntegrity)
        }
    }
}
