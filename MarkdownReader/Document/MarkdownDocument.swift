import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownDocument] }
    static var writableContentTypes: [UTType] { [.markdownDocument] }

    let source: String
    let sourceData: Data

    init(source: String = "") {
        self.source = source
        sourceData = Data(source.utf8)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        sourceData = data
        source = try MarkdownTextDecoder.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: sourceData)
    }
}
