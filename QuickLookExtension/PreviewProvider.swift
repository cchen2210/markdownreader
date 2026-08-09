import Cocoa
import Quartz
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
        let source = try MarkdownTextDecoder.decode(data)
        let rendered = MarkdownRenderer.render(
            source: source,
            sourceData: data,
            documentURL: request.fileURL
        )
        let title = request.fileURL.lastPathComponent

        let previewHTML = HTMLDocumentBuilder.buildPreview(rendered: rendered, title: title, style: .standard)
        var attachments: [String: QLPreviewReplyAttachment] = [:]
        var imageReplacements: [String: String] = [:]
        var attachmentBytes = 0

        for (assetID, assetURL) in rendered.imageAssets {
            guard let imageRoot = rendered.imageRoot,
                  let image = try? LocalImageLoader.load(from: assetURL, within: imageRoot) else {
                imageReplacements[assetID] = "data:,"
                continue
            }
            guard attachmentBytes <= MarkdownRenderer.maximumDeclaredImageBytes - image.data.count else {
                imageReplacements[assetID] = "data:,"
                continue
            }
            attachmentBytes += image.data.count
            attachments[assetID] = QLPreviewReplyAttachment(data: image.data, contentType: image.contentType)
            imageReplacements[assetID] = "cid:\(assetID)"
        }

        let html = HTMLDocumentBuilder.replacingImageSources(
            in: previewHTML,
            rendered: rendered,
            replacements: imageReplacements
        )

        let htmlData = Data(html.utf8)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 840, height: 900)) { reply in
            reply.stringEncoding = .utf8
            reply.title = title
            reply.attachments = attachments
            return htmlData
        }
        return reply
    }
}
