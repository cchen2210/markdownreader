import Foundation

enum ResolvedLinkTarget: Equatable, Sendable {
    case external(URL)
    case markdown(URL)
    case reveal(URL)
}

enum LinkTargetResolver {
    static func resolve(_ target: String, relativeTo documentURL: URL?) -> ResolvedLinkTarget? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            guard ["http", "https", "mailto"].contains(scheme) else { return nil }
            return .external(url)
        }

        guard let documentURL else { return nil }

        let withoutFragment = trimmed
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? trimmed
        var decoded = withoutFragment
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? withoutFragment
        for _ in 0..<3 {
            guard let next = decoded.removingPercentEncoding, next != decoded else { break }
            decoded = next
        }
        guard !decoded.isEmpty,
              !decoded.hasPrefix("/"),
              !decoded.hasPrefix("~"),
              URL(string: decoded)?.scheme == nil else { return nil }

        let root = documentURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: decoded, relativeTo: root)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else { return nil }

        if ["md", "markdown", "mdown", "mkd"].contains(candidate.pathExtension.lowercased()) {
            return .markdown(candidate)
        }
        return .reveal(candidate)
    }
}
