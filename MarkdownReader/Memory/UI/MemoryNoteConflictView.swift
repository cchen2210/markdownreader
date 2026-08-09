@preconcurrency import AppKit
import SwiftUI

struct MemoryNoteConflict: Equatable, Sendable {
    let memoryID: UUID
    let latestNoteText: String?
    let latestRecordVersion: Int64
}

struct MemoryNoteConflictView: View {
    let latestNote: String?
    let draft: String
    var isWorking = false
    var onUseLatest: () -> Void = {}
    var onReplace: () -> Void = {}
    var onCancel: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("This note changed in another window", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.ink)

            Text("Your draft has not been overwritten. Choose which version to keep.")
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(palette.secondaryInk)

            GroupBox("Latest saved note") {
                Text(latestNote.flatMap { $0.isEmpty ? nil : $0 } ?? "No note")
                    .font(.system(size: 13.5, design: .serif))
                    .foregroundStyle(palette.secondaryInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Copy My Draft") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(draft, forType: .string)
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Spacer()
                Button("Use Latest", action: onUseLatest)
                    .disabled(isWorking)
                Button("Replace with Mine", action: onReplace)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isWorking)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(palette.sidebar)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.accent, lineWidth: accessibilityContrast == .increased ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.24), radius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note conflict")
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
