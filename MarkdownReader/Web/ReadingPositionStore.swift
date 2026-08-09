import CryptoKit
import Foundation

enum ReadingPositionStore {
    static let scrollFractionJavaScript = "Math.max(0, window.scrollY) / Math.max(1, document.documentElement.scrollHeight - window.innerHeight)"
    static let maximumEntries = 200
    static let storageKey = "reader.positions.v2"

    private static let legacyKeyPrefix = "reader.position."
    private static let legacyCleanupKey = "reader.positions.legacy-cleaned"

    private struct Entry: Codable {
        var fraction: Double
        var lastUsed: TimeInterval
    }

    static func fraction(for documentURL: URL) -> Double? {
        fraction(for: documentURL, defaults: .standard)
    }

    static func set(_ fraction: Double, for documentURL: URL) {
        set(fraction, for: documentURL, defaults: .standard)
    }

    static func fraction(
        for documentURL: URL,
        defaults: UserDefaults,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> Double? {
        cleanLegacyKeysIfNeeded(in: defaults)
        var entries = loadEntries(from: defaults)
        let key = documentKey(for: documentURL)
        guard var entry = entries[key] else { return nil }
        entry.lastUsed = now
        entries[key] = entry
        save(entries, to: defaults)
        return min(max(entry.fraction, 0), 1)
    }

    static func set(
        _ fraction: Double,
        for documentURL: URL,
        defaults: UserDefaults,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        cleanLegacyKeysIfNeeded(in: defaults)
        var entries = loadEntries(from: defaults)
        entries[documentKey(for: documentURL)] = Entry(
            fraction: min(max(fraction, 0), 1),
            lastUsed: now
        )
        save(entries, to: defaults)
    }

    private static func documentKey(for documentURL: URL) -> String {
        let path = documentURL.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadEntries(from defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return entries
    }

    private static func save(_ entries: [String: Entry], to defaults: UserDefaults) {
        let retained = entries
            .sorted { lhs, rhs in lhs.value.lastUsed > rhs.value.lastUsed }
            .prefix(maximumEntries)
        let pruned = Dictionary<String, Entry>(
            uniqueKeysWithValues: retained.map { ($0.key, $0.value) }
        )
        guard let data = try? JSONEncoder().encode(pruned) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func cleanLegacyKeysIfNeeded(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: legacyCleanupKey) else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(legacyKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: legacyCleanupKey)
    }
}
