import CoreGraphics
import Foundation

/// Immutable, store-independent value consumed by the current-document Memory
/// views. View models adapt durable records into this type at the UI boundary.
struct MemoryPresentation: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case passage
        case headingBookmark

        var label: String {
            switch self {
            case .passage: "Highlight"
            case .headingBookmark: "Bookmark"
            }
        }
    }

    enum State: Equatable, Sendable {
        case resolved
        case chooseLocation(candidateCount: Int?)
        case needsRepair(hasProposedLocation: Bool)

        var label: String {
            switch self {
            case .resolved:
                "Resolved"
            case .chooseLocation:
                "Choose location"
            case let .needsRepair(hasProposedLocation):
                hasProposedLocation ? "Needs repair · proposed location" : "Needs repair"
            }
        }

        var shortLabel: String {
            switch self {
            case .resolved: "Resolved"
            case .chooseLocation: "Choose location"
            case .needsRepair: "Needs repair"
            }
        }

        var needsAttention: Bool {
            if case .resolved = self { return false }
            return true
        }

        var isLooseSlip: Bool {
            if case .needsRepair(hasProposedLocation: false) = self { return true }
            return false
        }

        var candidateCount: Int? {
            if case let .chooseLocation(candidateCount) = self {
                return candidateCount.map { max(0, $0) }
            }
            return nil
        }

        var hasUnknownCandidateCount: Bool {
            if case .chooseLocation(candidateCount: nil) = self { return true }
            return false
        }
    }

    struct AnchorDetails: Equatable, Sendable {
        let foundBy: String
        let lastChecked: String
        let candidateSummary: String
        let savedPassage: String?

        init(
            foundBy: String,
            lastChecked: String,
            candidateSummary: String,
            savedPassage: String? = nil
        ) {
            self.foundBy = foundBy
            self.lastChecked = lastChecked
            self.candidateSummary = candidateSummary
            self.savedPassage = savedPassage
        }
    }

    struct CandidateLocation: Identifiable, Equatable, Sendable {
        let id: String
        let headingPath: String?
        let passage: String
        let locationLabel: String
    }

    let id: UUID
    let kind: Kind
    let state: State
    let title: String
    let passage: String?
    let note: String?
    let headingPath: String?
    let savedAt: String
    let anchorDetails: AnchorDetails?
    let candidateLocations: [CandidateLocation]

    init(
        id: UUID,
        kind: Kind,
        state: State,
        title: String,
        passage: String? = nil,
        note: String? = nil,
        headingPath: String? = nil,
        savedAt: String,
        anchorDetails: AnchorDetails? = nil,
        candidateLocations: [CandidateLocation] = []
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.title = title
        self.passage = passage
        self.note = note
        self.headingPath = headingPath
        self.savedAt = savedAt
        self.anchorDetails = anchorDetails
        self.candidateLocations = candidateLocations
    }

    var hasNote: Bool {
        guard let note else { return false }
        return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var accessibilityLabel: String {
        var components = [state.shortLabel, kind.label, title]
        if hasNote { components.append("Has a note") }
        if let candidates = state.candidateCount {
            components.append("Matches \(candidates) locations and has not been placed")
        } else if state.hasUnknownCandidateCount {
            components.append("Matches multiple possible locations and has not been placed")
        } else if state.isLooseSlip {
            components.append("The saved passage has been kept but is not located in the document")
        }
        components.append("Saved \(savedAt)")
        return components.joined(separator: ". ") + "."
    }
}

/// Document-coordinate placement calculated by the parent annotation canvas.
/// Keeping geometry separate lets the same presentation render in a sidebar,
/// inspector, or packed gutter.
struct MemoryGutterPlacement: Identifiable, Equatable, Sendable {
    var id: UUID { memory.id }

    let memory: MemoryPresentation
    let anchorY: CGFloat
    let noteY: CGFloat

    init(memory: MemoryPresentation, anchorY: CGFloat, noteY: CGFloat) {
        self.memory = memory
        self.anchorY = anchorY
        self.noteY = noteY
    }

    var leaderDrop: CGFloat { max(0, noteY - anchorY) }
}
