// Author: Timur Isaev

import Foundation

enum V2Decoder {
    static func source(_ bytes: Data) throws -> V2Source {
        do {
            return try readSource(bytes)
        } catch let error as PolicySnapshotV2Error {
            throw error
        } catch {
            throw PolicySnapshotV2Error.layout
        }
    }

    private static func readSource(_ bytes: Data) throws -> V2Source {
        var cursor = DataCursor(bytes)
        guard try cursor.read(8) == V2Format.magic,
              try cursor.readUInt32() == 2,
              try cursor.readUInt32() == 0x0102_0304,
              try cursor.readUInt32() == V2Format.header,
              try cursor.readUInt32() == V2Format.entry else { throw PolicySnapshotV2Error.layout }
        let count = Int(try cursor.readUInt32())
        guard (1...V2Format.maxEntries).contains(count), try cursor.readUInt32() == 0,
              bytes.count == V2Format.header + count * V2Format.entry else { throw PolicySnapshotV2Error.layout }
        _ = try cursor.read(64)
        guard try cursor.read(32) == Data(repeating: 0, count: 32) else {
            throw PolicySnapshotV2Error.noncanonical
        }
        let fallback = try policy(&cursor)
        var processes: [V2Process] = []
        for _ in 1..<count {
            let digest = encodeHex(try cursor.read(32))
            processes.append(V2Process(imageSHA256: digest, policy: try policy(&cursor)))
        }
        return V2Source(schemaVersion: 2, defaultPolicy: fallback, processPolicies: processes)
    }

    private static func policy(_ cursor: inout DataCursor) throws -> V2Policy {
        let identifier = try cursor.readFixedUTF8(size: 64)
        let graphics = try cursor.readFixedUTF8(size: 64)
        let directory = try cursor.readFixedUTF8(size: 512)
        let presence = try cursor.readUInt32()
        let cpuCode = try cursor.readUInt32()
        let routeCount = Int(try cursor.readUInt32())
        let environmentCount = Int(try cursor.readUInt32())
        guard presence & ~31 == 0, routeCount <= V2Format.maxRoutes,
              environmentCount <= V2Format.maxEnvironment,
              cpuCode <= 2 else { throw PolicySnapshotV2Error.invalidField }
        let working = try cursor.readFixedUTF8(size: 512)
        let routes = try routes(&cursor, count: routeCount)
        var environment: [String: String] = [:]
        for index in 0..<V2Format.maxEnvironment {
            let key = try cursor.readFixedUTF8(size: 64)
            let value = try cursor.readFixedUTF8(size: 256)
            if index < environmentCount {
                guard environment.updateValue(value, forKey: key) == nil else {
                    throw PolicySnapshotV2Error.noncanonical
                }
            } else if !key.isEmpty || !value.isEmpty { throw PolicySnapshotV2Error.noncanonical }
        }
        return V2Policy(
            id: identifier, graphicsProvider: presence & 1 != 0 ? graphics : nil,
            providerDirectory: presence & 1 != 0 ? directory : nil,
            cpuProvider: cpuCode == 1 ? .nativeArm64ec : cpuCode == 2 ? .fexArm64ec : nil,
            environment: presence & 4 != 0 ? environment : nil,
            workingDirectory: presence & 8 != 0 ? working : nil,
            dllRoutes: presence & 16 != 0 ? routes : nil
        )
    }

    private static func routes(_ cursor: inout DataCursor, count: Int) throws -> [V2Route] {
        let orders: [LoadOrder] = [.disabled, .native, .builtin, .nativeBuiltin, .builtinNative]
        var routes: [V2Route] = []
        for index in 0..<V2Format.maxRoutes {
            let module = try cursor.readFixedUTF8(size: 32)
            let order = Int(try cursor.readUInt32())
            if index < count {
                guard (1...5).contains(order) else { throw PolicySnapshotV2Error.invalidField }
                routes.append(V2Route(module: module, loadOrder: orders[order - 1]))
            } else if !module.isEmpty || order != 0 { throw PolicySnapshotV2Error.noncanonical }
        }
        return routes
    }
}
