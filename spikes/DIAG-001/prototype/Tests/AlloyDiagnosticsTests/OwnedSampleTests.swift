// Author: Timur Isaev
import Darwin
import Foundation
import Testing
@testable import AlloyDiagnostics

struct OwnedSampleTests {
  private func correlation() throws -> CorrelationID {
    let fixture = try #require(Bundle.module.url(
      forResource: "event-v1", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(StructuredEvent.self, from: Data(contentsOf: fixture)).correlation
  }

  @Test func staleOwnerCannotBeSampled() throws {
    #expect(throws: CaptureError.missingEvidence("owned-process-identity")) {
      try NativeCapture.sampleOwned(processID: getpid(), startedSeconds: 1,
                                    startedMicroseconds: 0, correlation: correlation())
    }
  }

  @Test func invalidBorrowedCaptureBudgetIsRefused() throws {
    #expect(throws: CaptureError.invalidConfiguration) {
      try NativeCapture.sampleOwned(processID: getpid(), startedSeconds: 1,
                                    startedMicroseconds: 0, correlation: correlation(), timeoutSeconds: 1)
    }
  }
}
