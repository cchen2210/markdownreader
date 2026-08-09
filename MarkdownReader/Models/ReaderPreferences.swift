import Foundation

@MainActor
final class ReaderPreferences: ObservableObject {
    private enum Key {
        static let appearance = "reader.appearance"
        static let bodyStyle = "reader.bodyStyle"
        static let textSize = "reader.textSize"
        static let lineHeight = "reader.lineHeight"
        static let width = "reader.width"
        static let preferredEditorPath = "reader.preferredEditorPath"
        static let restorePosition = "reader.restorePosition"
        static let automaticRefresh = "reader.automaticRefresh"
    }

    private let defaults: UserDefaults

    @Published var appearance: ReaderAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    @Published var bodyStyle: ReaderBodyStyle {
        didSet { defaults.set(bodyStyle.rawValue, forKey: Key.bodyStyle) }
    }

    @Published var textSize: Double {
        didSet { defaults.set(textSize, forKey: Key.textSize) }
    }

    @Published var lineHeight: Double {
        didSet { defaults.set(lineHeight, forKey: Key.lineHeight) }
    }

    @Published var width: ReaderWidth {
        didSet { defaults.set(width.rawValue, forKey: Key.width) }
    }

    @Published var preferredEditorPath: String? {
        didSet { defaults.set(preferredEditorPath, forKey: Key.preferredEditorPath) }
    }

    @Published var restorePosition: Bool {
        didSet { defaults.set(restorePosition, forKey: Key.restorePosition) }
    }

    @Published var automaticRefresh: Bool {
        didSet { defaults.set(automaticRefresh, forKey: Key.automaticRefresh) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = ReaderAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .automatic
        bodyStyle = ReaderBodyStyle(rawValue: defaults.string(forKey: Key.bodyStyle) ?? "") ?? .serif
        textSize = defaults.object(forKey: Key.textSize) == nil ? 17 : defaults.double(forKey: Key.textSize)
        lineHeight = defaults.object(forKey: Key.lineHeight) == nil ? 1.65 : defaults.double(forKey: Key.lineHeight)
        width = ReaderWidth(rawValue: defaults.string(forKey: Key.width) ?? "") ?? .comfortable
        preferredEditorPath = defaults.string(forKey: Key.preferredEditorPath)
        restorePosition = defaults.object(forKey: Key.restorePosition) == nil ? true : defaults.bool(forKey: Key.restorePosition)
        automaticRefresh = defaults.object(forKey: Key.automaticRefresh) == nil ? true : defaults.bool(forKey: Key.automaticRefresh)
    }

    var renderStyle: RenderStyle {
        RenderStyle(
            appearance: appearance,
            bodyStyle: bodyStyle,
            textSize: max(13, min(textSize, 34)),
            lineHeight: max(1.35, min(lineHeight, 2.0)),
            width: width
        )
    }
}
