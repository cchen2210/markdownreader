import Foundation

enum DocumentIdentityProbe {
    struct Observation: Equatable, Sendable {
        let identity: FileIdentity
        let canonicalURL: URL
        let displayURL: URL
    }

    static func observe(_ url: URL) throws -> Observation {
        let displayURL = url.standardizedFileURL
        let canonicalURL = displayURL.resolvingSymlinksInPath()
        let values = try canonicalURL.resourceValues(forKeys: [
            .volumeIdentifierKey,
            .fileResourceIdentifierKey,
        ])
        return Observation(
            identity: FileIdentity(
                volumeIdentifier: try archive(values.volumeIdentifier),
                fileResourceIdentifier: try archive(values.fileResourceIdentifier)
            ),
            canonicalURL: canonicalURL,
            displayURL: displayURL
        )
    }

    private static func archive(_ value: Any?) throws -> Data? {
        guard let value else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false)
    }
}
