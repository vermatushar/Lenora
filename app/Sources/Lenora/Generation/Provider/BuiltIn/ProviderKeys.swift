import Foundation

struct ProviderKeys: Sendable, Equatable {
    var cloudinaryCloudName: String?
    var cloudinaryAPIKey: String?
    var cloudinaryAPISecret: String?
    var openAIAPIKey: String?

    enum Account {
        static let cloudinaryCloudName = "cloudinary-cloud-name"
        static let cloudinaryAPIKey = "cloudinary-api-key"
        static let cloudinaryAPISecret = "cloudinary-api-secret"
    }

    /// Reads the Keychain synchronously; call off the main actor.
    static func load(from store: CredentialStore) -> ProviderKeys {
        func read(_ account: String) -> String? { (try? store.read(account)) ?? nil }
        return ProviderKeys(
            cloudinaryCloudName: read(Account.cloudinaryCloudName),
            cloudinaryAPIKey: read(Account.cloudinaryAPIKey),
            cloudinaryAPISecret: read(Account.cloudinaryAPISecret),
            openAIAPIKey: read(AgentProvider.openAI.keychainAccount)
        )
    }
}

struct CloudinaryCredentials: Sendable, Equatable {
    let cloudName: String
    let apiKey: String
    let apiSecret: String

    static func parse(environmentVariable raw: String) -> CloudinaryCredentials? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("CLOUDINARY_URL=") { text.removeFirst("CLOUDINARY_URL=".count) }
        guard let match = text.wholeMatch(of: /cloudinary:\/\/([0-9]+):([A-Za-z0-9_-]+)@([A-Za-z0-9_-]+)/) else { return nil }
        return CloudinaryCredentials(cloudName: String(match.3), apiKey: String(match.1), apiSecret: String(match.2))
    }

    /// Writes the Keychain synchronously; call off the main actor.
    func save(to store: CredentialStore) -> Bool {
        store.save(cloudName, ProviderKeys.Account.cloudinaryCloudName)
            && store.save(apiKey, ProviderKeys.Account.cloudinaryAPIKey)
            && store.save(apiSecret, ProviderKeys.Account.cloudinaryAPISecret)
    }
}
