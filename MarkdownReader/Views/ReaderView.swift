@preconcurrency import AppKit
import SwiftUI

struct ReaderView: View {
    private enum DisplayMode: String, CaseIterable, Identifiable {
        case preview
        case source

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @EnvironmentObject private var preferences: ReaderPreferences
    @StateObject private var model: ReaderViewModel
    @StateObject private var webController = ReaderWebController()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var displayMode: DisplayMode = .preview
    @State private var showFindBar = false
    @State private var showReaderOptions = false
    @State private var findQuery = ""

    init(document: MarkdownDocument, fileURL: URL?) {
        _model = StateObject(wrappedValue: ReaderViewModel(source: document.source, fileURL: fileURL))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            OutlineSidebar(entries: model.rendered.outline, selection: $model.selectedHeadingID)
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

                Group {
                    switch displayMode {
                    case .preview:
                        MarkdownWebView(
                            rendered: model.rendered,
                            documentURL: model.fileURL,
                            title: fileName,
                            style: preferences.renderStyle,
                            restorePosition: preferences.restorePosition,
                            controller: webController
                        )
                    case .source:
                        SourceView(source: model.source)
                    }
                }
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
            }
        }
        .navigationTitle(fileName)
        .toolbar { toolbar }
        .onAppear {
            model.startMonitoring(enabled: preferences.automaticRefresh)
            if !model.isRendering, model.rendered.outline.isEmpty {
                columnVisibility = .detailOnly
            }
        }
        .onDisappear {
            webController.saveReadingPosition(for: model.fileURL, enabled: preferences.restorePosition)
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
        .onChange(of: model.rendered.outline.isEmpty) { _, isEmpty in
            if isEmpty {
                columnVisibility = .detailOnly
            }
        }
        .onChange(of: model.isRendering) { _, isRendering in
            if !isRendering, model.rendered.outline.isEmpty {
                columnVisibility = .detailOnly
            }
        }
        .focusedSceneValue(\.readerActions, readerActions)
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
            copyPath: copyPath
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
