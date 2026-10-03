// Author: Timur Isaev

import Foundation

// Every enum below is a direct transcription of one `enum` or `const` array
// in docs/schemas/game-profile.schema.json. SchemaDriftTests compares each
// `allCases` set back against the schema file, so a schema change that adds,
// removes, or renames a value shows up as a failing test here rather than as
// a validator that silently accepts or rejects the wrong thing.

public enum StorefrontKind: String, Codable, CaseIterable, Equatable, Sendable {
    case steam
    case gog
    case epic
    case battleNet = "battle.net"
    case ubisoft
    case rockstar
    case standalone
    case other
}

public enum ProfileLayerRole: String, Codable, CaseIterable, Equatable, Sendable {
    case host
    case wine
    case dependencies
    case profile
    case tooling
}

public enum CPUProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case fexArm64ec = "fex-arm64ec"
    case rosettaX64Bootstrap = "rosetta-x64-bootstrap"
    case nativeArm64ec = "native-arm64ec"
}

public enum GraphicsProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case metal12
    case dxmt
    case moltenvk
}

public enum SyncProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case adaptive
    case waitAddress = "wait-address"
    case machSemaphore = "mach-semaphore"
    case conservative
}

public enum TimezoneMode: String, Codable, CaseIterable, Equatable, Sendable {
    case host
    case fixed
}

public enum DriveTarget: String, Codable, CaseIterable, Equatable, Sendable {
    case runtime
    case game
    case saves
    case settings
    case cache
    case temp
    case userGrant = "user-grant"
}

public enum DriveAccess: String, Codable, CaseIterable, Equatable, Sendable {
    case readOnly = "read-only"
    case readWrite = "read-write"
}

public enum FilesystemCaseMode: String, Codable, CaseIterable, Equatable, Sendable {
    case windowsInsensitive = "windows-insensitive"
    case hostNative = "host-native"
}

public enum RegistryValueType: String, Codable, CaseIterable, Equatable, Sendable {
    case regSZ = "REG_SZ"
    case regExpandSZ = "REG_EXPAND_SZ"
    case regDWORD = "REG_DWORD"
    case regQWORD = "REG_QWORD"
    case regBinary = "REG_BINARY"
    case regMultiSZ = "REG_MULTI_SZ"
}

public enum DependencySource: String, Codable, CaseIterable, Equatable, Sendable {
    case bundledLicensed = "bundled-licensed"
    case storefront
    case publisher
    case userDownload = "user-download"
}

public enum DependencyInstallMode: String, Codable, CaseIterable, Equatable, Sendable {
    case layer
    case firstRun = "first-run"
    case launcherManaged = "launcher-managed"
}

public enum HealthCheckKind: String, Codable, CaseIterable, Equatable, Sendable {
    case processStarted = "process-started"
    case windowCreated = "window-created"
    case moduleLoaded = "module-loaded"
    case logPattern = "log-pattern"
    case framePresented = "frame-presented"
    case cleanExit = "clean-exit"
    case saveWritten = "save-written"
    case networkEndpoint = "network-endpoint"
}

public enum HealthCheckSeverity: String, Codable, CaseIterable, Equatable, Sendable {
    case informational
    case degraded
    case fatal
}

public enum TelemetryLevel: String, Codable, CaseIterable, Equatable, Sendable {
    case off
    case essential
    case diagnostic
    case lab
}

public enum CertificationLevel: String, Codable, CaseIterable, Equatable, Sendable {
    case experimental
    case launches
    case playable
    case certified
    case competitiveCertified = "competitive-certified"
}

public enum PEMachine: String, Codable, CaseIterable, Equatable, Sendable {
    case x86
    case x64
    case arm64
    case arm64ec
}

public enum ExecutionCPUProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case inherit
    case fexArm64ec = "fex-arm64ec"
    case rosettaX64Bootstrap = "rosetta-x64-bootstrap"
    case nativeArm64ec = "native-arm64ec"
}

public enum ExecutionGraphicsProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case inherit
    case metal12
    case dxmt
    case moltenvk
}

public enum ExecutionSyncProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case inherit
    case adaptive
    case waitAddress = "wait-address"
    case machSemaphore = "mach-semaphore"
    case conservative
}

public enum DLLLoadOrder: String, Codable, CaseIterable, Equatable, Sendable {
    case builtin
    case native
    case disabled
    case nativeBuiltin = "native,builtin"
    case builtinNative = "builtin,native"
}

public enum ProcessNetworkPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case inherit
    case allow
    case deny
    case publisherOnly = "publisher-only"
}

public enum ProcessDebugPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case off
    case crashOnly = "crash-only"
    case diagnostic
    case capture
}
