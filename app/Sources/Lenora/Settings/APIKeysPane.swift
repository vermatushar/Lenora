import AppKit
import SwiftUI

@MainActor
enum MissingProviderKeys {
    static func message(adapterID: String, reason: String?) -> String? {
        guard reason?.hasPrefix("missing or invalid:") == true else { return nil }
        switch adapterID {
        case "cloudinary": return L10n.string("Add your Cloudinary keys in Settings → API Keys.")
        case "openai": return L10n.string("Add your OpenAI key in Settings → API Keys.")
        default: return nil
        }
    }
}

struct APIKeysPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            caption(L10n.string("Keys are stored in the macOS Keychain and sent only to the provider that issued them."))
            SettingsSection(title: L10n.string("Anthropic")) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    caption(L10n.string("Used by the in-app agent on Claude models."))
                    APIKeySettingRow(provider: .anthropic)
                }
            }
            SettingsSection(title: L10n.string("OpenAI")) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    caption(L10n.string("Used by the in-app agent on OpenAI models, voiceover and Improve Prompt."))
                    APIKeySettingRow(provider: .openAI)
                }
            }
            SettingsSection(title: L10n.string("Cloudinary")) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    caption(L10n.string("Used by the built-in backend for Cloudinary features."))
                    CloudinaryKeysRow()
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CloudinaryKeysRow: View {
    private static let consoleURL = URL(string: "https://console.cloudinary.com/settings/api-keys")!

    @State private var cloudName = ""
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var pasteText = ""
    @State private var status: (message: String, isError: Bool)?
    @State private var hasStored = false
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            TextField(String(), text: $cloudName, prompt: Text(L10n.string("Cloud name")))
                .textFieldStyle(.plain)
                .fieldChrome()
            TextField(String(), text: $apiKey, prompt: Text(L10n.string("API key")))
                .textFieldStyle(.plain)
                .fieldChrome()
            SecureField(String(), text: $apiSecret, prompt: Text(hasStored ? L10n.string("Unchanged") : L10n.string("API secret")))
                .textFieldStyle(.plain)
                .fieldChrome()
                .onSubmit(save)
            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(String(), text: $pasteText, prompt: Text(L10n.string("Paste API environment variable")))
                    .textFieldStyle(.plain)
                    .fieldChrome()
                    .onSubmit(fill)
                Button(L10n.string("Fill"), action: fill)
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.large)
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: AppTheme.Spacing.md) {
                Button(L10n.string("Save"), action: save)
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.large)
                    .disabled(!canSave)
                if let status {
                    Text(verbatim: status.message)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(status.isError ? AppTheme.Status.errorColor : AppTheme.Status.successColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            Task {
                let keys = await Self.load()
                cloudName = keys.cloudinaryCloudName ?? ""
                hasStored = keys.cloudinaryAPISecret != nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("Cloudinary API Keys"))
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Button(action: openConsole) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text(L10n.string("Get a key"))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Accent.link)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .pointerStyle(.link)
        }
    }

    private var drafts: CloudinaryCredentials {
        CloudinaryCredentials(
            cloudName: cloudName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            apiSecret: apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var canSave: Bool {
        let c = drafts
        return !isSaving && !c.cloudName.isEmpty && !c.apiKey.isEmpty && !c.apiSecret.isEmpty
    }

    private func fill() {
        guard let c = CloudinaryCredentials.parse(environmentVariable: pasteText) else {
            status = (L10n.string("That isn't a Cloudinary API environment variable. Copy it from Cloudinary Console → Settings → API Keys."), true)
            return
        }
        cloudName = c.cloudName
        apiKey = c.apiKey
        apiSecret = c.apiSecret
        pasteText = ""
        status = nil
    }

    private func save() {
        guard canSave else { return }
        let credentials = drafts
        isSaving = true
        Task {
            let ok = await Self.save(credentials)
            isSaving = false
            hasStored = ok
            guard ok else {
                status = (L10n.string("Couldn't save to the Keychain."), true)
                return
            }
            apiSecret = ""
            status = (L10n.string("Saved."), false)
            BuiltInBackend.shared.keysChanged()
        }
    }

    private func openConsole() {
        NSWorkspace.shared.open(Self.consoleURL, configuration: .init(), completionHandler: nil)
    }

    @concurrent private static func load() async -> ProviderKeys { ProviderKeys.load(from: .current) }
    @concurrent private static func save(_ c: CloudinaryCredentials) async -> Bool { c.save(to: .current) }
}

private struct APIKeySettingRow: View {
    let provider: AgentProvider

    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            HStack(spacing: AppTheme.Spacing.sm) {
                field
                trailingControl
            }
        }
        .onAppear(perform: refresh)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text(provider.apiKeyPresentation.title)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Button(action: openConsole) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text(provider.apiKeyPresentation.getKeyTitle)
                    Image(systemName: "arrow.up.right")
                        .font(.system(
                            size: AppTheme.FontSize.xs,
                            weight: AppTheme.FontWeight.semibold
                        ))
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Accent.link)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .pointerStyle(.link)
        }
    }

    private var field: some View {
        SecureField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .onSubmit(save)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isFocused)
    }

    @ViewBuilder
    private var trailingControl: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button(L10n.string("Save"), action: save)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help(L10n.string("Remove API key"))
        }
    }

    private var placeholder: String {
        hasKey ? maskedKey : provider.apiKeyPresentation.placeholder
    }

    private func openConsole() {
        NSWorkspace.shared.open(
            provider.apiKeyPresentation.consoleURL, configuration: .init(), completionHandler: nil
        )
    }

    private func refresh() {
        Task {
            applyKey(await provider.loadAPIKey())
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        draft = ""
        isFocused = false
        let provider = provider
        Task {
            await provider.setAPIKey(key)
            applyKey(key)
        }
    }

    private func remove() {
        draft = ""
        let provider = provider
        Task {
            await provider.setAPIKey(nil)
            applyKey("")
        }
    }

    private func applyKey(_ key: String) {
        hasKey = !key.isEmpty
        maskedKey = key.count > 4
            ? String(repeating: "\u{2022}", count: 36) + key.suffix(4)
            : String(repeating: "\u{2022}", count: 32)
    }
}

@MainActor
private extension AgentProvider {
    var apiKeyPresentation: (
        title: String, getKeyTitle: String, placeholder: String, consoleURL: URL
    ) {
        switch self {
        case .anthropic:
            (
                L10n.string("Anthropic API Key"),
                L10n.string("Get Anthropic API key"),
                "sk-ant-…",
                URL(string: "https://console.anthropic.com/settings/keys")!
            )
        case .openAI:
            (
                L10n.string("OpenAI API Key"),
                L10n.string("Get OpenAI API key"),
                "sk-…",
                URL(string: "https://platform.openai.com/api-keys")!
            )
        }
    }
}
