import SwiftUI

struct OutlineSidebar: View {
    let entries: [OutlineEntry]
    @Binding var selection: String?

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Headings",
                    systemImage: "list.bullet.indent",
                    description: Text("This document has no headings to show.")
                )
            } else {
                List(selection: $selection) {
                    ForEach(entries) { entry in
                        Text(entry.title)
                            .lineLimit(2)
                            .help(entry.title)
                            .padding(.leading, CGFloat(min(max(entry.level - 1, 0), 3) * 12))
                            .accessibilityLabel("Heading level \(entry.level), \(entry.title)")
                            .tag(entry.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Outline")
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)
    }
}
