// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

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
        Self.io.sync {} // a write still in flight from the last instance has to land first
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

    /// How much of a score survives from `at` to `now`: half of it per half-life. Shared so
    /// the file-recency term in `Search.rank` decays on the same curve as the store itself.
    public static func decay(since at: Date, now: Date, halfLife: TimeInterval) -> Double {
        pow(0.5, now.timeIntervalSince(at) / halfLife)
    }

    private func decayed(_ entry: Entry, now: Date) -> Double {
        entry.score * Self.decay(since: entry.at, now: now, halfLife: Self.halfLife)
    }

    /// What was learned for this exact term far outweighs a general habit, so a typed
    /// term can always override the globally most-used app.
    ///
    /// `query` must already be lowercased. It is called once per candidate — every app
    /// plus every file hit, on every keystroke — and folding the case in here meant an
    /// allocation per candidate for a string the caller had already folded once.
    public func score(query: String, path: String, now: Date = Date()) -> Double {
        let typed = entries[Self.key(query, path)].map { decayed($0, now: now) } ?? 0
        let overall = entries[Self.key("", path)].map { decayed($0, now: now) } ?? 0
        return typed * 4 + overall
    }

    /// The most-used paths by the global habit alone, best first. The query-keyed entries
    /// are deliberately left out: this answers "what does this person open", not "what does
    /// this term mean", and folding the two together would let one heavily-typed term
    /// dominate a list that is supposed to be about the app.
    public func habitual(limit: Int, now: Date = Date()) -> [String] {
        var scored: [(path: String, score: Double)] = []
        for (key, entry) in entries where key.hasPrefix("\n") { // the empty-query key
            scored.append((String(key.dropFirst()), decayed(entry, now: now)))
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.path)
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
        // Scored once per entry: a comparator that decays on both sides would run `pow`
        // twice per comparison, n log n times.
        let keep = entries
            .map { (key: $0.key, entry: $0.value, score: decayed($0.value, now: now)) }
            .sorted { $0.score > $1.score }
            .prefix(Self.maxEntries * 4 / 5)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.entry) })
    }

    /// One serial queue, so writes land in the order they were made.
    private static let io = DispatchQueue(label: "spotvibe.frecency", qos: .utility)

    /// Encoding and writing up to 5000 entries is not work for the launch animation's thread.
    /// The snapshot is a value copy, so nothing here races the next `record`.
    private func save() {
        let snapshot = entries, url = url
        Self.io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
