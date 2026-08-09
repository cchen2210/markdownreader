@preconcurrency import AppKit
import Foundation
import WebKit

@MainActor
final class ReaderWebController: ObservableObject {
    weak var webView: WKWebView?
    @Published private(set) var findStatus: FindStatus = .idle

    enum FindStatus: Equatable {
        case idle
        case found
        case notFound
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func scrollToHeading(_ headingID: String) {
        guard let webView, let argument = javaScriptString(headingID) else { return }
        webView.evaluateJavaScript("document.getElementById(\(argument))?.scrollIntoView({block:'start'})")
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
    }

    func zoomOut() {
        guard let webView else { return }
        webView.pageZoom = max(0.6, webView.pageZoom - 0.1)
    }

    func resetZoom() {
        webView?.pageZoom = 1
    }

    func saveReadingPosition(for documentURL: URL?, enabled: Bool) {
        guard enabled, let documentURL, let webView else { return }
        webView.evaluateJavaScript(ReadingPositionStore.scrollFractionJavaScript) { result, _ in
            guard let fraction = result as? Double else { return }
            ReadingPositionStore.set(fraction, for: documentURL)
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

    private func javaScriptString(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2 else { return nil }
        return String(array.dropFirst().dropLast())
    }

    private func presentError(_ error: Error) {
        NSApplication.shared.presentError(error)
    }
}

private extension String {
    func replacingPathExtension(with newExtension: String) -> String {
        let base = (self as NSString).deletingPathExtension
        return "\(base).\(newExtension)"
    }
}
