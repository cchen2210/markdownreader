@preconcurrency import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var preferences: ReaderPreferences
    @State private var defaultStatus: String?

    var body: some View {
        TabView {
            Form {
                Toggle("Automatically refresh changed files", isOn: $preferences.automaticRefresh)
                Toggle("Restore reading position", isOn: $preferences.restorePosition)

                LabeledContent("Preferred editor") {
                    HStack {
                        Text(ExternalEditor.editorName(preferences: preferences))
                            .foregroundStyle(.secondary)
                        Button("Choose…") {
                            ExternalEditor.chooseEditor(preferences: preferences)
                        }
                    }
                }

                LabeledContent("Default app for Markdown") {
                    Button("Make Default") { makeDefault() }
                }

                if let defaultStatus {
                    Text(defaultStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            ReaderOptionsView()
                .tabItem { Label("Reading", systemImage: "textformat.size") }

            Form {
                LabeledContent("Remote images") {
                    Text("Blocked")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Document JavaScript") {
                    Text("Disabled")
                        .foregroundStyle(.secondary)
                }
                Text("Markdown is rendered locally. Embedded HTML is shown as inert text, and external links open in your default browser only after you click them.")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 340)
    }

    private func makeDefault() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .markdownDocument) { error in
            Task { @MainActor in
                defaultStatus = error == nil ? "Markdown Reader is now the default." : error?.localizedDescription
            }
        }
    }
}
