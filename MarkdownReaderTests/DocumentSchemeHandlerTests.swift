import UniformTypeIdentifiers
@preconcurrency import WebKit
import XCTest
@testable import MarkdownReader

final class DocumentSchemeHandlerTests: XCTestCase {
    @MainActor
    func testDocumentCallbacksStayOnMainThreadAndFinishOnce() throws {
        let handler = DocumentSchemeHandler()
        let rendered = MarkdownRenderer.render(source: "# Hello", documentURL: nil)
        handler.update(rendered: rendered, title: "Hello", style: .standard)
        let url = try XCTUnwrap(URL(string: "mdreader://document/\(rendered.resourceToken)/index.html"))
        let task = RecordingSchemeTask(url: url)

        handler.webView(WKWebView(frame: .zero), start: task)

        XCTAssertEqual(task.events, [.response, .data, .finished])
        XCTAssertTrue(task.callbacksWereOnMainThread)
    }

    @MainActor
    func testStoppedImageTaskReceivesNoLateCallbacks() async throws {
        let loaderStarted = expectation(description: "Image loader started")
        let releaseLoader = DispatchSemaphore(value: 0)
        let handler = DocumentSchemeHandler { _, _ in
            loaderStarted.fulfill()
            releaseLoader.wait()
            return LoadedLocalImage(data: Data([0x00]), contentType: .png)
        }
        let documentURL = FileManager.default.temporaryDirectory.appendingPathComponent("readme.md")
        let rendered = MarkdownRenderer.render(source: "![image](image.png)", documentURL: documentURL)
        handler.update(rendered: rendered, title: "Image", style: .standard)
        let url = try XCTUnwrap(URL(string: "mdreader://asset/\(rendered.resourceToken)/image-0"))
        let task = RecordingSchemeTask(url: url)
        let webView = WKWebView(frame: .zero)

        handler.webView(webView, start: task)
        await fulfillment(of: [loaderStarted], timeout: 2)
        handler.webView(webView, stop: task)
        releaseLoader.signal()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(task.events.isEmpty)
    }

    @MainActor
    func testUnknownResourceTokenFailsOnce() throws {
        let handler = DocumentSchemeHandler()
        let rendered = MarkdownRenderer.render(source: "# Hello", documentURL: nil)
        handler.update(rendered: rendered, title: "Hello", style: .standard)
        let task = RecordingSchemeTask(url: try XCTUnwrap(URL(string: "mdreader://document/wrong/index.html")))

        handler.webView(WKWebView(frame: .zero), start: task)

        XCTAssertEqual(task.events, [.failed])
        XCTAssertTrue(task.callbacksWereOnMainThread)
    }
}

@MainActor
private final class RecordingSchemeTask: NSObject, @preconcurrency WKURLSchemeTask {
    enum Event: Equatable {
        case response
        case data
        case finished
        case failed
    }

    let request: URLRequest
    private(set) var events: [Event] = []
    private(set) var callbacksWereOnMainThread = true

    init(url: URL) {
        request = URLRequest(url: url)
    }

    func didReceive(_ response: URLResponse) {
        record(.response)
    }

    func didReceive(_ data: Data) {
        record(.data)
    }

    func didFinish() {
        record(.finished)
    }

    func didFailWithError(_ error: any Error) {
        record(.failed)
    }

    private func record(_ event: Event) {
        callbacksWereOnMainThread = callbacksWereOnMainThread && Thread.isMainThread
        events.append(event)
    }
}
