import SwiftUI

struct BackendPane: View {
    private let connection = BackendConnection.shared
    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var mode = BackendMode.effective(environment: ProcessInfo.processInfo.environment, defaults: .standard)

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: L10n.string("Backend")) {
                connectionSection
            }
            if let health = connection.health {
                SettingsSection(title: L10n.string("Adapters")) {
                    adaptersSection(health)
                }
            }
        }
        .onAppear {
            urlText = UserDefaults.standard.string(forKey: LenoraBackendConfiguration.urlDefaultsKey) ?? ""
        }
        .onChange(of: mode) { BuiltInBackend.shared.select($1) }
    }

    private var modePicker: some View {
        Picker(String(), selection: $mode) {
            Text(L10n.string("Built-in")).tag(BackendMode.builtIn)
            Text(L10n.string("Custom URL")).tag(BackendMode.custom)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(connection.urlFromEnvironment)
    }

    @ViewBuilder private var builtInSection: some View {
        switch BuiltInBackend.shared.state {
        case .stopped, .starting:
            HStack(spacing: AppTheme.Spacing.sm) {
                ProgressView().controlSize(.small)
                status(L10n.string("Starting…"), color: AppTheme.Text.secondaryColor)
            }
            .font(.system(size: AppTheme.FontSize.sm))
        case .running:
            status(L10n.string("Running on this Mac"), color: AppTheme.Status.successColor)
                .font(.system(size: AppTheme.FontSize.sm))
        case .notIncluded:
            status(L10n.string("This build doesn't include the built-in backend. Run ./scripts/dev or choose Custom URL."), color: AppTheme.Text.secondaryColor)
                .font(.system(size: AppTheme.FontSize.sm))
        case .failed(let failure, let log):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack(spacing: AppTheme.Spacing.md) {
                    Button(L10n.string("Restart")) { BuiltInBackend.shared.restart() }
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .controlSize(.large)
                    status(failureMessage(failure), color: AppTheme.Status.errorColor)
                }
                DisclosureGroup(L10n.string("Log")) {
                    Text(verbatim: log.joined(separator: "\n"))
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))
        }
    }

    private func failureMessage(_ failure: BuiltInBackendFailure) -> String {
        switch failure {
        case .timeout: L10n.string("The built-in backend didn't start in time.")
        case .protocolViolation, .internal: L10n.string("The built-in backend stopped responding.")
        case .alreadyRunning: L10n.string("Another copy of Lenora is using the built-in backend.")
        case .configuration: L10n.string("The built-in backend rejected its settings.")
        case .crashed(let code): L10n.string("The built-in backend quit (code \(Int(code))).")
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            modePicker
            Text(verbatim: mode == .builtIn
                ? L10n.string("Generation runs in a backend built into Lenora. Add provider keys in API Keys.")
                : L10n.string("Generation runs on your Lenora backend. The token is stored in the macOS Keychain."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if mode == .builtIn {
                builtInSection
            } else {
                customSection
            }
        }
    }

    @ViewBuilder private var customSection: some View {
        fieldGroup(title: L10n.string("URL")) {
            if connection.urlFromEnvironment {
                textField(.constant(connection.configuration?.baseURL.absoluteString ?? ""), prompt: "")
                    .disabled(true)
                Text(L10n.string("Set by LENORA_BACKEND_URL for this launch."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                textField($urlText, prompt: LenoraBackendConfiguration.defaultURL)
            }
        }
        fieldGroup(title: L10n.string("Token")) {
            if connection.tokenFromEnvironment {
                SecureField(String(), text: .constant(""), prompt: Text(L10n.string("Unchanged")))
                    .textFieldStyle(.plain)
                    .fieldChrome()
                    .disabled(true)
                Text(L10n.string("Set by LENORA_TOKEN for this launch."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                SecureField(tokenPrompt, text: $tokenText)
                    .textFieldStyle(.plain)
                    .fieldChrome()
            }
        }
        HStack(spacing: AppTheme.Spacing.md) {
            Button(L10n.string("Test Connection"), action: testConnection)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
                .disabled(connection.state == .connecting)
            statusLabel
        }
    }

    private func adaptersSection(_ health: BackendHealth) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(L10n.string("Backend \(health.backendVersion ?? "?") · Protocol \(health.protocolVersion)"))
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            ForEach(health.adapters ?? [], id: \.id) { adapter in
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                    Text(verbatim: adapter.id)
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Spacer(minLength: AppTheme.Spacing.lg)
                    if adapter.enabled {
                        Text(L10n.string("Enabled"))
                            .foregroundStyle(AppTheme.Status.successColor)
                    } else {
                        Text(verbatim: disabledReason(adapter))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
                .font(.system(size: AppTheme.FontSize.sm))
                if let details = adapter.details {
                    detailRows(details)
                }
            }
        }
    }

    private func disabledReason(_ adapter: AdapterHealth) -> String {
        let raw = adapter.reason ?? ""
        guard mode == .builtIn else { return raw }
        return MissingProviderKeys.message(adapterID: adapter.id, reason: adapter.reason) ?? raw
    }

    @ViewBuilder private func detailRows(_ details: AdapterHealthDetails) -> some View {
        ForEach(details.addons ?? []) { addon in
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(verbatim: addon.id)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(verbatim: addon.reason ?? addon.mode)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer(minLength: AppTheme.Spacing.lg)
                Text(addon.available ? L10n.string("Available") : L10n.string("Unavailable"))
                    .foregroundStyle(addon.available ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
            }
            .font(.system(size: AppTheme.FontSize.xs))
        }
        if let budget = details.budget {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Daily budget"))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: AppTheme.Spacing.lg)
                Text(budget.summary)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .font(.system(size: AppTheme.FontSize.xs))
        }
    }

    private var tokenPrompt: String {
        connection.configuration?.token == nil ? L10n.string("Paste LENORA_TOKEN") : L10n.string("Unchanged")
    }

    private func fieldGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(verbatim: title)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            content()
        }
    }

    private func textField(_ text: Binding<String>, prompt: String) -> some View {
        TextField(String(), text: text, prompt: Text(verbatim: prompt))
            .textFieldStyle(.plain)
            .fieldChrome()
    }

    private func testConnection() {
        let url = urlText
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenText = ""
        Task { await connection.save(url: url, token: token.isEmpty ? nil : token) }
    }

    @ViewBuilder private var statusLabel: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            switch connection.state {
            case .unknown:
                EmptyView()
            case .connecting:
                ProgressView().controlSize(.small)
            case .connected:
                status(L10n.string("Connected"), color: AppTheme.Status.successColor)
            case .unreachable(let url):
                status(L10n.string("Can't reach backend at \(url.absoluteString). Start it with ./scripts/dev, then test again."), color: AppTheme.Status.errorColor)
            case .unauthorized:
                status(L10n.string("Token rejected. Paste LENORA_TOKEN from .env."), color: AppTheme.Status.errorColor)
            case .invalidConfiguration(.invalidURL(let url)):
                status(L10n.string("\(url) is not a valid URL."), color: AppTheme.Status.errorColor)
            case .invalidConfiguration(.insecureURL(let url)):
                status(L10n.string("\(url) must use HTTPS, or HTTP on this Mac only."), color: AppTheme.Status.errorColor)
            case .invalidConfiguration(.builtInNotRunning):
                EmptyView()
            case .tokenNotSaved:
                status(L10n.string("Couldn't save the token to the Keychain."), color: AppTheme.Status.errorColor)
            case .failed(let message):
                status(L10n.string("Connection failed: \(message)"), color: AppTheme.Status.errorColor)
            }
        }
        .font(.system(size: AppTheme.FontSize.sm))
    }

    private func status(_ message: String, color: Color) -> some View {
        Text(verbatim: message)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    func fieldChrome() -> some View {
        font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            )
    }
}

@MainActor
extension BudgetStatus {
    private static let usd = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(2...4))

    var summary: String {
        if unit == "usd" {
            let spent = used.formatted(Self.usd)
            guard let limit else { return L10n.string("\(spent) used · No limit") }
            return L10n.string("\(spent) of \(limit.formatted(Self.usd))")
        }
        let spent = used.formatted(.number.precision(.fractionLength(0...3)))
        guard let limit else { return L10n.string("\(spent) credits used · No limit") }
        return L10n.string("\(spent) of \(limit.formatted()) credits")
    }
}
