import Foundation

struct MemoryRepairCandidatePresentation: Identifiable, Equatable, Sendable {
    let id: String
    let passage: String
    let headingPath: String?
    let locationLabel: String
    let evidenceLabel: String
}

struct MemoryRepairCommit: Equatable, Sendable {
    let storedMemory: StoredMemory
    let undo: ReattachmentUndoPayload
}

struct MemoryRepairWriteRequest: Equatable, Sendable {
    let memoryID: UUID
    let anchor: NewConfirmedAnchor
    let resolution: ResolutionDraft
    let expectedMemoryRecordVersion: Int64
    let expectedResolutionRecordVersion: Int64
    let expectedDocumentRecordVersion: Int64
}

struct MemoryRepairProjectionSnapshot: Sendable {
    let sourceURL: URL
    let projection: DocumentProjection
}

struct MemoryRepairUndoWriteRequest: Equatable, Sendable {
    let payload: ReattachmentUndoPayload
    let validatedResolution: ResolutionDraft
    let expectedCurrentAnchorID: UUID
    let sourceURL: URL
    let expectedRevisionHash: String
}

@MainActor
struct MemoryRepairDependencies {
    var captureDOMSelection: () async throws -> DOMProjectionSelection
    var sourceMatchesRevision: (String) async -> Bool
    var reattachMemory: (MemoryRepairWriteRequest) async throws -> ReattachmentMutation
    var loadCurrentProjection: () async throws -> MemoryRepairProjectionSnapshot = {
        throw MemoryRepairError.sourceChanged
    }
    var currentAnchorID: (UUID) async throws -> UUID? = { _ in nil }
    var undoReattachment: (MemoryRepairUndoWriteRequest) async throws -> StoredMemory
    var makeAnchorID: () -> UUID = UUID.init
    var now: () -> Date = Date.init

    static func live(
        webController: ReaderWebController,
        model: ReaderViewModel,
        repository: MemoryRepository
    ) -> MemoryRepairDependencies {
        MemoryRepairDependencies(
            captureDOMSelection: {
                try await webController.captureMemorySelection()
            },
            sourceMatchesRevision: { revisionHash in
                await model.coordinatedSourceMatches(revisionHash: revisionHash)
            },
            reattachMemory: { request in
                guard let sourceURL = model.fileURL else {
                    throw MemoryRepairError.sourceChanged
                }
                return try await repository.reattachMemory(
                    memoryID: request.memoryID,
                    anchor: request.anchor,
                    resolution: request.resolution,
                    expectedMemoryRecordVersion: request.expectedMemoryRecordVersion,
                    expectedResolutionRecordVersion: request.expectedResolutionRecordVersion,
                    expectedDocumentRecordVersion: request.expectedDocumentRecordVersion,
                    verifyingSourceAt: sourceURL,
                    filePresenter: model.coordinatedFilePresenter,
                    expectedRevisionHash: request.anchor.sourceRevisionHash
                )
            },
            loadCurrentProjection: {
                guard let sourceURL = model.fileURL else {
                    throw MemoryRepairError.sourceChanged
                }
                let presenter = model.coordinatedFilePresenter
                return try await Task.detached(priority: .userInitiated) {
                    try Self.coordinatedProjection(
                        at: sourceURL,
                        filePresenter: presenter
                    )
                }.value
            },
            currentAnchorID: { memoryID in
                try await repository.memory(id: memoryID)?.memory.currentAnchorID
            },
            undoReattachment: { request in
                try await repository.undoReattachment(
                    request.payload,
                    validatedResolution: request.validatedResolution,
                    expectedCurrentAnchorID: request.expectedCurrentAnchorID,
                    verifyingSourceAt: request.sourceURL,
                    filePresenter: model.coordinatedFilePresenter,
                    expectedRevisionHash: request.expectedRevisionHash
                )
            }
        )
    }

    nonisolated private static func coordinatedProjection(
        at sourceURL: URL,
        filePresenter: FileRefreshPresenter?
    ) throws -> MemoryRepairProjectionSnapshot {
        var coordinatorError: NSError?
        var result: Result<MemoryRepairProjectionSnapshot, Error>?
        let coordinator = NSFileCoordinator(filePresenter: filePresenter)
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            result = Result {
                let data = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
                return MemoryRepairProjectionSnapshot(
                    sourceURL: coordinatedURL,
                    projection: try DocumentProjection.build(
                        sourceData: data,
                        documentURL: coordinatedURL
                    )
                )
            }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}

@MainActor
final class MemoryRepairSession: ObservableObject {
    enum Mode: Equatable, Sendable {
        case chooseLocation
        case reattachLooseSlip
    }

    @Published private(set) var mode: Mode
    @Published private(set) var savedPassage: String
    @Published private(set) var candidates: [MemoryRepairCandidatePresentation]
    @Published var selectedCandidateID: String?
    @Published private(set) var pendingSelectionQuote: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isCancelled = false
    @Published private(set) var didCommit = false
    @Published private(set) var errorMessage: String?

    private let document: DocumentRecord
    private let projection: DocumentProjection
    private let existingPassages: [ExistingResolvedPassage]
    private let dependencies: MemoryRepairDependencies
    private var storedMemory: StoredMemory
    private var currentAnchor: ConfirmedMemoryAnchor
    private var recovery: MemoryRecoveryResult
    private var pendingSelection: ProjectionSelection?

    var canUseSelectedCandidate: Bool {
        mode == .chooseLocation
            && selectedCandidateID != nil
            && !isWorking
            && !isCancelled
            && !didCommit
    }

    var canUseCurrentSelection: Bool {
        mode == .reattachLooseSlip
            && pendingSelection != nil
            && !isWorking
            && !isCancelled
            && !didCommit
    }

    init(
        storedMemory: StoredMemory,
        document: DocumentRecord,
        documentMemories: [StoredMemory],
        projection: DocumentProjection,
        dependencies: MemoryRepairDependencies
    ) throws {
        guard storedMemory.memory.documentID == document.id,
              let anchorID = storedMemory.memory.currentAnchorID,
              let anchorRecord = storedMemory.anchors.first(where: { $0.id == anchorID }) else {
            throw MemoryRepairError.missingCurrentAnchor
        }
        let anchor = try ProjectionStoreAdapter.confirmedAnchor(from: anchorRecord)
        let recovery = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            currentProjection: projection
        )
        let mode: Mode
        switch recovery.resolution.state {
        case .ambiguous:
            mode = .chooseLocation
        case .orphaned, .needsReview:
            mode = .reattachLooseSlip
        case .resolved:
            throw MemoryRepairError.alreadyResolved
        }

        self.mode = mode
        savedPassage = storedMemory.memory.originalVisibleQuote
            ?? storedMemory.memory.canonicalMatchQuote
            ?? anchor.exactQuote
        self.document = document
        self.projection = projection
        self.dependencies = dependencies
        self.storedMemory = storedMemory
        currentAnchor = anchor
        self.recovery = recovery
        existingPassages = Self.resolvedPassages(
            in: documentMemories,
            revisionHash: projection.source.revisionHash,
            projectionVersion: projection.version,
            excluding: storedMemory.memory.id
        )
        candidates = Self.presentations(for: recovery.candidates, in: projection)
        // Deliberately no default. A visible first row is not consent.
        selectedCandidateID = nil
    }

    convenience init(
        storedMemory: StoredMemory,
        document: DocumentRecord,
        documentMemories: [StoredMemory],
        projection: DocumentProjection,
        webController: ReaderWebController,
        model: ReaderViewModel,
        library: ReadingMemoryLibrary
    ) throws {
        let repository = try library.requireRepository()
        try self.init(
            storedMemory: storedMemory,
            document: document,
            documentMemories: documentMemories,
            projection: projection,
            dependencies: .live(
                webController: webController,
                model: model,
                repository: repository
            )
        )
    }

    func selectCandidate(id: String) {
        guard mode == .chooseLocation,
              candidates.contains(where: { $0.id == id }),
              !isCancelled,
              !didCommit else { return }
        selectedCandidateID = id
        errorMessage = nil
    }

    func captureCurrentSelection() async {
        guard mode == .reattachLooseSlip, !isCancelled, !didCommit, !isWorking else { return }
        pendingSelection = nil
        pendingSelectionQuote = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let domSelection = try await dependencies.captureDOMSelection()
            guard await dependencies.sourceMatchesRevision(projection.source.revisionHash) else {
                throw MemoryRepairError.sourceChanged
            }
            let selection = try projection.selection(fromDOM: domSelection)
            switch projection.validatePassageSelection(
                selection,
                existingPassages: existingPassages
            ) {
            case .valid:
                pendingSelection = selection
                pendingSelectionQuote = selection.selectedVisibleText
                errorMessage = nil
            case let .invalid(issue):
                throw issue.repairError
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func commitSelectedCandidate() async -> MemoryRepairCommit? {
        guard mode == .chooseLocation,
              let selectedCandidateID,
              !isCancelled,
              !didCommit,
              !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            guard await dependencies.sourceMatchesRevision(projection.source.revisionHash) else {
                throw MemoryRepairError.sourceChanged
            }
            let refreshed = try MemoryAnchorResolver.resolve(
                anchor: currentAnchor,
                currentProjection: projection
            )
            guard refreshed.resolution.state == .ambiguous,
                  let candidate = refreshed.candidates.first(where: { $0.id == selectedCandidateID }),
                  let previouslyShown = recovery.candidates.first(where: { $0.id == selectedCandidateID }),
                  candidate.selector == previouslyShown.selector else {
                recovery = refreshed
                candidates = Self.presentations(for: refreshed.candidates, in: projection)
                self.selectedCandidateID = nil
                throw MemoryRepairError.candidatesChanged
            }
            let selection = try Self.selection(for: candidate, in: projection)
            return try await commit(selection: selection)
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    func commitCurrentSelection() async -> MemoryRepairCommit? {
        guard mode == .reattachLooseSlip,
              let pendingSelection,
              !isCancelled,
              !didCommit,
              !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            guard await dependencies.sourceMatchesRevision(projection.source.revisionHash) else {
                throw MemoryRepairError.sourceChanged
            }
            return try await commit(selection: pendingSelection)
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    /// Cancels only the ephemeral chooser/selection. No store mutation is
    /// reachable from this method.
    func cancel() {
        guard !didCommit else { return }
        selectedCandidateID = nil
        pendingSelection = nil
        pendingSelectionQuote = nil
        errorMessage = nil
        isCancelled = true
    }

    /// Undo reruns the immutable prior anchor through the current resolver
    /// before asking the store to restore it as current.
    func undo(_ payload: ReattachmentUndoPayload) async -> StoredMemory? {
        guard didCommit,
              !isWorking,
              payload.memoryID == storedMemory.memory.id,
              storedMemory.memory.currentAnchorID == currentAnchor.id,
              let priorRecord = storedMemory.anchors.first(where: { $0.id == payload.previousAnchorID }) else {
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            guard try await dependencies.currentAnchorID(payload.memoryID) == currentAnchor.id else {
                throw MemoryRepairError.anchorGenerationChanged
            }
            let current = try await dependencies.loadCurrentProjection()
            let priorAnchor = try ProjectionStoreAdapter.confirmedAnchor(from: priorRecord)
            let validated = try MemoryAnchorResolver.resolve(
                anchor: priorAnchor,
                currentProjection: current.projection
            )
            let resolution = try ProjectionStoreAdapter.resolutionDraft(
                from: validated,
                projection: current.projection,
                checkedAt: dependencies.now()
            )
            let restored = try await dependencies.undoReattachment(
                MemoryRepairUndoWriteRequest(
                    payload: payload,
                    validatedResolution: resolution,
                    expectedCurrentAnchorID: currentAnchor.id,
                    sourceURL: current.sourceURL,
                    expectedRevisionHash: current.projection.source.revisionHash
                )
            )
            storedMemory = restored
            currentAnchor = priorAnchor
            recovery = validated
            didCommit = false
            errorMessage = nil
            return restored
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    private func commit(selection: ProjectionSelection) async throws -> MemoryRepairCommit {
        guard document.lastConfirmedContentHash == projection.source.revisionHash else {
            throw MemoryRepairError.sourceChanged
        }
        let createdAt = dependencies.now()
        let anchor = try projection.makeManualReattachment(
            superseding: currentAnchor,
            from: selection,
            existingPassages: existingPassages,
            anchorID: dependencies.makeAnchorID(),
            createdAt: createdAt
        )
        let confirmed = try MemoryAnchorResolver.confirmManualSelection(
            anchor: anchor,
            selection: selection,
            currentProjection: projection,
            existingPassages: existingPassages
        )
        var resolution = try ProjectionStoreAdapter.resolutionDraft(
            from: confirmed,
            projection: projection,
            checkedAt: createdAt
        )
        resolution.evidence.append(ResolutionEvidence(kind: .manualConfirmation))
        let mutation = try await dependencies.reattachMemory(
            MemoryRepairWriteRequest(
                memoryID: storedMemory.memory.id,
                anchor: ProjectionStoreAdapter.newAnchor(from: anchor),
                resolution: resolution,
                expectedMemoryRecordVersion: storedMemory.memory.recordVersion,
                expectedResolutionRecordVersion: storedMemory.resolution.recordVersion,
                expectedDocumentRecordVersion: document.recordVersion
            )
        )
        storedMemory = mutation.storedMemory
        currentAnchor = anchor
        didCommit = true
        errorMessage = nil
        return MemoryRepairCommit(storedMemory: mutation.storedMemory, undo: mutation.undo)
    }

    private static func selection(
        for candidate: RecoveryCandidate,
        in projection: DocumentProjection
    ) throws -> ProjectionSelection {
        let selector = candidate.selector
        guard selector.sourceRevisionHash == projection.source.revisionHash,
              selector.projectionVersion == projection.version,
              let block = projection.block(id: selector.blockID),
              let quote = CanonicalMarkdownText.substring(
                  block.canonicalText,
                  utf8Range: selector.canonicalUTF8RangeInBlock
              ) else {
            throw MemoryRepairError.candidatesChanged
        }
        return ProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: selector.blockID,
            canonicalUTF8RangeInBlock: selector.canonicalUTF8RangeInBlock,
            selectedVisibleText: quote,
            runIDs: selector.runFragments.map(\.runID)
        )
    }

    private static func resolvedPassages(
        in memories: [StoredMemory],
        revisionHash: String,
        projectionVersion: Int,
        excluding memoryID: UUID
    ) -> [ExistingResolvedPassage] {
        memories.compactMap { stored in
            guard stored.memory.id != memoryID,
                  stored.memory.kind == .passage,
                  stored.resolution.state == .resolved,
                  let selector = stored.resolution.resolvedSelector,
                  selector.sourceRevisionHash == revisionHash,
                  selector.projectionVersion == projectionVersion,
                  selector.canonicalTextPosition.isValid,
                  selector.canonicalTextPosition.upperBound <= Int64(Int.max) else { return nil }
            return ExistingResolvedPassage(
                memoryID: stored.memory.id,
                canonicalTextPosition: UTF8ByteRange(
                    Int(selector.canonicalTextPosition.lowerBound),
                    Int(selector.canonicalTextPosition.upperBound)
                )
            )
        }
    }

    private static func presentations(
        for candidates: [RecoveryCandidate],
        in projection: DocumentProjection
    ) -> [MemoryRepairCandidatePresentation] {
        candidates.enumerated().compactMap { index, candidate in
            guard let block = projection.block(id: candidate.selector.blockID),
                  let passage = CanonicalMarkdownText.substring(
                      block.canonicalText,
                      utf8Range: candidate.selector.canonicalUTF8RangeInBlock
                  ) else { return nil }
            let evidence = candidate.evidence.map { evidence in
                switch evidence {
                case .exactPassage: "Exact passage"
                case .matchingPrefix, .matchingSuffix: "matching surrounding text"
                case .sameBlockFingerprint: "same block"
                case .sameHeading: "same heading"
                }
            }
            return MemoryRepairCandidatePresentation(
                id: candidate.id,
                passage: passage,
                headingPath: block.headingPath.map(\.title).joined(separator: " › ").nilIfEmpty,
                locationLabel: "Location \(index + 1)",
                evidenceLabel: Array(Set(evidence)).sorted().joined(separator: " · ")
            )
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "The memory was left unchanged. Try the repair again."
    }
}

enum MemoryRepairError: Error, Equatable, LocalizedError {
    case missingCurrentAnchor
    case alreadyResolved
    case sourceChanged
    case candidatesChanged
    case invalidSelection
    case anchorGenerationChanged

    var errorDescription: String? {
        switch self {
        case .missingCurrentAnchor:
            "This memory has no confirmed anchor to repair."
        case .alreadyResolved:
            "This memory is already attached to an exact location."
        case .sourceChanged:
            "The source changed during repair. Nothing was saved; select the passage again."
        case .candidatesChanged:
            "The candidate locations changed. Review them again before choosing one."
        case .invalidSelection:
            "This selection cannot be used. Select one supported passage in the document."
        case .anchorGenerationChanged:
            "This memory was reattached again in another window. The newer anchor was left unchanged."
        }
    }
}

private extension PassageSelectionIssue {
    var repairError: Error {
        switch self {
        case .staleSourceRevision: DocumentProjectionError.staleSourceRevision
        case .staleRenderRevision: DocumentProjectionError.staleRenderRevision
        case .staleProjectionVersion: DocumentProjectionError.staleProjectionVersion
        case .unknownBlock: DocumentProjectionError.unknownBlock("unknown")
        case .emptySelection: DocumentProjectionError.emptySelection
        case .invalidUnicodeBoundary: DocumentProjectionError.nonScalarCanonicalBoundary
        case .visibleTextMismatch: DocumentProjectionError.selectedTextMismatch
        case let .unsupported(reason): DocumentProjectionError.unsupportedSelection(reason)
        case .overlaps: DocumentProjectionError.overlappingSelection
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
