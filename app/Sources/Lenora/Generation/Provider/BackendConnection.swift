import Foundation
import Observation

enum BackendConnectionState: Equatable, Sendable {
    case unknown, connecting, connected
    case unreachable(URL)
    case unauthorized
    case invalidConfiguration(BackendConfigurationError)
    case tokenNotSaved
    case failed(String)
}

@Observable @MainActor
final class BackendConnection {
    static let shared = BackendConnection()

    private(set) var configuration: LenoraBackendConfiguration?
    private(set) var provider: (any GenerationProvider)?
    private(set) var state: BackendConnectionState = .unknown
    private(set) var health: BackendHealth?
    private(set) var urlFromEnvironment = false
    private(set) var tokenFromEnvironment = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let catalog: ModelCatalog
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loadToken: @Sendable () async -> String?
    @ObservationIgnored private let makeProvider: @MainActor (LenoraBackendConfiguration) -> any GenerationProvider
    @ObservationIgnored private let builtInConfiguration: @MainActor () -> LenoraBackendConfiguration?

    init(
        catalog: ModelCatalog = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        loadToken: @escaping @Sendable () async -> String? = { await BackendConnection.loadStoredToken() },
        makeProvider: @escaping @MainActor (LenoraBackendConfiguration) -> any GenerationProvider = { LenoraBackendClient(configuration: $0) },
        builtInConfiguration: @escaping @MainActor () -> LenoraBackendConfiguration? = { BuiltInBackend.shared.configuration }
    ) {
        self.catalog = catalog
        self.environment = environment
        self.defaults = defaults
        self.loadToken = loadToken
        self.makeProvider = makeProvider
        self.builtInConfiguration = builtInConfiguration
    }

    func reload(recheckAddons: Bool = false) async {
        generation &+= 1
        let current = generation
        state = .connecting
        let sources = LenoraBackendConfiguration.Sources(
            environment: environment,
            storedURL: defaults.string(forKey: LenoraBackendConfiguration.urlDefaultsKey),
            plistURL: Bundle.main.object(forInfoDictionaryKey: "LenoraBackendURL") as? String,
            keychainToken: await loadToken(),
            mode: BackendMode.effective(environment: environment, defaults: defaults),
            builtIn: builtInConfiguration()
        )
        guard current == generation else { return }
        urlFromEnvironment = LenoraBackendConfiguration.environmentURL(sources.environment) != nil
        tokenFromEnvironment = LenoraBackendConfiguration.environmentToken(sources.environment) != nil
        let resolved: (configuration: LenoraBackendConfiguration, tokenToPersist: String?)
        do {
            resolved = try LenoraBackendConfiguration.resolve(sources)
        } catch {
            clear()
            state = .invalidConfiguration(error)
            return
        }
        if let token = resolved.tokenToPersist, !(await Self.storeToken(token)) {
            Log.generation.warning("backend token could not be saved to the Keychain")
        }
        guard current == generation else { return }
        let client = makeProvider(resolved.configuration)
        configuration = resolved.configuration
        provider = client
        do {
            let health = try await client.health(recheckAddons: recheckAddons)
            let capabilities = try await client.capabilities()
            guard current == generation else { return }
            self.health = health
            catalog.apply(capabilities)
            state = .connected
        } catch {
            guard current == generation else { return }
            health = nil
            catalog.apply(.empty)
            switch error as? BackendError {
            case .unauthorized: state = .unauthorized
            case .unreachable(let url): state = .unreachable(url)
            default: state = .failed(error.localizedDescription)
            }
            Log.generation.warning("backend connection failed: \(error.localizedDescription)")
        }
    }

    func refreshCapabilities() async {
        guard state == .connected, let provider else { return }
        let current = generation
        do {
            let health = try await provider.health(recheckAddons: false)
            let capabilities = try await provider.capabilities()
            guard current == generation else { return }
            self.health = health
            catalog.apply(capabilities)
        } catch {
            Log.generation.warning("capability refresh failed: \(error.localizedDescription)")
        }
    }

    func save(url: String, token: String?) async {
        generation &+= 1
        let current = generation
        state = .connecting
        if LenoraBackendConfiguration.environmentURL(environment) == nil {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? nil : trimmed, forKey: LenoraBackendConfiguration.urlDefaultsKey)
        }
        if let token, !(await Self.storeToken(token)) {
            guard current == generation else { return }
            clear()
            state = .tokenNotSaved
            Log.generation.warning("backend token could not be saved to the Keychain")
            return
        }
        guard current == generation else { return }
        await reload(recheckAddons: true)
    }

    private func clear() {
        configuration = nil
        provider = nil
        health = nil
        catalog.apply(.empty)
    }

    @concurrent private static func loadStoredToken() async -> String? {
        (try? CredentialStore.current.read(LenoraBackendConfiguration.tokenAccount)) ?? nil
    }

    @concurrent private static func storeToken(_ token: String) async -> Bool {
        CredentialStore.current.save(token, LenoraBackendConfiguration.tokenAccount)
    }
}
