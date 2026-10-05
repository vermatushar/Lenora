import Foundation
import Testing
@testable import Lenora

@Suite(.timeLimit(.minutes(1)))
final class BuiltInBackendSupervisorTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "BuiltInBackend-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    private actor Recorder {
        private(set) var states: [BuiltInBackendState] = []
        private(set) var backoffs: [Duration] = []
        private var waiters: [(@Sendable ([BuiltInBackendState]) -> Bool, CheckedContinuation<Void, Never>)] = []

        func record(_ state: BuiltInBackendState) {
            states.append(state)
            var remaining: [(@Sendable ([BuiltInBackendState]) -> Bool, CheckedContinuation<Void, Never>)] = []
            for waiter in waiters {
                if waiter.0(states) { waiter.1.resume() } else { remaining.append(waiter) }
            }
            waiters = remaining
        }

        func recordBackoff(_ duration: Duration) { backoffs.append(duration) }

        func waitUntil(_ predicate: @escaping @Sendable ([BuiltInBackendState]) -> Bool) async {
            if predicate(states) { return }
            await withCheckedContinuation { waiters.append((predicate, $0)) }
        }
    }

    private actor QuarantineFlag {
        private(set) var isSet = true
        func clear() { isSet = false }
    }

    /// Each `wait()` gets its own id, so cancelling an earlier wait never resumes a later one.
    private actor Gate {
        private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
        private var nextID = 0
        private(set) var completed = 0
        var waitingCount: Int { pending.count }

        func wait() async throws {
            let id = nextID
            nextID += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending[id] = $0 }
            } onCancel: {
                Task { await self.cancel(id) }
            }
            completed += 1
        }

        /// Releases the one wait left uncancelled once `count` waits have begun.
        func releaseSoleWaiter(afterWaits count: Int) -> Bool {
            guard nextID == count, pending.count == 1, let id = pending.keys.first else { return false }
            pending.removeValue(forKey: id)?.resume()
            return true
        }
        private func cancel(_ id: Int) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    }

    private func runtime(script: String) throws -> URL {
        let bin = root.appending(path: "Backend/python/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appending(path: "python3")
        try "#!/bin/sh\n\(script)\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path(percentEncoded: false))
        return root.appending(path: "Backend")
    }

    private func supervisor(
        script: String?, recorder: Recorder, probe: Bool = true,
        readyTimeout: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(3600)) },
        debounce: @escaping @Sendable () async throws -> Void = {},
        backoff: (@Sendable (Duration) async throws -> Void)? = nil,
        isQuarantined: @escaping @Sendable (URL) async -> Bool = { _ in false }
    ) throws -> BuiltInBackendSupervisor {
        let runtime = try script.map { try self.runtime(script: $0) }
        let dependencies = BuiltInBackendSupervisor.Dependencies(
            runtimeDirectory: { runtime },
            dataDirectory: root.appending(path: "data"),
            loadKeys: { ProviderKeys() },
            isQuarantined: isQuarantined,
            probe: { _ in probe },
            readyTimeout: readyTimeout,
            backoff: backoff ?? { await recorder.recordBackoff($0) },
            debounce: debounce,
            parentPID: getpid(),
            baseEnvironment: [:]
        )
        return BuiltInBackendSupervisor(dependencies: dependencies) { await recorder.record($0) }
    }

    private static func isRunning(_ state: BuiltInBackendState) -> Bool {
        if case .running = state { true } else { false }
    }

    private static func isFailed(_ state: BuiltInBackendState) -> Bool {
        if case .failed = state { true } else { false }
    }

    private static func isAlreadyRunning(_ state: BuiltInBackendState?) -> Bool {
        if case .failed(.alreadyRunning, _) = state { true } else { false }
    }

    @Test func readyLineMakesItRunningOnThatPort() async throws {
        let recorder = Recorder()
        let sut = try supervisor(script: "echo 'LENORA_READY port=4567'; exec sleep 3600", recorder: recorder)
        await sut.start()
        await recorder.waitUntil { $0.contains(where: Self.isRunning) }
        guard case .running(let configuration) = await recorder.states.last else { Issue.record("not running"); return }
        #expect(configuration.baseURL.absoluteString == "http://127.0.0.1:4567")
        #expect(configuration.token?.count == 64)
        await sut.stop()
    }

    @Test func missingRuntimeReportsNotIncluded() async throws {
        let recorder = Recorder()
        let sut = try supervisor(script: nil, recorder: recorder)
        await sut.start()
        await recorder.waitUntil { $0.last == .notIncluded }
    }

    @Test func lockedDataDirectoryIsNotRetried() async throws {
        let recorder = Recorder()
        let sut = try supervisor(script: "exit 3", recorder: recorder)
        await sut.start()
        await recorder.waitUntil { if case .failed(.alreadyRunning, _) = $0.last { true } else { false } }
        await sut.stop()
        #expect(await recorder.backoffs.isEmpty)
    }

    @Test func crashLoopBacksOffThenStopsAfterFiveFailures() async throws {
        let recorder = Recorder()
        let sut = try supervisor(script: "echo boom >&2; exit 1", recorder: recorder)
        await sut.start()
        await recorder.waitUntil { $0.filter { if case .failed = $0 { true } else { false } }.count == 5 }
        await sut.stop()
        #expect(await recorder.backoffs == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
        guard case .failed(.crashed(1), let log) = await recorder.states.last(where: { if case .failed = $0 { true } else { false } }) else {
            Issue.record("expected a crash"); return
        }
        #expect(log == ["boom"])
    }

    @Test func noReadyLineTimesOutAndKillsTheProcess() async throws {
        let recorder = Recorder()
        let sut = try supervisor(script: "exec sleep 3600", recorder: recorder, readyTimeout: {})
        await sut.start()
        await recorder.waitUntil { if case .failed(.timeout, _) = $0.last { true } else { false } }
        await sut.stop()
        #expect(await sut.currentPID() == nil)
    }

    @Test func malformedReadyLineIsAProtocolViolation() async throws {
        let recorder = Recorder()
        let sut = try supervisor(script: "echo hello; exec sleep 3600", recorder: recorder)
        await sut.start()
        await recorder.waitUntil { if case .failed(.protocolViolation, _) = $0.last { true } else { false } }
        await sut.stop()
    }

    @Test func chattyStderrDoesNotBlockReadiness() async throws {
        let recorder = Recorder()
        let script = "i=0; while [ $i -lt 20000 ]; do echo \"log line $i\" >&2; i=$((i+1)); done; echo 'LENORA_READY port=4567'; exec sleep 3600"
        let sut = try supervisor(script: script, recorder: recorder)
        await sut.start()
        await recorder.waitUntil { $0.contains(where: Self.isRunning) }
        await sut.stop()
    }

    @Test func stopTerminatesTheChild() async throws {
        let recorder = Recorder()
        let sut = try supervisor(script: "echo 'LENORA_READY port=4567'; exec sleep 3600", recorder: recorder)
        await sut.start()
        await recorder.waitUntil { $0.contains(where: Self.isRunning) }
        let pid = try #require(await sut.currentPID())
        await sut.stop()
        #expect(kill(pid, 0) == -1)
        #expect(await recorder.states.last == .stopped)
    }

    @Test func rapidKeyChangesRestartOnce() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let sut = try supervisor(script: "echo 'LENORA_READY port=4567'; exec sleep 3600", recorder: recorder,
                                 debounce: { try await gate.wait() })
        await sut.start()
        await recorder.waitUntil { $0.contains(where: Self.isRunning) }
        await sut.keysChanged()
        await sut.keysChanged()
        await sut.keysChanged()
        while !(await gate.releaseSoleWaiter(afterWaits: 3)) { await Task.yield() }
        await recorder.waitUntil { $0.filter(Self.isRunning).count == 2 }
        #expect(await gate.completed == 1)
        await sut.stop()
    }

    @Test func overlappingRestartsLeaveOneStoppableChild() async throws {
        let recorder = Recorder()
        let pids = root.appending(path: "pids").path(percentEncoded: false)
        let terminating = root.appending(path: "terminating").path(percentEncoded: false)
        let release = root.appending(path: "release").path(percentEncoded: false)
        let script = """
        echo $$ >> '\(pids)'
        trap 'touch "\(terminating)"; while [ ! -e "\(release)" ]; do sleep 0.01; done; kill $!; exit 0' TERM
        echo 'LENORA_READY port=4567'
        sleep 3600 & wait
        """
        let sut = try supervisor(script: script, recorder: recorder)
        await sut.start()
        await recorder.waitUntil { $0.contains(where: Self.isRunning) }
        let restarts = Task {
            async let first: Void = sut.restart()
            async let second: Void = sut.restart()
            _ = await (first, second)
        }
        while !FileManager.default.fileExists(atPath: terminating) { await Task.yield() }
        FileManager.default.createFile(atPath: release, contents: nil)
        await restarts.value
        await recorder.waitUntil { $0.last.map(Self.isRunning) ?? false }
        let launched = try String(contentsOfFile: pids, encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
        let live = launched.filter { kill($0, 0) == 0 }
        #expect(live.count == 1)
        #expect(live.first == (await sut.currentPID()))
        await sut.stop()
        #expect(launched.allSatisfy { kill($0, 0) == -1 })
    }

    @Test func stopDoesNotWaitOutTheBackoff() async throws {
        let recorder = Recorder()
        let gate = Gate()
        let sut = try supervisor(script: "exit 1", recorder: recorder, backoff: { _ in try await gate.wait() })
        await sut.start()
        while await gate.waitingCount == 0 { await Task.yield() }
        await sut.stop()
        #expect(await gate.completed == 0)
        #expect(await recorder.states.last == .stopped)
    }

    @Test func exitIsReportedWhileAGrandchildHoldsStderr() async throws {
        let recorder = Recorder()
        let grandchild = root.appending(path: "grandchild")
        let sut = try supervisor(script: "sleep 3600 & echo $! > '\(grandchild.path(percentEncoded: false))'; exit 3", recorder: recorder)
        await sut.start()
        await recorder.waitUntil { Self.isAlreadyRunning($0.last) }
        let pid = try #require(Int32(String(contentsOf: grandchild, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(pid, SIGKILL)
        await sut.stop()
    }

    @Test func signalDeathIsARetryableCrash() async throws {
        let recorder = Recorder()
        let sut = try supervisor(script: "kill -INT $$", recorder: recorder)
        await sut.start()
        await recorder.waitUntil { $0.filter(Self.isFailed).count == 2 }
        await sut.stop()
        #expect(await recorder.states.first(where: Self.isFailed) == .failed(.crashed(SIGINT), log: []))
        #expect(await recorder.backoffs.first == .seconds(1))
    }

    @Test func startRelaunchesAfterATerminalFailure() async throws {
        let recorder = Recorder()
        let sut = try supervisor(script: "exit 3", recorder: recorder)
        await sut.start()
        await recorder.waitUntil { Self.isAlreadyRunning($0.last) }
        await sut.start()
        await recorder.waitUntil { $0.filter { $0 == .starting }.count == 2 }
        await sut.stop()
    }

    @Test func quarantinedInterpreterFailsWithoutLaunching() async throws {
        let recorder = Recorder()
        let quarantined = QuarantineFlag()
        let marker = root.appending(path: "launched")
        let sut = try supervisor(
            script: "touch '\(marker.path(percentEncoded: false))'; exit 3", recorder: recorder,
            isQuarantined: { _ in await quarantined.isSet }
        )
        await sut.start()
        await recorder.waitUntil { if case .failed(.quarantined, _) = $0.last { true } else { false } }
        #expect(!(await recorder.states.contains(.starting)))
        #expect(await recorder.backoffs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))

        await quarantined.clear()
        await sut.start()
        await recorder.waitUntil { Self.isAlreadyRunning($0.last) }
        #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
        await sut.stop()
    }

    @Test func quarantineCheckReadsTheExtendedAttribute() async throws {
        let python = try runtime(script: "exit 0").appending(path: "python/bin/python3")
        #expect(!(await BuiltInBackendSupervisor.isQuarantined(python)))
        let flag = "0081;00000000;Safari;"
        #expect(setxattr(python.path(percentEncoded: false), "com.apple.quarantine", flag, flag.utf8.count, 0, 0) == 0)
        #expect(await BuiltInBackendSupervisor.isQuarantined(python))
    }

    @Test func keyChangeRelaunchesAfterAConfigurationFailure() async throws {
        let recorder = Recorder()
        let sut = try supervisor(script: "exit 2", recorder: recorder)
        await sut.start()
        await recorder.waitUntil { if case .failed(.configuration, _) = $0.last { true } else { false } }
        await sut.keysChanged()
        await recorder.waitUntil { $0.filter { $0 == .starting }.count == 2 }
        await sut.stop()
    }
}
