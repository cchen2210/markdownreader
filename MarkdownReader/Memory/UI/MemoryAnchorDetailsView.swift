import SwiftUI

struct MemoryAnchorDetailsView: View {
    let memory: MemoryPresentation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        if let details = memory.anchorDetails {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 5) {
                    detailRow("State", memory.state.label)
                    detailRow("Found by", details.foundBy)
                    detailRow("Last checked", details.lastChecked)
                    detailRow("Candidates", details.candidateSummary)
                }

                if let passage = details.savedPassage, !passage.isEmpty {
                    HStack(alignment: .top, spacing: 9) {
                        Rectangle()
                            .fill(palette.hairline)
                            .frame(width: accessibilityContrast == .increased ? 2 : 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Passage as you saved it")
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.metadataInk)
                            Text("“\(passage)”")
                                .font(.system(size: 13, design: .serif))
                                .italic()
                                .foregroundStyle(palette.secondaryInk)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Anchor details")
        }
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key)
                .frame(width: 96, alignment: .leading)
                .foregroundStyle(palette.metadataInk)
            Text(value)
                .foregroundStyle(palette.secondaryInk)
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5))
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
