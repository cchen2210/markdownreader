import SwiftUI

struct SourceView: View {
    let source: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(source)
                .font(.system(size: 14, design: .monospaced))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(28)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("Markdown source")
    }
}
