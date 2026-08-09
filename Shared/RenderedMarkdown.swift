import Foundation

struct OutlineEntry: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let level: Int
    let title: String
}

struct RenderedMarkdown: Sendable {
    let revision: UUID
    let bodyHTML: String
    let outline: [OutlineEntry]
    let linkTargets: [String: String]
    let imageAssets: [String: URL]
    let imageRoot: URL?

    var resourceToken: String {
        revision.uuidString.lowercased()
    }

    func linkSource(for linkID: String) -> String {
        "mdreader-link://open/\(resourceToken)/\(linkID)"
    }

    func imageSource(for assetID: String) -> String {
        "mdreader://asset/\(resourceToken)/\(assetID)"
    }
}

enum ReaderAppearance: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case light
    case dark
    case sepia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        case .sepia: "Sepia"
        }
    }
}

enum ReaderBodyStyle: String, CaseIterable, Identifiable, Sendable {
    case serif
    case sans

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ReaderWidth: String, CaseIterable, Identifiable, Sendable {
    case narrow
    case comfortable
    case wide

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var points: Int {
        switch self {
        case .narrow: 620
        case .comfortable: 720
        case .wide: 880
        }
    }
}

struct RenderStyle: Equatable, Sendable {
    var appearance: ReaderAppearance = .automatic
    var bodyStyle: ReaderBodyStyle = .serif
    var textSize: Double = 17
    var lineHeight: Double = 1.65
    var width: ReaderWidth = .comfortable

    static let standard = RenderStyle()
}
