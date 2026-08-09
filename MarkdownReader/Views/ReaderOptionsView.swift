import SwiftUI

struct ReaderOptionsView: View {
    @EnvironmentObject private var preferences: ReaderPreferences

    var body: some View {
        Form {
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(ReaderAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }

            Picker("Body", selection: $preferences.bodyStyle) {
                ForEach(ReaderBodyStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Text size") {
                HStack {
                    Slider(value: $preferences.textSize, in: 13...34, step: 1)
                    Text("\(Int(preferences.textSize)) pt")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }

            Picker("Width", selection: $preferences.width) {
                ForEach(ReaderWidth.allCases) { width in
                    Text(width.label).tag(width)
                }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .padding(.vertical, 8)
    }
}
