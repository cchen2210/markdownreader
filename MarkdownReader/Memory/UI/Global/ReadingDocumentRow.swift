import SwiftUI

struct ReadingDocumentRow: View {
    let document: ReadingDocumentPresentation
    let isSelected: Bool
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    var onToggleFavourite: () -> Void = {}
    var onForget: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .trailing, spacing: 3) {
                Text("LAST READ")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.55)
                Text(document.lastRead)
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(palette.metadataInk)
            .multilineTextAlignment(.trailing)
            .frame(width: 158, alignment: .trailing)

            HStack(alignment: .top, spacing: 11) {
                Rectangle()
                    .fill(document.isOriginalAvailable ? palette.accent : palette.metadataInk)
                    .frame(width: accessibilityContrast == .increased ? 3 : 2)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(document.displayName)
                                .font(.system(size: 16, weight: .medium, design: .serif))
                                .foregroundStyle(palette.ink)
                                .lineLimit(2)

                            if let parentFolder = document.parentFolder, !parentFolder.isEmpty {
                                Text(parentFolder)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.metadataInk)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer(minLength: 8)

                        Button(action: onToggleFavourite) {
                            Image(systemName: document.isFavourite ? "star.fill" : "star")
                                .foregroundStyle(document.isFavourite ? palette.accentLabel : palette.metadataInk)
                        }
                        .buttonStyle(.plain)
                        .help(document.isFavourite ? "Remove from Favourites" : "Add to Favourites")
                        .accessibilityLabel(document.isFavourite ? "Remove from Favourites" : "Add to Favourites")
                    }

                    if let lastHeading = document.lastHeading, !lastHeading.isEmpty {
                        Text("Continue at \(lastHeading)")
                            .font(.system(size: 13.5, design: .serif))
                            .foregroundStyle(palette.secondaryInk)
                            .lineLimit(2)
                    }

                    if let progress = document.boundedProgress {
                        HStack(spacing: 9) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(palette.accent)
                                .frame(maxWidth: 240)
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .font(.system(size: 11.5))
                                .monospacedDigit()
                                .foregroundStyle(palette.metadataInk)
                        }
                    }

                    if !document.isOriginalAvailable {
                        Label("Original file unavailable", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(palette.metadataInk)
                    }

                    if isSelected {
                        Button(document.isOriginalAvailable ? "Continue Reading" : "Locate File…", action: onOpen)
                            .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
            }
            .padding(.horizontal, isSelected ? 12 : 2)
            .padding(.vertical, isSelected ? 12 : 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(palette.selectedFill)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(palette.accent, lineWidth: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(document.isOriginalAvailable ? "Continue Reading" : "Locate File…", action: onOpen)
            Button(document.isFavourite ? "Remove from Favourites" : "Add to Favourites", action: onToggleFavourite)
            Divider()
            Button("Forget Document from Reading Memory…", role: .destructive, action: onForget)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(document.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Select", onSelect)
        .accessibilityAction(named: document.isOriginalAvailable ? "Continue Reading" : "Locate File", onOpen)
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
