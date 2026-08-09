import Foundation

/// Returned when a cold open finds that a registered current path now points
/// at a different filesystem identity. The repository has not rebound or
/// created any record when this value is produced.
struct DocumentOpenIdentityDecision: Equatable, Sendable {
    let registeredDocumentID: UUID
    let registeredPath: URL
    let candidatePath: URL
    let storedIdentityFingerprint: String
    let candidateIdentityFingerprint: String
    let storedContentHash: String?
    let candidateContentHash: String
    let identityMatchedDocumentIDs: [UUID]
}

struct DocumentIdentityDecisionRequiredError: Error, Equatable, Sendable, LocalizedError {
    let decision: DocumentOpenIdentityDecision

    var errorDescription: String? {
        "This path now points to a different file. Reading Memory left both records unchanged; confirm the identity before relinking."
    }
}

struct DocumentRelinkRecoveryEvidence: Equatable, Sendable {
    let memoryCount: Int
    let resolvedCount: Int
    let ambiguousCount: Int
    let needsReviewCount: Int
    let orphanedCount: Int
    let invalidAnchorCount: Int

    var summary: String {
        guard memoryCount > 0 else { return "No saved memories to recover" }
        var parts = ["\(resolvedCount) exact"]
        if ambiguousCount > 0 { parts.append("\(ambiguousCount) ambiguous") }
        if needsReviewCount > 0 { parts.append("\(needsReviewCount) need review") }
        if orphanedCount > 0 { parts.append("\(orphanedCount) orphaned") }
        if invalidAnchorCount > 0 { parts.append("\(invalidAnchorCount) invalid") }
        return parts.joined(separator: " · ")
    }
}

/// Ephemeral evidence for one explicit Locate Original confirmation. It is
/// never persisted or exported. Confirmation re-probes every field that could
/// have changed before updating the durable document record.
struct DocumentRelinkProposal: Identifiable, Equatable, Sendable {
    let id: UUID
    let documentID: UUID
    let documentDisplayName: String
    let oldPath: URL
    let candidatePath: URL
    let storedIdentityFingerprint: String
    let candidateIdentityFingerprint: String
    let identitiesMatch: Bool
    let storedContentHash: String?
    let candidateContentHash: String
    let recovery: DocumentRelinkRecoveryEvidence
    let conflictingDocumentIDs: [UUID]
    let expectedDocumentRecordVersion: Int64

    var hashesMatch: Bool { storedContentHash == candidateContentHash }
    var canConfirm: Bool { conflictingDocumentIDs.isEmpty }
}

enum DocumentRelinkError: Error, Equatable, Sendable, LocalizedError {
    case proposalNotFound
    case proposalChanged
    case candidateAlreadyRegistered([UUID])

    var errorDescription: String? {
        switch self {
        case .proposalNotFound:
            "This relink review expired. Choose the original file again."
        case .proposalChanged:
            "The document or candidate changed during review. Nothing was relinked; review it again."
        case .candidateAlreadyRegistered:
            "That file already belongs to another Reading Memory record. The records were not merged."
        }
    }
}
