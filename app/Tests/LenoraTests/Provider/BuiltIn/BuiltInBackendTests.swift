import Foundation
import Testing
@testable import Lenora

@MainActor @Suite(.timeLimit(.minutes(1)))
struct BuiltInBackendTests {
    private static let noRuntime = BuiltInBackendSupervisor.Dependencies(
        runtimeDirectory: { nil },
        dataDirectory: FileManager.default.temporaryDirectory.appending(path: "BuiltInBackendTests-\(UUID().uuidString)"),
        loadKeys: { ProviderKeys() },
        isQuarantined: { _ in false },
        probe: { _ in false },
        readyTimeout: {},
        backoff: { _ in },
        debounce: {},
        parentPID: getpid(),
        baseEnvironment: [:]
    )

    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let suite = "BuiltInBackendTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    @Test func selectingBuiltInPersistsTheModeAndReportsAMissingRuntime() async throws {
        try await withDefaults { defaults in
            let backend = BuiltInBackend(dependencies: Self.noRuntime, environment: [:], defaults: defaults, onConfigurationChange: {})
            backend.select(.builtIn)
            #expect(defaults.string(forKey: BackendMode.defaultsKey) == "builtIn")
            while backend.state != .notIncluded { await Task.yield() }
            #expect(backend.configuration == nil)
        }
    }

    @Test func selectingCustomPersistsTheModeAndReloadsTheConnection() async throws {
        try await withDefaults { defaults in
            let reloaded = AsyncStream<Void>.makeStream()
            let backend = BuiltInBackend(dependencies: Self.noRuntime, environment: [:], defaults: defaults,
                                         onConfigurationChange: { reloaded.continuation.yield() })
            backend.select(.custom)
            #expect(defaults.string(forKey: BackendMode.defaultsKey) == "custom")
            var iterator = reloaded.stream.makeAsyncIterator()
            #expect(await iterator.next() != nil)
            #expect(backend.state == .stopped)
        }
    }
}
