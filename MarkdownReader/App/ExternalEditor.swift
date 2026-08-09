@preconcurrency import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ExternalEditor {
    static func open(fileURL: URL, preferences: ReaderPreferences) {
        let storedEditorURL = resolvedEditorURL(preferences: preferences)
        if storedEditorURL == nil, preferences.preferredEditorPath != nil {
            preferences.preferredEditorPath = nil
        }
        guard let editorURL = storedEditorURL ?? chooseEditor(preferences: preferences) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: configuration) { _, error in
            if let error {
                let applicationError = error as NSError
                Task { @MainActor in
                    NSApplication.shared.presentError(applicationError)
                }
            }
        }
    }

    @discardableResult
    static func chooseEditor(preferences: ReaderPreferences) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Markdown Editor"
        panel.prompt = "Choose Editor"
        panel.message = "Choose the application Markdown Reader should use for editing."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        preferences.preferredEditorPath = url.path
        return url
    }

    static func editorName(preferences: ReaderPreferences) -> String {
        guard let url = resolvedEditorURL(preferences: preferences) else { return "Not Selected" }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func resolvedEditorURL(preferences: ReaderPreferences) -> URL? {
        guard let path = preferences.preferredEditorPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
