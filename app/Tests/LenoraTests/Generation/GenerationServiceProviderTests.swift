import Foundation
import Testing
@testable import Lenora

@MainActor
private func cloudinaryCatalog() throws -> ModelCatalog {
    let catalog = ModelCatalog()
    catalog.apply(try BackendCoding.decoder().decode(BackendCapabilities.self, from: ProtocolFixtures.data("Capabilities.cloudinary")))
    return catalog
}

@MainActor
struct GenerationServiceProviderTests {
    private func start(_ service: GenerationService, editor: EditorViewModel, source: MediaAsset) -> String {
        var input = GenerationInput(prompt: "", model: "cloudinary/background-removal", duration: 0, aspectRatio: "")
        input.createdAt = Date()
        return service.generate(
            genInput: input, assetType: .image, placeholderDuration: 0, references: [source],
            name: "Remove Background", buildParams: { _ in .removeBackground },
            fileExtension: "png", projectURL: editor.projectURL, editor: editor
        )
    }

    private func placeholder(_ id: String, in editor: EditorViewModel) throws -> MediaAsset {
        try #require(editor.mediaAssets.first { $0.id == id })
    }

    @Test func submitsJobWithModelKindAndAssetRefsAndPersistsJobId() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let provider = FakeProvider(states: [jobState(.running)])
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationInput?.jobId == "fake:1" }
        let (job, key) = try #require(await provider.submitted.first)
        #expect(job.kind == "image.removeBackground")
        #expect(job.model == "cloudinary/background-removal")
        #expect(job.inputs == [.assetRef(try #require(await provider.uploads.first))])
        #expect(!key.isEmpty)
        service.stopMonitoring()
    }

    @Test func unknownModelFailsPlaceholderWithoutSubmitting() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let provider = FakeProvider(states: [])
        let service = GenerationService(provider: { provider }, catalog: ModelCatalog())
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { if case .failed = placeholder.generationStatus { true } else { false } }
        #expect(await provider.submitted.isEmpty)
        #expect(await provider.uploads.isEmpty)
    }

    @Test func unsupportedInputsAfterUploadFailAsARefusalNotAnUploadFailure() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let provider = FakeProvider(states: [])
        let service = GenerationService(provider: { provider }, catalog: try cloudinaryCatalog())
        var input = GenerationInput(prompt: "", model: "cloudinary/background-removal", duration: 0, aspectRatio: "")
        input.createdAt = Date()
        let params = VideoGenerationParams(prompt: "x", duration: 4, aspectRatio: "", resolution: nil, referenceVideoURLs: ["ref"])
        let id = service.generate(
            genInput: input, assetType: .image, placeholderDuration: 0, references: [fixture.image],
            buildParams: { _ in .video(params) }, fileExtension: "png", projectURL: fixture.editor.projectURL, editor: fixture.editor
        )
        let placeholder = try placeholder(id, in: fixture.editor)
        let refusal = GenerationError.unsupportedInputs("video and audio references").localizedDescription
        try await fixture.waitUntil { placeholder.generationStatus == .failed(refusal) }
        #expect(await provider.submitted.isEmpty)
    }

    @Test func disconnectedBackendFailsPlaceholder() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let service = GenerationService(provider: { nil }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationStatus == .failed(GenerationError.backendUnavailable.localizedDescription) }
    }

    @Test func failedJobMarksPlaceholderFailedWithMessage() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let failed = try BackendCoding.decoder().decode(JobState.self, from: ProtocolFixtures.data("JobState.failed"))
        let service = GenerationService(provider: { FakeProvider(states: [failed]) }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationStatus == .failed("Resource not found") }
    }

    @Test func notFoundDuringPollFailsWithRestartMessage() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let notFound = BackendError.problem(BackendProblem(code: "not_found", detail: "Unknown job.", status: 404, retryable: false))
        let service = GenerationService(provider: { FakeProvider(failure: notFound) }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationStatus == .failed("The backend restarted. Generate again.") }
    }

    @Test func succeededJobLandsResultInProject() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let service = GenerationService(provider: { FakeProvider(states: [jobState(.succeeded, results: [result])]) }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
        #expect(placeholder.generationInput?.results == [result])
    }

    @Test func rejectedResultDownloadKeepsRetryableFailure() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        fixture.editor.remoteDownloadFetch = { request in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data().write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let service = GenerationService(provider: { FakeProvider(states: [jobState(.succeeded, results: [result])]) }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationStatus == .failed(RemoteDownloadError.badStatus(404).localizedDescription) }
        #expect(placeholder.pendingDownloadURL == fixture.servedImageURL)
    }

    @Test func retryDownloadLandsPersistedResult() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let placeholder = fixture.addGeneratingPlaceholder(jobId: "fake:1", fileExtension: "png")
        placeholder.generationInput?.results = [result]
        placeholder.generationStatus = .failed("The download failed (HTTP 404).")
        placeholder.pendingDownloadURL = fixture.servedImageURL
        let service = GenerationService(provider: { nil }, catalog: ModelCatalog())
        service.retryDownload(asset: placeholder, editor: fixture.editor)
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
        #expect(placeholder.pendingDownloadURL == nil)
    }

    @Test func transientPollingFailureLeavesPlaceholderGenerating() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let provider = FakeProvider(states: [jobState(.running)], failure: .unreachable(URL(string: "https://backend.example")!))
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationInput?.jobId != nil }
        try await fixture.waitUntil { service.monitoredJobIds.isEmpty }
        #expect(placeholder.generationStatus == .generating)
    }

    @Test func permanentPollingFailureFailsPlaceholder() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let provider = FakeProvider(states: [], failure: .invalidResponse(status: 404))
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationStatus == .failed(BackendError.invalidResponse(status: 404).localizedDescription) }
    }

    @Test func unauthorizedPollingPausesAndResumesWhenReconnected() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let provider = FakeProvider(states: [], failure: .unauthorized)
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationInput?.jobId != nil }
        try await fixture.waitUntil { service.monitoredJobIds.isEmpty }
        #expect(placeholder.generationStatus == .generating)
        #expect(placeholder.isRecoveringGeneration)

        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let reconnected = GenerationService(provider: { FakeProvider(states: [jobState(.succeeded, results: [result])]) }, catalog: catalog)
        reconnected.resumePendingGenerations(editor: fixture.editor)
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
    }

    @Test func submitPersistsKeyAndRequestBeforeSubmitting() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let provider = FakeProvider(states: [], hangsOnSubmit: true)
        let service = GenerationService(provider: { provider }, catalog: try cloudinaryCatalog())
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { await !provider.submitted.isEmpty }
        let (job, key) = try #require(await provider.submitted.first)
        let input = try #require(placeholder.generationInput)
        #expect(input.idempotencyKey == key)
        #expect(input.jobId == nil)
        #expect(input.submission?.kind == job.kind)
        #expect(input.submission?.inputs == job.inputs)
        let entry = try #require(fixture.editor.mediaManifest.entries.first { $0.id == placeholder.id })
        #expect(entry.generationStatus == "preparing")
        #expect(entry.generationInput?.idempotencyKey == key)
        service.stopMonitoring()
        #expect(placeholder.generationStatus == .preparing)
    }

    @Test func restoredPreparingPlaceholderResubmitsWithSameKey() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let hanging = FakeProvider(states: [], hangsOnSubmit: true)
        let first = GenerationService(provider: { hanging }, catalog: catalog)
        let original = try placeholder(start(first, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { await !hanging.submitted.isEmpty }
        let (firstJob, key) = try #require(await hanging.submitted.first)
        first.stopMonitoring()

        let data = try JSONEncoder().encode(original.toManifestEntry(projectURL: fixture.editor.projectURL))
        let restored = MediaAsset(entry: try JSONDecoder().decode(MediaManifestEntry.self, from: data), resolvedURL: original.url)
        #expect(restored.generationStatus == .preparing)
        fixture.editor.removeGenerationPlaceholders([original])
        fixture.editor.mediaAssets.append(restored)

        let provider = FakeProvider(states: [jobState(.running)])
        let second = GenerationService(provider: { provider }, catalog: catalog)
        second.resumePendingGenerations(editor: fixture.editor)
        try await fixture.waitUntil { restored.generationInput?.jobId == "fake:1" }
        let (job, resubmittedKey) = try #require(await provider.submitted.first)
        #expect(resubmittedKey == key)
        #expect(job.kind == firstJob.kind && job.model == firstJob.model && job.inputs == firstJob.inputs)
        #expect(try BackendCoding.encoder().encode(job) == BackendCoding.encoder().encode(firstJob))
        #expect(restored.generationInput?.submission == nil)
        second.stopMonitoring()
    }

    @Test func deletingPlaceholderDuringDownloadLeavesNoFileOrManifestEntry() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let gate = Gate()
        let png = try Data(contentsOf: fixture.image.url)
        fixture.editor.remoteDownloadFetch = { request in
            await gate.arrive()
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try png.write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
        }
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let service = GenerationService(
            provider: { FakeProvider(states: [jobState(.succeeded, results: [result])]) }, catalog: try cloudinaryCatalog()
        )
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { await gate.hasArrived }
        fixture.editor.deleteMediaAssets(ids: [placeholder.id])
        await gate.open()
        try await fixture.waitUntil { service.monitoredJobIds.isEmpty }

        let media = fixture.editor.projectURL!.appending(path: Project.mediaDirectoryName)
        let files = try FileManager.default.contentsOfDirectory(atPath: media.path)
        #expect(files == ["source.png"])
        #expect(!fixture.editor.mediaManifest.entries.contains { $0.id == placeholder.id })
        #expect(!fixture.editor.mediaAssets.contains { $0.id == placeholder.id })
    }

    @Test func notCancellableKeepsPlaceholder() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let provider = FakeProvider(states: [jobState(.running)])
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let id = start(service, editor: fixture.editor, source: fixture.image)
        let placeholder = try placeholder(id, in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationInput?.jobId != nil }
        #expect(await service.cancelGeneration(placeholder, editor: fixture.editor) == .notCancellable)
        #expect(fixture.editor.mediaAssets.contains { $0.id == id })
        service.stopMonitoring()
    }

    @Test func cancelledJobRemovesPlaceholderWithoutUndoEntry() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let undoManager = UndoManager()
        fixture.editor.undo.attach(undoManager)
        let provider = FakeProvider(states: [jobState(.running)])
        await provider.setCancelResult(.success(jobState(.cancelled)))
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let id = start(service, editor: fixture.editor, source: fixture.image)
        let placeholder = try placeholder(id, in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationInput?.jobId != nil }
        #expect(await service.cancelGeneration(placeholder, editor: fixture.editor) == .cancelled)
        #expect(!fixture.editor.mediaAssets.contains { $0.id == id })
        #expect(!fixture.editor.mediaManifest.entries.contains { $0.id == id })
        #expect(!undoManager.canUndo)
    }

    @Test func cancelFailureIsReported() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let placeholder = fixture.addGeneratingPlaceholder(jobId: "fake:1", fileExtension: "png")
        let provider = FakeProvider(states: [])
        await provider.setCancelResult(.failure(.unauthorized))
        let service = GenerationService(provider: { provider }, catalog: ModelCatalog())
        #expect(await service.cancelGeneration(placeholder, editor: fixture.editor) == .failed(BackendError.unauthorized.localizedDescription))
        #expect(fixture.editor.mediaAssets.contains { $0 === placeholder })
    }
}

@MainActor
struct GenerationCancellationTests {
    @Test func stopMonitoringLeavesJobResumable() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let service = GenerationService(provider: { FakeProvider(states: [jobState(.running)]) }, catalog: catalog)
        var input = GenerationInput(prompt: "", model: "cloudinary/background-removal", duration: 0, aspectRatio: "")
        input.createdAt = Date()
        let id = service.generate(
            genInput: input, assetType: .image, placeholderDuration: 0, references: [fixture.image],
            name: "Remove Background", buildParams: { _ in .removeBackground },
            fileExtension: "png", projectURL: fixture.editor.projectURL, editor: fixture.editor
        )
        let placeholder = try #require(fixture.editor.mediaAssets.first { $0.id == id })
        try await fixture.waitUntil { placeholder.generationInput?.jobId != nil }
        service.stopMonitoring()
        #expect(placeholder.generationStatus == .generating)
        #expect(placeholder.generationInput?.jobId == "fake:1")
    }

    @Test func stopMonitoringEndsPolling() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let provider = FakeProvider(states: [jobState(.running)])
        let service = GenerationService(provider: { provider }, catalog: try cloudinaryCatalog())
        var input = GenerationInput(prompt: "", model: "cloudinary/background-removal", duration: 0, aspectRatio: "")
        input.createdAt = Date()
        let id = service.generate(
            genInput: input, assetType: .image, placeholderDuration: 0, references: [fixture.image],
            name: "Remove Background", buildParams: { _ in .removeBackground },
            fileExtension: "png", projectURL: fixture.editor.projectURL, editor: fixture.editor
        )
        let placeholder = try #require(fixture.editor.mediaAssets.first { $0.id == id })
        try await fixture.waitUntil { await provider.pollers == 1 }
        service.stopMonitoring()
        try await fixture.waitUntil { await provider.terminations == 1 }
        #expect(service.monitoredJobIds.isEmpty)
        #expect(placeholder.generationStatus == .generating)
    }

    @Test func closingProjectEndsPolling() async throws {
        let document = VideoProject()
        let provider = FakeProvider(states: [jobState(.running)])
        let service = GenerationService(provider: { provider }, catalog: try cloudinaryCatalog())
        document.editorViewModel.generationService = service
        let fixture = try await EditorTestFixture.withImage(editor: document.editorViewModel)
        defer { fixture.cleanup() }
        var input = GenerationInput(prompt: "", model: "cloudinary/background-removal", duration: 0, aspectRatio: "")
        input.createdAt = Date()
        service.generate(
            genInput: input, assetType: .image, placeholderDuration: 0, references: [fixture.image],
            name: "Remove Background", buildParams: { _ in .removeBackground },
            fileExtension: "png", projectURL: fixture.editor.projectURL, editor: fixture.editor
        )
        try await fixture.waitUntil { await provider.pollers == 1 }
        document.close()
        try await fixture.waitUntil { await provider.terminations == 1 }
        #expect(service.monitoredJobIds.isEmpty)
    }
}

@MainActor
struct GenerationResumeTests {
    @Test func resumesPersistedJobAndFinalizes() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let placeholder = fixture.addGeneratingPlaceholder(jobId: "fake:1", fileExtension: "png")
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let provider = FakeProvider(states: [jobState(.succeeded, results: [result])])
        let service = GenerationService(provider: { provider }, catalog: ModelCatalog())
        service.resumePendingGenerations(editor: fixture.editor)
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
        #expect(await provider.pollers == 1)
        #expect(placeholder.url.pathExtension == "png")
    }

    @Test func persistedResultsFinalizeWithoutPolling() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let placeholder = fixture.addGeneratingPlaceholder(jobId: "fake:1", fileExtension: "png")
        placeholder.generationInput?.results = [result]
        placeholder.generationStatus = .downloading
        let provider = FakeProvider(states: [])
        let service = GenerationService(provider: { provider }, catalog: ModelCatalog())
        service.resumePendingGenerations(editor: fixture.editor)
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
        #expect(await provider.pollers == 0)
    }

    @Test func resumeWithoutBackendLeavesJobPending() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let placeholder = fixture.addGeneratingPlaceholder(jobId: "fake:1", fileExtension: "png")
        let service = GenerationService(provider: { nil }, catalog: ModelCatalog())
        service.resumePendingGenerations(editor: fixture.editor)
        #expect(service.monitoredJobIds.isEmpty)
        #expect(placeholder.generationStatus == .generating)
    }
}

private actor Gate {
    private var arrived = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false

    var hasArrived: Bool { arrived }

    func arrive() async {
        arrived = true
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}
