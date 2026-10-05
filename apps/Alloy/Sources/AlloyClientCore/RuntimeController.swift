// Author: Timur Isaev
import AlloyRuntimeAPI
import AlloyStoreCatalog
import Foundation
import Observation

@MainActor @Observable
public final class RuntimeController {
    public let store: ClientStore
    public private(set) var operations: [OperationPresentation] = []
    public private(set) var sessions: [SessionPresentation] = []
    public private(set) var plan: InstallPlan?
    public private(set) var details: GameDetails?
    public private(set) var busy = false
    public private(set) var refreshing = false
    public private(set) var hasEndpoint = false
    public private(set) var developmentEnabled = false
    public private(set) var problem: ClientProblem?
    public private(set) var connectionProblem: ClientProblem?
    public private(set) var instanceID: String?
    @ObservationIgnored var gateway: ServiceGateway?
    @ObservationIgnored let storage: PreferencesStore
    @ObservationIgnored var journal = ClientJournal()
    @ObservationIgnored var journalUsable = true
    @ObservationIgnored var recipe: DevelopmentRecipe?
    @ObservationIgnored var epoch = UUID()

    public init(store: ClientStore, storage: PreferencesStore) {
        self.store = store
        self.storage = storage
        do {
            if let bytes = try storage.readData(name: "requests.json", maximum: 4 * 1024 * 1024) {
                journal = try JSONDecoder().decode(ClientJournal.self, from: bytes)
            }
        } catch { problem = .service(error); journalUsable = false }
    }

    public func connect(endpoint: String, fixture: String? = nil) async {
        guard !store.snapshot.preview, !busy, !refreshing else { return }
        do {
            let configuration = try ServiceConfiguration.read(endpoint)
            let newRecipe = try fixture.map(DevelopmentRecipe.read)
            if newRecipe != nil && configuration.fixtureMode != true { throw ClientServiceError.developmentOnly }
            gateway = ServiceGateway(configuration: configuration)
            recipe = newRecipe
            developmentEnabled = newRecipe != nil
            hasEndpoint = true
            epoch = UUID()
            operations = []; sessions = []; plan = nil; details = nil
            store.snapshot.phase = .loading
            await refresh()
        } catch { problem = .service(error) }
    }

    public func refresh() async {
        guard let gateway, !busy, !refreshing else { return }
        refreshing = true
        let ticket = epoch
        defer { refreshing = false }
        do {
            let observation = try await gateway.observe(cursors: journal.cursors[gateway.namespace] ?? [:])
            guard ticket == epoch else { return }
            operations = observation.updates.map(OperationPresentation.init)
            sessions = observation.sessions.map(SessionPresentation.init)
            for update in observation.updates {
                journal.cursors[gateway.namespace, default: [:]][update.snapshot.operationID] = update.next.nextIndex
            }
            if journalUsable { try persistJournal() }
            instanceID = observation.info.instanceID
            var snapshot = ClientSnapshot()
            snapshot.connected = true
            snapshot.phase = observation.games.isEmpty ? .empty : .available
            snapshot.games = observation.games
            snapshot.serviceDescription = "Connected · Local development service"
            store.update(snapshot)
            connectionProblem = nil
            if let identifier = store.preferences.selectedGameID {
                details = try await gateway.request("catalog.get", IdentifierRequest(identifier), as: GameDetails.self)
            } else { details = nil }
        } catch {
            guard ticket == epoch else { return }
            connectionProblem = .service(error)
            store.snapshot.connected = false
            store.snapshot.phase = .disconnected
            store.snapshot.serviceDescription = "Disconnected · Last known activity retained"
        }
    }

    public func monitor() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    public func prepareInstall() async {
        await action { gateway in
            let recipe = try self.developmentRecipe()
            _ = try await gateway.validate(recipe)
            self.plan = try await gateway.request("install.plan", recipe.install, as: InstallPlan.self)
        }
    }

    public func installRuntime() async {
        await action { gateway in
            let recipe = try self.developmentRecipe()
            _ = try await gateway.validate(recipe)
            guard let plan = self.plan else { throw ClientServiceError.invalidResponse }
            let intent = try self.reserve(slot: "install:" + plan.planID,
                                          method: "install.start", identifier: plan.planID)
            let operation = try await gateway.request(intent.method,
                KeyedIdentifier(identifier: plan.planID, key: intent.key), as: CatalogOperation.self)
            _ = try await gateway.request("operation.run", IdentifierRequest(operation.operationID),
                                          as: CatalogOperation.self)
            self.store.preferences.section = .activity
        }
    }

    public func control(_ identifier: String, command: String) async {
        guard ["run", "pause", "resume", "cancel"].contains(command) else { return }
        await action { gateway in
            _ = try await gateway.request("operation." + command, IdentifierRequest(identifier),
                                          as: CatalogOperation.self)
        }
    }

    public func checkStorage() async {
        await action { gateway in
            let intent = try self.reserve(slot: "inventory", method: "inventory.start", identifier: nil)
            let operation = try await gateway.request(intent.method, KeyRequest(intent.key), as: CatalogOperation.self)
            _ = try await gateway.request("operation.run", IdentifierRequest(operation.operationID),
                                          as: CatalogOperation.self)
            self.store.preferences.section = .activity
        }
    }

    public func startDevelopmentSession() async {
        await action { gateway in
            let recipe = try self.developmentRecipe()
            _ = try await gateway.validate(recipe)
            let slot = "fixture:" + ClientJournal.digest(try RuntimeEncoding.encode(recipe))
            let intent: ClientIntent
            if let existing = self.journal.intent(namespace: gateway.namespace, slot: slot) { intent = existing } else {
                let preview = try await gateway.request("launch.resolve", recipe.launch, as: LaunchPreview.self)
                _ = try await gateway.request("launch.verify", IdentifierRequest(preview.previewID),
                                              as: LaunchPreview.self)
                intent = try self.reserve(slot: slot, method: "fixture.start", identifier: preview.previewID)
            }
            guard let identifier = intent.identifier else { throw ClientServiceError.invalidResponse }
            _ = try await gateway.request("fixture.start",
                FixtureStart(previewID: identifier, key: intent.key, scenario: .hang), as: SessionSnapshot.self)
            self.store.preferences.section = .activity
        }
    }

    public func stopSession(_ identifier: String) async {
        await action { gateway in
            _ = try await gateway.request("session.stop", IdentifierRequest(identifier), as: SessionSnapshot.self)
        }
    }

    func action(_ body: (ServiceGateway) async throws -> Void) async {
        guard let gateway, !busy, !refreshing, store.snapshot.connected, !store.snapshot.preview else { return }
        guard journalUsable else { problem = .service(PreferencesError.unsafeStorage); return }
        busy = true
        problem = nil
        var failure: ClientProblem?
        do { try await body(gateway) } catch { failure = .service(error) }
        busy = false
        await refresh()
        if let failure { problem = failure }
    }

    func developmentRecipe() throws -> DevelopmentRecipe {
        guard developmentEnabled, gateway?.allowsFixtures == true, let recipe,
              store.preferences.selectedGameID == recipe.install.gameID else {
            throw ClientServiceError.developmentOnly
        }
        return recipe
    }

    func reserve(slot: String, method: String, identifier: String?) throws -> ClientIntent {
        guard let gateway else { throw ClientServiceError.noConnection }
        let result = try journal.reserve(namespace: gateway.namespace, slot: slot,
                                         method: method, identifier: identifier)
        try persistJournal()
        return result
    }

    func persistJournal() throws {
        try storage.writeData(JSONEncoder().encode(journal), name: "requests.json")
    }
}
