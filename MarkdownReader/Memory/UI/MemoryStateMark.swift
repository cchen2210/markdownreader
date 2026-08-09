import SwiftUI

struct MemoryStateMark: View {
    let state: MemoryPresentation.State
    var size: CGFloat = 10
    var showsLabel = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        HStack(spacing: 6) {
            mark
                .frame(width: size, height: size)
                .accessibilityHidden(true)

            if showsLabel {
                Text(state.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(0.45)
                    .foregroundStyle(palette.accentLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, isIncreasedContrast ? 4 : 0)
                    .padding(.vertical, isIncreasedContrast ? 2 : 0)
                    .overlay {
                        if isIncreasedContrast {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(palette.accentLabel, lineWidth: 1.5)
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stateAccessibilityLabel)
    }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .resolved:
            Rectangle()
                .fill(palette.accent)
        case .chooseLocation:
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.clear)
                Rectangle()
                    .fill(palette.accent)
                    .frame(width: size / 2)
                Rectangle()
                    .stroke(palette.accent, lineWidth: isIncreasedContrast ? 2 : 1.25)
            }
        case .needsRepair:
            Rectangle()
                .stroke(palette.metadataInk, lineWidth: isIncreasedContrast ? 2 : 1.5)
        }
    }

    private var stateAccessibilityLabel: String {
        if let count = state.candidateCount {
            return "Choose location, \(count) candidates"
        }
        return state.label
    }

    private var isIncreasedContrast: Bool {
        accessibilityContrast == .increased
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: isIncreasedContrast
        )
    }
}
