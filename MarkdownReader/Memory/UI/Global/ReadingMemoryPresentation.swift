import Foundation

enum ReadingMemoryFacet: String, CaseIterable, Hashable, Identifiable, Sendable {
    case allMemories
    case continueReading
    case favourites
    case highlights
    case notes
    case bookmarks
    case chooseLocation
    case needsRepair

    enum Group: String, CaseIterable, Sendable {
        case library = "Library"
        case kinds = "Kinds"
        case attention = "Attention"
    }

    var id: Self { self }

    var label: String {
        switch self {
        case .allMemories: "All Memories"
        case .continueReading: "Continue Reading"
        case .favourites: "Favourites"
        case .highlights: "Highlights"
        case .notes: "Notes"
        case .bookmarks: "Bookmarks"
        case .chooseLocation: "Choose Location"
        case .needsRepair: "Needs Repair"
        }
    }

    var group: Group {
        switch self {
        case .allMemories, .continueReading, .favourites:
            .library
        case .highlights, .notes, .bookmarks:
            .kinds
        case .chooseLocation, .needsRepair:
            .attention
        }
    }

    var presentsDocuments: Bool {
        self == .continueReading || self == .favourites
    }

    var emptyTitle: String {
        switch self {
        case .continueReading: "Nothing to continue yet"
        case .favourites: "No favourite documents"
        case .chooseLocation: "No locations to choose"
        case .needsRepair: "Nothing needs repair"
        default: "Nothing kept yet"
        }
    }

    var emptyMessage: String {
        switch self {
        case .continueReading:
            "Documents appear here after you read them."
        case .favourites:
            "Favourite a document to keep it close at hand."
        case .chooseLocation:
            "Memories with more than one possible home appear here."
        case .needsRepair:
            "Memories whose saved passage cannot be found appear here."
        default:
            "Open a Markdown document, select a passage, and choose Remember."
        }
    }
}

enum ReadingMemorySearchScope: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case passages
    case notes
    case headings

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All"
        case .passages: "Passages"
        case .notes: "Notes"
        case .headings: "Headings"
        }
    }
}

struct ReadingMemorySearchRequest: Equatable, Sendable {
    let text: String
    let scope: ReadingMemorySearchScope
    let facet: ReadingMemoryFacet

    init(text: String, scope: ReadingMemorySearchScope, facet: ReadingMemoryFacet) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope
        self.facet = facet
    }
}

struct ReadingMemorySidebarCounts: Equatable, Sendable {
    private let values: [ReadingMemoryFacet: Int]

    init(_ values: [ReadingMemoryFacet: Int] = [:]) {
        self.values = values.mapValues { max(0, $0) }
    }

    func count(for facet: ReadingMemoryFacet) -> Int {
        values[facet, default: 0]
    }
}

struct ReadingMemorySearchSummary: Equatable, Sendable {
    let documentCount: Int
    let attentionCount: Int

    init(documentCount: Int = 0, attentionCount: Int = 0) {
        self.documentCount = max(0, documentCount)
        self.attentionCount = max(0, attentionCount)
    }
}

struct ReadingDocumentPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let parentFolder: String?
    let lastHeading: String?
    let lastRead: String
    let progress: Double?
    let isFavourite: Bool
    let isOriginalAvailable: Bool

    init(
        id: UUID,
        displayName: String,
        parentFolder: String? = nil,
        lastHeading: String? = nil,
        lastRead: String,
        progress: Double? = nil,
        isFavourite: Bool,
        isOriginalAvailable: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.parentFolder = parentFolder
        self.lastHeading = lastHeading
        self.lastRead = lastRead
        self.progress = progress
        self.isFavourite = isFavourite
        self.isOriginalAvailable = isOriginalAvailable
    }

    var boundedProgress: Double? {
        progress.map { min(max($0, 0), 1) }
    }

    var accessibilityLabel: String {
        var components = [displayName]
        if let lastHeading, !lastHeading.isEmpty {
            components.append("Last read at \(lastHeading)")
        }
        components.append("Last read \(lastRead)")
        if let boundedProgress {
            components.append("\(Int((boundedProgress * 100).rounded())) percent complete")
        }
        if isFavourite { components.append("Favourite") }
        if !isOriginalAvailable { components.append("Original file unavailable") }
        return components.joined(separator: ". ") + "."
    }
}

struct ReadingMemoryEntryPresentation: Identifiable, Equatable, Sendable {
    var id: UUID { memory.id }

    let memory: MemoryPresentation
    let documentID: UUID?
    let documentName: String
    let parentFolder: String?
    let heading: String?
    let provenanceDate: String
    let retainedMatchExplanation: String?

    init(
        memory: MemoryPresentation,
        documentID: UUID? = nil,
        documentName: String,
        parentFolder: String? = nil,
        heading: String? = nil,
        provenanceDate: String,
        retainedMatchExplanation: String? = nil
    ) {
        self.memory = memory
        self.documentID = documentID
        self.documentName = documentName
        self.parentFolder = parentFolder
        self.heading = heading
        self.provenanceDate = provenanceDate
        self.retainedMatchExplanation = retainedMatchExplanation
    }

    var accessibilityLabel: String {
        var components = [memory.accessibilityLabel, "From \(documentName)"]
        if let heading, !heading.isEmpty { components.append("Under \(heading)") }
        if let retainedMatchExplanation, !retainedMatchExplanation.isEmpty {
            components.append(retainedMatchExplanation)
        }
        return components.joined(separator: ". ")
    }
}

struct ReadingMemoryActions {
    var selectFacet: (ReadingMemoryFacet) -> Void
    var selectMemory: (UUID) -> Void
    var openMemory: (UUID) -> Void
    var openDocument: (UUID) -> Void
    var editNote: (UUID) -> Void
    var reviewLocation: (UUID) -> Void
    var deleteMemory: (UUID) -> Void
    var toggleFavourite: (UUID) -> Void
    var forgetDocument: (UUID) -> Void
    var openDocumentPicker: () -> Void
    var requestExport: () -> Void
    var search: (ReadingMemorySearchRequest) -> Void

    init(
        selectFacet: @escaping (ReadingMemoryFacet) -> Void = { _ in },
        selectMemory: @escaping (UUID) -> Void = { _ in },
        openMemory: @escaping (UUID) -> Void = { _ in },
        openDocument: @escaping (UUID) -> Void = { _ in },
        editNote: @escaping (UUID) -> Void = { _ in },
        reviewLocation: @escaping (UUID) -> Void = { _ in },
        deleteMemory: @escaping (UUID) -> Void = { _ in },
        toggleFavourite: @escaping (UUID) -> Void = { _ in },
        forgetDocument: @escaping (UUID) -> Void = { _ in },
        openDocumentPicker: @escaping () -> Void = {},
        requestExport: @escaping () -> Void = {},
        search: @escaping (ReadingMemorySearchRequest) -> Void = { _ in }
    ) {
        self.selectFacet = selectFacet
        self.selectMemory = selectMemory
        self.openMemory = openMemory
        self.openDocument = openDocument
        self.editNote = editNote
        self.reviewLocation = reviewLocation
        self.deleteMemory = deleteMemory
        self.toggleFavourite = toggleFavourite
        self.forgetDocument = forgetDocument
        self.openDocumentPicker = openDocumentPicker
        self.requestExport = requestExport
        self.search = search
    }
}
