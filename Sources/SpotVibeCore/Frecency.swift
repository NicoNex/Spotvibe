import Foundation

// MARK: - Frecency
// Frequency and recency folded into one number, the approach Firefox's address bar and
// zoxide both use: every open adds 1 to a score that halves every `halfLife`. Something
// opened constantly last year loses, eventually, to something opened twice last week.
//
// The learning is keyed by what was *typed*, and recorded against every prefix of it, so
// opening Safari after typing "safari" also teaches "s", "sa" and "saf". Next time, the
// first keystroke already puts Safari on top.

public final class Frecency {
    private struct Entry: Codable {
        var score: Double
        var at: Date
    }

    private static let halfLife: TimeInterval = 30 * 24 * 3600
    private static let maxEntries = 5000

    private var entries: [String: Entry] = [:]
    private let url: URL

    public init(url: URL = Frecency.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored
        }
    }

    public static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotVibe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("frecency.json")
    }

    private static func key(_ query: String, _ path: String) -> String { query + "\n" + path }

    private func decayed(_ entry: Entry, now: Date) -> Double {
        entry.score * pow(0.5, now.timeIntervalSince(entry.at) / Self.halfLife)
    }

    /// What was learned for this exact term far outweighs a general habit, so a typed
    /// term can always override the globally most-used app.
    public func score(query: String, path: String, now: Date = Date()) -> Double {
        let typed = entries[Self.key(query.lowercased(), path)].map { decayed($0, now: now) } ?? 0
        let overall = entries[Self.key("", path)].map { decayed($0, now: now) } ?? 0
        return typed * 4 + overall
    }

    public func record(query: String, path: String, now: Date = Date()) {
        let term = query.lowercased()
        var keys = [""] // the global habit, learned regardless of what was typed
        if !term.isEmpty {
            keys += (1 ... term.count).map { String(term.prefix($0)) }
        }
        for key in keys {
            let full = Self.key(key, path)
            let carried = entries[full].map { decayed($0, now: now) } ?? 0
            entries[full] = Entry(score: carried + 1, at: now)
        }
        prune(now: now)
        save()
    }

    private func prune(now: Date) {
        guard entries.count > Self.maxEntries else { return }
        let keep = entries
            .sorted { decayed($0.value, now: now) > decayed($1.value, now: now) }
            .prefix(Self.maxEntries * 4 / 5)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    // ponytail: synchronous write of a file measured in kilobytes, on an action that
    // already launches an app. Move it off the main thread if it ever shows up in a trace.
    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
