@preconcurrency import AppKit
import SwiftUI

struct ReaderView: View {
    private enum DisplayMode: String, CaseIterable, Identifiable {
        case preview
        case source

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    private enum SidebarMode: String, CaseIterable, Identifiable {
        case outline
        case memory

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @EnvironmentObject private var preferences: ReaderPreferences
    @EnvironmentObject private var memoryLibrary: ReadingMemoryLibrary
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @StateObject private var model: ReaderViewModel
    @StateObject private var webController = ReaderWebController()
    @StateObject private var memorySession = DocumentMemorySession()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var sidebarMode: SidebarMode = .outline
    @State private var displayMode: DisplayMode = .preview
    @State private var showFindBar = false
    @State private var showReaderOptions = false
    @State private var findQuery = ""
    @State private var memorySearchQuery = ""
    @State private var confirmsMemoryDeletion = false
    @State private var repairSession: MemoryRepairSession?
    @State private var measuredMemoryNoteHeights: [UUID: CGFloat] = [:]
    @State private var measuredLooseSlipHeight: CGFloat = 0

    init(document: MarkdownDocument, fileURL: URL?) {
        _model = StateObject(
            wrappedValue: ReaderViewModel(
                source: document.source,
                sourceData: document.sourceData,
                fileURL: fileURL
            )
        )
    }

    var body: some View {
        commandWindow
    }

    private var readerWindow: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if let errorMessage = model.errorMessage {
                    ErrorBanner(
                        message: errorMessage,
                        retry: model.reloadFromDisk,
                        dismiss: model.dismissError
                    )
                }

                if showFindBar {
                    FindBar(
                        query: $findQuery,
                        status: webController.findStatus,
                        findNext: { webController.find(findQuery) },
                        findPrevious: { webController.find(findQuery, backwards: true) },
                        close: { showFindBar = false }
                    )
                }

                readerSurface
                .overlay(alignment: .topTrailing) {
                    if let notice = model.updateNotice {
                        Text(notice)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(12)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    if model.isRendering {
                        ProgressView("Rendering…")
                            .padding(14)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                if let memoryError = memorySession.errorMessage {
                    MemoryErrorBanner(
                        message: memoryError,
                        dismiss: memorySession.dismissError
                    )
                }
            }
        }
        .navigationTitle(fileName)
        .toolbar { toolbar }
    }

    private var monitoredWindow: some View {
        readerWindow
        .onAppear {
            webController.onMemoryActivated = { memoryID in
                memorySession.selectedMemoryID = memoryID
                memorySession.showsMemorySurface = true
            }
            model.startMonitoring(enabled: preferences.automaticRefresh)
            if !model.isRendering, model.rendered.outline.isEmpty {
                columnVisibility = .detailOnly
            }
            synchronizeMemory()
        }
        .onDisappear {
            webController.onMemoryActivated = nil
            Task {
                await memorySession.saveReadingState(
                    selectedHeadingID: model.selectedHeadingID,
                    outline: model.rendered.outline,
                    enabled: preferences.restorePosition,
                    library: memoryLibrary
                )
            }
            model.stopMonitoring()
        }
        .onChange(of: preferences.automaticRefresh) { _, enabled in
            model.setMonitoring(enabled: enabled)
        }
        .onChange(of: model.selectedHeadingID) { _, headingID in
            guard let headingID else { return }
            if displayMode == .source {
                displayMode = .preview
                Task { @MainActor in
                    await Task.yield()
                    webController.scrollToHeading(headingID)
                }
            } else {
                webController.scrollToHeading(headingID)
            }
        }
        .onChange(of: findQuery) { _, query in
            webController.find(query)
        }
        .onChange(of: displayMode) { _, mode in
            if mode == .source {
                showFindBar = false
            }
        }
    }

    private var synchronizedWindow: some View {
        monitoredWindow
        .onChange(of: model.rendered.outline.isEmpty) { _, isEmpty in
            if isEmpty, sidebarMode == .outline {
                columnVisibility = .detailOnly
            }
        }
        .onChange(of: model.isRendering) { _, isRendering in
            if !isRendering, model.rendered.outline.isEmpty, sidebarMode == .outline {
                columnVisibility = .detailOnly
            }
        }
        .onChange(of: model.rendered.revision) { _, _ in
            synchronizeMemory()
        }
        .onChange(of: model.fileURL) { _, _ in
            synchronizeMemory()
        }
    }

    private var memoryObservedWindow: some View {
        synchronizedWindow
        .onChange(of: memoryLibrary.isReady) { _, ready in
            if ready { synchronizeMemory() }
        }
        .onChange(of: memoryLibrary.pendingNavigation?.token) { _, _ in
            navigateToPendingMemory()
        }
        .onChange(of: memoryLibrary.changeSequence) { _, _ in
            Task { await memorySession.refreshFromStore(library: memoryLibrary) }
        }
        .onChange(of: memorySession.document?.id) { _, _ in
            navigateToPendingMemory()
        }
        .onChange(of: memorySession.selectedMemoryID) { _, memoryID in
            guard memoryID != nil else { return }
            memorySession.showsMemorySurface = true
        }
    }

    private var commandWindow: some View {
        memoryObservedWindow
        .focusedSceneValue(\.readerActions, readerActions)
        .marginaliaAppearance(marginaliaAppearance)
        .confirmationDialog(
            "Delete this memory and its note?",
            isPresented: $confirmsMemoryDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Memory", role: .destructive, action: performDeleteSelectedMemory)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Markdown file will not change. You can undo this deletion during this app session.")
        }
        .confirmationDialog(
            "Restore this memory as a new item?",
            isPresented: Binding(
                get: { memorySession.pendingRestoreDeletedAsNewProposal != nil },
                set: { if !$0 { memorySession.cancelRestoreDeletedAsNew() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore as New") {
                Task {
                    await memorySession.confirmRestoreDeletedAsNew(
                        model: model,
                        library: memoryLibrary
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                memorySession.cancelRestoreDeletedAsNew()
            }
        } message: {
            Text("Exact undo is no longer safe because Reading Memory changed. This creates a new local memory only after rechecking this Markdown file, revision, anchor, and overlap rules. The Markdown file will not change.")
        }
        .sheet(item: pendingDocumentRelinkBinding) { proposal in
            DocumentRelinkConfirmationView(
                proposal: proposal,
                isConfirming: memorySession.isWorking,
                confirmLabel: "Keep Existing Memories",
                alternativeLabel: "Open as New Document",
                onConfirm: { confirmPendingDocumentRelink(asReplacement: false) },
                onAlternative: { confirmPendingDocumentRelink(asReplacement: true) },
                onCancel: cancelPendingDocumentRelink
            )
            .marginaliaAppearance(marginaliaAppearance)
        }
        .onDeleteCommand(perform: handleDeleteCommand)
    }

    private var pendingDocumentRelinkBinding: Binding<DocumentRelinkProposal?> {
        Binding(
            get: { memorySession.pendingDocumentRelinkProposal },
            set: { _ in }
        )
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $sidebarMode) {
                ForEach(SidebarMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            switch sidebarMode {
            case .outline:
                OutlineSidebar(entries: model.rendered.outline, selection: $model.selectedHeadingID)
            case .memory:
                CurrentDocumentMemorySidebar(
                    memories: memorySession.presentations,
                    selection: $memorySession.selectedMemoryID,
                    searchText: $memorySearchQuery,
                    onSelect: { _ in memorySession.showsMemorySurface = true }
                )
            }
        }
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private var readerSurface: some View {
        switch displayMode {
        case .preview:
            GeometryReader { proxy in
                let policy = MemoryLayoutPolicy.resolve(
                    availableWidth: proxy.size.width,
                    chosenTextMeasure: CGFloat(preferences.width.points),
                    showsMemorySurface: memorySession.showsMemorySurface
                )

                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        markdownPreview
                            .frame(width: policy.documentViewportWidth)

                        switch policy.mode {
                        case let .fullGutter(width):
                            memoryGutter(width: width, height: proxy.size.height, compact: false)
                        case let .rail(width):
                            memoryGutter(width: width, height: proxy.size.height, compact: true)
                        case .hidden, .overlayInspector:
                            Color.clear
                                .frame(width: 0, height: 0)
                                .onAppear { webController.setMemoryBottomInset(0) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                    if case let .overlayInspector(width) = policy.mode {
                        MemoryInspectorView(
                            memories: memorySession.presentations,
                            selection: $memorySession.selectedMemoryID,
                            width: min(width, max(220, proxy.size.width - 24)),
                            onClose: { memorySession.showsMemorySurface = false },
                            onSelect: { memorySession.selectedMemoryID = $0 },
                            onEditNote: memorySession.beginEditingNote,
                            onReviewLocation: beginRepair
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }

                    if memorySession.editingMemoryID != nil {
                        MemoryNoteEditorView(
                            memory: editingMemory,
                            draft: $memorySession.noteDraft,
                            width: min(
                                MemoryLayoutPolicy.inspectorWidth,
                                max(220, proxy.size.width - 24)
                            ),
                            isSaving: memorySession.isWorking,
                            onSave: saveMemoryNote,
                            onCancel: memorySession.cancelNoteEditing
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(5)
                    }

                    if let conflict = memorySession.noteConflict {
                        MemoryNoteConflictView(
                            latestNote: conflict.latestNoteText,
                            draft: memorySession.noteDraft,
                            isWorking: memorySession.isWorking,
                            onUseLatest: {
                                Task { await memorySession.useLatestConflictedNote(library: memoryLibrary) }
                            },
                            onReplace: replaceConflictedNote,
                            onCancel: memorySession.cancelNoteConflict
                        )
                        .padding(.trailing, 20)
                        .zIndex(10)
                    }

                    if let repairSession {
                        MemoryRepairView(
                            session: repairSession,
                            onCommit: { finishRepair($0, session: repairSession) },
                            onCancel: { self.repairSession = nil }
                        )
                        .padding(.trailing, 20)
                        .zIndex(12)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: memorySession.showsMemorySurface)
                .onChange(of: proxy.size) { _, _ in
                    webController.scheduleMemoryGeometryRefresh()
                }
            }
        case .source:
            SourceView(source: model.source)
                .onAppear { webController.setMemoryBottomInset(0) }
        }
    }

    private var markdownPreview: some View {
        MarkdownWebView(
            rendered: model.rendered,
            documentURL: model.fileURL,
            title: fileName,
            style: preferences.renderStyle,
            controller: webController
        )
    }

    private func memoryGutter(width: CGFloat, height: CGFloat, compact: Bool) -> some View {
        let metrics = webController.memoryDocumentGeometry
        let geometryScale = metrics.nativeScale(forViewportHeight: height)
        let placements = gutterPlacements(geometryScale: geometryScale)
        let unlocatedMemories = memorySession.presentations.filter(\.state.isLooseSlip)
        let baseDocumentHeight = max(height, CGFloat(metrics.baseDocumentHeight) * geometryScale)
        let packedBottom = placements.map {
            measuredHeight(for: $0.memory) + $0.noteY
        }.max() ?? 0
        let looseHeight = unlocatedMemories.isEmpty
            ? 0
            : max(measuredLooseSlipHeight, estimatedLooseSlipHeight(unlocatedMemories))
        let looseTop = unlocatedMemories.isEmpty
            ? 0
            : max(
                packedBottom + MemoryNotePacking.scrollReachabilityPadding,
                baseDocumentHeight - looseHeight - MemoryNotePacking.scrollReachabilityPadding
            )
        let contentBottom = max(packedBottom, looseTop + looseHeight)
        let bottomInset = MemoryNotePacking.requiredBottomInset(
            contentBottom: contentBottom,
            baseDocumentHeight: baseDocumentHeight
        )
        let canvasHeight = max(
            height,
            baseDocumentHeight + bottomInset,
            contentBottom + MemoryNotePacking.scrollReachabilityPadding
        )
        return MemoryGutterView(
            placements: placements,
            unlocatedMemories: unlocatedMemories,
            selection: $memorySession.selectedMemoryID,
            width: width,
            viewportHeight: height,
            canvasHeight: canvasHeight,
            scrollOffset: CGFloat(metrics.scrollY) * geometryScale,
            looseSlipTop: looseTop,
            compact: compact,
            onSelect: { memorySession.selectedMemoryID = $0 },
            onEditNote: memorySession.beginEditingNote,
            onReviewLocation: beginRepair,
            onMeasuredNoteHeights: recordMeasuredMemoryHeights,
            onMeasuredLooseSlipHeight: recordMeasuredLooseSlipHeight
        )
        .onAppear { webController.setMemoryBottomInset(bottomInset / geometryScale) }
        .onChange(of: bottomInset) { _, newValue in
            webController.setMemoryBottomInset(newValue / geometryScale)
        }
    }

    private func gutterPlacements(geometryScale: CGFloat) -> [MemoryGutterPlacement] {
        let presentations = Dictionary(uniqueKeysWithValues: memorySession.presentations.map { ($0.id, $0) })
        let geometryByMemoryID = webController.memoryGeometry
        let scrollOffset = webController.memoryDocumentGeometry.scrollY
        let inputs = memorySession.presentations.compactMap { memory -> MemoryNoteLayoutInput? in
            guard !memory.state.isLooseSlip,
                  let geometry = geometryByMemoryID[memory.id],
                  let rect = geometry.rects.min(by: { $0.y < $1.y }),
                  rect.y.isFinite,
                  scrollOffset.isFinite else { return nil }
            let documentY = CGFloat(rect.y + scrollOffset) * geometryScale
            return MemoryNoteLayoutInput(
                id: memory.id,
                desiredTop: max(8, documentY - 8),
                height: measuredHeight(for: memory)
            )
        }
        let packed = MemoryNotePacking.pack(inputs, minimumTop: 8)
        return packed.compactMap { layout in
            guard let memory = presentations[layout.id] else { return nil }
            return MemoryGutterPlacement(
                memory: memory,
                anchorY: layout.desiredTop + 8,
                noteY: layout.top
            )
        }
    }

    private func measuredHeight(for memory: MemoryPresentation) -> CGFloat {
        guard let measured = measuredMemoryNoteHeights[memory.id],
              measured.isFinite,
              measured > 0 else {
            return estimatedMemoryHeight(memory)
        }
        return measured
    }

    private func estimatedMemoryHeight(_ memory: MemoryPresentation) -> CGFloat {
        let characterCount = memory.note?.count ?? memory.passage?.count ?? memory.title.count
        let lines = min(8, max(1, Int(ceil(Double(characterCount) / 30.0))))
        return CGFloat(76 + lines * 20 + (memory.state.needsAttention ? 24 : 0))
    }

    private func estimatedLooseSlipHeight(_ memories: [MemoryPresentation]) -> CGFloat {
        guard !memories.isEmpty else { return 0 }
        let cards = memories.reduce(CGFloat(0)) { $0 + estimatedMemoryHeight($1) }
        let spacing = CGFloat(max(0, memories.count - 1)) * MemoryNotePacking.collisionSpacing
        return 44 + cards + spacing
    }

    private func recordMeasuredMemoryHeights(_ heights: [UUID: CGFloat]) {
        let validIDs = Set(memorySession.presentations.map(\.id))
        var next = measuredMemoryNoteHeights.filter { validIDs.contains($0.key) }
        for (id, height) in heights where validIDs.contains(id) && height.isFinite && height > 0 {
            next[id] = (height * 2).rounded() / 2
        }
        guard next != measuredMemoryNoteHeights else { return }
        measuredMemoryNoteHeights = next
    }

    private func recordMeasuredLooseSlipHeight(_ height: CGFloat) {
        let normalized = height.isFinite && height > 0 ? (height * 2).rounded() / 2 : 0
        guard normalized != measuredLooseSlipHeight else { return }
        measuredLooseSlipHeight = normalized
    }

    private var editingMemory: MemoryPresentation? {
        guard let id = memorySession.editingMemoryID else { return nil }
        return memorySession.presentations.first { $0.id == id }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                toggleOutline()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Outline")
            .accessibilityLabel("Toggle Outline")
        }

        ToolbarItem(placement: .principal) {
            Picker("View", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                memorySession.showsMemorySurface.toggle()
            } label: {
                if !memorySession.showsMemorySurface, memorySession.attentionCount > 0 {
                    Label(
                        "\(memorySession.attentionCount) need attention",
                        systemImage: "bookmark"
                    )
                } else {
                    Image(systemName: memorySession.showsMemorySurface ? "bookmark.fill" : "bookmark")
                }
            }
            .help(memorySession.showsMemorySurface ? "Hide Document Memory" : "Show Document Memory")
            .accessibilityLabel(memorySession.showsMemorySurface ? "Hide Document Memory" : "Show Document Memory")
            .disabled(displayMode == .source || !memoryLibrary.isReady)

            Button {
                toggleFavourite()
            } label: {
                Image(systemName: memorySession.document?.isFavourite == true ? "star.fill" : "star")
            }
            .help(memorySession.document?.isFavourite == true ? "Remove from Favourites" : "Add to Favourites")
            .accessibilityLabel(memorySession.document?.isFavourite == true ? "Remove from Favourites" : "Add to Favourites")
            .disabled(memorySession.document == nil)

            Button {
                showFindBar.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Find in Document")
            .accessibilityLabel("Find in Document")
            .disabled(displayMode == .source)

            Button {
                showReaderOptions.toggle()
            } label: {
                Image(systemName: "textformat.size")
            }
            .help("Reader Options")
            .accessibilityLabel("Reader Options")
            .popover(isPresented: $showReaderOptions, arrowEdge: .bottom) {
                ReaderOptionsView()
                    .environmentObject(preferences)
            }

            Menu {
                Button("Print…", action: webController.printDocument)
                    .disabled(displayMode == .source)
                Button("Export as PDF…") {
                    webController.exportPDF(suggestedName: fileName)
                }
                .disabled(displayMode == .source)
                Button("Export as HTML…") {
                    let html = HTMLDocumentBuilder.buildStandalone(
                        rendered: model.rendered,
                        title: fileName,
                        style: preferences.renderStyle
                    )
                    webController.exportHTML(html, suggestedName: fileName)
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Print and Export")
            .accessibilityLabel("Print and Export")

            Menu {
                Button("Remember Passage", action: { rememberPassage(withNote: false) })
                    .disabled(displayMode == .source || !memoryLibrary.isReady)
                Button("Remember Passage with Note", action: { rememberPassage(withNote: true) })
                    .disabled(displayMode == .source || !memoryLibrary.isReady)
                Button("Bookmark This Heading", action: bookmarkHeading)
                    .disabled(displayMode == .source || !memoryLibrary.isReady)
                Button("Open Reading Memory") {
                    openWindow(id: "reading-memory")
                }
                Divider()
                Button("Open in Editor…", action: openInEditor)
                Divider()
                Button("Reveal in Finder", action: revealInFinder)
                Button("Copy Path", action: copyPath)
                Button("Copy Markdown", action: copyMarkdown)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Document Actions")
            .accessibilityLabel("Document Actions")
        }
    }

    private var readerActions: ReaderActions {
        ReaderActions(
            canUsePreview: displayMode == .preview,
            showFind: { showFindBar = true },
            findNext: { webController.find(findQuery) },
            findPrevious: { webController.find(findQuery, backwards: true) },
            toggleOutline: toggleOutline,
            toggleSource: { displayMode = displayMode == .preview ? .source : .preview },
            previousHeading: { moveHeading(by: -1) },
            nextHeading: { moveHeading(by: 1) },
            zoomIn: webController.zoomIn,
            zoomOut: webController.zoomOut,
            resetZoom: webController.resetZoom,
            printDocument: webController.printDocument,
            openInEditor: openInEditor,
            copyPath: copyPath,
            rememberPassage: { rememberPassage(withNote: false) },
            rememberPassageWithNote: { rememberPassage(withNote: true) },
            bookmarkHeading: bookmarkHeading,
            toggleMemory: { memorySession.showsMemorySurface.toggle() },
            openReadingMemory: { openWindow(id: "reading-memory") },
            previousMemory: { memorySession.selectAdjacentMemory(offset: -1) },
            nextMemory: { memorySession.selectAdjacentMemory(offset: 1) },
            deleteMemory: deleteSelectedMemory
        )
    }

    private var fileName: String {
        model.fileURL?.lastPathComponent ?? "Markdown Document"
    }

    private func toggleOutline() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    private func moveHeading(by offset: Int) {
        let entries = model.rendered.outline
        guard !entries.isEmpty else { return }
        let currentIndex = model.selectedHeadingID.flatMap { id in entries.firstIndex { $0.id == id } }
        let startingIndex = currentIndex ?? (offset > 0 ? -1 : entries.count)
        let nextIndex = min(max(startingIndex + offset, 0), entries.count - 1)
        model.selectedHeadingID = entries[nextIndex].id
    }

    private func openInEditor() {
        guard let fileURL = model.fileURL else { return }
        ExternalEditor.open(fileURL: fileURL, preferences: preferences)
    }

    private func revealInFinder() {
        guard let fileURL = model.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func copyPath() {
        guard let path = model.fileURL?.path else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.source, forType: .string)
    }

    private func synchronizeMemory() {
        guard memoryLibrary.isReady, !model.isRendering else { return }
        Task {
            await memorySession.synchronize(
                library: memoryLibrary,
                content: model.content,
                fileURL: model.fileURL,
                webController: webController,
                restorePosition: preferences.restorePosition
            )
            navigateToPendingMemory()
        }
    }

    private func confirmPendingDocumentRelink(asReplacement: Bool) {
        Task {
            guard await memorySession.confirmPendingDocumentRelink(
                asReplacement: asReplacement,
                library: memoryLibrary
            ) else { return }
            synchronizeMemory()
        }
    }

    private func cancelPendingDocumentRelink() {
        Task {
            await memorySession.cancelPendingDocumentRelink(library: memoryLibrary)
        }
    }

    private func navigateToPendingMemory() {
        guard let pending = memoryLibrary.pendingNavigation,
              pending.documentID == memorySession.document?.id else { return }
        if let memoryID = pending.memoryID {
            memorySession.selectedMemoryID = memoryID
            memorySession.showsMemorySurface = true
            Task { @MainActor in
                await Task.yield()
                webController.scrollToMemory(memoryID)
            }
            if pending.entersRepair {
                Task { @MainActor in
                    await Task.yield()
                    beginRepair(memoryID)
                }
            }
        } else {
            memorySession.restoreReadingPosition()
        }
        memoryLibrary.consumeNavigation(token: pending.token)
    }

    private func rememberPassage(withNote: Bool) {
        guard displayMode == .preview else { return }
        Task {
            guard let payload = await memorySession.rememberPassage(
                withNote: withNote,
                model: model,
                library: memoryLibrary
            ) else { return }
            registerCreateUndo(payload, actionName: "Remember Passage")
        }
    }

    private func bookmarkHeading() {
        Task {
            guard let payload = await memorySession.bookmarkHeading(
                model: model,
                library: memoryLibrary
            ) else { return }
            registerCreateUndo(payload, actionName: "Bookmark Heading")
        }
    }

    private func saveMemoryNote() {
        Task {
            guard let payload = await memorySession.commitNote(library: memoryLibrary) else { return }
            undoManager?.registerUndo(withTarget: memorySession) { target in
                Task { await target.undoNote(payload, library: memoryLibrary) }
            }
            undoManager?.setActionName("Edit Memory Note")
        }
    }

    private func replaceConflictedNote() {
        Task {
            guard let payload = await memorySession.replaceConflictedNote(library: memoryLibrary) else { return }
            undoManager?.registerUndo(withTarget: memorySession) { target in
                Task { await target.undoNote(payload, library: memoryLibrary) }
            }
            undoManager?.setActionName("Replace Memory Note")
        }
    }

    private func deleteSelectedMemory() {
        guard let selected = memorySession.selectedMemoryID.flatMap({ id in
            memorySession.presentations.first { $0.id == id }
        }) else { return }
        if selected.hasNote {
            confirmsMemoryDeletion = true
        } else {
            performDeleteSelectedMemory()
        }
    }

    private func handleDeleteCommand() {
        guard memorySession.editingMemoryID == nil, repairSession == nil else { return }
        deleteSelectedMemory()
    }

    private func performDeleteSelectedMemory() {
        Task {
            guard let payload = await memorySession.deleteSelected(library: memoryLibrary) else { return }
            undoManager?.registerUndo(withTarget: memorySession) { target in
                Task {
                    await target.undoDelete(
                        payload,
                        model: model,
                        library: memoryLibrary
                    )
                }
            }
            undoManager?.setActionName("Delete Memory")
        }
    }

    private func toggleFavourite() {
        Task {
            guard let payload = await memorySession.toggleFavourite(library: memoryLibrary) else { return }
            undoManager?.registerUndo(withTarget: memorySession) { target in
                Task { await target.undoFavourite(payload, library: memoryLibrary) }
            }
            undoManager?.setActionName("Favourite Document")
        }
    }

    private func registerCreateUndo(_ payload: CreateMemoryUndoPayload, actionName: String) {
        undoManager?.registerUndo(withTarget: memorySession) { target in
            Task { await target.undoCreate(payload, library: memoryLibrary) }
        }
        undoManager?.setActionName(actionName)
    }

    private func beginRepair(_ memoryID: UUID) {
        memorySession.selectedMemoryID = memoryID
        memorySession.showsMemorySurface = true
        guard let stored = memorySession.memories.first(where: { $0.memory.id == memoryID }),
              let document = memorySession.document,
              let projection = model.content.projection else {
            memorySession.report("Open the original document before repairing this memory.")
            return
        }
        do {
            displayMode = .preview
            repairSession = try MemoryRepairSession(
                storedMemory: stored,
                document: document,
                documentMemories: memorySession.memories,
                projection: projection,
                webController: webController,
                model: model,
                library: memoryLibrary
            )
        } catch {
            memorySession.report(
                (error as? LocalizedError)?.errorDescription
                    ?? "This memory could not enter repair mode."
            )
        }
    }

    private func finishRepair(_ commit: MemoryRepairCommit, session: MemoryRepairSession) {
        repairSession = nil
        memorySession.selectedMemoryID = commit.storedMemory.memory.id
        undoManager?.registerUndo(withTarget: session) { target in
            Task {
                guard await target.undo(commit.undo) != nil else { return }
                await memorySession.refreshFromStore(library: memoryLibrary)
            }
        }
        undoManager?.setActionName("Reattach Memory")
        Task { await memorySession.refreshFromStore(library: memoryLibrary) }
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

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(2)
            Spacer()
            Button("Retry", action: retry)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct MemoryErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark.slash")
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(3)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
