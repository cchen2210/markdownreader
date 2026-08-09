import Foundation
@preconcurrency import WebKit

@MainActor
final class DocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    typealias ImageLoader = @Sendable (URL, URL) throws -> LoadedLocalImage

    private let imageQueue = DispatchQueue(label: "MarkdownReader.ImageLoading", qos: .userInitiated)
    private let imageLoader: ImageLoader
    private var htmlData = Data()
    private var imageAssets: [String: URL] = [:]
    private var imageRoot: URL?
    private var resourceToken = ""
    private var activeTasks: [ObjectIdentifier: SchemeTaskBox] = [:]

    init(imageLoader: @escaping ImageLoader = { url, root in
        try LocalImageLoader.load(from: url, within: root)
    }) {
        self.imageLoader = imageLoader
        super.init()
    }

    func update(rendered: RenderedMarkdown, title: String, style: RenderStyle) {
        let html = HTMLDocumentBuilder.build(rendered: rendered, title: title, style: style)
        htmlData = Data(html.utf8)
        imageAssets = rendered.imageAssets
        imageRoot = rendered.imageRoot
        resourceToken = rendered.resourceToken
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        let url = urlSchemeTask.request.url
        let taskBox = SchemeTaskBox(urlSchemeTask)
        start(taskBox: taskBox, identifier: identifier, url: url)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        activeTasks.removeValue(forKey: identifier)
    }

    private func start(taskBox: SchemeTaskBox, identifier: ObjectIdentifier, url: URL?) {
        activeTasks[identifier] = taskBox
        guard let url, url.scheme == "mdreader" else {
            fail(identifier: identifier, error: SchemeError.invalidRequest)
            return
        }

        switch url.host {
        case "document":
            let data = htmlData
            let token = resourceToken
            let components = url.path.split(separator: "/").map(String.init)
            guard components == [token, "index.html"] else {
                fail(identifier: identifier, error: SchemeError.invalidRequest)
                return
            }
            finish(
                identifier: identifier,
                data: data,
                mimeType: "text/html",
                url: url
            )

        case "asset":
            let components = url.path.split(separator: "/").map(String.init)
            let token = resourceToken
            let assetURL = components.count == 2 && components[0] == token
                ? imageAssets[components[1]]
                : nil

            guard let assetURL, let imageRoot else {
                fail(identifier: identifier, error: SchemeError.unknownAsset)
                return
            }
            let imageLoader = imageLoader
            imageQueue.async { [weak self] in
                let result = Result { try imageLoader(assetURL, imageRoot) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch result {
                    case let .success(image):
                        finish(
                            identifier: identifier,
                            data: image.data,
                            mimeType: image.contentType.preferredMIMEType ?? "application/octet-stream",
                            url: url
                        )
                    case let .failure(error):
                        fail(identifier: identifier, error: error)
                    }
                }
            }

        default:
            fail(identifier: identifier, error: SchemeError.invalidRequest)
        }
    }

    private func finish(
        identifier: ObjectIdentifier,
        data: Data,
        mimeType: String,
        url: URL
    ) {
        guard let task = activeTasks[identifier]?.task else { return }
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType == "text/html" ? "utf-8" : nil
        )
        task.didReceive(response)
        guard activeTasks[identifier] != nil else { return }
        task.didReceive(data)
        guard activeTasks.removeValue(forKey: identifier) != nil else { return }
        task.didFinish()
    }

    private func fail(identifier: ObjectIdentifier, error: Error) {
        guard let task = activeTasks.removeValue(forKey: identifier)?.task else { return }
        task.didFailWithError(error)
    }
}

private final class SchemeTaskBox {
    let task: any WKURLSchemeTask

    init(_ task: any WKURLSchemeTask) {
        self.task = task
    }
}

private enum SchemeError: LocalizedError {
    case invalidRequest
    case unknownAsset

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "Invalid reader resource request."
        case .unknownAsset: "The requested image is unavailable."
        }
    }
}
