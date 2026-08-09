import SwiftUI

/// A native, nonmodal editor that stays on the reading surface. The rendered
/// document never receives note text or an editing script.
struct MemoryNoteEditorView: View {
    let memory: MemoryPresentation?
    @Binding var draft: String
    var width: CGFloat = MemoryLayoutPolicy.inspectorWidth
    var isSaving = false
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory?.hasNote == true ? "Edit note" : "Write in the margin")
                        .font(.system(size: 14, weight: .semibold))
                    if let heading = memory?.headingPath, !heading.isEmpty {
                        Text(heading)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.metadataInk)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Cancel Note")
                .accessibilityLabel("Cancel Note")
            }

            if let passage = memory?.passage, !passage.isEmpty {
                Text("“\(passage)”")
                    .font(.system(size: 13.5, design: .serif))
                    .italic()
                    .foregroundStyle(palette.secondaryInk)
                    .lineLimit(4)
            }

            TextEditor(text: $draft)
                .font(.system(size: 15, design: .serif))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 130)
                .padding(7)
                .background(palette.paper)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isFocused ? palette.accent : palette.hairline, lineWidth: isFocused ? 1.5 : 1)
                }
                .accessibilityLabel("Memory note")

            HStack {
                Text("Saved locally; the Markdown file is unchanged.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.metadataInk)
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isSaving)
            }
        }
        .padding(16)
        .frame(width: width)
        .background(palette.sidebar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.hairline)
                .frame(width: accessibilityContrast == .increased ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(0.20), radius: 18, x: -8)
        .onAppear { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory note editor")
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
