import Foundation
import Testing
@testable import Lenora

struct LenoraBackendConfigurationTests {
    private typealias Config = LenoraBackendConfiguration

    @Test func defaultsToLocalBackend() throws {
        let resolved = try Config.resolve(.init(environment: [:], storedURL: nil, plistURL: nil, keychainToken: "k"))
        #expect(resolved.configuration == Config(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "k"))
        #expect(resolved.tokenToPersist == nil)
    }

    @Test func environmentWinsOverSettingsAndPlist() throws {
        let resolved = try Config.resolve(.init(
            environment: ["LENORA_BACKEND_URL": "https://api.example.com"],
            storedURL: "https://settings.example.com", plistURL: "http://127.0.0.1:9000", keychainToken: nil))
        #expect(resolved.configuration.baseURL.absoluteString == "https://api.example.com")
    }

    @Test func emptyEnvironmentURLIsTreatedAsUnset() throws {
        let resolved = try Config.resolve(.init(
            environment: ["LENORA_BACKEND_URL": ""], storedURL: "https://s.example.com", plistURL: nil, keychainToken: nil))
        #expect(resolved.configuration.baseURL.host() == "s.example.com")
    }

    @Test func settingsWinOverPlist() throws {
        let resolved = try Config.resolve(.init(environment: [:], storedURL: "https://s.example.com", plistURL: "http://127.0.0.1:9000", keychainToken: nil))
        #expect(resolved.configuration.baseURL.host() == "s.example.com")
    }

    @Test func plistWinsOverDefault() throws {
        let resolved = try Config.resolve(.init(environment: [:], storedURL: nil, plistURL: "http://127.0.0.1:9000", keychainToken: nil))
        #expect(resolved.configuration.baseURL.absoluteString == "http://127.0.0.1:9000")
    }

    @Test func environmentTokenWinsAndIsPersistedWhenDifferent() throws {
        let resolved = try Config.resolve(.init(environment: ["LENORA_TOKEN": "fresh"], storedURL: nil, plistURL: nil, keychainToken: "stale"))
        #expect(resolved.configuration.token == "fresh")
        #expect(resolved.tokenToPersist == "fresh")
    }

    @Test func matchingEnvironmentTokenIsNotRewritten() throws {
        let resolved = try Config.resolve(.init(environment: ["LENORA_TOKEN": "same"], storedURL: nil, plistURL: nil, keychainToken: "same"))
        #expect(resolved.tokenToPersist == nil)
    }

    @Test func emptyEnvironmentTokenFallsBackToKeychain() throws {
        let resolved = try Config.resolve(.init(environment: ["LENORA_TOKEN": ""], storedURL: nil, plistURL: nil, keychainToken: "k"))
        #expect(resolved.configuration.token == "k")
        #expect(resolved.tokenToPersist == nil)
    }

    @Test(arguments: [(["LENORA_TOKEN": "abc"], "abc"), (["LENORA_TOKEN": ""], nil), ([:], nil)] as [([String: String], String?)])
    func environmentToken(environment: [String: String], token: String?) {
        #expect(LenoraBackendConfiguration.environmentToken(environment) == token)
    }

    @Test(arguments: ["http://example.com", "ftp://127.0.0.1", "http://192.168.1.4:8787"])
    func rejectsInsecureURLs(url: String) {
        #expect(throws: BackendConfigurationError.insecureURL(url)) {
            try Config.resolve(.init(environment: [:], storedURL: url, plistURL: nil, keychainToken: nil))
        }
    }

    @Test(arguments: ["", "not a url", "://"])
    func rejectsMalformedURLs(url: String) {
        #expect(throws: BackendConfigurationError.invalidURL(url)) {
            try Config.resolve(.init(environment: [:], storedURL: url, plistURL: nil, keychainToken: nil))
        }
    }

    @Test(arguments: ["http://localhost:8787", "http://[::1]:8787", "https://lenora.example.com/base"])
    func acceptsSecureOrLoopbackURLs(url: String) throws {
        _ = try Config.resolve(.init(environment: [:], storedURL: url, plistURL: nil, keychainToken: nil))
    }

    @Test func builtInModeUsesTheSupervisorConfiguration() throws {
        let builtIn = Config(baseURL: URL(string: "http://127.0.0.1:54817")!, token: "tok")
        let sources = Config.Sources(environment: [:], storedURL: "https://custom.example",
                                     plistURL: nil, keychainToken: "k", mode: .builtIn, builtIn: builtIn)
        #expect(try Config.resolve(sources).configuration == builtIn)
    }

    @Test func builtInModeBeforeReadyIsNotRunning() {
        let sources = Config.Sources(environment: [:], storedURL: nil, plistURL: nil,
                                     keychainToken: nil, mode: .builtIn, builtIn: nil)
        #expect(throws: BackendConfigurationError.builtInNotRunning) { try Config.resolve(sources) }
    }

    @Test func environmentURLOverridesBuiltInMode() throws {
        let sources = Config.Sources(environment: ["LENORA_BACKEND_URL": "http://127.0.0.1:8787"],
                                     storedURL: nil, plistURL: nil, keychainToken: nil, mode: .builtIn, builtIn: nil)
        #expect(try Config.resolve(sources).configuration.baseURL.absoluteString == "http://127.0.0.1:8787")
    }

    @Test func modeDefaultsToBuiltInAndEnvironmentForcesCustom() throws {
        let suite = "BackendMode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BackendMode.effective(environment: [:], defaults: defaults) == .builtIn)
        defaults.set("custom", forKey: BackendMode.defaultsKey)
        #expect(BackendMode.effective(environment: [:], defaults: defaults) == .custom)
        defaults.set("builtIn", forKey: BackendMode.defaultsKey)
        #expect(BackendMode.effective(environment: ["LENORA_BACKEND_URL": "http://127.0.0.1:1"], defaults: defaults) == .custom)
    }
}
