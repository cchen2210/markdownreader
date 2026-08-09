import SwiftUI

struct ReadingMemorySearchBar: View {
    @Binding var text: String
    @Binding var scope: ReadingMemorySearchScope
    let facet: ReadingMemoryFacet
    var debounceNanoseconds: UInt64 = 180_000_000
    var onDebouncedSearch: (ReadingMemorySearchRequest) -> Void = { _ in }

    @FocusState private var isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.metadataInk)
                    .accessibilityHidden(true)

                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .accessibilityLabel(prompt)

                if !text.isEmpty {
                    Button {
                        text = ""
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(palette.metadataInk)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 13.5))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(palette.sidebar.opacity(0.78))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isFocused ? palette.accent : palette.hairline,
                        lineWidth: isFocused || accessibilityContrast == .increased ? 1.5 : 1
                    )
            }

            if !facet.presentsDocuments {
                Picker("Search in", selection: $scope) {
                    ForEach(ReadingMemorySearchScope.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Search in")
            }
        }
        .task(id: request) {
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
                guard !Task.isCancelled else { return }
                onDebouncedSearch(request)
            } catch {
                // A newer query cancels this task; only the latest reaches the repository.
            }
        }
    }

    private var request: ReadingMemorySearchRequest {
        ReadingMemorySearchRequest(text: text, scope: scope, facet: facet)
    }

    private var prompt: String {
        facet.presentsDocuments ? "Search documents" : "Search memories"
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
