import AppKit
import Observation

@Observable @MainActor
final class BuiltInBackend {
    static let shared = BuiltInBackend()

    private(set) var state: BuiltInBackendState = .stopped
    @ObservationIgnored private var supervisor: BuiltInBackendSupervisor?
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onConfigurationChange: @MainActor () async -> Void

    var configuration: LenoraBackendConfiguration? {
        if case .running(let configuration) = state { configuration } else { nil }
    }

    init(
        dependencies: BuiltInBackendSupervisor.Dependencies = .live,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        onConfigurationChange: @escaping @MainActor () async -> Void = { await BackendConnection.shared.reload() }
    ) {
        self.environment = environment
        self.defaults = defaults
        self.onConfigurationChange = onConfigurationChange
        supervisor = BuiltInBackendSupervisor(dependencies: dependencies) { [weak self] _ in
            await self?.refreshState()
        }
        _ = NotificationCenter.default.addObserver(forName: .agentAPIKeyChanged, object: nil, queue: .main) { [weak self] note in
            guard note.object as? String == AgentProvider.openAI.rawValue else { return }
            MainActor.assumeIsolated { self?.keysChanged() }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
    }

    private var isSelected: Bool { BackendMode.effective(environment: environment, defaults: defaults) == .builtIn }

    func startIfSelected() {
        guard isSelected else { return }
        Task { await supervisor?.start() }
    }

    func select(_ mode: BackendMode) {
        defaults.set(mode.rawValue, forKey: BackendMode.defaultsKey)
        let start = isSelected
        Task {
            if start { await supervisor?.start() } else { await supervisor?.stop() }
            await onConfigurationChange()
        }
    }

    func restart() { Task { await supervisor?.restart() } }
    func keysChanged() { Task { await supervisor?.keysChanged() } }
    func recheck() { Task { await supervisor?.recheck() } }
    func terminateForQuit() { supervisor?.terminateImmediately() }

    /// Reads the supervisor's state back because reports can arrive out of order.
    private func refreshState() async {
        guard let latest = await supervisor?.currentState() else { return }
        let previous = configuration
        state = latest
        guard configuration != previous else { return }
        Task { await onConfigurationChange() }
    }
}
