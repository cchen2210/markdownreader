import CryptoKit
import Foundation

enum ReadingPositionStore {
    static let scrollFractionJavaScript = "Math.max(0, window.scrollY) / Math.max(1, document.documentElement.scrollHeight - window.innerHeight)"
    static let maximumEntries = 200
    static let storageKey = "reader.positions.v2"

    private static let legacyKeyPrefix = "reader.position."
    private static let lock = NSLock()

    /// An opaque snapshot of exactly one position from the pre-SQLite store.
    /// The key is a SHA-256 digest of the canonical path; no local path leaves
    /// this type or the UserDefaults payload.
    struct LegacyPosition: Equatable, Sendable {
        fileprivate enum Storage: Equatable, Sendable {
            case cappedMap
            case individualKey
        }

        let keyHash: String
        let fraction: Double
        fileprivate let lastUsed: TimeInterval?
        fileprivate let storage: Storage
    }

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
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        var entries = loadEntries(from: defaults)
        entries[documentKey(for: documentURL)] = Entry(
            fraction: min(max(fraction, 0), 1),
            lastUsed: now
        )
        save(entries, to: defaults)
    }

    /// Looks up only the requested document. This deliberately does not scan
    /// the capped map or enumerate historical per-document keys.
    static func legacyPosition(
        for documentURL: URL,
        defaults: UserDefaults = .standard
    ) -> LegacyPosition? {
        lock.lock()
        defer { lock.unlock() }
        return unlockedLegacyPosition(for: documentURL, defaults: defaults)
    }

    /// Removes the exact value that was imported. A concurrent update is left
    /// intact rather than being mistaken for the consumed snapshot.
    @discardableResult
    static func removeLegacyPosition(
        _ position: LegacyPosition,
        defaults: UserDefaults = .standard
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return unlockedRemoveLegacyPosition(position, defaults: defaults)
    }

    /// Serializes the final legacy lookup, SQLite importer, and exact-key
    /// removal against in-process position writers. If `importer` throws, the
    /// UserDefaults value remains available for the next open.
    @discardableResult
    static func consumeLegacyPosition(
        for documentURL: URL,
        defaults: UserDefaults = .standard,
        importer: (LegacyPosition) throws -> Void
    ) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let position = unlockedLegacyPosition(for: documentURL, defaults: defaults) else {
            return false
        }
        try importer(position)
        return unlockedRemoveLegacyPosition(position, defaults: defaults)
    }

    private static func unlockedLegacyPosition(
        for documentURL: URL,
        defaults: UserDefaults
    ) -> LegacyPosition? {
        let keyHash = documentKey(for: documentURL)
        if let entry = loadEntries(from: defaults)[keyHash] {
            return LegacyPosition(
                keyHash: keyHash,
                fraction: min(max(entry.fraction, 0), 1),
                lastUsed: entry.lastUsed,
                storage: .cappedMap
            )
        }

        // Very early builds used one hashed key per document. Supporting that
        // format remains lazy because its exact derived key is queried directly.
        let individualKey = legacyKeyPrefix + keyHash
        if let fraction = defaults.object(forKey: individualKey) as? NSNumber {
            return LegacyPosition(
                keyHash: keyHash,
                fraction: min(max(fraction.doubleValue, 0), 1),
                lastUsed: nil,
                storage: .individualKey
            )
        }
        return nil
    }

    private static func unlockedRemoveLegacyPosition(
        _ position: LegacyPosition,
        defaults: UserDefaults
    ) -> Bool {
        switch position.storage {
        case .cappedMap:
            var entries = loadEntries(from: defaults)
            guard let current = entries[position.keyHash],
                  current.fraction == position.fraction,
                  current.lastUsed == position.lastUsed else {
                return false
            }
            entries.removeValue(forKey: position.keyHash)
            save(entries, to: defaults)
            return true
        case .individualKey:
            let key = legacyKeyPrefix + position.keyHash
            guard let current = defaults.object(forKey: key) as? NSNumber,
                  min(max(current.doubleValue, 0), 1) == position.fraction else {
                return false
            }
            defaults.removeObject(forKey: key)
            return true
        }
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

}
