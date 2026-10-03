// Author: Timur Isaev

import Foundation

public struct ProcessIdentity: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String?
    public var peMachine: PEMachine?
    public var productName: String?
    public var parentPolicyId: String?
    public var commandLine: String
    public var moduleFingerprints: [String]

    public init(
        path: String, sha256: String? = nil, peMachine: PEMachine? = nil, productName: String? = nil,
        parentPolicyId: String? = nil, commandLine: String = "", moduleFingerprints: [String] = []
    ) {
        self.path = path
        self.sha256 = sha256
        self.peMachine = peMachine
        self.productName = productName
        self.parentPolicyId = parentPolicyId
        self.commandLine = commandLine
        self.moduleFingerprints = moduleFingerprints
    }
}

enum ProcessMatcher {
    static func matches(_ match: ProcessMatch, process: ProcessIdentity) throws -> Bool {
        let path = try windowsPath(process.path)
        if let digest = process.sha256, !isHexDigest(digest) {
            throw CompilerFailure.rejected("invalid process digest")
        }
        if let required = match.sha256, required != process.sha256 { return false }
        if let glob = match.pathGlob, try !globMatches(glob, path: path) { return false }
        if let machine = match.peMachine, machine != process.peMachine { return false }
        if let product = match.productName, product != process.productName { return false }
        if let parent = match.parentPolicyId, parent != process.parentPolicyId { return false }
        if let modules = match.moduleFingerprint,
           !Set(modules).isSubset(of: Set(process.moduleFingerprints)) { return false }
        if let pattern = match.commandLineRegex {
            guard process.commandLine.utf8.count <= 4096 else {
                throw CompilerFailure.rejected("command line exceeds matcher limit")
            }
            let expression = try safeExpression(pattern)
            let range = NSRange(process.commandLine.startIndex..., in: process.commandLine)
            guard expression.firstMatch(in: process.commandLine, range: range) != nil else { return false }
        }
        return true
    }

    static func safeExpression(_ pattern: String) throws -> NSRegularExpression {
        // A bounded linear subset: one optional repetition, no groups, backrefs,
        // lookaround, counted repetitions or alternation. Unsupported expressions fail closed.
        guard pattern.utf8.count <= 256,
              !pattern.contains(where: { "(){}|".contains($0) }),
              pattern.filter({ "*+?".contains($0) }).count <= 1,
              pattern.range(of: #"\\[0-9]"#, options: .regularExpression) == nil else {
            throw CompilerFailure.rejected("unsupported command-line regular expression")
        }
        return try NSRegularExpression(pattern: pattern)
    }

    // Dynamic programming bounds work by pattern length × path length, including adversarial globs.
    static func globMatches(_ pattern: String, path: String) throws -> Bool {
        let pattern = Array(try windowsPath(pattern))
        let text = Array(path)
        var previous = [Bool](repeating: false, count: text.count + 1)
        previous[0] = true
        var index = 0
        while index < pattern.count {
            let token = pattern[index]
            let recursive = token == "*" && index + 1 < pattern.count && pattern[index + 1] == "*"
            if recursive { index += 1 }
            var next = [Bool](repeating: false, count: text.count + 1)
            if token == "*" {
                next[0] = previous[0]
                for position in text.indices {
                    next[position + 1] = previous[position + 1]
                        || (next[position] && (recursive || text[position] != "/"))
                }
                // **/ also matches zero directories.
                if recursive, index + 1 < pattern.count, pattern[index + 1] == "/" {
                    var withSlash = previous
                    for position in text.indices where text[position] == "/" {
                        withSlash[position + 1] = withSlash[position + 1] || next[position]
                    }
                    next = withSlash
                    index += 1
                }
            } else {
                for position in text.indices {
                    next[position + 1] = previous[position]
                        && (token == text[position] || (token == "?" && text[position] != "/"))
                }
            }
            previous = next
            index += 1
        }
        return previous[text.count]
    }
}
