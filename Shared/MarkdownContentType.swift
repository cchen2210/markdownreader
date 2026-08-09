import UniformTypeIdentifiers

extension UTType {
    static let markdownDocument = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .utf8PlainText
    )
}
