// Author: Timur Isaev

import Darwin
import Foundation
import Metal

public struct HostCapabilities: Codable, Equatable, Sendable {
    public var architecture: String
    public var macOS: String
    public var macOSBuild: String
    public var gpuFamilies: [String]
    public var memoryGiB: Int
    public var features: [String]
    public var entitlements: [String]

    public init(
        architecture: String, macOS: String, macOSBuild: String, gpuFamilies: [String], memoryGiB: Int,
        features: [String] = [], entitlements: [String] = []
    ) {
        self.architecture = architecture
        self.macOS = macOS
        self.macOSBuild = macOSBuild
        self.gpuFamilies = gpuFamilies
        self.memoryGiB = memoryGiB
        self.features = features
        self.entitlements = entitlements
    }

    /// Local placeholder, never a control-plane `hc_` identifier.
    public func localClassId() throws -> String {
        guard memoryGiB >= 8, !macOSBuild.isEmpty, macOSBuild.utf8.count <= 64 else {
            throw CompilerFailure.rejected("invalid host memory class or OS build")
        }
        var normalized = self
        normalized.macOS = try SemanticVersion(macOS).description
        normalized.gpuFamilies = Array(Set(gpuFamilies)).sorted()
        normalized.features = Array(Set(features)).sorted()
        normalized.entitlements = Array(Set(entitlements)).sorted()
        return "local-unregistered:" + CanonicalJSON.digest(try CanonicalJSON.encode(normalized)).dropFirst(7)
    }

    public static func current() throws -> Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var length = 0
        guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 1 else {
            throw CompilerFailure.rejected("cannot read macOS build")
        }
        var build = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.osversion", &build, &length, nil, 0) == 0 else {
            throw CompilerFailure.rejected("cannot read macOS build")
        }
        var families: [String] = []
        if let device = MTLCreateSystemDefaultDevice() {
            let known: [MTLGPUFamily] = [
                .apple1, .apple2, .apple3, .apple4, .apple5, .apple6, .apple7, .apple8, .apple9
            ]
            for (index, family) in known.enumerated() where device.supportsFamily(family) {
                families.append("apple\(index + 1)")
            }
            if #available(macOS 26.0, *), device.supportsFamily(.apple10) { families.append("apple10") }
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        guard let buildString = String(bytes: build.dropLast().map({ UInt8(bitPattern: $0) }), encoding: .utf8) else {
            throw CompilerFailure.rejected("invalid macOS build encoding")
        }
        return Self(
            architecture: architecture,
            macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            macOSBuild: buildString,
            gpuFamilies: families, memoryGiB: Int(ProcessInfo.processInfo.physicalMemory / (1 << 30))
        )
    }

    public func matches(_ selector: HostSelector) throws -> Bool {
        guard architecture == selector.architecture else { return false }
        let version = try SemanticVersion(macOS)
        if let minimum = selector.macos?.min, version < (try SemanticVersion(minimum)) { return false }
        if let maximum = selector.macos?.maxExclusive, version >= (try SemanticVersion(maximum)) { return false }
        if let builds = selector.macos?.allowedBuilds, !builds.contains(macOSBuild) { return false }
        if let families = selector.gpuFamilies, Set(families).isDisjoint(with: gpuFamilies) { return false }
        if let classes = selector.memoryClassesGiB, !classes.contains(memoryGiB) { return false }
        return true
    }

    public func matches(_ requirements: RuntimeHostRequirements) throws -> Bool {
        let version = try SemanticVersion(macOS)
        let minimum = try SemanticVersion(requirements.minimumMacOS)
        return architecture == requirements.architecture
            && version >= minimum
            && Set(requirements.metalFeatureSets ?? []).isSubset(of: Set(features + gpuFamilies))
            && Set(requirements.requiredEntitlements ?? []).isSubset(of: Set(entitlements))
    }
}

struct SemanticVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init(_ text: String) throws {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), components.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && Int($0) != nil
        }) else { throw CompilerFailure.rejected("invalid numeric version: \(text)") }
        parts = components.map { Int($0)! } + Array(repeating: 0, count: 3 - components.count)
    }

    var description: String { parts.map(String.init).joined(separator: ".") }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}
