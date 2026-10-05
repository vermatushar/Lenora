import Foundation
import Security
import Synchronization

enum BuiltInBackendFailure: Sendable, Equatable {
    case timeout, protocolViolation, alreadyRunning, configuration, `internal`
    case crashed(Int32)

    var isRetryable: Bool {
        switch self {
        case .alreadyRunning, .configuration: false
        case .timeout, .protocolViolation, .internal, .crashed: true
        }
    }

    init(exitCode: Int32) {
        switch exitCode {
        case 2: self = .configuration
        case 3: self = .alreadyRunning
        default: self = .crashed(exitCode)
        }
    }
}

enum BuiltInBackendState: Sendable, Equatable {
    case stopped, notIncluded, starting
    case running(LenoraBackendConfiguration)
    case failed(BuiltInBackendFailure, log: [String])
}

actor BuiltInBackendSupervisor {
    struct Dependencies: Sendable {
        var runtimeDirectory: @Sendable () -> URL?
        var dataDirectory: URL
        var loadKeys: @Sendable () -> ProviderKeys
        var probe: @Sendable (LenoraBackendConfiguration) async -> Bool
        var readyTimeout: @Sendable () async -> Void
        var backoff: @Sendable (Duration) async throws -> Void
        var debounce: @Sendable () async throws -> Void
        var parentPID: Int32
        var baseEnvironment: [String: String]
    }

    static let backoffSchedule: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
    static let maxConsecutiveFailures = 5
    static let logCapacity = 100

    private enum Event: Sendable { case line(String), exited(Int32), timedOut }

    private let dependencies: Dependencies
    private let report: @Sendable (BuiltInBackendState) async -> Void
    private var loop: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var stopping = false
    private var state: BuiltInBackendState = .stopped
    private let runningPID = Mutex<Int32?>(nil)

    init(dependencies: Dependencies, report: @escaping @Sendable (BuiltInBackendState) async -> Void) {
        self.dependencies = dependencies
        self.report = report
    }

    func start() {
        guard loop == nil else { return }
        stopping = false
        loop = Task { await self.run() }
    }

    func stop() async {
        debounceTask?.cancel()
        guard let loop else { return }
        stopping = true
        send(SIGTERM)
        let escalation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.send(SIGKILL)
        }
        await loop.value
        escalation.cancel()
        self.loop = nil
        await publish(.stopped)
    }

    func restart() async {
        await stop()
        start()
    }

    func keysChanged() {
        debounceTask?.cancel()
        let debounce = dependencies.debounce
        debounceTask = Task {
            do { try await debounce() } catch { return }
            await self.restartIfActive()
        }
    }

    func recheck() async {
        guard case .running(let configuration) = state else { return }
        if !(await dependencies.probe(configuration)) { send(SIGTERM) }
    }

    nonisolated func terminateImmediately() {
        runningPID.withLock { pid in if let pid { kill(pid, SIGTERM) } }
    }

    func currentPID() -> Int32? { runningPID.withLock { $0 } }

    private func restartIfActive() async {
        guard loop != nil else { return }
        await restart()
    }

    private func send(_ signal: Int32) {
        runningPID.withLock { pid in if let pid { kill(pid, signal) } }
    }

    private func publish(_ new: BuiltInBackendState) async {
        state = new
        await report(new)
    }

    private func run() async {
        var failures = 0
        while !stopping {
            guard let runtime = dependencies.runtimeDirectory() else {
                await publish(.notIncluded)
                return
            }
            let (failure, log, reachedRunning) = await runOnce(runtime: runtime)
            if stopping { return }
            if reachedRunning { failures = 0 }
            await publish(.failed(failure, log: log))
            guard failure.isRetryable else { return }
            failures += 1
            guard failures < Self.maxConsecutiveFailures else { return }
            do {
                try await dependencies.backoff(Self.backoffSchedule[min(failures, Self.backoffSchedule.count) - 1])
            } catch { return }
        }
    }

    private func runOnce(runtime: URL) async -> (BuiltInBackendFailure, [String], Bool) {
        let log = LogBuffer(capacity: Self.logCapacity)
        do {
            try await Self.createDirectory(dependencies.dataDirectory)
        } catch {
            return (.configuration, [error.localizedDescription], false)
        }
        guard let token = Self.makeToken() else { return (.internal, ["Could not create a launch token."], false) }
        let process = Process()
        process.executableURL = runtime.appending(path: "python/bin/python3")
        process.arguments = ["-I", "-B", "-m", "lenora_backend"]
        process.environment = BuiltInBackendEnvironment.make(
            keys: dependencies.loadKeys(), token: token, dataDirectory: dependencies.dataDirectory,
            parentPID: dependencies.parentPID, base: dependencies.baseEnvironment)
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let (events, sink) = AsyncStream<Event>.makeStream()
        process.terminationHandler = { sink.yield(.exited($0.terminationStatus)) }

        await publish(.starting)
        do {
            try process.run()
        } catch {
            return (.internal, [error.localizedDescription], false)
        }
        runningPID.withLock { $0 = process.processIdentifier }
        defer { runningPID.withLock { $0 = nil } }

        let stdoutLines = PipeLines(stdout.fileHandleForReading), stderrLines = PipeLines(stderr.fileHandleForReading)
        let stdoutReader = Task.detached {
            var first = true
            for await line in stdoutLines.lines where first {
                first = false
                sink.yield(.line(line))
            }
        }
        let stderrReader = Task.detached {
            for await line in stderrLines.lines { log.append(line) }
        }
        let readyTimeout = dependencies.readyTimeout
        let timeout = Task { await readyTimeout(); sink.yield(.timedOut) }
        defer { timeout.cancel(); stdoutReader.cancel(); stderrReader.cancel() }

        var failure: BuiltInBackendFailure?
        var reachedRunning = false
        for await event in events {
            switch event {
            case .line(let line) where failure == nil && !reachedRunning:
                timeout.cancel()
                guard let port = BuiltInBackendReadyLine.port(from: line),
                      let url = URL(string: "http://127.0.0.1:\(port)") else {
                    failure = .protocolViolation
                    send(SIGTERM)
                    continue
                }
                let configuration = LenoraBackendConfiguration(baseURL: url, token: token)
                guard await dependencies.probe(configuration) else {
                    failure = .internal
                    send(SIGTERM)
                    continue
                }
                reachedRunning = true
                await publish(.running(configuration))
            case .timedOut where failure == nil && !reachedRunning:
                failure = .timeout
                send(SIGKILL)
            case .exited(let code):
                _ = await stderrReader.result
                return (failure ?? BuiltInBackendFailure(exitCode: code), log.snapshot(), reachedRunning)
            default:
                continue
            }
        }
        return (.internal, log.snapshot(), reachedRunning)
    }

    @concurrent private static func createDirectory(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func makeToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private final class LogBuffer: Sendable {
    private let lines = Mutex<[String]>([])
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func append(_ line: String) {
        lines.withLock { lines in
            lines.append(line)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
    }

    func snapshot() -> [String] { lines.withLock { $0 } }
}

/// `FileHandle.bytes` blocks a cooperative thread in `read(2)`; the readability handler reads on dispatch instead.
private final class PipeLines: Sendable {
    let lines: AsyncStream<String>
    private let pending = Mutex(Data())

    init(_ handle: FileHandle) {
        let (lines, continuation) = AsyncStream<String>.makeStream()
        self.lines = lines
        continuation.onTermination = { _ in handle.readabilityHandler = nil }
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                let rest = pending.withLock { pending in defer { pending = Data() }; return pending }
                if !rest.isEmpty { continuation.yield(Self.line(rest)) }
                continuation.finish()
                return
            }
            for line in completeLines(appending: chunk) { continuation.yield(line) }
        }
    }

    private func completeLines(appending chunk: Data) -> [String] {
        pending.withLock { pending in
            pending.append(chunk)
            guard let last = pending.lastIndex(of: 0x0A) else { return [] }
            let complete = pending[..<last]
            defer { pending = Data(pending[pending.index(after: last)...]) }
            return complete.split(separator: 0x0A, omittingEmptySubsequences: false).map(Self.line)
        }
    }

    private static func line(_ bytes: Data) -> String {
        String(decoding: bytes.last == 0x0D ? bytes.dropLast() : bytes, as: UTF8.self)
    }
}

extension BuiltInBackendSupervisor.Dependencies {
    static var live: Self {
        let bundleID = Bundle.main.bundleIdentifier ?? "xyz.agentage.lenora"
        let support = URL.applicationSupportDirectory.appending(path: bundleID).appending(path: "Backend")
        return Self(
            runtimeDirectory: { BundledResource.url("Backend") },
            dataDirectory: support,
            loadKeys: { ProviderKeys.load(from: .current) },
            probe: { configuration in
                (try? await LenoraBackendClient(configuration: configuration).health(recheckAddons: false)) != nil
            },
            readyTimeout: { try? await Task.sleep(for: .seconds(90)) },
            backoff: { try await Task.sleep(for: $0) },
            debounce: { try await Task.sleep(for: .seconds(1)) },
            parentPID: getpid(),
            baseEnvironment: ProcessInfo.processInfo.environment
        )
    }
}
