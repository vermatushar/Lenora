import Foundation

/// Used by replace-clip callbacks so only the
/// first successful asset of an N-image generation swaps the clip
@MainActor
final class FirstOnlyFlag {
    private var fired = false
    func fire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

enum GenerationError: Error, LocalizedError, Equatable {
    case modelUnavailable(String)
    case backendUnavailable
    case unsupportedInputs(String)
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let id): "\(id) is not available from the connected backend."
        case .backendUnavailable: "No backend is connected. Open Settings → Backend."
        case .unsupportedInputs(let what): "This model can't use \(what)."
        case .analysisFailed(let message): message
        }
    }
}

enum GenerationCancelOutcome: Equatable { case cancelled, notCancellable, failed(String) }

@MainActor
final class GenerationService {

    private let provider: @MainActor () -> (any GenerationProvider)?
    let catalog: ModelCatalog
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private struct JobMonitor {
        let taskId: UUID
        let onComplete: (@MainActor (MediaAsset) -> Void)?
        let onFailure: (@MainActor () -> Void)?
    }
    private var jobMonitors: [String: JobMonitor] = [:]
    var monitoredJobIds: Set<String> { Set(jobMonitors.keys) }
    private var submittingKeys: Set<String> = []
    var onCapabilityRefusal: @MainActor () -> Void = { Task { await BackendConnection.shared.refreshCapabilities() } }

    init(provider: @escaping @MainActor () -> (any GenerationProvider)?, catalog: ModelCatalog = .shared) {
        self.provider = provider
        self.catalog = catalog
    }

    func stopMonitoring() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        jobMonitors.removeAll()
        submittingKeys.removeAll()
    }

    func waitForIdle() async {
        while let task = tasks.values.first { await task.value }
    }

    static func isCapabilityRefusal(code: String, retryable: Bool) -> Bool {
        code == "provider_unavailable" && !retryable
    }

    private func own(id: UUID = UUID(), _ operation: @escaping @MainActor () async -> Void) {
        tasks[id] = Task { @MainActor [weak self] in
            await operation()
            self?.tasks[id] = nil
        }
    }

    private struct PreparedReferences {
        let uploaded: [String]
        let tempFiles: [URL]
    }

    @discardableResult
    func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        placeholderDuration: Double,
        references: [MediaAsset] = [],
        trimmedSourceOverride: TrimmedSource? = nil,
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil,
        buildParams: @escaping ([String]) -> GenerationJobParams,
        snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)? = nil,
        preprocessRef: (@Sendable (Int, MediaAsset, URL) async throws -> URL?)? = nil,
        preprocessSourceVideo: (@Sendable (URL) async throws -> URL?)? = nil,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let count = max(1, min(4, numImages))
        let baseName = name ?? String(genInput.prompt.prefix(30))

        let resolvedFolderId = folderId.flatMap { id in
            editor.folder(id: id) != nil ? id : nil
        }
        var created: [MediaAsset] = []
        let destDir = Self.destinationDirectory(for: projectURL)

        for outputIndex in 0..<count {
            var placeholderInput = genInput
            placeholderInput.outputIndex = outputIndex
            let placeholder = createPlaceholder(
                type: assetType,
                name: baseName,
                duration: placeholderDuration,
                genInput: placeholderInput,
                folderId: resolvedFolderId,
                destDir: destDir,
                fileExtension: fileExtension,
                editor: editor
            )
            created.append(placeholder)
        }
        let placeholders = created
        let primaryId = placeholders[0].id

        let idempotencyKey = UUID().uuidString
        submittingKeys.insert(idempotencyKey)
        own {
            defer { self.submittingKeys.remove(idempotencyKey) }
            @MainActor func fail(_ message: String) {
                for placeholder in placeholders {
                    self.updateGenerationMetadata(placeholder, editor: editor, status: .failed(message))
                }
                editor.onProjectCheckpointRequired?()
                onFailure?()
            }

            let provider: any GenerationProvider
            let model: BackendModel
            do {
                (provider, model) = try self.backend(for: genInput.model)
            } catch {
                Log.generation.warning("submit refused model=\(genInput.model) error=\(error.localizedDescription)")
                fail(error.localizedDescription)
                return
            }

            do {
                let prepared = try await self.prepareReferences(
                    references: references,
                    trimmedSourceOverride: trimmedSourceOverride,
                    preprocessRef: preprocessRef,
                    preprocessSourceVideo: preprocessSourceVideo,
                    provider: provider,
                    model: model.id
                )
                defer { Self.cleanupTempFiles(prepared.tempFiles) }
                try Task.checkCancellation()
                let uploaded = prepared.uploaded

                var finalGenInput = genInput
                if let snapshotRefs {
                    snapshotRefs(&finalGenInput, uploaded)
                } else {
                    finalGenInput.imageURLs = uploaded.isEmpty ? nil : uploaded
                }
                if finalGenInput.createdAt == nil {
                    finalGenInput.createdAt = Date()
                }
                let job: JobRequest
                do {
                    let parts = try buildParams(uploaded).jobParts(uploaded: uploaded)
                    job = JobRequest(kind: model.kind, model: model.id, inputs: parts.inputs, params: parts.params)
                    finalGenInput.submission = try PendingSubmission(job)
                } catch {
                    Log.generation.warning("submit refused model=\(genInput.model) error=\(error.localizedDescription)")
                    fail(error.localizedDescription)
                    return
                }
                finalGenInput.idempotencyKey = idempotencyKey
                for (outputIndex, placeholder) in placeholders.enumerated() {
                    var storedInput = finalGenInput
                    storedInput.outputIndex = outputIndex
                    self.updateGenerationMetadata(placeholder, editor: editor) { input in
                        input = storedInput
                    }
                }
                editor.onProjectCheckpointRequired?()

                await self.runJob(
                    placeholders: placeholders,
                    genInput: finalGenInput,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure,
                    submit: { try await provider.submit(job, idempotencyKey: idempotencyKey) }
                )
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                Log.generation.error("upload failed model=\(genInput.model) error=\(message)")
                fail("Upload failed: \(message)")
            }
        }

        return primaryId
    }

    private func prepareReferences(
        references: [MediaAsset],
        trimmedSourceOverride: TrimmedSource?,
        preprocessRef: (@Sendable (Int, MediaAsset, URL) async throws -> URL?)?,
        preprocessSourceVideo: (@Sendable (URL) async throws -> URL?)?,
        provider: any GenerationProvider,
        model: String
    ) async throws -> PreparedReferences {
        var tempFiles: [URL] = []
        do {
            var urlsToUpload = references.map(\.url)
            let refTypes = references.map(\.type)
            if let trim = trimmedSourceOverride, trim.hasTrim,
               let index = urlsToUpload.firstIndex(of: trim.sourceURL) {
                Log.generation.notice("using trimmed source: frames \(trim.trimStartFrame)+\(trim.sourceFramesConsumed) of \(urlsToUpload[index].lastPathComponent)")
                let extracted = try await VideoTrimExtractor.extract(trim)
                urlsToUpload[index] = extracted
                tempFiles.append(extracted)
            }
            if let preprocessSourceVideo, let sourceURL = urlsToUpload.first,
               let processed = try await preprocessSourceVideo(sourceURL) {
                urlsToUpload[0] = processed
                tempFiles.append(processed)
            }
            if let preprocessRef, !references.isEmpty {
                let rewrites = try await preprocessedReferenceURLs(
                    references: references,
                    currentURLs: urlsToUpload,
                    preprocessRef: preprocessRef
                )
                for (i, rewritten) in rewrites {
                    guard let rewritten else { continue }
                    urlsToUpload[i] = rewritten
                    tempFiles.append(rewritten)
                }
            }
            let uploaded = try await uploadReferences(
                at: urlsToUpload,
                types: refTypes,
                provider: provider,
                model: model
            )
            return PreparedReferences(uploaded: uploaded, tempFiles: tempFiles)
        } catch {
            Self.cleanupTempFiles(tempFiles)
            throw error
        }
    }

    private func preprocessedReferenceURLs(
        references: [MediaAsset],
        currentURLs: [URL],
        preprocessRef: @escaping @Sendable (Int, MediaAsset, URL) async throws -> URL?
    ) async throws -> [(Int, URL?)] {
        try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
            for (i, asset) in references.enumerated() {
                let currentURL = currentURLs[i]
                group.addTask { (i, try await preprocessRef(i, asset, currentURL)) }
            }
            var results: [(Int, URL?)] = []
            for try await result in group { results.append(result) }
            return results
        }
    }

    private static func cleanupTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Shared

    private func createPlaceholder(
        type: ClipType,
        name: String,
        duration: Double,
        genInput: GenerationInput,
        folderId: String?,
        destDir: URL,
        fileExtension: String,
        editor: EditorViewModel
    ) -> MediaAsset {
        let id = UUID().uuidString
        let destURL = destDir.appendingPathComponent("gen-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(
            id: id,
            url: destURL,
            type: type,
            name: name,
            duration: duration,
            generationInput: genInput
        )
        placeholder.generationStatus = .preparing
        placeholder.folderId = folderId
        editor.importMediaAsset(placeholder)
        return placeholder
    }

    private static func destinationDirectory(for projectURL: URL?) -> URL {
        if let projectURL {
            return projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    func retryDownload(asset: MediaAsset, editor: EditorViewModel) {
        guard let remoteURL = asset.pendingDownloadURL else { return }
        let fileExtension = asset.generationInput?.results?.first { $0.url == remoteURL }?.fileExtension
        own {
            await self.land(asset, from: remoteURL, fileExtension: fileExtension, editor: editor)
        }
    }

    func resumePendingGenerations(editor: EditorViewModel) {
        let pending = editor.mediaAssets.filter(\.isRecoveringGeneration)
        let byJob = Dictionary(grouping: pending.compactMap { asset -> (String, MediaAsset)? in
            guard let jobId = asset.generationInput?.jobId, !jobId.isEmpty else { return nil }
            return (jobId, asset)
        }, by: { $0.0 })

        for (jobId, group) in byJob {
            let placeholders = group.map(\.1).sorted {
                ($0.generationInput?.outputIndex ?? 0) < ($1.generationInput?.outputIndex ?? 0)
            }
            let existing = jobMonitors[jobId]
            if let results = placeholders.lazy.compactMap({ $0.generationInput?.results }).first(where: { !$0.isEmpty }) {
                guard existing == nil else { continue }
                track(jobId: jobId, onComplete: nil, onFailure: nil) {
                    await self.finalizeSuccess(
                        results: results, placeholders: placeholders, editor: editor, onComplete: nil, onFailure: nil
                    )
                }
            } else {
                // A running monitor may be polling a backend that has since restarted.
                monitorJob(
                    jobId: jobId, placeholders: placeholders, editor: editor,
                    onComplete: existing?.onComplete, onFailure: existing?.onFailure
                )
            }
        }

        let unsubmitted = Dictionary(grouping: pending.filter { $0.generationInput?.canResubmit == true }) {
            $0.generationInput?.idempotencyKey ?? ""
        }
        for (key, group) in unsubmitted where !submittingKeys.contains(key) {
            guard let provider = provider(), let input = group.first?.generationInput, let submission = input.submission else { continue }
            let placeholders = group.sorted { ($0.generationInput?.outputIndex ?? 0) < ($1.generationInput?.outputIndex ?? 0) }
            submittingKeys.insert(key)
            own {
                defer { self.submittingKeys.remove(key) }
                await self.runJob(
                    placeholders: placeholders, genInput: input, editor: editor, onComplete: nil, onFailure: nil,
                    submit: { try await provider.submit(submission.request, idempotencyKey: key) }
                )
            }
        }
    }

    func cancelGeneration(_ asset: MediaAsset, editor: EditorViewModel) async -> GenerationCancelOutcome {
        guard let jobId = asset.generationInput?.jobId, let provider = provider() else {
            return .failed(GenerationError.backendUnavailable.localizedDescription)
        }
        do {
            let state = try await provider.cancel(jobId: jobId)
            guard state.status == .cancelled else { return .failed(L10n.string("The job already finished.")) }
            editor.removeGenerationPlaceholders(editor.mediaAssets.filter { $0.generationInput?.jobId == jobId })
            return .cancelled
        } catch BackendError.problem(let problem) where problem.code == "not_cancellable" {
            return .notCancellable
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func backend(for modelId: String) throws -> (any GenerationProvider, BackendModel) {
        guard let provider = provider() else { throw GenerationError.backendUnavailable }
        guard let model = catalog.backendModel(id: modelId) else { throw GenerationError.modelUnavailable(modelId) }
        return (provider, model)
    }

    private func updateGenerationMetadata(
        _ asset: MediaAsset,
        editor: EditorViewModel,
        status: MediaAsset.GenerationStatus? = nil,
        mutateInput: ((inout GenerationInput) -> Void)? = nil
    ) {
        guard editor.mediaAssetsById[asset.id] === asset else { return }
        if let status {
            asset.generationStatus = status
        }
        if let mutateInput, var input = asset.generationInput {
            mutateInput(&input)
            asset.generationInput = input
        }
        editor.updateManifestMetadata(for: [asset])
    }

    private func uploadReferences(
        at urls: [URL],
        types: [ClipType],
        provider: any GenerationProvider,
        model: String
    ) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, url) in urls.enumerated() {
                let type = types.indices.contains(i) ? types[i] : .image
                let requiresConversion = type == .image
                    && ImageConverter.requiresConversion(url)
                let contentType = requiresConversion
                    ? "image/jpeg"
                    : Self.contentType(for: url, fallback: type)
                group.addTask {
                    let convertedURL = requiresConversion
                        ? try await ImageConverter.convertToJPEG(url)
                        : nil
                    do {
                        let assetRef = try await provider.uploadFile(
                            convertedURL ?? url, contentType: contentType, model: model
                        )
                        if let convertedURL {
                            await ImageConverter.removeConvertedFile(convertedURL)
                        }
                        return (i, assetRef)
                    } catch {
                        if let convertedURL {
                            await ImageConverter.removeConvertedFile(convertedURL)
                        }
                        throw error
                    }
                }
            }
            var results = [(Int, String)]()
            for try await r in group { results.append(r) }
            return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    /// Uploads one image, runs an `image.analyze` model, and returns the provider's analysis object.
    func analyzeImage(fileURL: URL, modelId: String, params: AnalyzeJobParams) async throws -> JSONValue {
        let (provider, model) = try backend(for: modelId)
        guard model.kind == "image.analyze" else { throw GenerationError.modelUnavailable(modelId) }
        let refs = try await uploadReferences(at: [fileURL], types: [.image], provider: provider, model: modelId)
        guard let assetRef = refs.first else { throw GenerationError.backendUnavailable }
        let submitted = try await provider.submit(
            JobRequest(kind: model.kind, model: modelId, inputs: [.assetRef(assetRef)], params: params),
            idempotencyKey: UUID().uuidString
        )
        for try await state in provider.jobUpdates(jobId: submitted.jobId) {
            switch state.status {
            case .queued, .running:
                continue
            case .succeeded:
                guard let analysis = state.analysis else {
                    throw GenerationError.analysisFailed("The analysis finished without a result.")
                }
                return analysis
            case .failed:
                throw GenerationError.analysisFailed(state.error?.message ?? "The analysis failed.")
            case .cancelled:
                throw GenerationError.analysisFailed("The analysis was cancelled.")
            }
        }
        throw GenerationError.analysisFailed("The analysis ended without a result.")
    }

    func uploadReference(fileURL: URL, contentType: String, model: String) async throws -> String {
        guard let provider = provider() else { throw GenerationError.backendUnavailable }
        return try await provider.uploadFile(fileURL, contentType: contentType, model: model)
    }

    private static func contentType(for url: URL, fallback: ClipType) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aiff", "aif", "aifc": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        default:
            switch fallback {
            case .image: return "image/jpeg"
            case .video: return "video/mp4"
            case .audio: return "audio/mpeg"
            case .text, .subtitle: return "application/octet-stream"
            case .lottie: return "application/json"
            case .sequence: return "video/mp4"
            }
        }
    }

    // MARK: - Job execution

    private func runJob(
        placeholders: [MediaAsset],
        genInput: GenerationInput,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?,
        submit: () async throws -> SubmittedJob
    ) async {
        let runId = String(UUID().uuidString.prefix(8))
        Log.generation.notice("run \(runId) start model=\(genInput.model) placeholders=\(placeholders.count)")
        defer { Log.generation.notice("run \(runId) settled") }

        let submitted: SubmittedJob
        do {
            submitted = try await submit()
        } catch is CancellationError {
            return
        } catch {
            if case BackendError.problem(let problem) = error {
                Log.generation.warning("submit failed model=\(genInput.model) code=\(problem.code)")
                if Self.isCapabilityRefusal(code: problem.code, retryable: problem.retryable) { onCapabilityRefusal() }
            } else {
                Log.generation.error("submit failed model=\(genInput.model) error=\(error.localizedDescription)")
            }
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(error.localizedDescription)) { input in
                    input.submission = nil
                }
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return
        }

        for placeholder in placeholders {
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                input.jobId = submitted.jobId
                input.estimate = submitted.estimate
                input.submission = nil
            }
        }
        editor.onProjectCheckpointRequired?()

        monitorJob(
            jobId: submitted.jobId,
            placeholders: placeholders,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    private func track(
        jobId: String,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?,
        _ operation: @escaping @MainActor () async -> Void
    ) {
        if let previous = jobMonitors[jobId] { tasks[previous.taskId]?.cancel() }
        let id = UUID()
        jobMonitors[jobId] = JobMonitor(taskId: id, onComplete: onComplete, onFailure: onFailure)
        own(id: id) {
            await operation()
            if self.jobMonitors[jobId]?.taskId == id { self.jobMonitors[jobId] = nil }
        }
    }

    private func monitorJob(
        jobId: String,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) {
        guard let provider = provider() else { return }
        track(jobId: jobId, onComplete: onComplete, onFailure: onFailure) {
            await self.pollJob(
                jobId: jobId, provider: provider, placeholders: placeholders, editor: editor,
                onComplete: onComplete, onFailure: onFailure
            )
        }
    }

    private func pollJob(
        jobId: String,
        provider: any GenerationProvider,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        do {
            for try await state in provider.jobUpdates(jobId: jobId) {
                guard !Task.isCancelled else { return }
                guard placeholders.contains(where: { editor.mediaAssetsById[$0.id] === $0 }) else { return }
                switch state.status {
                case .queued, .running:
                    continue
                case .succeeded:
                    await finalizeSuccess(
                        results: state.results ?? [], placeholders: placeholders, editor: editor,
                        onComplete: onComplete, onFailure: onFailure
                    )
                    return
                case .failed:
                    let message = state.error?.message ?? L10n.string("Generation failed.")
                    Log.generation.error("job \(jobId) failed code=\(state.error?.code ?? "unknown")")
                    if let failure = state.error, Self.isCapabilityRefusal(code: failure.code, retryable: failure.retryable) { onCapabilityRefusal() }
                    placeholders.forEach { updateGenerationMetadata($0, editor: editor, status: .failed(message)) }
                    editor.onProjectCheckpointRequired?()
                    onFailure?()
                    return
                case .cancelled:
                    editor.removeGenerationPlaceholders(placeholders)
                    return
                }
            }
        } catch where error is CancellationError || Task.isCancelled {
            return
        } catch let error as BackendError where error.isTransient || error == .unauthorized {
            Log.generation.warning("job \(jobId) polling paused: \(error.localizedDescription)")
        } catch BackendError.problem(let problem) where problem.code == "not_found" {
            Log.generation.error("job \(jobId) is unknown to the backend")
            let message = L10n.string("The backend restarted. Generate again.")
            placeholders.forEach { updateGenerationMetadata($0, editor: editor, status: .failed(message)) }
            editor.onProjectCheckpointRequired?()
            onFailure?()
        } catch {
            Log.generation.error("job \(jobId) polling failed: \(error.localizedDescription)")
            placeholders.forEach { updateGenerationMetadata($0, editor: editor, status: .failed(error.localizedDescription)) }
            editor.onProjectCheckpointRequired?()
            onFailure?()
        }
    }

    @discardableResult
    private func land(_ asset: MediaAsset, from remoteURL: URL, fileExtension: String?, editor: EditorViewModel) async -> Bool {
        guard editor.mediaAssetsById[asset.id] === asset else { return false }
        if asset.generationStatus != .downloading {
            updateGenerationMetadata(asset, editor: editor, status: .downloading)
        }
        do {
            try Task.checkCancellation()
            try await editor.downloadRemoteMedia(
                into: asset, from: remoteURL, fileExtension: fileExtension,
                undoActionName: asset.generationInput?.undoActionName
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            Log.generation.error("download failed asset=\(asset.id.prefix(8)) error=\(error.localizedDescription)")
            asset.pendingDownloadURL = remoteURL
            updateGenerationMetadata(asset, editor: editor, status: .failed(error.localizedDescription))
            return false
        }
    }

    private func finalizeSuccess(
        results: [JobResult],
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        let noResult = L10n.string("The job finished without a result.")
        guard !results.isEmpty else {
            Log.generation.error("backend job succeeded with no results")
            placeholders.forEach { updateGenerationMetadata($0, editor: editor, status: .failed(noResult)) }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return
        }
        if results.count < placeholders.count {
            Log.generation.notice("backend returned \(results.count) result(s) for \(placeholders.count) placeholder(s); marking extras as failed")
        }

        var finalized: [MediaAsset] = []
        for (i, placeholder) in placeholders.enumerated() {
            guard editor.mediaAssetsById[placeholder.id] === placeholder else { continue }
            let outputIndex = placeholder.generationInput?.outputIndex ?? i
            guard results.indices.contains(outputIndex) else {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(noResult))
                continue
            }
            let result = results[outputIndex]
            updateGenerationMetadata(placeholder, editor: editor, status: .downloading) { input in
                input.results = results
            }
            if await land(placeholder, from: result.url, fileExtension: result.fileExtension, editor: editor) {
                onComplete?(placeholder)
                finalized.append(placeholder)
            } else if Task.isCancelled {
                return
            }
        }
        editor.onProjectCheckpointRequired?()

        if let first = finalized.first {
            AppNotifications.generationComplete(
                assetId: first.id,
                projectURL: editor.projectURL,
                assetName: first.name,
                assetType: first.type,
                count: finalized.count
            )
        } else if placeholders.contains(where: { editor.mediaAssetsById[$0.id] === $0 }) {
            onFailure?()
        }
    }
}
