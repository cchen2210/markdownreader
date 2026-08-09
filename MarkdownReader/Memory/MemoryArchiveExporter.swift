import Foundation

struct MemoryArchivePayload: Equatable, Sendable {
    let createdAt: Date
    let storeSequence: UInt64
    let markdown: Data
    let json: Data

    /// Returns the immutable bytes created by the snapshot transaction.
    /// Callers must not re-render between preview and save.
    func data(
        for representation: MemoryArchiveRepresentation,
        currentStoreSequence: UInt64
    ) throws -> Data {
        guard currentStoreSequence == storeSequence else {
            throw MemoryArchiveExportError.payloadInvalidated(
                payloadSequence: storeSequence,
                currentSequence: currentStoreSequence
            )
        }
        switch representation {
        case .markdown:
            return markdown
        case .json:
            return json
        }
    }

    func isCurrent(storeSequence currentStoreSequence: UInt64) -> Bool {
        storeSequence == currentStoreSequence
    }
}

enum MemoryArchiveRepresentation: String, Equatable, Sendable {
    case markdown
    case json
}

enum MemoryArchiveExportError: Error, Equatable, Sendable {
    case payloadInvalidated(payloadSequence: UInt64, currentSequence: UInt64)
}

extension MemoryArchiveExportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .payloadInvalidated:
            return "Reading Memory changed after this preview was prepared. Refresh the preview before saving."
        }
    }
}

struct MemoryArchiveMarkdownOptions: Equatable, Sendable {
    var includesNotes: Bool = true
    var includesRepairLabels: Bool = true
    var includesAnchorDetails: Bool = false
    var groupsByDocument: Bool = true
}

enum MemoryArchiveExporter {
    static let exportSchemaVersion = 1

    static func makePayload(
        snapshot: MemoryStoreSnapshot,
        storeSequence: UInt64,
        includeFileLocations: Bool,
        markdownOptions: MemoryArchiveMarkdownOptions = MemoryArchiveMarkdownOptions(),
        createdAt: Date = Date()
    ) throws -> MemoryArchivePayload {
        let documentsByID = try uniqueDocumentsByID(snapshot.documents)
        try validate(snapshot: snapshot, documentsByID: documentsByID)
        let locationsByDocument = Dictionary(
            grouping: snapshot.documentLocations.filter(\.isCurrent),
            by: \.documentID
        )
        let memoriesByDocument = Dictionary(grouping: snapshot.memories, by: { $0.memory.documentID })

        let orderedDocuments = snapshot.documents
            .filter { memoriesByDocument[$0.id]?.isEmpty == false || $0.isFavourite }
            .sorted {
                let comparison = $0.displayName.localizedStandardCompare($1.displayName)
                return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
            }

        let archiveDocuments = try orderedDocuments.map { document -> ArchiveDocument in
            let memories = (memoriesByDocument[document.id] ?? []).sorted {
                if $0.memory.createdAt == $1.memory.createdAt {
                    return $0.memory.id.uuidString < $1.memory.id.uuidString
                }
                return $0.memory.createdAt < $1.memory.createdAt
            }
            let currentLocation = includeFileLocations
                ? locationsByDocument[document.id]?.sorted(by: { $0.lastSeenAt > $1.lastSeenAt }).first?.url.path
                : nil
            return ArchiveDocument(
                id: document.id,
                displayName: document.displayName,
                lastConfirmedContentHash: document.lastConfirmedContentHash,
                availability: document.availability,
                isFavourite: document.isFavourite,
                currentLocation: currentLocation,
                memories: try memories.map(ArchiveMemory.init)
            )
        }

        let archive = Archive(
            exportSchemaVersion: exportSchemaVersion,
            selectorSchemaVersion: 1,
            projectionSchemaVersion: 1,
            createdAt: createdAt,
            documents: archiveDocuments
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(archive)
        let markdown = Data(renderMarkdown(documents: archiveDocuments, options: markdownOptions).utf8)
        return MemoryArchivePayload(
            createdAt: createdAt,
            storeSequence: storeSequence,
            markdown: markdown,
            json: json
        )
    }

    private static func renderMarkdown(
        documents: [ArchiveDocument],
        options: MemoryArchiveMarkdownOptions
    ) -> String {
        var lines = [
            "# Reading Memory",
            "",
            "This is a human-readable export. It is not an importable backup.",
            "",
        ]
        for document in documents {
            if options.groupsByDocument {
                lines.append("## \(document.displayName)")
            }
            var metadata: [String] = []
            if document.isFavourite { metadata.append("Favourite") }
            if document.availability == .unavailable { metadata.append("Original unavailable") }
            if !metadata.isEmpty {
                lines.append("*\(metadata.joined(separator: " · "))*")
            }
            lines.append("")
            for memory in document.memories {
                let heading = memory.anchor.headingPath.last?.title
                    ?? (memory.kind == .headingBookmark ? "Bookmark" : "Saved passage")
                lines.append("\(options.groupsByDocument ? "###" : "##") \(heading)")
                lines.append("")
                var labels: [String] = []
                if options.includesRepairLabels {
                    labels.append(label(for: memory.resolution.state))
                }
                labels.append(memory.kind == .headingBookmark ? "Bookmark" : "Passage")
                if !options.groupsByDocument {
                    labels.append("From \(document.displayName)")
                }
                lines.append("**\(labels.joined(separator: " · "))**")
                if let quote = memory.originalVisibleQuote, !quote.isEmpty {
                    lines.append("")
                    lines.append(contentsOf: quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" })
                }
                if options.includesNotes, let note = memory.noteText, !note.isEmpty {
                    lines.append("")
                    lines.append(note)
                }
                if options.includesAnchorDetails {
                    lines.append("")
                    lines.append("- Anchor ID: `\(memory.anchor.id.uuidString.lowercased())`")
                    lines.append("- Source revision: `\(memory.anchor.sourceRevisionHash)`")
                    lines.append("- Block: `\(memory.anchor.blockKind)` at ordinal \(memory.anchor.blockOrdinal)")
                    lines.append("- Resolution: \(label(for: memory.resolution.state)); checked \(iso8601(memory.resolution.lastCheckedAt))")
                }
                lines.append("")
                lines.append("Saved \(iso8601(memory.createdAt))")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func label(for state: MemoryResolutionState) -> String {
        switch state {
        case .resolved: "Resolved"
        case .ambiguous: "Choose location"
        case .needsReview: "Needs repair · proposed location"
        case .orphaned: "Needs repair · loose slip"
        }
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func uniqueDocumentsByID(
        _ documents: [DocumentRecord]
    ) throws -> [UUID: DocumentRecord] {
        var result: [UUID: DocumentRecord] = [:]
        for document in documents {
            guard result.updateValue(document, forKey: document.id) == nil else {
                throw MemoryStoreError.invalidRecord(
                    "The export snapshot contains a duplicate document identifier."
                )
            }
        }
        return result
    }

    private static func validate(
        snapshot: MemoryStoreSnapshot,
        documentsByID: [UUID: DocumentRecord]
    ) throws {
        var memoryIDs = Set<UUID>()
        for stored in snapshot.memories {
            let memory = stored.memory
            guard memoryIDs.insert(memory.id).inserted else {
                throw MemoryStoreError.invalidRecord(
                    "The export snapshot contains a duplicate memory identifier."
                )
            }
            guard documentsByID[memory.documentID] != nil else {
                throw MemoryStoreError.invalidRecord(
                    "A memory refers to a document that is not present in the export snapshot."
                )
            }
            guard let currentAnchorID = memory.currentAnchorID,
                  let currentAnchor = stored.anchors.first(where: { $0.id == currentAnchorID }) else {
                throw MemoryStoreError.invalidRecord(
                    "A memory does not have the confirmed anchor required for export."
                )
            }
            guard stored.anchors.allSatisfy({ $0.memoryID == memory.id }),
                  currentAnchor.memoryID == memory.id,
                  stored.resolution.memoryID == memory.id,
                  stored.resolution.anchorID == currentAnchor.id else {
                throw MemoryStoreError.invalidRecord(
                    "A memory's anchor or resolution belongs to a different record."
                )
            }
        }
    }
}

private struct Archive: Codable, Equatable {
    let exportSchemaVersion: Int
    let selectorSchemaVersion: Int
    let projectionSchemaVersion: Int
    let createdAt: Date
    let documents: [ArchiveDocument]
}

private struct ArchiveDocument: Codable, Equatable {
    let id: UUID
    let displayName: String
    let lastConfirmedContentHash: String?
    let availability: DocumentAvailability
    let isFavourite: Bool
    let currentLocation: String?
    let memories: [ArchiveMemory]
}

private struct ArchiveMemory: Codable, Equatable {
    let id: UUID
    let kind: ReadingMemoryKind
    let originalVisibleQuote: String?
    let canonicalMatchQuote: String?
    let noteText: String?
    let createdAt: Date
    let updatedAt: Date
    let recordVersion: Int64
    let anchor: ConfirmedAnchorRecord
    let resolution: CurrentResolutionRecord

    init(_ stored: StoredMemory) throws {
        guard let currentAnchorID = stored.memory.currentAnchorID,
              let currentAnchor = stored.anchors.first(where: { $0.id == currentAnchorID }) else {
            throw MemoryStoreError.invalidRecord(
                "A memory does not have the confirmed anchor required for export."
            )
        }
        id = stored.memory.id
        kind = stored.memory.kind
        originalVisibleQuote = stored.memory.originalVisibleQuote
        canonicalMatchQuote = stored.memory.canonicalMatchQuote
        noteText = stored.memory.noteText
        createdAt = stored.memory.createdAt
        updatedAt = stored.memory.updatedAt
        recordVersion = stored.memory.recordVersion
        anchor = currentAnchor
        resolution = stored.resolution
    }
}
