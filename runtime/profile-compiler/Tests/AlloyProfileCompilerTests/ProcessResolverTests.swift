// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

@Suite("Process precedence and conservative routing")
struct ProcessResolverTests {
    @Test func pairedPrecedenceGoldens() throws {
        let rows = try #require(JSONSerialization.jsonObject(
            with: extraFixture("Resolver/process-precedence.json")
        ) as? [[String: Any]])
        #expect(rows.count == 7)
        let runtime = try GameProfileValidator.validate(compilerProfile()).runtime
        var parent = ResolvedProcessPolicy.conservativeDefault(runtime)
        parent.ruleIds = ["launcher"]
        parent.graphicsProvider = "metal12"
        parent.networkPolicy = "allow"
        for row in rows {
            let name = try #require(row["name"] as? String)
            for variant in ["clean", "counterfactual"] {
                let scenario = try #require(row[variant] as? [String: Any])
                let policies = try decodePolicies(try #require(scenario["rules"]))
                let process = ProcessIdentity(
                    path: scenario["path"] as? String ?? "C:\\Games\\Game.exe",
                    sha256: String(repeating: "a", count: 64), parentPolicyId: "launcher"
                )
                for iteration in 0..<10 {
                    let ordered = iteration.isMultiple(of: 2) ? policies : policies.reversed()
                    if scenario["conflict"] as? Bool == true {
                        #expect(throws: CompilerFailure.rejected("process-policy-conflict")) {
                            try ProcessResolver.resolve(ordered, runtime: runtime, process: process, parent: parent)
                        }
                    } else {
                        let result = try ProcessResolver.resolve(
                            ordered, runtime: runtime, process: process, parent: parent
                        )
                        #expect(result.ruleIds == scenario["expectedRuleIds"] as? [String], "\(name) \(variant)")
                        #expect(result.graphicsProvider == scenario["graphics"] as? String, "\(name) \(variant)")
                        #expect(result.networkPolicy == scenario["network"] as? String, "\(name) \(variant)")
                        if let disabled = scenario["disabled"] as? String {
                            #expect(result.dllOverrides[disabled] == "disabled")
                        }
                    }
                }
            }
        }
    }

    @Test func allMatchDimensionsAndGlobBoundaries() throws {
        let digest = String(repeating: "a", count: 64)
        let policies = try decodePolicies([[
            "id": "all", "priority": 1,
            "match": ["pathGlob": "**/game.exe", "sha256": digest, "peMachine": "x64",
                      "productName": "Game", "parentPolicyId": "launcher", "commandLineRegex": "^--safe$",
                      "moduleFingerprint": ["module-a"]],
            "execution": ["graphicsProvider": "metal12"]
        ]])
        let policy = try #require(policies.first)
        let clean = ProcessIdentity(
            path: "Game.exe", sha256: digest, peMachine: .x64, productName: "Game", parentPolicyId: "launcher",
            commandLine: "--safe", moduleFingerprints: ["module-a"]
        )
        #expect(try ProcessMatcher.matches(policy.match, process: clean))
        let changes: [(inout ProcessIdentity) -> Void] = [
            { $0.path = "other.exe" }, { $0.sha256 = String(repeating: "b", count: 64) }, { $0.peMachine = .x86 },
            { $0.productName = "Other" }, { $0.parentPolicyId = "other" }, { $0.commandLine = "--unsafe" },
            { $0.moduleFingerprints = [] }
        ]
        for change in changes {
            var invalid = clean
            change(&invalid)
            #expect(try !ProcessMatcher.matches(policy.match, process: invalid))
        }
        #expect(try ProcessMatcher.globMatches("**/game.exe", path: "game.exe"))
        #expect(try ProcessMatcher.globMatches("**/game.exe", path: "a/b/game.exe"))
        #expect(try !ProcessMatcher.globMatches("*/game.exe", path: "a/b/game.exe"))
        #expect(try !ProcessMatcher.globMatches("**/game.exe", path: "a/game.exe.bak"))
        #expect(try ProcessMatcher.globMatches("a/?.exe", path: "a/x.exe"))
        #expect(throws: (any Error).self) { try ProcessMatcher.safeExpression("(a+)+$") }
    }

    @Test func inheritanceCannotUseAnUnrelatedParentAndIdsAreUnique() throws {
        let runtime = try GameProfileValidator.validate(compilerProfile()).runtime
        let policies = try decodePolicies([[
            "id": "child", "priority": 1, "match": ["pathGlob": "**/*.exe"],
            "execution": ["cpuProvider": "inherit"]
        ]])
        let process = ProcessIdentity(path: "game.exe", parentPolicyId: "actual-parent")
        var wrongParent = ResolvedProcessPolicy.conservativeDefault(runtime)
        wrongParent.ruleIds = ["unrelated-parent"]
        #expect(throws: (any Error).self) {
            try ProcessResolver.resolve(policies, runtime: runtime, process: process, parent: wrongParent)
        }
        #expect(throws: (any Error).self) {
            try ProcessResolver.resolve(policies + policies, runtime: runtime, process: process)
        }
    }
}
