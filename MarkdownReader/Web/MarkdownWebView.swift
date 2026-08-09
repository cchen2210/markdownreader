@preconcurrency import AppKit
import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let rendered: RenderedMarkdown
    let documentURL: URL?
    let title: String
    let style: RenderStyle
    let restorePosition: Bool
    @ObservedObject var controller: ReaderWebController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: "mdreader")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.setAccessibilityLabel("Rendered Markdown document")
        controller.attach(webView)
        context.coordinator.load(
            rendered: rendered,
            documentURL: documentURL,
            title: title,
            style: style,
            restorePosition: restorePosition,
            in: webView
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(
            rendered: rendered,
            documentURL: documentURL,
            title: title,
            style: style,
            restorePosition: restorePosition,
            in: webView
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.persistReadingPosition(in: webView)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let schemeHandler = DocumentSchemeHandler()
        private weak var controller: ReaderWebController?
        private var rendered: RenderedMarkdown?
        private var documentURL: URL?
        private var loadedRevision: UUID?
        private var loadedStyle: RenderStyle?
        private var pendingScrollFraction: Double?
        private var activeDocumentURL: URL?
        private var restorePosition = false

        init(controller: ReaderWebController) {
            self.controller = controller
        }

        func load(
            rendered: RenderedMarkdown,
            documentURL: URL?,
            title: String,
            style: RenderStyle,
            restorePosition: Bool,
            in webView: WKWebView
        ) {
            guard rendered.revision != loadedRevision || style != loadedStyle else { return }

            let isInitialLoad = loadedRevision == nil
            self.rendered = rendered
            self.documentURL = documentURL
            self.restorePosition = restorePosition
            schemeHandler.update(rendered: rendered, title: title, style: style)
            loadedRevision = rendered.revision
            loadedStyle = style

            let token = rendered.resourceToken
            let loadID = UUID().uuidString.lowercased()
            guard let nextURL = URL(string: "mdreader://document/\(token)/index.html?load=\(loadID)") else { return }
            activeDocumentURL = nextURL

            if isInitialLoad {
                pendingScrollFraction = restorePosition ? documentURL.flatMap(ReadingPositionStore.fraction) : nil
                webView.load(URLRequest(url: nextURL))
                return
            }

            webView.evaluateJavaScript(ReadingPositionStore.scrollFractionJavaScript) { [weak self, weak webView] result, _ in
                self?.pendingScrollFraction = result as? Double
                guard let webView else { return }
                webView.load(URLRequest(url: nextURL))
            }
        }

        func persistReadingPosition(in webView: WKWebView) {
            guard restorePosition, let documentURL else { return }
            webView.evaluateJavaScript(ReadingPositionStore.scrollFractionJavaScript) { result, _ in
                guard let fraction = result as? Double else { return }
                ReadingPositionStore.set(fraction, for: documentURL)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let fraction = pendingScrollFraction else { return }
            pendingScrollFraction = nil
            guard fraction > 0 else { return }
            let clamped = min(max(fraction, 0), 1)
            webView.evaluateJavaScript("window.scrollTo(0, \(clamped) * Math.max(0, document.documentElement.scrollHeight - window.innerHeight))")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if url.scheme == "mdreader",
               url.host == "document",
               url.path == activeDocumentURL?.path,
               url.query == activeDocumentURL?.query {
                decisionHandler(.allow)
                return
            }

            if url.scheme == "mdreader-link",
               navigationAction.navigationType == .linkActivated,
               url.host == "open" {
                let components = url.path.split(separator: "/").map(String.init)
                if components.count == 2,
                   components[0] == rendered?.resourceToken,
                   let target = rendered?.linkTargets[components[1]] {
                    openLinkTarget(target)
                }
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        private func openLinkTarget(_ target: String) {
            guard let destination = LinkTargetResolver.resolve(target, relativeTo: documentURL) else { return }

            switch destination {
            case let .external(url):
                NSWorkspace.shared.open(url)
            case let .markdown(url):
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            case let .reveal(url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
