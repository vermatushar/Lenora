import Foundation
import Testing
@testable import Lenora

@MainActor
struct BackendConnectionTests {
    private final class ProviderQueue {
        var providers: [FakeProvider]
        init(_ providers: [FakeProvider]) { self.providers = providers }
    }

    /// Parks token loads after `park()` until `release()`, so a test can act while a reload is in flight.
    private actor TokenGate {
        private var parks = false
        private var parked: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?

        func park() { parks = true }

        func load() async -> String? {
            guard parks else { return nil }
            await withCheckedContinuation { parked = $0; arrival?.resume(); arrival = nil }
            return nil
        }

        func waitUntilParked() async {
            if parked != nil { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release() { parks = false; parked?.resume(); parked = nil }
    }

    private func connection(
        _ providers: [FakeProvider], catalog: ModelCatalog, defaults: UserDefaults, tokens: TokenGate = TokenGate()
    ) -> BackendConnection {
        let queue = ProviderQueue(providers)
        return BackendConnection(
            catalog: catalog, environment: [:], defaults: defaults, loadToken: { await tokens.load() },
            makeProvider: { _ in queue.providers.removeFirst() }
        )
    }

    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let suite = "BackendConnectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(BackendMode.custom.rawValue, forKey: BackendMode.defaultsKey)
        try await body(defaults)
    }

    private func fullCapabilities() throws -> BackendCapabilities {
        try BackendCoding.decoder().decode(BackendCapabilities.self, from: ProtocolFixtures.data("Capabilities.cloudinaryFull"))
    }

    @Test func refreshAppliesCapabilitiesForTheCurrentConnection() async throws {
        try await withDefaults { defaults in
            let catalog = ModelCatalog()
            let provider = FakeProvider()
            let connection = connection([provider], catalog: catalog, defaults: defaults)
            await connection.reload()
            await provider.setCapabilities(try fullCapabilities())
            await connection.refreshCapabilities()
            #expect(!catalog.backendModels.isEmpty)
        }
    }

    @Test func refreshInFlightAcrossAFailedReloadIsDropped() async throws {
        try await withDefaults { defaults in
            let catalog = ModelCatalog()
            let url = try #require(URL(string: "http://127.0.0.1:8787"))
            let first = FakeProvider(), second = FakeProvider(healthFailure: .unreachable(url))
            let connection = connection([first, second], catalog: catalog, defaults: defaults)
            await connection.reload()
            await first.setCapabilities(try fullCapabilities())
            await first.hold(.capabilities)
            let refresh = Task { await connection.refreshCapabilities() }
            try await first.waitForCalls(.capabilities, count: 2)
            await connection.reload()
            #expect(connection.state == .unreachable(url))
            await first.release(.capabilities)
            await refresh.value
            #expect(catalog.backendModels.isEmpty)
        }
    }

    @Test func refreshDuringAReloadSkipsTheOldProvider() async throws {
        try await withDefaults { defaults in
            let catalog = ModelCatalog()
            let url = try #require(URL(string: "http://127.0.0.1:8787"))
            let tokens = TokenGate()
            let first = FakeProvider(), second = FakeProvider(healthFailure: .unreachable(url))
            let connection = connection([first, second], catalog: catalog, defaults: defaults, tokens: tokens)
            await connection.reload()
            await first.setCapabilities(try fullCapabilities())
            await tokens.park()
            let reload = Task { await connection.reload() }
            await tokens.waitUntilParked()
            await connection.refreshCapabilities()
            #expect(catalog.backendModels.isEmpty)
            await tokens.release()
            await reload.value
            #expect(connection.state == .unreachable(url))
            #expect(catalog.backendModels.isEmpty)
        }
    }

    @Test func refreshInFlightAcrossAConfigurationChangeIsDropped() async throws {
        try await withDefaults { defaults in
            let catalog = ModelCatalog()
            let first = FakeProvider(), second = FakeProvider()
            let connection = connection([first, second], catalog: catalog, defaults: defaults)
            await connection.reload()
            await first.setCapabilities(try fullCapabilities())
            await first.hold(.capabilities)
            let refresh = Task { await connection.refreshCapabilities() }
            try await first.waitForCalls(.capabilities, count: 2)
            await connection.save(url: "https://other.example.com", token: nil)
            #expect(connection.configuration?.baseURL.host() == "other.example.com")
            await first.release(.capabilities)
            await refresh.value
            #expect(catalog.backendModels.isEmpty)
        }
    }

    @Test func builtInModeConnectsToTheSupervisorConfiguration() async throws {
        let suite = "BackendConnectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let builtIn = LenoraBackendConfiguration(baseURL: try #require(URL(string: "http://127.0.0.1:54817")), token: "tok")
        var made: [LenoraBackendConfiguration] = []
        let connection = BackendConnection(catalog: ModelCatalog(), environment: [:], defaults: defaults, loadToken: { nil },
                                           makeProvider: { made.append($0); return FakeProvider() },
                                           builtInConfiguration: { builtIn })
        await connection.reload()
        #expect(made == [builtIn])
        #expect(connection.state == .connected)
    }
}
