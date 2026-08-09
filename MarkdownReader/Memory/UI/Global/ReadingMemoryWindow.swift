@preconcurrency import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReadingMemoryWindow: View {
    @EnvironmentObject private var library: ReadingMemoryLibrary
    @EnvironmentObject private var preferences: ReaderPreferences
    @Environment(\.undoManager) private var undoManager
    @StateObject private var model = ReadingMemoryWindowModel()
    @State private var pendingDeletionID: UUID?
    @State private var pendingForgetDocumentID: UUID?
    @State private var pendingRelinkProposal: DocumentRelinkProposal?
    @State private var isConfirmingRelink = false

    var body: some View {
        ZStack(alignment: .trailing) {
            ReadingMemoryView(
                facet: $model.facet,
                searchText: $model.searchText,
                searchScope: $model.searchScope,
                selectedMemoryID: $model.selectedMemoryID,
                selectedDocumentID: $model.selectedDocumentID,
                showsExportSheet: $model.showsExportSheet,
                exportConfiguration: $model.exportConfiguration,
                counts: model.counts,
                memories: model.memories,
                documents: model.documents,
                searchSummary: model.searchSummary,
                isLoading: model.isLoading,
                actions: actions,
                exportPreview: model.exportPreview,
                exportActions: exportActions
            )

            if model.editingMemoryID != nil {
                MemoryNoteEditorView(
                    memory: model.editingPresentation,
                    draft: $model.noteDraft,
                    isSaving: model.isLoading || model.isWorking,
                    onSave: saveNote,
                    onCancel: model.cancelEditingNote
                )
                .padding(.trailing, 18)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(4)
            }

            if let conflict = model.noteConflict {
                MemoryNoteConflictView(
                    latestNote: conflict.latestNoteText,
                    draft: model.noteDraft,
                    isWorking: model.isWorking,
                    onUseLatest: {
                        Task { await model.useLatestConflictedNote(library: library) }
                    },
                    onReplace: replaceConflictedNote,
                    onCancel: model.cancelNoteConflict
                )
                .padding(.trailing, 24)
                .zIndex(8)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = model.errorMessage ?? library.errorMessage {
                ReadingMemoryWindowErrorBanner(message: error, dismiss: model.dismissError)
            }
        }
        .task {
            model.refresh(library: library)
        }
        .onChange(of: library.isReady) { _, ready in
            if ready { model.refresh(library: library) }
        }
        .onChange(of: library.changeSequence) { _, _ in
            model.refresh(library: library)
        }
        .marginaliaAppearance(marginaliaAppearance)
        .confirmationDialog(
            "Delete this memory and its note?",
            isPresented: Binding(
                get: { pendingDeletionID != nil },
                set: { if !$0 { pendingDeletionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Memory", role: .destructive) {
                guard let memoryID = pendingDeletionID else { return }
                pendingDeletionID = nil
                performDeleteMemory(memoryID)
            }
            Button("Cancel", role: .cancel) { pendingDeletionID = nil }
        } message: {
            Text("The Markdown file will not change. You can undo this deletion during this app session.")
        }
        .confirmationDialog(
            "Restore this memory as a new item?",
            isPresented: Binding(
                get: { model.pendingRestoreDeletedAsNewProposal != nil },
                set: { if !$0 { model.cancelRestoreDeletedAsNew() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore as New") {
                Task { await model.confirmRestoreDeletedAsNew(library: library) }
            }
            Button("Cancel", role: .cancel) { model.cancelRestoreDeletedAsNew() }
        } message: {
            Text("Exact undo is no longer safe because Reading Memory changed. This creates a new local memory only after rechecking the registered Markdown file, revision, anchor, and overlap rules. The Markdown file will not change.")
        }
        .confirmationDialog(
            "Forget this document from Reading Memory?",
            isPresented: Binding(
                get: { pendingForgetDocumentID != nil },
                set: { if !$0 { pendingForgetDocumentID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget Document", role: .destructive) {
                guard let documentID = pendingForgetDocumentID else { return }
                pendingForgetDocumentID = nil
                forgetDocument(documentID)
            }
            Button("Cancel", role: .cancel) { pendingForgetDocumentID = nil }
        } message: {
            Text("Its reading position, favourite status, memories, notes, and anchor history will be removed. The Markdown file is untouched.")
        }
        .sheet(item: $pendingRelinkProposal) { proposal in
            DocumentRelinkConfirmationView(
                proposal: proposal,
                isConfirming: isConfirmingRelink,
                onConfirm: { confirmRelink(proposal) },
                onCancel: { cancelRelink(proposal) }
            )
            .marginaliaAppearance(marginaliaAppearance)
        }
        .onDeleteCommand {
            guard model.editingMemoryID == nil,
                  let memoryID = model.selectedMemoryID else { return }
            requestDeleteMemory(memoryID)
        }
    }

    private var actions: ReadingMemoryActions {
        ReadingMemoryActions(
            selectFacet: { model.selectFacet($0, library: library) },
            selectMemory: { model.selectedMemoryID = $0 },
            openMemory: openMemory,
            openDocument: openDocument,
            editNote: model.beginEditingNote,
            reviewLocation: reviewMemory,
            deleteMemory: requestDeleteMemory,
            toggleFavourite: toggleFavourite,
            forgetDocument: { pendingForgetDocumentID = $0 },
            openDocumentPicker: openDocumentPicker,
            requestExport: { model.prepareExport(model.exportConfiguration) },
            search: { model.search($0, library: library) }
        )
    }

    private var exportActions: ReadingMemoryExportActions {
        ReadingMemoryExportActions(
            requestPreview: model.prepareExport,
            save: saveExport,
            cancel: {}
        )
    }

    private func openMemory(_ memoryID: UUID) {
        guard let documentID = model.documentID(for: memoryID) else { return }
        library.requestNavigation(documentID: documentID, memoryID: memoryID)
        openDocument(documentID)
    }

    private func reviewMemory(_ memoryID: UUID) {
        guard let documentID = model.documentID(for: memoryID) else { return }
        model.selectedMemoryID = memoryID
        library.requestNavigation(
            documentID: documentID,
            memoryID: memoryID,
            entersRepair: true
        )
        openDocument(documentID)
    }

    private func openDocument(_ documentID: UUID) {
        guard let url = model.currentURL(for: documentID),
              FileManager.default.fileExists(atPath: url.path) else {
            locateDocument(documentID)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApplication.shared.presentError(error) }
        }
    }

    private func openDocumentPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdownDocument]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApplication.shared.presentError(error) }
                }
            }
        }
    }

    private func locateDocument(_ documentID: UUID) {
        let panel = NSOpenPanel()
        panel.message = "Choose the Markdown file that belongs to this Reading Memory record."
        panel.prompt = "Relink"
        panel.allowedContentTypes = [.markdownDocument]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let repository = try library.requireRepository()
                    let proposal = try await repository.stageDocumentRelink(
                        documentID: documentID,
                        to: url
                    )
                    pendingRelinkProposal = proposal
                } catch {
                    NSApplication.shared.presentError(error)
                }
            }
        }
    }

    private func confirmRelink(_ proposal: DocumentRelinkProposal) {
        guard !isConfirmingRelink else { return }
        isConfirmingRelink = true
        Task {
            defer { isConfirmingRelink = false }
            do {
                let repository = try library.requireRepository()
                _ = try await repository.confirmDocumentRelink(proposalID: proposal.id)
                pendingRelinkProposal = nil
                NSDocumentController.shared.openDocument(
                    withContentsOf: proposal.candidatePath,
                    display: true
                ) { _, _, error in
                    if let error { NSApplication.shared.presentError(error) }
                }
                model.refresh(library: library)
            } catch {
                NSApplication.shared.presentError(error)
            }
        }
    }

    private func cancelRelink(_ proposal: DocumentRelinkProposal) {
        guard !isConfirmingRelink else { return }
        pendingRelinkProposal = nil
        Task {
            guard let repository = try? library.requireRepository() else { return }
            await repository.cancelDocumentRelink(proposalID: proposal.id)
        }
    }

    private func saveNote() {
        Task {
            guard let undo = await model.saveNote(library: library) else { return }
            undoManager?.registerUndo(withTarget: model) { target in
                Task { await target.undoNote(undo, library: library) }
            }
            undoManager?.setActionName("Edit Memory Note")
        }
    }

    private func replaceConflictedNote() {
        Task {
            guard let undo = await model.replaceConflictedNote(library: library) else { return }
            undoManager?.registerUndo(withTarget: model) { target in
                Task { await target.undoNote(undo, library: library) }
            }
            undoManager?.setActionName("Replace Memory Note")
        }
    }

    private func requestDeleteMemory(_ memoryID: UUID) {
        if model.memoryHasNote(memoryID) {
            pendingDeletionID = memoryID
        } else {
            performDeleteMemory(memoryID)
        }
    }

    private func performDeleteMemory(_ memoryID: UUID) {
        Task {
            guard let undo = await model.deleteMemory(memoryID, library: library) else { return }
            undoManager?.registerUndo(withTarget: model) { target in
                Task { await target.restoreDeleted(undo, library: library) }
            }
            undoManager?.setActionName("Delete Memory")
        }
    }

    private func toggleFavourite(_ documentID: UUID) {
        Task {
            guard let undo = await model.toggleFavourite(documentID, library: library) else { return }
            undoManager?.registerUndo(withTarget: model) { target in
                Task { await target.undoFavourite(undo, library: library) }
            }
            undoManager?.setActionName("Favourite Document")
        }
    }

    private func forgetDocument(_ documentID: UUID) {
        Task {
            guard let undo = await model.forgetDocument(documentID, library: library) else { return }
            undoManager?.registerUndo(withTarget: model) { target in
                Task { await target.restoreForgotten(undo, library: library) }
            }
            undoManager?.setActionName("Forget Document")
        }
    }

    private func saveExport(_ data: Data, configuration: ReadingMemoryExportConfiguration) {
        let normalized = configuration.normalizedForExport
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = normalized.format == .json
            ? [.json]
            : [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Reading Memory.\(normalized.format.fileExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try model.validateExportDestination(destination)
            let prepared = try model.preparedArchive(
                matching: normalized,
                previewData: data
            )
            let repository = try library.requireRepository()
            Task {
                do {
                    try await repository.writeArchive(
                        prepared.payload,
                        representation: prepared.representation,
                        to: destination
                    )
                    model.showsExportSheet = false
                } catch {
                    NSApplication.shared.presentError(error)
                }
            }
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    private var marginaliaAppearance: MarginaliaAppearance {
        switch preferences.appearance {
        case .automatic: .automatic
        case .light: .light
        case .dark: .dark
        case .sepia: .sepia
        }
    }
}

private struct ReadingMemoryWindowErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
