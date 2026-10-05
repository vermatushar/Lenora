import Foundation
import Testing
@testable import Lenora

struct BuiltInBackendInputsTests {
    @Test(arguments: [
        ("LENORA_READY port=54817", 54817),
        ("LENORA_READY port=1", 1),
        ("LENORA_READY port=65535", 65535),
    ])
    func readyLineYieldsPort(line: String, port: Int) {
        #expect(BuiltInBackendReadyLine.port(from: line) == port)
    }

    @Test(arguments: ["LENORA_READY port=0", "LENORA_READY port=65536", "LENORA_READY port=123456",
                      "LENORA_READY port=", " LENORA_READY port=80", "LENORA_READY port=80 ", "hello"])
    func malformedReadyLineIsRejected(line: String) {
        #expect(BuiltInBackendReadyLine.port(from: line) == nil)
    }

    @Test(arguments: [
        "cloudinary://123456789012345:abc_DEF-9@demo-cloud",
        "CLOUDINARY_URL=cloudinary://123456789012345:abc_DEF-9@demo-cloud",
        "  cloudinary://123456789012345:abc_DEF-9@demo-cloud\n",
    ])
    func cloudinaryEnvironmentVariableParses(raw: String) {
        #expect(CloudinaryCredentials.parse(environmentVariable: raw)
            == CloudinaryCredentials(cloudName: "demo-cloud", apiKey: "123456789012345", apiSecret: "abc_DEF-9"))
    }

    @Test(arguments: ["", "https://123:abc@demo", "cloudinary://123:abc@", "cloudinary://:abc@demo",
                      "cloudinary://123@demo", "cloudinary://12a:abc@demo", "cloudinary://123:abc@demo cloud"])
    func malformedCloudinaryEnvironmentVariableIsRejected(raw: String) {
        #expect(CloudinaryCredentials.parse(environmentVariable: raw) == nil)
    }

    @Test func providerKeysLoadFromTheirAccounts() {
        let store = CredentialStore.memory()
        _ = CloudinaryCredentials(cloudName: "c", apiKey: "1", apiSecret: "s").save(to: store)
        _ = store.save("sk-test", AgentProvider.openAI.keychainAccount)
        #expect(ProviderKeys.load(from: store)
            == ProviderKeys(cloudinaryCloudName: "c", cloudinaryAPIKey: "1", cloudinaryAPISecret: "s", openAIAPIKey: "sk-test"))
    }

    @Test func environmentContainsOnlyTheAllowlist() {
        let env = BuiltInBackendEnvironment.make(
            keys: ProviderKeys(cloudinaryCloudName: "c", cloudinaryAPIKey: "1", cloudinaryAPISecret: "s", openAIAPIKey: "sk"),
            token: "tok", dataDirectory: URL(filePath: "/tmp/data dir"), parentPID: 42,
            base: ["HOME": "/Users/x", "TMPDIR": "/tmp/", "LANG": "en_US.UTF-8", "SHELL": "/bin/zsh"])
        #expect(env == [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/x", "TMPDIR": "/tmp/", "LANG": "en_US.UTF-8",
            "LENORA_ENV": "production", "LENORA_HOST": "127.0.0.1", "LENORA_PORT": "0",
            "LENORA_DATA_DIR": "/tmp/data dir", "LENORA_TOKEN": "tok", "LENORA_PARENT_PID": "42",
            "LENORA_CLOUDINARY_CLOUD_NAME": "c", "LENORA_CLOUDINARY_API_KEY": "1", "LENORA_CLOUDINARY_API_SECRET": "s",
            "LENORA_OPENAI_API_KEY": "sk",
        ])
    }

    @Test func environmentIgnoresInheritedSecrets() {
        let env = BuiltInBackendEnvironment.make(
            keys: ProviderKeys(), token: "tok", dataDirectory: URL(filePath: "/d"), parentPID: 42,
            base: ["OPENAI_API_KEY": "leak", "LENORA_TOKEN": "leak", "LENORA_CLOUDINARY_API_SECRET": "leak"])
        #expect(!env.values.contains("leak"))
        #expect(env["LENORA_TOKEN"] == "tok")
    }

    @Test func partialCloudinaryKeysPassOnlyPresentValues() {
        let env = BuiltInBackendEnvironment.make(
            keys: ProviderKeys(cloudinaryCloudName: "c", cloudinaryAPIKey: " ", cloudinaryAPISecret: nil, openAIAPIKey: ""),
            token: "tok", dataDirectory: URL(filePath: "/d"), parentPID: 42, base: [:])
        #expect(env["LENORA_CLOUDINARY_CLOUD_NAME"] == "c")
        #expect(env["LENORA_CLOUDINARY_API_KEY"] == nil && env["LENORA_CLOUDINARY_API_SECRET"] == nil)
        #expect(env["LENORA_OPENAI_API_KEY"] == nil)
    }
}
