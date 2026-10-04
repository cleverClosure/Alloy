// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private func leaseTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-content-store-lease-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func withLeaseStore(
    _ body: (URL, ContentStore) throws -> Void
) throws {
    let root = try leaseTestRoot()
    defer {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            chmod(url.path, S_IRWXU)
        }
        chmod(root.path, S_IRWXU)
        try? FileManager.default.removeItem(at: root)
    }
    try body(root, ContentStore(root: root))
}

private func leaseLayer(_ value: String, version: String) -> LayerInput {
    let data = Data(value.utf8)
    return LayerInput(
        descriptor: LayerDescriptor(
            name: "lease-test-runtime",
            version: version,
            digest: ContentStore.digest(data),
            mediaType: "application/vnd.alloy.test-layer",
            size: data.count,
            role: .hostRuntime
        ),
        contents: data
    )
}

private enum LeaseTestProcessError: Error {
    case systemCall(String, Int32)
    case timedOut
}

private func spawnLeaseHolder(
    readDescriptor: Int32,
    writeDescriptor: Int32
) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    let initializationResult = posix_spawn_file_actions_init(&actions)
    guard initializationResult == 0 else {
        throw LeaseTestProcessError.systemCall(
            "spawn actions",
            initializationResult
        )
    }
    defer { posix_spawn_file_actions_destroy(&actions) }

    let duplicateResult = posix_spawn_file_actions_adddup2(
        &actions,
        readDescriptor,
        STDIN_FILENO
    )
    let closeReadResult = posix_spawn_file_actions_addclose(&actions, readDescriptor)
    let closeWriteResult = posix_spawn_file_actions_addclose(&actions, writeDescriptor)
    for result in [duplicateResult, closeReadResult, closeWriteResult] where result != 0 {
        throw LeaseTestProcessError.systemCall("configure spawn actions", result)
    }

    var processID: pid_t = 0
    let executable = "/bin/cat"
    let spawnResult = executable.withCString { path in
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(arguments[0]) }
        return arguments.withUnsafeMutableBufferPointer { argumentBuffer in
            posix_spawn(
                &processID,
                path,
                &actions,
                nil,
                argumentBuffer.baseAddress,
                environ
            )
        }
    }
    guard spawnResult == 0 else {
        throw LeaseTestProcessError.systemCall("posix_spawn", spawnResult)
    }
    return processID
}

private func exitEventQueue(processID: pid_t) throws -> Int32 {
    let queue = kqueue()
    guard queue >= 0 else {
        throw LeaseTestProcessError.systemCall("kqueue", errno)
    }
    var change = kevent(
        ident: UInt(processID),
        filter: Int16(EVFILT_PROC),
        flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
        fflags: UInt32(NOTE_EXIT),
        data: 0,
        udata: nil
    )
    guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
        let code = errno
        close(queue)
        throw LeaseTestProcessError.systemCall("kevent register", code)
    }
    return queue
}

private func waitForProcessExit(queue: Int32) throws {
    while true {
        var event = kevent()
        var timeout = timespec(tv_sec: 30, tv_nsec: 0)
        let result = kevent(queue, nil, 0, &event, 1, &timeout)
        if result < 0, errno == EINTR {
            continue
        }
        guard result > 0 else {
            throw LeaseTestProcessError.timedOut
        }
        return
    }
}

private func reapProcess(_ processID: pid_t) {
    var status: Int32 = 0
    while waitpid(processID, &status, 0) < 0 {
        if errno != EINTR {
            return
        }
    }
}

private func withControlledLeaseHolder(
    _ body: (pid_t, () throws -> Void) throws -> Void
) throws {
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else {
        throw LeaseTestProcessError.systemCall("pipe", errno)
    }

    let processID: pid_t
    do {
        processID = try spawnLeaseHolder(
            readDescriptor: descriptors[0],
            writeDescriptor: descriptors[1]
        )
    } catch {
        close(descriptors[0])
        close(descriptors[1])
        throw error
    }
    close(descriptors[0])
    var releaseDescriptorOpen = true
    let queue = try exitEventQueue(processID: processID)
    defer {
        if releaseDescriptorOpen {
            close(descriptors[1])
        }
        close(queue)
        reapProcess(processID)
    }

    let exitWithoutReaping = {
        if releaseDescriptorOpen {
            guard close(descriptors[1]) == 0 else {
                throw LeaseTestProcessError.systemCall("release child", errno)
            }
            releaseDescriptorOpen = false
        }
        try waitForProcessExit(queue: queue)
    }
    try body(processID, exitWithoutReaping)
}

private func activateLeaseFixture(_ store: ContentStore) throws -> GenerationReference {
    try store.activate(
        gameID: "game",
        generationID: "generation-a",
        layers: [
            leaseLayer("shared", version: "1"),
            leaseLayer("specific", version: "2")
        ]
    )
}

@Test("lease covers every unique generation object and releases explicitly")
func leaseCoversGenerationAndReleases() throws {
    try withLeaseStore { _, store in
        let generation = try activateLeaseFixture(store)
        let lease = try store.acquireLease(gameID: "game", generation: generation)

        #expect(lease.schemaVersion == "1.0")
        #expect(lease.generationID == generation.generationID)
        #expect(lease.objectDigests.count == 2)
        #expect(lease.objectDigests == lease.objectDigests.sorted())
        #expect(try store.liveLeases() == [lease])
        #expect(
            try Data(contentsOf: store.leaseURL(lease.leaseID))
                == store.encoder.encode(lease)
        )

        try store.releaseLease(lease)
        try store.releaseLease(lease)
        #expect(try store.liveLeases().isEmpty)
    }
}

@Test("old lease for an exactly live process remains a collection root")
func oldLiveProcessLeaseStillBlocks() throws {
    try withLeaseStore { _, store in
        let generation = try activateLeaseFixture(store)
        let holder = try store.requireProcessIdentity(getpid())
        let lease = try store.withExclusiveLock {
            try store.acquireLeaseUnlocked(
                gameID: "game",
                generation: generation,
                holder: holder,
                createdAtUnixSeconds: 0,
                leaseID: "fake-stale-live"
            )
        }

        #expect(try store.liveLeases() == [lease])
        #expect(try store.liveLeaseObjectDigestsPruningStaleForTesting() == Set(
            lease.objectDigests
        ))
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            layers: [leaseLayer("payload-b", version: "b")]
        )
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-c",
            layers: [leaseLayer("payload-c", version: "c")]
        )
        #expect(try store.collectGarbage() == .zero)
        #expect(store.pathEntryExists(store.generationURL(
            gameID: "game",
            generationID: "generation-a"
        )))

        try store.releaseLease(lease)
        let collected = try store.collectGarbage()
        #expect(collected.generationsRemoved == 1)
        #expect(collected.objectsRemoved == 2)
    }
}

@Test("same PID with a different start time is stale")
func reusedProcessIDDoesNotKeepLeaseLive() throws {
    try withLeaseStore { _, store in
        let generation = try activateLeaseFixture(store)
        let current = try store.requireProcessIdentity(getpid())
        let reusedIdentity = LeaseProcessIdentity(
            processID: current.processID,
            startTimeSeconds: current.startTimeSeconds + 1,
            startTimeMicroseconds: current.startTimeMicroseconds
        )
        let lease = try store.withExclusiveLock {
            try store.acquireLeaseUnlocked(
                gameID: "game",
                generation: generation,
                holder: reusedIdentity,
                createdAtUnixSeconds: 0,
                leaseID: "reused-process-id"
            )
        }

        #expect(try store.liveLeases().isEmpty)
        #expect(!store.pathEntryExists(store.leaseURL(lease.leaseID)))
    }
}

@Test("unsupported and schema-invalid lease documents fail closed")
func invalidLeaseDocumentsFailClosed() throws {
    try withLeaseStore { _, store in
        let generation = try activateLeaseFixture(store)
        let lease = try store.acquireLease(gameID: "game", generation: generation)
        let url = store.leaseURL(lease.leaseID)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )

        object["schemaVersion"] = "2.0"
        try store.writeAtomic(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            to: url
        )
        #expect(throws: ContentStoreError.unsupportedSchema(
            kind: "generation lease",
            version: "2.0"
        )) {
            _ = try store.readLease(url)
        }

        object["schemaVersion"] = "1.0"
        object["unexpected"] = true
        try store.writeAtomic(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            to: url
        )
        #expect(throws: ContentStoreError.invalidLease(lease.leaseID)) {
            _ = try store.readLease(url)
        }
    }
}

@Test("lease left by a genuinely dead process is reclaimed")
func deadProcessLeaseIsReclaimed() throws {
    try withLeaseStore { _, store in
        let generation = try activateLeaseFixture(store)
        let input = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        let holder = try store.requireProcessIdentity(child.processIdentifier)
        let lease = try store.withExclusiveLock {
            try store.acquireLeaseUnlocked(
                gameID: "game",
                generation: generation,
                holder: holder,
                createdAtUnixSeconds: 0,
                leaseID: "dead-holder"
            )
        }
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)

        #expect(try store.liveLeases().isEmpty)
        #expect(!store.pathEntryExists(store.leaseURL(lease.leaseID)))
    }
}

@Test("a launched holder protects its generation and a zombie is immediately stale")
func launchedHolderLeaseTracksActualProcessLifetime() throws {
    try withLeaseStore { _, store in
        let generation = try activateLeaseFixture(store)
        try withControlledLeaseHolder { processID, exitWithoutReaping in
            let lease = try store.acquireLease(
                gameID: "game",
                generation: generation,
                holderProcessID: processID
            )
            #expect(lease.holder.processID == processID)

            _ = try store.activate(
                gameID: "game",
                generationID: "generation-b",
                layers: [leaseLayer("payload-b", version: "b")]
            )
            _ = try store.activate(
                gameID: "game",
                generationID: "generation-c",
                layers: [leaseLayer("payload-c", version: "c")]
            )
            #expect(try store.collectGarbage() == .zero)

            try exitWithoutReaping()
            #expect(try store.liveLeases().isEmpty)
            #expect(!store.pathEntryExists(store.leaseURL(lease.leaseID)))

            let collected = try store.collectGarbage()
            #expect(collected.generationsRemoved == 1)
            #expect(collected.objectsRemoved == 2)
        }
    }
}

private extension ContentStore {
    func liveLeaseObjectDigestsPruningStaleForTesting() throws -> Set<String> {
        try withExclusiveLock {
            try liveLeaseObjectDigestsPruningStaleUnlocked()
        }
    }
}
