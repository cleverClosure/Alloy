// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

@Suite("Full profile-manifest-host pipeline fuzzing")
struct FullPipelineFuzzTests {
    @Test func seededControlsAnd512FullTupleIterations() throws {
        var random = PipelineRandom()
        let seed = random.state
        try verifySeededControls()
        var rejected = 0
        var accepted = 0
        var categories = Set<String>()
        for index in 0..<512 {
            let clean = try validPipelineVariant(index: index, random: &random)
            let result = try LaunchCompiler.compile(clean)
            try auditPipelineOutcome(shouldReject: false, output: result)
            try auditAgainstInputs(result, input: clean)
            accepted += 1
            #expect(try LaunchCompiler.verifyExport(result.canonicalJSON, input: clean).componentDigests
                == result.specification.componentDigests)
            let mutation = PipelineMutation.allCases[index % PipelineMutation.allCases.count]
            categories.insert(mutation.rawValue)
            let bad = try invalidPipelineVariant(clean, mutation: mutation)
            let output: CompiledLaunch?
            do {
                output = try LaunchCompiler.compile(bad)
            } catch {
                output = nil
                rejected += 1
            }
            try auditPipelineOutcome(shouldReject: true, output: output)
        }
        #expect(accepted == 512)
        #expect(rejected == 512)
        #expect(categories == Set(PipelineMutation.allCases.map(\.rawValue)))
        print("Pipeline fuzz seed=\(seed) iterations=512 clean=\(accepted) rejected=\(rejected) "
            + "categories=\(categories.count) seeded-controls=14 false-accepts=0 crashes=0")
    }

    private func verifySeededControls() throws {
        let baseline = try launchFixture()
        let baselineOutput = try LaunchCompiler.compile(baseline)
        var controlRandom = PipelineRandom()
        let changedInputs = try validPipelineVariant(index: 100, random: &controlRandom)
        try requireRejection(.invalidOutput) { try auditAgainstInputs(baselineOutput, input: changedInputs) }
        // Prove that the audit itself rejects a false acceptance for EVERY category.
        // Then send one actual seeded bad tuple per category through the real compiler.
        for mutation in PipelineMutation.allCases {
            try requireRejection(.falseAccept) {
                try auditPipelineOutcome(shouldReject: true, output: baselineOutput)
            }
            let bad = try invalidPipelineVariant(baseline, mutation: mutation)
            try requireRejection { _ = try LaunchCompiler.compile(bad) }
        }
    }

    private func requireRejection(_ expected: FuzzAuditFailure? = nil, operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            if let expected, error as? FuzzAuditFailure != expected { throw error }
            return
        }
        throw CompilerFailure.rejected("seeded fuzz control failed; refusing to trust the clean run")
    }

}
