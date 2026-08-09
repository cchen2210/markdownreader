@preconcurrency import AppKit
import Foundation
import WebKit

@MainActor
final class ReaderWebController: NSObject, ObservableObject {
    weak var webView: WKWebView?
    var onMemoryActivated: ((UUID) -> Void)?
    @Published private(set) var findStatus: FindStatus = .idle
    @Published private(set) var memoryGeometry: [UUID: WebMarkGeometry] = [:]
    @Published private(set) var memoryDocumentGeometry: WebDocumentGeometry = .empty

    private var memoryMarks: [MemoryRenderMark] = []
    private var memoryContext: MemoryRenderContext?
    private var pendingReadingRestore: ReadingRestoreTarget?
    private var scrollObserver: NSObjectProtocol?
    private weak var clickRecognizer: NSClickGestureRecognizer?
    private var geometryTask: Task<Void, Never>?
    private var geometryGeneration = 0
    private var markGeneration = 0
    private var bottomInsetTask: Task<Void, Never>?
    private var bottomInsetGeneration = 0
    private var requestedMemoryBottomInset = 0.0

    enum FindStatus: Equatable {
        case idle
        case found
        case notFound
    }

    override init() {
        super.init()
    }

    func attach(_ webView: WKWebView) {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        geometryTask?.cancel()
        bottomInsetTask?.cancel()
        if let clickRecognizer, let priorView = clickRecognizer.view {
            priorView.removeGestureRecognizer(clickRecognizer)
        }
        self.webView = webView
        memoryDocumentGeometry = .empty
        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleReaderClick(_:)))
        clickRecognizer.buttonMask = 0x1
        webView.addGestureRecognizer(clickRecognizer)
        self.clickRecognizer = clickRecognizer
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleMemoryGeometryRefresh() }
        }
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    @objc private func handleReaderClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended,
              let webView,
              let context = memoryContext else { return }
        let generation = markGeneration
        let memoryByToken = Dictionary(uniqueKeysWithValues: memoryMarks.map { ($0.token, $0.memoryID) })
        let point = recognizer.location(in: webView)
        let clientY = webView.isFlipped ? point.y : webView.bounds.height - point.y
        Task { @MainActor in
            do {
                let result = try await webView.callAsyncJavaScript(
                    MemoryWebBridge.hitTestJavaScript,
                    arguments: [
                        "expectedRenderRevision": context.renderRevision.uuidString.lowercased(),
                        "x": point.x,
                        "y": clientY,
                    ],
                    in: nil,
                    contentWorld: MemoryWebBridge.contentWorld
                )
                guard generation == markGeneration,
                      memoryContext == context,
                      let token = result as? String,
                      let memoryID = memoryByToken[token] else { return }
                onMemoryActivated?(memoryID)
            } catch {
                return
            }
        }
    }

    func captureMemorySelection() async throws -> DOMProjectionSelection {
        guard let webView else { throw MemoryWebBridgeError.readerUnavailable }
        let result = try await webView.callAsyncJavaScript(
            MemoryWebBridge.selectionJavaScript,
            arguments: [
                "maxCharacters": MemoryWebBridge.maximumSelectionCharacters,
                "maxRuns": MemoryWebBridge.maximumSelectionRuns,
            ],
            in: nil,
            contentWorld: MemoryWebBridge.contentWorld
        )
        guard !(result is NSNull), let result else {
            throw MemoryWebBridgeError.unsupportedSelection
        }
        return try Self.decode(DOMProjectionSelection.self, from: result)
    }

    func headingBookmarkTarget() async throws -> DOMProjectionBlockTarget {
        guard let webView else { throw MemoryWebBridgeError.readerUnavailable }
        let result = try await webView.callAsyncJavaScript(
            MemoryWebBridge.headingTargetJavaScript,
            arguments: [:],
            in: nil,
            contentWorld: MemoryWebBridge.contentWorld
        )
        guard !(result is NSNull), let result else {
            throw MemoryWebBridgeError.unsupportedSelection
        }
        return try Self.decode(DOMProjectionBlockTarget.self, from: result)
    }

    func currentReadingPosition() async throws -> DOMProjectionReadingPosition {
        guard let webView else { throw MemoryWebBridgeError.readerUnavailable }
        let result = try await webView.callAsyncJavaScript(
            MemoryWebBridge.readingPositionJavaScript,
            arguments: [:],
            in: nil,
            contentWorld: MemoryWebBridge.contentWorld
        )
        guard !(result is NSNull), let result else {
            throw MemoryWebBridgeError.invalidResponse
        }
        return try Self.decode(DOMProjectionReadingPosition.self, from: result)
    }

    func setMemoryMarks(_ marks: [MemoryRenderMark], context: MemoryRenderContext) {
        memoryMarks = marks.map { mark in
            MemoryRenderMark(
                memoryID: mark.memoryID,
                token: "mark-\(UUID().uuidString.lowercased())",
                kind: mark.kind,
                selector: mark.selector,
                accessibilityLabel: mark.accessibilityLabel
            )
        }
        memoryContext = context
        scheduleMemoryMarkApplication()
    }

    func clearMemoryMarks() {
        requestedMemoryBottomInset = 0
        if let context = memoryContext {
            scheduleMemoryBottomInset(context: context, force: true)
        }
        markGeneration &+= 1
        memoryMarks = []
        memoryContext = nil
        memoryGeometry = [:]
        memoryDocumentGeometry = .empty
    }

    func didFinishDocumentLoad() {
        Task { @MainActor in
            await reapplyMemoryMarks()
            await applyPendingReadingRestore()
            try? await Task.sleep(for: .milliseconds(120))
            scheduleMemoryGeometryRefresh()
            try? await Task.sleep(for: .milliseconds(380))
            scheduleMemoryGeometryRefresh()
        }
    }

    func requestReadingRestore(
        blockID: String?,
        point: DOMProjectionPoint?,
        fallbackFraction: Double,
        context: MemoryRenderContext
    ) {
        pendingReadingRestore = ReadingRestoreTarget(
            blockID: blockID,
            point: point,
            fallbackFraction: min(max(fallbackFraction, 0), 1),
            context: context
        )
        Task { @MainActor in await applyPendingReadingRestore() }
    }

    func scheduleMemoryGeometryRefresh() {
        geometryGeneration &+= 1
        let generation = geometryGeneration
        geometryTask?.cancel()
        geometryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            await self?.refreshMemoryGeometry(generation: generation)
        }
    }

    /// Requests only the additional document height needed by the native
    /// Marginalia canvas. Repeated values are coalesced, while a newly loaded
    /// render is repaired automatically when its reported inset is still zero.
    func setMemoryBottomInset(_ points: CGFloat) {
        let rawValue = Double(points)
        let normalized = rawValue.isFinite ? min(max(0, rawValue), 1_000_000) : 0
        guard abs(normalized - requestedMemoryBottomInset) > 0.5 else {
            if abs(memoryDocumentGeometry.bottomInset - normalized) > 0.5 {
                scheduleMemoryBottomInset(force: true)
            }
            return
        }
        requestedMemoryBottomInset = normalized
        scheduleMemoryBottomInset(force: true)
    }

    private func refreshMemoryGeometry(generation: Int) async {
        guard let webView, let context = memoryContext else {
            memoryGeometry = [:]
            return
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                MemoryWebBridge.geometryProgram,
                arguments: Self.contextArguments(context),
                in: nil,
                contentWorld: MemoryWebBridge.contentWorld
            )
            guard !(result is NSNull), let result else { return }
            let response = try Self.decode(WebMarkGeometryResponse.self, from: result)
            guard generation == geometryGeneration, Self.matches(response, context: context) else { return }
            publishMemoryGeometry(response, marks: memoryMarks, context: context)
        } catch {
            guard generation == geometryGeneration else { return }
            memoryGeometry = [:]
        }
    }

    private func scheduleMemoryBottomInset(
        context contextOverride: MemoryRenderContext? = nil,
        force: Bool = false
    ) {
        guard let context = contextOverride ?? memoryContext else { return }
        if !force,
           memoryContext == context,
           abs(memoryDocumentGeometry.bottomInset - requestedMemoryBottomInset) <= 0.5 {
            return
        }

        bottomInsetGeneration &+= 1
        let generation = bottomInsetGeneration
        let inset = requestedMemoryBottomInset
        bottomInsetTask?.cancel()
        bottomInsetTask = Task { [weak self] in
            guard let self else { return }
            await self.applyMemoryBottomInset(inset, context: context, generation: generation)
        }
    }

    private func applyMemoryBottomInset(
        _ inset: Double,
        context: MemoryRenderContext,
        generation: Int
    ) async {
        guard let webView else { return }
        var arguments = Self.contextArguments(context)
        arguments["bottomInset"] = inset
        do {
            let result = try await webView.callAsyncJavaScript(
                MemoryWebBridge.bottomInsetProgram,
                arguments: arguments,
                in: nil,
                contentWorld: MemoryWebBridge.contentWorld
            )
            guard !(result is NSNull), let result else { return }
            let response = try Self.decode(WebMarkGeometryResponse.self, from: result)
            guard generation == bottomInsetGeneration else {
                scheduleMemoryBottomInset(force: true)
                return
            }
            guard Self.matches(response, context: context) else { return }
            if memoryContext == context {
                publishMemoryGeometry(response, marks: memoryMarks, context: context)
            }
        } catch {
            guard generation != bottomInsetGeneration else { return }
            scheduleMemoryBottomInset(force: true)
        }
    }

    private func publishMemoryGeometry(
        _ response: WebMarkGeometryResponse,
        marks: [MemoryRenderMark],
        context: MemoryRenderContext
    ) {
        let memoryByToken = Dictionary(uniqueKeysWithValues: marks.map { ($0.token, $0.memoryID) })
        memoryDocumentGeometry = response.documentGeometry
        memoryGeometry = Dictionary(
            uniqueKeysWithValues: response.marks.compactMap { row in
                memoryByToken[row.token].map { ($0, row) }
            }
        )
        if memoryContext == context,
           abs(response.bottomInset - requestedMemoryBottomInset) > 0.5 {
            scheduleMemoryBottomInset(force: true)
        }
    }

    func scrollToHeading(_ headingID: String) {
        guard let webView else { return }
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                "document.getElementById(headingID)?.scrollIntoView({block:'start'}); return true;",
                arguments: ["headingID": headingID],
                in: nil,
                contentWorld: MemoryWebBridge.contentWorld
            )
        }
    }

    func scrollToMemory(_ memoryID: UUID) {
        guard let webView,
              let token = memoryMarks.first(where: { $0.memoryID == memoryID })?.token else { return }
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                """
                const mark = document.querySelector('mark.memory-mark[data-memory-token="' + CSS.escape(token) + '"]');
                const heading = Array.from(document.querySelectorAll('[data-memory-block-tokens]')).find(block => {
                  try { return JSON.parse(block.dataset.memoryBlockTokens || '[]').includes(token); }
                  catch (_) { return false; }
                });
                const target = mark || heading;
                target?.scrollIntoView({ block: 'center' });
                mark?.focus({ preventScroll: true });
                return Boolean(target);
                """,
                arguments: ["token": token],
                in: nil,
                contentWorld: MemoryWebBridge.contentWorld
            )
            scheduleMemoryGeometryRefresh()
        }
    }

    func find(_ query: String, backwards: Bool = false) {
        guard let webView else { return }
        guard !query.isEmpty else {
            findStatus = .idle
            return
        }

        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(query, configuration: configuration) { [weak self] result in
            self?.findStatus = result.matchFound ? .found : .notFound
        }
    }

    func zoomIn() {
        guard let webView else { return }
        webView.pageZoom = min(2.0, webView.pageZoom + 0.1)
        scheduleMemoryGeometryRefresh()
    }

    func zoomOut() {
        guard let webView else { return }
        webView.pageZoom = max(0.6, webView.pageZoom - 0.1)
        scheduleMemoryGeometryRefresh()
    }

    func resetZoom() {
        webView?.pageZoom = 1
        scheduleMemoryGeometryRefresh()
    }

    func readingPositionFraction() async -> Double? {
        guard let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return Math.max(0, window.scrollY) / Math.max(1, document.documentElement.scrollHeight - window.innerHeight);",
                arguments: [:],
                in: nil,
                contentWorld: MemoryWebBridge.contentWorld
            )
            if let value = result as? Double { return min(max(value, 0), 1) }
            if let number = result as? NSNumber { return min(max(number.doubleValue, 0), 1) }
            return nil
        } catch {
            return nil
        }
    }

    func printDocument() {
        guard let webView,
              let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        let operation = webView.printOperation(with: printInfo)
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    func exportPDF(suggestedName: String) {
        guard let webView else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName.replacingPathExtension(with: "pdf")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task { @MainActor in
            do {
                let data = try await webView.pdf()
                try data.write(to: destination, options: .atomic)
            } catch {
                presentError(error)
            }
        }
    }

    func exportHTML(_ html: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName.replacingPathExtension(with: "html")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(html.utf8).write(to: destination, options: .atomic)
        } catch {
            presentError(error)
        }
    }

    private func scheduleMemoryMarkApplication() {
        guard let context = memoryContext else { return }
        markGeneration &+= 1
        let generation = markGeneration
        let marks = memoryMarks
        Task { @MainActor in
            await applyMemoryMarks(marks: marks, context: context, generation: generation)
        }
    }

    private func reapplyMemoryMarks() async {
        guard let context = memoryContext else { return }
        markGeneration &+= 1
        let generation = markGeneration
        await applyMemoryMarks(marks: memoryMarks, context: context, generation: generation)
    }

    private func applyMemoryMarks(
        marks: [MemoryRenderMark],
        context: MemoryRenderContext,
        generation: Int
    ) async {
        guard let webView else { return }
        let rows: [[String: Any]] = marks.map { mark in
            [
                "token": mark.token,
                "kind": mark.kind.rawValue,
                "blockID": mark.selector.blockID,
                "accessibilityLabel": mark.accessibilityLabel,
                "fragments": mark.selector.runFragments.map { fragment in
                    [
                        "runID": fragment.runID,
                        "lower": fragment.domUTF16RangeInRun.lowerBound,
                        "upper": fragment.domUTF16RangeInRun.upperBound,
                    ]
                },
            ]
        }
        var arguments = Self.contextArguments(context)
        arguments["marks"] = rows
        do {
            let result = try await webView.callAsyncJavaScript(
                MemoryWebBridge.markProgram,
                arguments: arguments,
                in: nil,
                contentWorld: MemoryWebBridge.contentWorld
            )
            guard !(result is NSNull), let result else { return }
            let response = try Self.decode(WebMarkGeometryResponse.self, from: result)
            guard generation == markGeneration,
                  memoryContext == context,
                  memoryMarks == marks,
                  Self.matches(response, context: context) else {
                scheduleMemoryMarkApplication()
                return
            }
            publishMemoryGeometry(response, marks: marks, context: context)
        } catch {
            guard generation == markGeneration else { return }
            memoryGeometry = [:]
        }
    }

    private func applyPendingReadingRestore() async {
        guard let webView, let target = pendingReadingRestore else { return }
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                const root = document.getElementById('reader');
                if (!root || root.dataset.sourceRevision !== expectedSourceRevision ||
                    root.dataset.renderRevision !== expectedRenderRevision ||
                    Number(root.dataset.projectionVersion || 0) !== expectedProjectionVersion) return false;
                const block = blockID ? root.querySelector('[data-memory-block="' + CSS.escape(blockID) + '"]') : null;
                const run = point && point.runID
                  ? root.querySelector('[data-memory-run="' + CSS.escape(point.runID) + '"]') : null;
                let restoredExactPoint = false;
                if (block && run && block.contains(run) && Number.isInteger(point.utf16Offset) && point.utf16Offset >= 0) {
                  const walker = document.createTreeWalker(run, NodeFilter.SHOW_TEXT);
                  let remaining = point.utf16Offset;
                  let node = walker.nextNode();
                  while (node && remaining > (node.nodeValue?.length || 0)) {
                    remaining -= node.nodeValue?.length || 0;
                    node = walker.nextNode();
                  }
                  if (node && remaining <= (node.nodeValue?.length || 0)) {
                    const range = document.createRange();
                    try {
                      range.setStart(node, remaining);
                      range.collapse(true);
                      const rect = range.getBoundingClientRect();
                      if (Number.isFinite(rect.top)) {
                        window.scrollTo(0, Math.max(0, window.scrollY + rect.top));
                        restoredExactPoint = true;
                      }
                    } catch (_) {}
                  }
                }
                if (!restoredExactPoint && block) {
                  block.scrollIntoView({ block: 'start' });
                } else if (!restoredExactPoint) {
                  const maximum = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
                  window.scrollTo(0, maximum * fallbackFraction);
                }
                return true;
                """,
                arguments: [
                    "expectedSourceRevision": target.context.sourceRevisionHash,
                    "expectedProjectionVersion": target.context.projectionVersion,
                    "expectedRenderRevision": target.context.renderRevision.uuidString.lowercased(),
                    "blockID": target.blockID ?? "",
                    "point": target.point.map {
                        ["runID": $0.runID, "utf16Offset": $0.utf16Offset]
                    } ?? NSNull(),
                    "fallbackFraction": target.fallbackFraction,
                ],
                in: nil,
                contentWorld: MemoryWebBridge.contentWorld
            )
            guard (result as? Bool) == true,
                  pendingReadingRestore == target else { return }
            pendingReadingRestore = nil
            scheduleMemoryGeometryRefresh()
        } catch {
            return
        }
    }

    private static func contextArguments(_ context: MemoryRenderContext) -> [String: Any] {
        [
            "expectedSourceRevision": context.sourceRevisionHash,
            "expectedProjectionVersion": context.projectionVersion,
            "expectedRenderRevision": context.renderRevision.uuidString.lowercased(),
        ]
    }

    private static func matches(_ response: WebMarkGeometryResponse, context: MemoryRenderContext) -> Bool {
        response.sourceRevisionHash == context.sourceRevisionHash
            && response.projectionVersion == context.projectionVersion
            && response.renderRevision == context.renderRevision
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from object: Any?) throws -> Value {
        guard let object else { throw MemoryWebBridgeError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }

    private func presentError(_ error: Error) {
        NSApplication.shared.presentError(error)
    }
}

private struct ReadingRestoreTarget: Equatable {
    let blockID: String?
    let point: DOMProjectionPoint?
    let fallbackFraction: Double
    let context: MemoryRenderContext
}

enum MemoryWebBridgeError: LocalizedError {
    case readerUnavailable
    case unsupportedSelection
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .readerUnavailable:
            "The rendered document is not available."
        case .unsupportedSelection:
            "Select text inside one paragraph, heading, code block, or table cell, then try again."
        case .invalidResponse:
            "The document selection could not be mapped safely."
        }
    }
}

private extension String {
    func replacingPathExtension(with newExtension: String) -> String {
        let base = (self as NSString).deletingPathExtension
        return "\(base).\(newExtension)"
    }
}
