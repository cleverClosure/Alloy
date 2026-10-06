// Author: Timur Isaev

import AlloyRuntimeAPI
import Foundation

/// Complete pinned-server protocol stream, not a periodic process sampler.
final class WineTrace {
    private struct Creation { let image: String; let parent: String? }
    private var creations: [String: Creation] = [:]
    private var initializers: [String: Int32] = [:]
    private var threads: [String: String] = [:]
    private var active: [String: Int] = [:]
    private var pending = Data()
    private let session: String
    private let rootPID: Int32
    private let entry: String
    private(set) var processes: [WineProcess] = []
    private(set) var serverStart: String?
    private(set) var started = false
    private(set) var bytesRead = 0

    init(session: String, rootPID: Int32, entry: String) {
        self.session = session
        self.rootPID = rootPID
        self.entry = entry
    }

    func append(_ bytes: Data) throws {
        bytesRead += bytes.count
        guard bytesRead <= 16 << 20 else { throw RuntimeFailure.status(.oversized) }
        pending.append(bytes)
        var cursor = pending.startIndex
        while let newline = pending[cursor...].firstIndex(of: 10) {
            guard let line = String(data: pending[cursor..<newline], encoding: .utf8) else { throw failure() }
            try consume(line)
            cursor = pending.index(after: newline)
        }
        pending = Data(pending[cursor...])
        guard pending.count <= 256 << 10 else { throw failure() }
    }

    func confirmNativeExit(_ identifiers: Set<String>) {
        for index in processes.indices where identifiers.contains(processes[index].identifier) {
            processes[index].exited = true
        }
    }

    func validateComplete() throws {
        guard started, serverStart != nil, !processes.isEmpty, pending.isEmpty,
              creations.isEmpty, initializers.isEmpty,
              processes.allSatisfy(\.exited) else { throw failure() }
    }

    private func consume(_ line: String) throws {
        if line.hasPrefix("wineserver: starting (pid=") { started = true; return }
        guard line.contains("init_first_thread(") || line.contains("new_process(") ||
              line.contains("new_thread() = 0") || line.contains("*process killed*") else { return }
        guard let match = captures(#"^([0-9a-f]+): (.*)$"#, line) else { return }
        let thread = match[0], body = match[1]
        if body == "*process killed*" {
            guard let index = active.removeValue(forKey: thread) else { throw failure() }
            processes[index].exited = true
        } else if body.hasPrefix("new_process(") {
            try creation(thread, body)
        } else if body.hasPrefix("init_first_thread(") {
            try initialization(thread, body)
        } else if body.hasPrefix("new_thread() = 0"), let parent = threads[thread],
                  let tid = captures(#"\btid=([0-9a-f]+)"#, body)?.first {
            threads[tid] = parent
        }
    }

    private func creation(_ thread: String, _ body: String) throws {
        if body.hasPrefix("new_process() =") {
            guard let creation = creations.removeValue(forKey: thread) else { throw failure() }
            guard body.hasPrefix("new_process() = 0 ") else { return }
            guard let pid = captures(#"\bpid=([0-9a-f]+)"#, body)?.first else { throw failure() }
            _ = try add(pid, image: creation.image, parent: creation.parent)
        } else {
            guard creations[thread] == nil,
                  let escaped = captures(#"imagepath=L\"((?:\\.|[^\"\\])*)\""#, body)?.first else {
                throw failure()
            }
            let image = try decodePath(escaped)
            creations[thread] = Creation(image: image, parent: threads[thread])
        }
    }

    private func initialization(_ thread: String, _ body: String) throws {
        if body.hasPrefix("init_first_thread() =") {
            guard let unix = initializers.removeValue(forKey: thread),
                  body.hasPrefix("init_first_thread() = 0 "),
                  let fields = captures(#"\bpid=([0-9a-f]+), tid=([0-9a-f]+), server_start=([0-9a-f]+)"#, body) else {
                throw failure()
            }
            if let previous = serverStart, previous != fields[2] { throw failure() }
            serverStart = fields[2]
            let index = try active[fields[0]] ?? add(fields[0], image: unix == rootPID ? entry : "", parent: nil)
            guard processes[index].unixPID == nil else { throw failure() }
            processes[index].unixPID = unix
            if unix == rootPID { processes[index].imagePath = entry }
            threads[fields[1]] = processes[index].identifier
        } else {
            guard initializers[thread] == nil,
                  let value = captures(#"\bunix_pid=([0-9]+)"#, body)?.first,
                  let unix = Int32(value), unix > 0 else { throw failure() }
            initializers[thread] = unix
        }
    }

    private func add(_ pid: String, image: String, parent: String?) throws -> Int {
        guard active[pid] == nil, processes.count < 128 else { throw failure() }
        let index = processes.count
        let identifier = session + "/" + String(index + 1)
        processes.append(WineProcess(identifier: identifier, winePID: pid, parentIdentifier: parent, imagePath: image))
        active[pid] = index
        return index
    }

    private func decodePath(_ escaped: String) throws -> String {
        // Pinned Wine dumps Windows paths with C escapes. Unsupported escapes
        // reject inventory rather than silently inventing a path or identity.
        var result = "", iterator = escaped.makeIterator()
        while let character = iterator.next() {
            if character != "\\" { result.append(character); continue }
            guard let next = iterator.next(), next == "\\" || next == "\"" else { throw failure() }
            result.append(next)
        }
        if result.hasPrefix("\\??\\") { result.removeFirst(4) }
        return result
    }

    private func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]) }
        }
    }

    private func failure() -> RuntimeFailure { .status(.processInventory) }
}
