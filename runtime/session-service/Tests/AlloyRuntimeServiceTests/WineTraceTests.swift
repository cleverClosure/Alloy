// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyRuntimeService

@Test func wineTraceRetainsShortLivedChildrenAndRejectsMissingEvidence() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/wine-process.trace")
    let bytes = try Data(contentsOf: fixture)
    let trace = WineTrace(session: "test", rootPID: 100, entry: "G:\\launcher.exe")
    // Split on arbitrary byte boundaries, including the middle of protocol lines.
    for offset in stride(from: 0, to: bytes.count, by: 17) {
        try trace.append(bytes[offset..<min(offset + 17, bytes.count)])
    }
    try trace.validateComplete()
    #expect(trace.processes.count == 10)
    #expect(Set(trace.processes.map(\.identifier)).count == 10)
    #expect(trace.processes.allSatisfy { $0.exited })
    #expect(trace.processes.first?.imagePath == "G:\\launcher.exe")
    #expect(trace.processes.dropFirst().allSatisfy { $0.parentIdentifier != nil })
    let empty = WineTrace(session: "zero", rootPID: 100, entry: "G:\\launcher.exe")
    #expect(throws: (any Error).self) { try empty.validateComplete() }
    let truncated = WineTrace(session: "short", rootPID: 100, entry: "G:\\launcher.exe")
    try truncated.append(bytes.dropLast(80))
    #expect(throws: (any Error).self) { try truncated.validateComplete() }
    let unmatched = WineTrace(session: "bad", rootPID: 100, entry: "G:\\launcher.exe")
    #expect(throws: (any Error).self) { try unmatched.append(Data("0020: *process killed*\n".utf8)) }
}
