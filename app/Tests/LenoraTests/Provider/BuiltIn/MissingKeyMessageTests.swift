import Testing
@testable import Lenora

@MainActor
struct MissingKeyMessageTests {
    @Test func missingCloudinarySettingsPointToAPIKeys() {
        #expect(MissingProviderKeys.message(adapterID: "cloudinary", reason: "missing or invalid: LENORA_CLOUDINARY_API_KEY")
            == "Add your Cloudinary keys in Settings → API Keys.")
    }

    @Test func missingOpenAISettingsPointToAPIKeys() {
        #expect(MissingProviderKeys.message(adapterID: "openai", reason: "missing or invalid: LENORA_OPENAI_API_KEY")
            == "Add your OpenAI key in Settings → API Keys.")
    }

    @Test(arguments: [("cloudinary", "start failed: ConnectError"), ("template", "missing or invalid: X"), ("openai", nil)])
    func otherReasonsAreLeftAlone(adapterID: String, reason: String?) {
        #expect(MissingProviderKeys.message(adapterID: adapterID, reason: reason) == nil)
    }
}
