// Author: Timur Isaev

import AlloyDiagnostics
import Foundation

@main
struct DiagnosticsOracle {
  static func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 3, arguments[0] == "generate" {
      let rows = try SyntheticLaboratory.generateEight(
        at: URL(fileURLWithPath: arguments[1]), subject: URL(fileURLWithPath: arguments[2])
      )
      for row in rows { print("\(row.fixture): expected=\(row.expected.rawValue) observed=\(row.observed.rawValue)") }
    } else if arguments.count == 2, arguments[0] == "classify" {
      let bundle = try SealedBundleReader.read(URL(fileURLWithPath: arguments[1]))
      print(FailureClassifier.classify(bundle).rawValue)
    } else {
      throw LaboratoryError.unsupportedScenario
    }
  }
}
