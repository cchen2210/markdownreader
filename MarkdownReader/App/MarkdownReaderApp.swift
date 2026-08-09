import AppKit
import SwiftUI

@main
struct MarkdownReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences = ReaderPreferences()

    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { configuration in
            ReaderView(document: configuration.document, fileURL: configuration.fileURL)
                .environmentObject(preferences)
                .frame(minWidth: 620, minHeight: 460)
        }
        .windowToolbarStyle(.unified)
        .commands {
            ReaderCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(preferences)
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }
}
