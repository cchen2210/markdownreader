import SwiftUI

struct FindBar: View {
    @Binding var query: String
    let status: ReaderWebController.FindStatus
    let findNext: () -> Void
    let findPrevious: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in document", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(findNext)

            if status == .notFound, !query.isEmpty {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: findPrevious) {
                Image(systemName: "chevron.up")
            }
            .help("Previous Match")
            .disabled(query.isEmpty)

            Button(action: findNext) {
                Image(systemName: "chevron.down")
            }
            .help("Next Match")
            .disabled(query.isEmpty)

            Button("Done", action: close)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
    }
}
