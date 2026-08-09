import SwiftUI

struct ReaderActions {
    let canUsePreview: Bool
    let showFind: () -> Void
    let findNext: () -> Void
    let findPrevious: () -> Void
    let toggleOutline: () -> Void
    let toggleSource: () -> Void
    let previousHeading: () -> Void
    let nextHeading: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let printDocument: () -> Void
    let openInEditor: () -> Void
    let copyPath: () -> Void
    let rememberPassage: () -> Void
    let rememberPassageWithNote: () -> Void
    let bookmarkHeading: () -> Void
    let toggleMemory: () -> Void
    let openReadingMemory: () -> Void
    let previousMemory: () -> Void
    let nextMemory: () -> Void
    let deleteMemory: () -> Void
}

private struct ReaderActionsKey: FocusedValueKey {
    typealias Value = ReaderActions
}

extension FocusedValues {
    var readerActions: ReaderActions? {
        get { self[ReaderActionsKey.self] }
        set { self[ReaderActionsKey.self] = newValue }
    }
}

struct ReaderCommands: Commands {
    @FocusedValue(\.readerActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Reader") {
            Button("Find in Document…") { actions?.showFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.canUsePreview != true)
            Button("Find Next") { actions?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(actions?.canUsePreview != true)
            Button("Find Previous") { actions?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions?.canUsePreview != true)

            Divider()

            Button("Toggle Outline") { actions?.toggleOutline() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(actions == nil)
            Button("Toggle Preview and Source") { actions?.toggleSource() }
                .keyboardShortcut("\\", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Previous Heading") { actions?.previousHeading() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Next Heading") { actions?.nextHeading() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(actions == nil)

            Divider()

            Button("Remember Passage") { actions?.rememberPassage() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(actions?.canUsePreview != true)
            Button("Remember Passage with Note") { actions?.rememberPassageWithNote() }
                .keyboardShortcut("m", modifiers: [.command, .option, .shift])
                .disabled(actions?.canUsePreview != true)
            Button("Bookmark This Heading") { actions?.bookmarkHeading() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(actions?.canUsePreview != true)

            Divider()

            Button("Toggle Document Memory") { actions?.toggleMemory() }
                .keyboardShortcut("m", modifiers: [.command, .control])
                .disabled(actions?.canUsePreview != true)
            Button("Open Reading Memory") {
                if let actions {
                    actions.openReadingMemory()
                } else {
                    openWindow(id: "reading-memory")
                }
            }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Previous Memory") { actions?.previousMemory() }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(actions?.canUsePreview != true)
            Button("Next Memory") { actions?.nextMemory() }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(actions?.canUsePreview != true)
            Button("Delete Selected Memory") { actions?.deleteMemory() }
                .disabled(actions?.canUsePreview != true)

            Divider()

            Button("Increase Text Size") { actions?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(actions?.canUsePreview != true)
            Button("Decrease Text Size") { actions?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions?.canUsePreview != true)
            Button("Actual Size") { actions?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(actions?.canUsePreview != true)

            Divider()

            Button("Open in Editor…") { actions?.openInEditor() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Copy File Path") { actions?.copyPath() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Print…") { actions?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(actions?.canUsePreview != true)
        }
    }
}
