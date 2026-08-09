import CryptoKit
import Foundation

struct ReaderContentSnapshot: Sendable {
    let source: String
    let sourceData: Data
    let rendered: RenderedMarkdown

    var projection: DocumentProjection? { rendered.projection }
}

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var content: ReaderContentSnapshot
    @Published private(set) var fileURL: URL?
    @Published private(set) var updateNotice: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRendering: Bool

    private var presenter: FileRefreshPresenter?
    private var noticeTask: Task<Void, Never>?
    private var reloadDebounceTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?

    var source: String { content.source }
    var sourceData: Data { content.sourceData }
    var rendered: RenderedMarkdown { content.rendered }
    var coordinatedFilePresenter: FileRefreshPresenter? { presenter }

    init(source: String, sourceData: Data? = nil, fileURL: URL?) {
        let exactData = sourceData ?? Data(source.utf8)
        self.fileURL = fileURL
        content = ReaderContentSnapshot(
            source: source,
            sourceData: exactData,
            rendered: MarkdownRenderer.render(source: "", sourceData: Data(), documentURL: fileURL)
        )
        isRendering = true
        renderSource(source, sourceData: exactData, for: fileURL, notice: nil)
    }

    func startMonitoring(enabled: Bool) {
        guard enabled, presenter == nil, let fileURL else { return }

        let presenter = FileRefreshPresenter(
            url: fileURL,
            onChange: { [weak self] in
                Task { @MainActor in self?.scheduleReloadFromDisk() }
            },
            onMove: { [weak self] newURL in
                Task { @MainActor in self?.handleMove(to: newURL) }
            },
            onDelete: { [weak self] in
                Task { @MainActor in
                    self?.errorMessage = "The file moved or was deleted. Showing the last available preview."
                }
            }
        )
        self.presenter = presenter
        presenter.start()
    }

    func stopMonitoring() {
        presenter?.stop()
        presenter = nil
        reloadDebounceTask?.cancel()
        reloadDebounceTask = nil
    }

    func setMonitoring(enabled: Bool) {
        if enabled {
            startMonitoring(enabled: true)
        } else {
            stopMonitoring()
        }
    }

    func reloadFromDisk() {
        guard let fileURL else { return }
        let presenter = presenter
        renderTask?.cancel()
        isRendering = false
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            do {
                let load = Task.detached(priority: .userInitiated) {
                    let data = try Self.coordinatedData(at: fileURL, presenter: presenter)
                    let newSource = try MarkdownTextDecoder.decode(data)
                    let newRender = MarkdownRenderer.render(
                        source: newSource,
                        sourceData: data,
                        documentURL: fileURL
                    )
                    return (data, newSource, newRender)
                }
                let (newData, newSource, newRender) = try await load.value
                guard !Task.isCancelled,
                      let self,
                      self.fileURL == fileURL,
                      newData != self.sourceData else { return }
                self.content = ReaderContentSnapshot(
                    source: newSource,
                    sourceData: newData,
                    rendered: newRender
                )
                self.isRendering = false
                self.errorMessage = nil
                self.showNotice("Updated")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.fileURL == fileURL else { return }
                self.isRendering = false
                self.errorMessage = "Couldn’t refresh. Showing the last available preview."
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func coordinatedSourceMatches(revisionHash: String) async -> Bool {
        guard let fileURL else { return false }
        let presenter = presenter
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Self.coordinatedData(at: fileURL, presenter: presenter) else {
                return false
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return hash == revisionHash
        }.value
    }

    private func handleMove(to newURL: URL) {
        fileURL = newURL
        reloadTask?.cancel()
        renderSource(source, sourceData: sourceData, for: newURL, notice: "File moved")
    }

    private func scheduleReloadFromDisk() {
        reloadDebounceTask?.cancel()
        reloadDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.reloadDebounceTask = nil
            self?.reloadFromDisk()
        }
    }

    private func renderSource(_ source: String, sourceData: Data, for url: URL?, notice: String?) {
        renderTask?.cancel()
        isRendering = true
        renderTask = Task { [weak self] in
            let operation = Task.detached(priority: .userInitiated) {
                MarkdownRenderer.render(source: source, sourceData: sourceData, documentURL: url)
            }
            let newRender = await operation.value
            guard !Task.isCancelled,
                  let self,
                  self.source == source,
                  self.sourceData == sourceData,
                  self.fileURL == url else { return }
            self.content = ReaderContentSnapshot(
                source: source,
                sourceData: sourceData,
                rendered: newRender
            )
            self.isRendering = false
            if let notice {
                self.showNotice(notice)
            }
        }
    }

    nonisolated private static func coordinatedData(
        at url: URL,
        presenter: FileRefreshPresenter?
    ) throws -> Data {
        var coordinatorError: NSError?
        var result: Result<Data, Error>?
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL, options: .mappedIfSafe) }
        }
        if let coordinatorError { throw coordinatorError }
        return try result?.get() ?? { throw CocoaError(.fileReadUnknown) }()
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        updateNotice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.updateNotice = nil
        }
    }
}
