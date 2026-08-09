import AppKit
import SwiftUI

@main
struct MarkdownReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences = ReaderPreferences()
    @StateObject private var memoryLibrary = ReadingMemoryLibrary()

    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { configuration in
            ReaderView(document: configuration.document, fileURL: configuration.fileURL)
                .environmentObject(preferences)
                .environmentObject(memoryLibrary)
                .frame(minWidth: 620, minHeight: 460)
        }
        .windowToolbarStyle(.unified)
        .commands {
            ReaderCommands()
        }

        Window("Reading Memory", id: "reading-memory") {
            ReadingMemoryWindow()
                .environmentObject(preferences)
                .environmentObject(memoryLibrary)
        }
        .defaultSize(width: 1040, height: 720)
        .windowToolbarStyle(.unified)

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
