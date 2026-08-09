import SwiftUI

struct MemoryEmptyStateView: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var compact = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        VStack(spacing: compact ? 9 : 13) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: compact ? 22 : 30, weight: .ultraLight))
                .foregroundStyle(palette.metadataInk)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: compact ? 15 : 18, weight: .medium, design: .serif))
                .foregroundStyle(palette.ink)

            Text(message)
                .font(.system(size: compact ? 12.5 : 14, design: .serif))
                .foregroundStyle(palette.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .frame(maxWidth: compact ? 230 : 340)
        .padding(compact ? 16 : 28)
        .accessibilityElement(children: .contain)
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
