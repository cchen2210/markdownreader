import CryptoKit
import Foundation

enum MemoryAnchorConfirmation: String, Codable, Equatable, Sendable {
    case initialCapture
    case manualReattach
}

/// One immutable generation of a passage anchor. Automatic recovery only
/// produces a `MemoryResolutionSnapshot`; it never rewrites this value.
struct ConfirmedMemoryAnchor: Codable, Equatable, Sendable {
    let id: UUID
    let memoryID: UUID
    let supersedesAnchorID: UUID?
    let confirmation: MemoryAnchorConfirmation
    let createdAt: Date
    let selectorVersion: Int
    let projectionVersion: Int
    let sourceRevisionHash: String
    let resolverPolicyVersion: Int
    let exactQuote: String
    let prefix: String
    let suffix: String
    let canonicalTextPosition: UTF8ByteRange
    let canonicalUTF8RangeInBlock: UTF8ByteRange
    let blockKind: SemanticBlockKind
    let blockFingerprint: String
    let headingPath: [HeadingBreadcrumb]
    let blockOrdinal: Int
    /// Durable proof needed after the old projection is no longer in memory.
    /// A duplicate block is never mapped by ordinal alone.
    let blockFingerprintOccurrenceCountInSection: Int
    let sourceUTF8Span: DecodedSourceUTF8Span?
}

struct ExistingResolvedPassage: Equatable, Sendable {
    let memoryID: UUID
    let canonicalTextPosition: UTF8ByteRange
}

enum PassageSelectionIssue: Equatable, Sendable {
    case staleSourceRevision
    case staleRenderRevision
    case staleProjectionVersion
    case unknownBlock
    case emptySelection
    case invalidUnicodeBoundary
    case visibleTextMismatch
    case unsupported(ProjectionUnsupportedReason)
    case overlaps(memoryID: UUID)
}

struct ValidatedPassageSelection: Equatable, Sendable {
    let block: SemanticBlock
    let rangeInBlock: UTF8ByteRange
    let canonicalTextPosition: UTF8ByteRange
    let visibleQuote: String
    let exactQuote: String
    let prefix: String
    let suffix: String
    let sourceUTF8Span: DecodedSourceUTF8Span?
}

enum PassageSelectionValidation: Equatable, Sendable {
    case valid(ValidatedPassageSelection)
    case invalid(PassageSelectionIssue)
}

extension DocumentProjection {
    /// Revalidates transport state and overlap immediately before a capture or
    /// manual reattachment is committed.
    func validatePassageSelection(
        _ selection: ProjectionSelection,
        existingPassages: [ExistingResolvedPassage] = []
    ) -> PassageSelectionValidation {
        guard selection.sourceRevisionHash == source.revisionHash else {
            return .invalid(.staleSourceRevision)
        }
        guard selection.renderRevision == renderRevision else {
            return .invalid(.staleRenderRevision)
        }
        guard selection.projectionVersion == version else {
            return .invalid(.staleProjectionVersion)
        }
        guard let block = block(id: selection.blockID) else {
            return .invalid(.unknownBlock)
        }
        let range = selection.canonicalUTF8RangeInBlock
        guard !range.isEmpty else { return .invalid(.emptySelection) }
        guard range.lowerBound >= 0,
              range.upperBound <= block.canonicalUTF8Count,
              let exactQuote = CanonicalMarkdownText.substring(
                  block.canonicalText,
                  utf8Range: range
              ) else {
            return .invalid(.invalidUnicodeBoundary)
        }
        guard block.captureCapability.permitsAnySelection else {
            if case let .unsupported(reason) = block.captureCapability {
                return .invalid(.unsupported(reason))
            }
            return .invalid(.unsupported(.unsupportedInlineMarkup))
        }

        let intersectingRuns = block.textRuns.filter { run in
            guard let runRange = run.canonicalUTF8RangeInBlock else { return true }
            return runRange.overlaps(range)
        }
        if let reason = intersectingRuns.compactMap(\.unsupportedReason).first {
            return .invalid(.unsupported(reason))
        }
        guard CanonicalMarkdownText.normalize(selection.selectedVisibleText) == exactQuote else {
            return .invalid(.visibleTextMismatch)
        }

        let globalRange = UTF8ByteRange(
            block.canonicalUTF8RangeInDocument.lowerBound + range.lowerBound,
            block.canonicalUTF8RangeInDocument.lowerBound + range.upperBound
        )
        if let overlap = existingPassages.first(where: {
            $0.canonicalTextPosition.overlaps(globalRange)
        }) {
            return .invalid(.overlaps(memoryID: overlap.memoryID))
        }

        return .valid(
            ValidatedPassageSelection(
                block: block,
                rangeInBlock: range,
                canonicalTextPosition: globalRange,
                visibleQuote: selection.selectedVisibleText,
                exactQuote: exactQuote,
                prefix: contextBefore(range.lowerBound, in: block.canonicalText),
                suffix: contextAfter(range.upperBound, in: block.canonicalText),
                sourceUTF8Span: exactSourceSpan(for: range, in: block)
            )
        )
    }

    func makeInitialAnchor(
        memoryID: UUID,
        from selection: ProjectionSelection,
        existingPassages: [ExistingResolvedPassage] = [],
        anchorID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> ConfirmedMemoryAnchor {
        try makeAnchorGeneration(
            id: anchorID,
            memoryID: memoryID,
            supersedesAnchorID: nil,
            confirmation: .initialCapture,
            selection: selection,
            existingPassages: existingPassages,
            createdAt: createdAt
        )
    }

    func makeManualReattachment(
        superseding previous: ConfirmedMemoryAnchor,
        from selection: ProjectionSelection,
        existingPassages: [ExistingResolvedPassage] = [],
        anchorID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> ConfirmedMemoryAnchor {
        try makeAnchorGeneration(
            id: anchorID,
            memoryID: previous.memoryID,
            supersedesAnchorID: previous.id,
            confirmation: .manualReattach,
            selection: selection,
            existingPassages: existingPassages.filter { $0.memoryID != previous.memoryID },
            createdAt: createdAt
        )
    }

    private func makeAnchorGeneration(
        id: UUID,
        memoryID: UUID,
        supersedesAnchorID: UUID?,
        confirmation: MemoryAnchorConfirmation,
        selection: ProjectionSelection,
        existingPassages: [ExistingResolvedPassage],
        createdAt: Date
    ) throws -> ConfirmedMemoryAnchor {
        let validated: ValidatedPassageSelection
        switch validatePassageSelection(selection, existingPassages: existingPassages) {
        case let .valid(value):
            validated = value
        case let .invalid(issue):
            throw issue.projectionError
        }
        let occurrenceCount = blocks.filter {
            $0.headingSectionID == validated.block.headingSectionID
                && $0.kind == validated.block.kind
                && $0.fingerprint == validated.block.fingerprint
        }.count
        return ConfirmedMemoryAnchor(
            id: id,
            memoryID: memoryID,
            supersedesAnchorID: supersedesAnchorID,
            confirmation: confirmation,
            createdAt: createdAt,
            selectorVersion: DocumentProjection.currentSelectorVersion,
            projectionVersion: version,
            sourceRevisionHash: source.revisionHash,
            resolverPolicyVersion: MemoryAnchorResolver.policyVersion,
            exactQuote: validated.exactQuote,
            prefix: validated.prefix,
            suffix: validated.suffix,
            canonicalTextPosition: validated.canonicalTextPosition,
            canonicalUTF8RangeInBlock: validated.rangeInBlock,
            blockKind: validated.block.kind,
            blockFingerprint: validated.block.fingerprint,
            headingPath: validated.block.headingPath,
            blockOrdinal: validated.block.ordinal,
            blockFingerprintOccurrenceCountInSection: occurrenceCount,
            sourceUTF8Span: validated.sourceUTF8Span
        )
    }

    private func contextBefore(_ offset: Int, in text: String) -> String {
        let lowerLimit = max(0, offset - MemoryAnchorResolver.maximumContextUTF8Bytes)
        var lower = lowerLimit
        while lower < offset, !CanonicalMarkdownText.isScalarBoundary(lower, in: text) {
            lower += 1
        }
        return CanonicalMarkdownText.substring(
            text,
            utf8Range: UTF8ByteRange(lower, offset)
        ) ?? ""
    }

    private func contextAfter(_ offset: Int, in text: String) -> String {
        let upperLimit = min(
            text.utf8.count,
            offset + MemoryAnchorResolver.maximumContextUTF8Bytes
        )
        var upper = upperLimit
        while upper > offset, !CanonicalMarkdownText.isScalarBoundary(upper, in: text) {
            upper -= 1
        }
        return CanonicalMarkdownText.substring(
            text,
            utf8Range: UTF8ByteRange(offset, upper)
        ) ?? ""
    }

    private func exactSourceSpan(
        for selectionRange: UTF8ByteRange,
        in block: SemanticBlock
    ) -> DecodedSourceUTF8Span? {
        guard let run = block.textRuns.first(where: { run in
            guard let range = run.canonicalUTF8RangeInBlock else { return false }
            return range.contains(selectionRange)
        }),
        run.kind == .text,
        let runCanonicalRange = run.canonicalUTF8RangeInBlock,
        let sourceRange = run.sourceUTF8Span?.range,
        sourceRange.count == run.domText.utf8.count,
        runCanonicalRange.count == run.domText.utf8.count else { return nil }

        let relativeLower = selectionRange.lowerBound - runCanonicalRange.lowerBound
        let relativeUpper = selectionRange.upperBound - runCanonicalRange.lowerBound
        return DecodedSourceUTF8Span(
            range: UTF8ByteRange(
                sourceRange.lowerBound + relativeLower,
                sourceRange.lowerBound + relativeUpper
            )
        )
    }
}

private extension PassageSelectionIssue {
    var projectionError: DocumentProjectionError {
        switch self {
        case .staleSourceRevision: .staleSourceRevision
        case .staleRenderRevision: .staleRenderRevision
        case .staleProjectionVersion: .staleProjectionVersion
        case .unknownBlock: .unknownBlock("unknown")
        case .emptySelection: .emptySelection
        case .invalidUnicodeBoundary: .nonScalarCanonicalBoundary
        case .visibleTextMismatch: .selectedTextMismatch
        case let .unsupported(reason): .unsupportedSelection(reason)
        case .overlaps: .overlappingSelection
        }
    }
}

enum AnchorResolutionState: String, Codable, Equatable, Sendable {
    case resolved
    case ambiguous
    case needsReview
    case orphaned
}

enum AnchorResolutionEvidence: String, Codable, CaseIterable, Equatable, Sendable {
    case exactPassage
    case matchingPrefix
    case matchingSuffix
    case sameBlockFingerprint
    case sameHeading
}

struct ResolvedRunFragment: Codable, Equatable, Sendable {
    let runID: String
    let domUTF16RangeInRun: UTF16CodeUnitRange
    let canonicalUTF8RangeInBlock: UTF8ByteRange
}

/// The exact, revision-scoped selector the renderer may paint. The renderer
/// must not search for the quote again.
struct ResolvedMemorySelector: Codable, Equatable, Sendable {
    let sourceRevisionHash: String
    let projectionVersion: Int
    let blockID: String
    let blockKind: SemanticBlockKind
    let canonicalUTF8RangeInBlock: UTF8ByteRange
    let canonicalTextPosition: UTF8ByteRange
    let runFragments: [ResolvedRunFragment]
}

struct MemoryResolutionSnapshot: Codable, Equatable, Sendable {
    let anchorID: UUID
    let state: AnchorResolutionState
    let checkedRevisionHash: String
    let resolverPolicyVersion: Int
    let resolvedSelector: ResolvedMemorySelector?
    let evidence: [AnchorResolutionEvidence]
}

struct RecoveryCandidate: Equatable, Sendable {
    /// Deterministic only within the checked source revision and policy.
    let id: String
    let selector: ResolvedMemorySelector
    let evidence: [AnchorResolutionEvidence]
}

struct MemoryRecoveryResult: Equatable, Sendable {
    let resolution: MemoryResolutionSnapshot
    /// Ephemeral candidates for this recovery run. Never persist or export.
    let candidates: [RecoveryCandidate]
    let retainedCheckedResolution: Bool
}

enum MemoryAnchorResolverError: Error, Equatable, LocalizedError {
    case unsupportedSelectorVersion(Int)
    case unsupportedProjectionVersion(Int)
    case unsupportedPolicyVersion(Int)
    case anchorProjectionMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedSelectorVersion:
            "This memory uses a newer selector version."
        case .unsupportedProjectionVersion:
            "This memory uses a newer document projection version."
        case .unsupportedPolicyVersion:
            "This memory uses a newer recovery policy."
        case .anchorProjectionMismatch:
            "The saved anchor does not match its prior document projection."
        }
    }
}

enum MemoryAnchorResolver {
    static let policyVersion = 1
    static let maximumContextUTF8Bytes = 64

    static func resolve(
        anchor: ConfirmedMemoryAnchor,
        priorProjection: DocumentProjection? = nil,
        currentProjection: DocumentProjection,
        currentResolution: MemoryResolutionSnapshot? = nil
    ) throws -> MemoryRecoveryResult {
        let lookup = RecoveryLookup(
            priorProjection: priorProjection,
            currentProjection: currentProjection
        )
        return try resolve(
            anchor: anchor,
            currentResolution: currentResolution,
            lookup: lookup
        )
    }

    /// Resolves a document's anchors in input order while indexing each
    /// projection once. Callers recovering many memories should use this API
    /// instead of rebuilding the same block lookup for every anchor.
    static func resolveBatch(
        anchors: [ConfirmedMemoryAnchor],
        priorProjection: DocumentProjection? = nil,
        currentProjection: DocumentProjection,
        currentResolutionsByAnchorID: [UUID: MemoryResolutionSnapshot] = [:]
    ) throws -> [MemoryRecoveryResult] {
        let lookup = RecoveryLookup(
            priorProjection: priorProjection,
            currentProjection: currentProjection
        )
        return try anchors.map { anchor in
            try resolve(
                anchor: anchor,
                currentResolution: currentResolutionsByAnchorID[anchor.id],
                lookup: lookup
            )
        }
    }

    /// Rebuilds the revision-scoped run fragments intentionally omitted from
    /// durable storage. The caller must separately compare any persisted block
    /// fingerprint, heading path, ordinal, and global range to this result.
    static func reconstructResolvedSelector(
        projection: DocumentProjection,
        blockID: String,
        canonicalUTF8RangeInBlock range: UTF8ByteRange
    ) throws -> ResolvedMemorySelector {
        guard let block = projection.block(id: blockID) else {
            throw DocumentProjectionError.unknownBlock(blockID)
        }
        guard let selectedText = CanonicalMarkdownText.substring(
            block.canonicalText,
            utf8Range: range
        ) else {
            throw DocumentProjectionError.nonScalarCanonicalBoundary
        }
        let selection = ProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            canonicalUTF8RangeInBlock: range,
            selectedVisibleText: selectedText,
            runIDs: block.textRuns.compactMap { run in
                guard let runRange = run.canonicalUTF8RangeInBlock,
                      runRange.overlaps(range) else { return nil }
                return run.id
            }
        )
        switch projection.validatePassageSelection(selection) {
        case .valid:
            break
        case let .invalid(issue):
            throw issue.projectionError
        }
        guard let selector = resolvedSelector(
            index: ProjectionRecoveryIndex(projection),
            block: block,
            range: range
        ) else {
            throw DocumentProjectionError.nonScalarCanonicalBoundary
        }
        return selector
    }

    private static func resolve(
        anchor: ConfirmedMemoryAnchor,
        currentResolution: MemoryResolutionSnapshot?,
        lookup: RecoveryLookup
    ) throws -> MemoryRecoveryResult {
        let currentProjection = lookup.current.projection
        guard anchor.selectorVersion == DocumentProjection.currentSelectorVersion else {
            throw MemoryAnchorResolverError.unsupportedSelectorVersion(anchor.selectorVersion)
        }
        guard anchor.projectionVersion == DocumentProjection.currentVersion,
              currentProjection.version == DocumentProjection.currentVersion else {
            throw MemoryAnchorResolverError.unsupportedProjectionVersion(anchor.projectionVersion)
        }
        guard anchor.resolverPolicyVersion == policyVersion else {
            throw MemoryAnchorResolverError.unsupportedPolicyVersion(anchor.resolverPolicyVersion)
        }

        if let currentResolution,
           currentResolution.anchorID == anchor.id,
           currentResolution.checkedRevisionHash == currentProjection.source.revisionHash,
           currentResolution.resolverPolicyVersion == policyVersion,
           currentResolution.state == .resolved,
           let selector = currentResolution.resolvedSelector,
           selectorIsCurrent(selector, in: lookup.current) {
            return MemoryRecoveryResult(
                resolution: currentResolution,
                candidates: [],
                retainedCheckedResolution: true
            )
        }

        let searchScope = try scopedBlocks(
            anchor: anchor,
            lookup: lookup
        )
        var candidates = eligibleCandidates(
            anchor: anchor,
            blocks: searchScope.primary,
            index: lookup.current
        )
        if candidates.isEmpty, let fallbackSectionID = searchScope.fallbackSectionID {
            candidates = eligibleCandidates(
                anchor: anchor,
                blocks: lookup.current.blocks(
                    inSection: fallbackSectionID,
                    kind: anchor.blockKind
                ),
                index: lookup.current
            )
        }
        candidates = deduplicatedAndSorted(candidates)

        let state: AnchorResolutionState
        let resolvedSelector: ResolvedMemorySelector?
        let evidence: [AnchorResolutionEvidence]
        switch candidates.count {
        case 1:
            state = .resolved
            resolvedSelector = candidates[0].selector
            evidence = candidates[0].evidence
        case 2...:
            state = .ambiguous
            resolvedSelector = nil
            evidence = []
        default:
            state = .orphaned
            resolvedSelector = nil
            evidence = []
        }

        return MemoryRecoveryResult(
            resolution: MemoryResolutionSnapshot(
                anchorID: anchor.id,
                state: state,
                checkedRevisionHash: currentProjection.source.revisionHash,
                resolverPolicyVersion: policyVersion,
                resolvedSelector: resolvedSelector,
                evidence: evidence
            ),
            candidates: candidates,
            retainedCheckedResolution: false
        )
    }

    /// Confirms the exact DOM coordinates used to create an initial anchor.
    /// This must be used at capture time so identical passages elsewhere in
    /// the document cannot turn the user's explicit location into ambiguity.
    static func confirmInitialSelection(
        anchor: ConfirmedMemoryAnchor,
        selection: ProjectionSelection,
        currentProjection: DocumentProjection,
        existingPassages: [ExistingResolvedPassage] = []
    ) throws -> MemoryRecoveryResult {
        try confirmSelection(
            anchor: anchor,
            requiring: .initialCapture,
            selection: selection,
            currentProjection: currentProjection,
            existingPassages: existingPassages
        )
    }

    /// Turns an explicit, user-confirmed selection into the one resolved
    /// selector that may be persisted for a manual anchor generation. Unlike
    /// automatic recovery, this deliberately does not search for the quote:
    /// the DOM coordinates are the user's confirmation of one exact location.
    /// Callers must still pass the same overlap set used for capture.
    static func confirmManualSelection(
        anchor: ConfirmedMemoryAnchor,
        selection: ProjectionSelection,
        currentProjection: DocumentProjection,
        existingPassages: [ExistingResolvedPassage] = []
    ) throws -> MemoryRecoveryResult {
        try confirmSelection(
            anchor: anchor,
            requiring: .manualReattach,
            selection: selection,
            currentProjection: currentProjection,
            existingPassages: existingPassages
        )
    }

    private static func confirmSelection(
        anchor: ConfirmedMemoryAnchor,
        requiring confirmation: MemoryAnchorConfirmation,
        selection: ProjectionSelection,
        currentProjection: DocumentProjection,
        existingPassages: [ExistingResolvedPassage]
    ) throws -> MemoryRecoveryResult {
        guard anchor.confirmation == confirmation,
              anchor.selectorVersion == DocumentProjection.currentSelectorVersion,
              anchor.projectionVersion == currentProjection.version,
              anchor.sourceRevisionHash == currentProjection.source.revisionHash,
              anchor.resolverPolicyVersion == policyVersion else {
            throw MemoryAnchorResolverError.anchorProjectionMismatch
        }

        let validated: ValidatedPassageSelection
        switch currentProjection.validatePassageSelection(
            selection,
            existingPassages: existingPassages.filter { $0.memoryID != anchor.memoryID }
        ) {
        case let .valid(value):
            validated = value
        case let .invalid(issue):
            throw issue.projectionError
        }

        guard validated.exactQuote == anchor.exactQuote,
              validated.canonicalTextPosition == anchor.canonicalTextPosition,
              validated.rangeInBlock == anchor.canonicalUTF8RangeInBlock,
              validated.block.kind == anchor.blockKind,
              validated.block.fingerprint == anchor.blockFingerprint,
              validated.block.ordinal == anchor.blockOrdinal,
              validated.block.headingPath == anchor.headingPath,
              let selector = resolvedSelector(
                  index: ProjectionRecoveryIndex(currentProjection),
                  block: validated.block,
                  range: validated.rangeInBlock
              ) else {
            throw MemoryAnchorResolverError.anchorProjectionMismatch
        }

        return MemoryRecoveryResult(
            resolution: MemoryResolutionSnapshot(
                anchorID: anchor.id,
                state: .resolved,
                checkedRevisionHash: currentProjection.source.revisionHash,
                resolverPolicyVersion: policyVersion,
                resolvedSelector: selector,
                evidence: [.exactPassage]
            ),
            candidates: [],
            retainedCheckedResolution: false
        )
    }

    private struct SearchScope {
        let primary: [SemanticBlock]
        let fallbackSectionID: String?
    }

    private static func scopedBlocks(
        anchor: ConfirmedMemoryAnchor,
        lookup: RecoveryLookup
    ) throws -> SearchScope {
        let oldBlockWasUnique: Bool
        if let prior = lookup.prior,
           prior.projection.source.revisionHash == anchor.sourceRevisionHash {
            guard let oldBlock = prior.block(ordinal: anchor.blockOrdinal),
                  oldBlock.kind == anchor.blockKind,
                  oldBlock.fingerprint == anchor.blockFingerprint else {
                throw MemoryAnchorResolverError.anchorProjectionMismatch
            }
            oldBlockWasUnique = prior.fingerprintCount(
                inSection: oldBlock.headingSectionID,
                kind: anchor.blockKind,
                fingerprint: anchor.blockFingerprint
            ) == 1
        } else {
            oldBlockWasUnique = anchor.blockFingerprintOccurrenceCountInSection == 1
        }

        let fingerprintMatches = lookup.current.blocks(
            kind: anchor.blockKind,
            fingerprint: anchor.blockFingerprint
        )
        let exactHeadingMatches = fingerprintMatches.filter {
            $0.headingPath == anchor.headingPath
        }
        let mappedBlock: SemanticBlock?
        if oldBlockWasUnique, fingerprintMatches.count == 1,
           lookup.current.blockIsUniqueInItsSection(fingerprintMatches[0]) {
            // Global uniqueness permits an unchanged block to survive heading
            // rename or reordering without trusting heading text or ordinal.
            mappedBlock = fingerprintMatches[0]
        } else if oldBlockWasUnique, exactHeadingMatches.count == 1,
                  lookup.current.blockIsUniqueInItsSection(exactHeadingMatches[0]) {
            mappedBlock = exactHeadingMatches[0]
        } else {
            mappedBlock = nil
        }

        if let mappedBlock {
            return SearchScope(
                primary: [mappedBlock],
                fallbackSectionID: mappedBlock.headingSectionID
            )
        }

        let matchingSections = lookup.current.sections(headingPath: anchor.headingPath)
        if matchingSections.count == 1 {
            return SearchScope(
                primary: [],
                fallbackSectionID: matchingSections[0].id
            )
        }
        return SearchScope(primary: [], fallbackSectionID: nil)
    }

    private static func eligibleCandidates(
        anchor: ConfirmedMemoryAnchor,
        blocks: [SemanticBlock],
        index: ProjectionRecoveryIndex
    ) -> [RecoveryCandidate] {
        guard !anchor.exactQuote.isEmpty else { return [] }
        var candidates: [RecoveryCandidate] = []
        for block in blocks where block.kind == anchor.blockKind {
            for range in exactRanges(of: anchor.exactQuote, in: block.canonicalText) {
                guard contextMatches(anchor: anchor, range: range, in: block.canonicalText),
                      let selector = resolvedSelector(
                          index: index,
                          block: block,
                          range: range
                      ) else { continue }
                var evidence: [AnchorResolutionEvidence] = [.exactPassage]
                if !anchor.prefix.isEmpty { evidence.append(.matchingPrefix) }
                if !anchor.suffix.isEmpty { evidence.append(.matchingSuffix) }
                if block.fingerprint == anchor.blockFingerprint {
                    evidence.append(.sameBlockFingerprint)
                }
                if block.headingPath == anchor.headingPath {
                    evidence.append(.sameHeading)
                }
                candidates.append(
                    RecoveryCandidate(
                        id: candidateID(selector: selector),
                        selector: selector,
                        evidence: evidence
                    )
                )
            }
        }
        return candidates
    }

    private static func exactRanges(of quote: String, in text: String) -> [UTF8ByteRange] {
        let haystack = Data(text.utf8)
        let needle = Data(quote.utf8)
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var ranges: [UTF8ByteRange] = []
        var lower = 0
        while lower <= haystack.count - needle.count {
            let searchRange = lower..<haystack.count
            guard let found = haystack.range(of: needle, options: [], in: searchRange) else { break }
            let candidate = UTF8ByteRange(found.lowerBound, found.upperBound)
            if CanonicalMarkdownText.isScalarBoundary(candidate.lowerBound, in: text),
               CanonicalMarkdownText.isScalarBoundary(candidate.upperBound, in: text) {
                ranges.append(candidate)
            }
            lower = found.lowerBound + 1
        }
        return ranges
    }

    private static func contextMatches(
        anchor: ConfirmedMemoryAnchor,
        range: UTF8ByteRange,
        in text: String
    ) -> Bool {
        if !anchor.prefix.isEmpty {
            let byteCount = anchor.prefix.utf8.count
            guard range.lowerBound >= byteCount,
                  CanonicalMarkdownText.substring(
                      text,
                      utf8Range: UTF8ByteRange(range.lowerBound - byteCount, range.lowerBound)
                  ) == anchor.prefix else { return false }
        }
        if !anchor.suffix.isEmpty {
            let byteCount = anchor.suffix.utf8.count
            guard range.upperBound + byteCount <= text.utf8.count,
                  CanonicalMarkdownText.substring(
                      text,
                      utf8Range: UTF8ByteRange(range.upperBound, range.upperBound + byteCount)
                  ) == anchor.suffix else { return false }
        }
        return true
    }

    private static func resolvedSelector(
        index: ProjectionRecoveryIndex,
        block: SemanticBlock,
        range: UTF8ByteRange
    ) -> ResolvedMemorySelector? {
        guard let lowerDOM = domUTF16Offset(
            forCanonicalUTF8Offset: range.lowerBound,
            in: block,
            index: index
        ),
        let upperDOM = domUTF16Offset(
            forCanonicalUTF8Offset: range.upperBound,
            in: block,
            index: index
        ) else { return nil }

        var fragments: [ResolvedRunFragment] = []
        for run in block.textRuns {
            let intersectionLower = max(lowerDOM, run.domUTF16RangeInBlock.lowerBound)
            let intersectionUpper = min(upperDOM, run.domUTF16RangeInBlock.upperBound)
            guard intersectionLower < intersectionUpper else { continue }
            let fragmentDOM = UTF16CodeUnitRange(
                intersectionLower - run.domUTF16RangeInBlock.lowerBound,
                intersectionUpper - run.domUTF16RangeInBlock.lowerBound
            )
            let fragmentLowerCanonical = canonicalUTF8Offset(
                forDOMUTF16Offset: intersectionLower,
                in: block,
                index: index
            )
            let fragmentUpperCanonical = canonicalUTF8Offset(
                forDOMUTF16Offset: intersectionUpper,
                in: block,
                index: index
            )
            guard let fragmentLowerCanonical, let fragmentUpperCanonical else { return nil }
            fragments.append(
                ResolvedRunFragment(
                    runID: run.id,
                    domUTF16RangeInRun: fragmentDOM,
                    canonicalUTF8RangeInBlock: UTF8ByteRange(
                        fragmentLowerCanonical,
                        fragmentUpperCanonical
                    )
                )
            )
        }
        guard !fragments.isEmpty else { return nil }
        return ResolvedMemorySelector(
            sourceRevisionHash: index.projection.source.revisionHash,
            projectionVersion: index.projection.version,
            blockID: block.id,
            blockKind: block.kind,
            canonicalUTF8RangeInBlock: range,
            canonicalTextPosition: UTF8ByteRange(
                block.canonicalUTF8RangeInDocument.lowerBound + range.lowerBound,
                block.canonicalUTF8RangeInDocument.lowerBound + range.upperBound
            ),
            runFragments: fragments
        )
    }

    private static func domUTF16Offset(
        forCanonicalUTF8Offset target: Int,
        in block: SemanticBlock,
        index: ProjectionRecoveryIndex
    ) -> Int? {
        if let run = block.textRuns.first(where: { run in
            guard let range = run.canonicalUTF8RangeInBlock else { return false }
            return range.lowerBound <= target
                && target <= range.upperBound
                && index.hasLinearASCIIMapping(runID: run.id)
        }), let range = run.canonicalUTF8RangeInBlock {
            return run.domUTF16RangeInBlock.lowerBound + target - range.lowerBound
        }

        let domText = block.textRuns.map(\.domText).joined()
        if let boundary = CanonicalMarkdownText.normalizationBoundaries(in: domText)
            .first(where: { $0.canonicalUTF8Offset == target }) {
            return boundary.domUTF16Offset
        }
        // A selector may end at a Unicode-scalar boundary inside one extended
        // grapheme. Keep the slower prefix check only for that rare case.
        var utf16Offset = 0
        var scalarIndex = domText.unicodeScalars.startIndex
        while true {
            guard let index = scalarIndex.samePosition(in: domText) else { return nil }
            let prefix = String(domText[..<index])
            let canonicalOffset = CanonicalMarkdownText.normalize(prefix).utf8.count
            if canonicalOffset == target { return utf16Offset }
            if canonicalOffset > target || scalarIndex == domText.unicodeScalars.endIndex {
                return nil
            }
            let scalar = domText.unicodeScalars[scalarIndex]
            utf16Offset += scalar.utf16.count
            scalarIndex = domText.unicodeScalars.index(after: scalarIndex)
        }
    }

    private static func canonicalUTF8Offset(
        forDOMUTF16Offset target: Int,
        in block: SemanticBlock,
        index: ProjectionRecoveryIndex
    ) -> Int? {
        if let run = block.textRuns.first(where: { run in
            run.domUTF16RangeInBlock.lowerBound <= target
                && target <= run.domUTF16RangeInBlock.upperBound
                && index.hasLinearASCIIMapping(runID: run.id)
        }), let range = run.canonicalUTF8RangeInBlock {
            return range.lowerBound + target - run.domUTF16RangeInBlock.lowerBound
        }

        let domText = block.textRuns.map(\.domText).joined()
        guard target >= 0, target <= domText.utf16.count else { return nil }
        let utf16Index = domText.utf16.index(domText.utf16.startIndex, offsetBy: target)
        guard let index = String.Index(utf16Index, within: domText) else { return nil }
        let prefix = String(domText[..<index])
        let offset = CanonicalMarkdownText.normalize(prefix).utf8.count
        return CanonicalMarkdownText.isScalarBoundary(offset, in: block.canonicalText) ? offset : nil
    }

    private static func candidateID(selector: ResolvedMemorySelector) -> String {
        let value = [
            selector.sourceRevisionHash,
            selector.blockID,
            String(selector.canonicalUTF8RangeInBlock.lowerBound),
            String(selector.canonicalUTF8RangeInBlock.upperBound),
            String(policyVersion)
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func selectorIsCurrent(
        _ selector: ResolvedMemorySelector,
        in index: ProjectionRecoveryIndex
    ) -> Bool {
        let projection = index.projection
        guard selector.sourceRevisionHash == projection.source.revisionHash,
              selector.projectionVersion == projection.version,
              let block = index.block(id: selector.blockID),
              block.kind == selector.blockKind,
              selector.canonicalUTF8RangeInBlock.lowerBound >= 0,
              selector.canonicalUTF8RangeInBlock.upperBound <= block.canonicalUTF8Count,
              !selector.runFragments.isEmpty else { return false }
        return selector.runFragments.allSatisfy { fragment in
            block.textRuns.contains { $0.id == fragment.runID }
        }
    }

    private struct RecoveryLookup {
        let prior: ProjectionRecoveryIndex?
        let current: ProjectionRecoveryIndex

        init(
            priorProjection: DocumentProjection?,
            currentProjection: DocumentProjection
        ) {
            prior = priorProjection.map(ProjectionRecoveryIndex.init)
            current = ProjectionRecoveryIndex(currentProjection)
        }
    }

    private struct ProjectionRecoveryIndex {
        struct FingerprintKey: Hashable {
            let kind: String
            let fingerprint: String
        }

        struct SectionFingerprintKey: Hashable {
            let sectionID: String
            let kind: String
            let fingerprint: String
        }

        struct HeadingPathKey: Hashable {
            let breadcrumbs: [HeadingBreadcrumb]
        }

        let projection: DocumentProjection
        private let blockIndexByID: [String: Int]
        private let blockIndicesByFingerprint: [FingerprintKey: [Int]]
        private let fingerprintCountsBySection: [SectionFingerprintKey: Int]
        private let sectionIndicesByHeadingPath: [HeadingPathKey: [Int]]
        private let linearASCIIRunIDs: Set<String>

        init(_ projection: DocumentProjection) {
            self.projection = projection

            var blockIndexByID: [String: Int] = [:]
            var blockIndicesByFingerprint: [FingerprintKey: [Int]] = [:]
            var fingerprintCountsBySection: [SectionFingerprintKey: Int] = [:]
            var linearASCIIRunIDs: Set<String> = []
            blockIndexByID.reserveCapacity(projection.blocks.count)
            blockIndicesByFingerprint.reserveCapacity(projection.blocks.count)
            fingerprintCountsBySection.reserveCapacity(projection.blocks.count)

            for index in projection.blocks.indices {
                let block = projection.blocks[index]
                blockIndexByID[block.id] = index
                blockIndicesByFingerprint[
                    FingerprintKey(kind: block.kind.rawValue, fingerprint: block.fingerprint),
                    default: []
                ].append(index)
                fingerprintCountsBySection[
                    SectionFingerprintKey(
                        sectionID: block.headingSectionID,
                        kind: block.kind.rawValue,
                        fingerprint: block.fingerprint
                    ),
                    default: 0
                ] += 1
                for run in block.textRuns {
                    guard let canonicalRange = run.canonicalUTF8RangeInBlock,
                          canonicalRange.count == run.domText.utf8.count,
                          run.domText.utf8.allSatisfy({ $0 < 0x80 }) else { continue }
                    linearASCIIRunIDs.insert(run.id)
                }
            }

            var sectionIndicesByHeadingPath: [HeadingPathKey: [Int]] = [:]
            sectionIndicesByHeadingPath.reserveCapacity(projection.headingSections.count)
            for index in projection.headingSections.indices {
                sectionIndicesByHeadingPath[
                    HeadingPathKey(
                        breadcrumbs: projection.headingSections[index].headingPath
                    ),
                    default: []
                ].append(index)
            }

            self.blockIndexByID = blockIndexByID
            self.blockIndicesByFingerprint = blockIndicesByFingerprint
            self.fingerprintCountsBySection = fingerprintCountsBySection
            self.sectionIndicesByHeadingPath = sectionIndicesByHeadingPath
            self.linearASCIIRunIDs = linearASCIIRunIDs
        }

        func block(id: String) -> SemanticBlock? {
            guard let index = blockIndexByID[id] else { return nil }
            return projection.blocks[index]
        }

        func block(ordinal: Int) -> SemanticBlock? {
            guard projection.blocks.indices.contains(ordinal),
                  projection.blocks[ordinal].ordinal == ordinal else { return nil }
            return projection.blocks[ordinal]
        }

        func hasLinearASCIIMapping(runID: String) -> Bool {
            linearASCIIRunIDs.contains(runID)
        }

        func blocks(
            kind: SemanticBlockKind,
            fingerprint: String
        ) -> [SemanticBlock] {
            let indices = blockIndicesByFingerprint[
                FingerprintKey(kind: kind.rawValue, fingerprint: fingerprint)
            ] ?? []
            return indices.map { projection.blocks[$0] }
        }

        func fingerprintCount(
            inSection sectionID: String,
            kind: SemanticBlockKind,
            fingerprint: String
        ) -> Int {
            fingerprintCountsBySection[
                SectionFingerprintKey(
                    sectionID: sectionID,
                    kind: kind.rawValue,
                    fingerprint: fingerprint
                )
            ] ?? 0
        }

        func blockIsUniqueInItsSection(_ block: SemanticBlock) -> Bool {
            fingerprintCount(
                inSection: block.headingSectionID,
                kind: block.kind,
                fingerprint: block.fingerprint
            ) == 1
        }

        func sections(headingPath: [HeadingBreadcrumb]) -> [HeadingSection] {
            let indices = sectionIndicesByHeadingPath[
                HeadingPathKey(breadcrumbs: headingPath)
            ] ?? []
            return indices.map { projection.headingSections[$0] }
        }

        func blocks(
            inSection sectionID: String,
            kind: SemanticBlockKind
        ) -> [SemanticBlock] {
            guard let section = projection.section(id: sectionID) else { return [] }
            return projection.blocks.filter {
                section.contains(blockOrdinal: $0.ordinal) && $0.kind == kind
            }
        }
    }

    private static func deduplicatedAndSorted(
        _ candidates: [RecoveryCandidate]
    ) -> [RecoveryCandidate] {
        var seen: Set<String> = []
        return candidates
            .sorted {
                if $0.selector.canonicalTextPosition.lowerBound
                    != $1.selector.canonicalTextPosition.lowerBound {
                    return $0.selector.canonicalTextPosition.lowerBound
                        < $1.selector.canonicalTextPosition.lowerBound
                }
                return $0.id < $1.id
            }
            .filter { seen.insert($0.id).inserted }
    }
}
