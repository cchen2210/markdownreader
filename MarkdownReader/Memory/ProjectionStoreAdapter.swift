import Foundation

enum ProjectionStoreAdapter {
    static func newAnchor(from anchor: ConfirmedMemoryAnchor) -> NewConfirmedAnchor {
        NewConfirmedAnchor(
            id: anchor.id,
            supersedesAnchorID: anchor.supersedesAnchorID,
            confirmation: anchor.confirmation == .initialCapture ? .initialCapture : .manualReattach,
            createdAt: anchor.createdAt,
            selectorVersion: anchor.selectorVersion,
            projectionVersion: anchor.projectionVersion,
            sourceRevisionHash: anchor.sourceRevisionHash,
            resolverPolicyVersion: anchor.resolverPolicyVersion,
            exactQuote: anchor.exactQuote,
            prefix: anchor.prefix,
            suffix: anchor.suffix,
            canonicalTextPosition: storedRange(anchor.canonicalTextPosition),
            canonicalUTF8RangeInBlock: storedRange(anchor.canonicalUTF8RangeInBlock),
            blockKind: anchor.blockKind.rawValue,
            blockFingerprint: anchor.blockFingerprint,
            headingPath: anchor.headingPath.map {
                StoredHeadingBreadcrumb(level: $0.level, title: $0.title)
            },
            blockOrdinal: Int64(anchor.blockOrdinal),
            blockFingerprintOccurrenceCountInSection: anchor.blockFingerprintOccurrenceCountInSection,
            sourceUTF8Span: anchor.sourceUTF8Span.map { storedSpan($0.range) }
        )
    }

    static func confirmedAnchor(from record: ConfirmedAnchorRecord) throws -> ConfirmedMemoryAnchor {
        guard let kind = SemanticBlockKind(rawValue: record.blockKind),
              let globalRange = projectionRange(record.canonicalTextPosition),
              let blockRange = projectionRange(record.canonicalUTF8RangeInBlock),
              record.blockOrdinal >= 0,
              record.blockOrdinal <= Int64(Int.max),
              record.blockFingerprintOccurrenceCountInSection >= 1 else {
            throw ProjectionStoreAdapterError.invalidAnchor
        }
        return ConfirmedMemoryAnchor(
            id: record.id,
            memoryID: record.memoryID,
            supersedesAnchorID: record.supersedesAnchorID,
            confirmation: record.confirmation == .initialCapture ? .initialCapture : .manualReattach,
            createdAt: record.createdAt,
            selectorVersion: record.selectorVersion,
            projectionVersion: record.projectionVersion,
            sourceRevisionHash: record.sourceRevisionHash,
            resolverPolicyVersion: record.resolverPolicyVersion,
            exactQuote: record.exactQuote,
            prefix: record.prefix,
            suffix: record.suffix,
            canonicalTextPosition: globalRange,
            canonicalUTF8RangeInBlock: blockRange,
            blockKind: kind,
            blockFingerprint: record.blockFingerprint,
            headingPath: record.headingPath.map {
                HeadingBreadcrumb(level: $0.level, title: $0.title)
            },
            blockOrdinal: Int(record.blockOrdinal),
            blockFingerprintOccurrenceCountInSection: record.blockFingerprintOccurrenceCountInSection,
            sourceUTF8Span: record.sourceUTF8Span.flatMap { span in
                projectionRange(span).map { DecodedSourceUTF8Span(range: $0) }
            }
        )
    }

    static func resolutionDraft(
        from result: MemoryRecoveryResult,
        projection: DocumentProjection,
        checkedAt: Date = Date()
    ) throws -> ResolutionDraft {
        let selector: ResolvedSelector?
        if let resolved = result.resolution.resolvedSelector {
            guard let block = projection.block(id: resolved.blockID) else {
                throw ProjectionStoreAdapterError.invalidResolution
            }
            selector = ResolvedSelector(
                sourceRevisionHash: resolved.sourceRevisionHash,
                projectionVersion: resolved.projectionVersion,
                blockID: resolved.blockID,
                canonicalUTF8RangeInBlock: storedRange(resolved.canonicalUTF8RangeInBlock),
                canonicalTextPosition: storedRange(resolved.canonicalTextPosition),
                blockKind: resolved.blockKind.rawValue,
                blockFingerprint: block.fingerprint,
                headingPath: block.headingPath.map {
                    StoredHeadingBreadcrumb(level: $0.level, title: $0.title)
                },
                blockOrdinal: Int64(block.ordinal),
                sourceUTF8Span: block.sourceUTF8Span.map { storedSpan($0.range) }
            )
        } else {
            selector = nil
        }
        return ResolutionDraft(
            state: storedState(result.resolution.state),
            checkedRevisionHash: result.resolution.checkedRevisionHash,
            resolverPolicyVersion: result.resolution.resolverPolicyVersion,
            resolvedSelector: selector,
            evidence: result.resolution.evidence.map(storedEvidence),
            lastCheckedAt: checkedAt
        )
    }

    /// Rehydrates the revision-scoped selector data that is intentionally not
    /// stored in SQLite. Only a selector that is fully consistent with the
    /// current projection is eligible for resolver retention; callers should
    /// ignore this value and run normal recovery when validation fails.
    static func resolutionSnapshot(
        from record: CurrentResolutionRecord,
        projection: DocumentProjection
    ) throws -> MemoryResolutionSnapshot {
        let state = anchorState(record.state)
        let selector: ResolvedMemorySelector?
        if state == .resolved {
            guard let stored = record.resolvedSelector,
                  stored.sourceRevisionHash == record.checkedRevisionHash,
                  stored.sourceRevisionHash == projection.source.revisionHash,
                  stored.projectionVersion == projection.version,
                  let kind = SemanticBlockKind(rawValue: stored.blockKind),
                  let block = projection.block(id: stored.blockID),
                  block.kind == kind,
                  block.fingerprint == stored.blockFingerprint,
                  Int64(block.ordinal) == stored.blockOrdinal,
                  block.headingPath == stored.headingPath.map({
                      HeadingBreadcrumb(level: $0.level, title: $0.title)
                  }),
                  let localRange = projectionRange(stored.canonicalUTF8RangeInBlock),
                  let globalRange = projectionRange(stored.canonicalTextPosition),
                  globalRange == UTF8ByteRange(
                      block.canonicalUTF8RangeInDocument.lowerBound + localRange.lowerBound,
                      block.canonicalUTF8RangeInDocument.lowerBound + localRange.upperBound
                  ) else {
                throw ProjectionStoreAdapterError.invalidResolution
            }
            if let storedSpan = stored.sourceUTF8Span {
                guard let projectionSpan = projectionRange(storedSpan),
                      projectionSpan == block.sourceUTF8Span?.range else {
                    throw ProjectionStoreAdapterError.invalidResolution
                }
            }
            selector = try MemoryAnchorResolver.reconstructResolvedSelector(
                projection: projection,
                blockID: block.id,
                canonicalUTF8RangeInBlock: localRange
            )
        } else {
            guard record.resolvedSelector == nil else {
                throw ProjectionStoreAdapterError.invalidResolution
            }
            selector = nil
        }

        return MemoryResolutionSnapshot(
            anchorID: record.anchorID,
            state: state,
            checkedRevisionHash: record.checkedRevisionHash,
            resolverPolicyVersion: record.resolverPolicyVersion,
            resolvedSelector: selector,
            evidence: record.evidence.compactMap(anchorEvidence)
        )
    }

    static func storedState(_ state: AnchorResolutionState) -> MemoryResolutionState {
        switch state {
        case .resolved: .resolved
        case .ambiguous: .ambiguous
        case .needsReview: .needsReview
        case .orphaned: .orphaned
        }
    }

    static func anchorState(_ state: MemoryResolutionState) -> AnchorResolutionState {
        switch state {
        case .resolved: .resolved
        case .ambiguous: .ambiguous
        case .needsReview: .needsReview
        case .orphaned: .orphaned
        }
    }

    private static func storedEvidence(_ evidence: AnchorResolutionEvidence) -> ResolutionEvidence {
        let kind: ResolutionEvidence.Kind
        switch evidence {
        case .exactPassage: kind = .exactQuote
        case .matchingPrefix: kind = .prefix
        case .matchingSuffix: kind = .suffix
        case .sameBlockFingerprint: kind = .blockFingerprint
        case .sameHeading: kind = .headingPath
        }
        return ResolutionEvidence(kind: kind)
    }

    private static func anchorEvidence(_ evidence: ResolutionEvidence) -> AnchorResolutionEvidence? {
        guard evidence.matched else { return nil }
        switch evidence.kind {
        case .exactQuote: return .exactPassage
        case .prefix: return .matchingPrefix
        case .suffix: return .matchingSuffix
        case .blockFingerprint: return .sameBlockFingerprint
        case .headingPath: return .sameHeading
        case .blockKind, .manualConfirmation: return nil
        }
    }

    private static func storedRange(_ range: UTF8ByteRange) -> CanonicalTextRange {
        CanonicalTextRange(lowerBound: Int64(range.lowerBound), upperBound: Int64(range.upperBound))
    }

    private static func storedSpan(_ range: UTF8ByteRange) -> SourceUTF8Span {
        SourceUTF8Span(lowerBound: Int64(range.lowerBound), upperBound: Int64(range.upperBound))
    }

    private static func projectionRange(_ range: CanonicalTextRange) -> UTF8ByteRange? {
        guard range.isValid,
              range.upperBound <= Int64(Int.max) else { return nil }
        return UTF8ByteRange(Int(range.lowerBound), Int(range.upperBound))
    }

    private static func projectionRange(_ span: SourceUTF8Span) -> UTF8ByteRange? {
        guard span.isValid,
              span.upperBound <= Int64(Int.max) else { return nil }
        return UTF8ByteRange(Int(span.lowerBound), Int(span.upperBound))
    }
}

enum ProjectionStoreAdapterError: Equatable, LocalizedError {
    case invalidAnchor
    case invalidResolution

    var errorDescription: String? {
        switch self {
        case .invalidAnchor:
            "A saved Reading Memory anchor is invalid and was left unchanged."
        case .invalidResolution:
            "A Reading Memory resolution could not be mapped to this document revision."
        }
    }
}
