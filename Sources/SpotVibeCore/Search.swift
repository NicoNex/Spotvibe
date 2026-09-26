import AppKit
import Foundation
import Observation

// MARK: - Search
// ponytail: no custom file index. Spotlight's index is already built, already live,
// already fast, so NSMetadataQuery reads it directly. Apps are the exception: three
// directory listings beat any query, and they let apps always outrank loose files.

@Observable
public final class Search {
    /// Package caches and build output: thousands of files nobody ever means to open by name.
    /// ponytail: a literal list, because that is what it is. Add a fragment when one annoys you.
    // ponytail: a static, not a module-level global. A global in an executable target
    // is not initialised when a test bundle loads that module, and reads as null memory.
    public static let noisyPathFragments = [
        "/node_modules/", "/.git/", "/go/pkg/mod/", "/.build/", "/.venv/", "/site-packages/",
        "/.cargo/registry/",
        "/Library/", // app support, caches, containers — Spotlight hides all of it too
    ]

    public var text = "" { didSet { guard text != oldValue else { return }; rebuild() } }
    /// Precomputed, because a view body can run many times per frame and filtering
    /// several hundred apps there is pure waste.
    public private(set) var hits: [Hit] = []
    /// How many leading entries of `hits` are drawn as grid cells. NOT "how many are apps":
    /// while browsing, the utilities after this mark are apps too, they just render as rows.
    public private(set) var appCount = 0
    /// How many of those leading app entries are the recently-used shelf, drawn as the first
    /// row with a separator under it. Zero once a term is typed: the ranking already folds
    /// frecency in, so a separate shelf would only repeat what is at the top of the grid.
    public private(set) var recentCount = 0
    /// One grid row's worth, and the single definition of how wide that row is — the view
    /// takes its column count from here, so the shelf can never end up a ragged block.
    public static let recentLimit = 7
    private var fileHits: [Hit] = []
    public var selection = 0
    /// Visible state drives the present/dismiss animation; the panel itself is ordered
    /// out only once that animation has finished.
    public var visible = false
    /// Bumped on every show so the view can re-assert first responder.
    public var focusToken = 0
    /// Mirrors System Settings > Accessibility > Display > Reduce transparency.
    public var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    /// Mirrors System Settings > Accessibility > Display > Reduce motion. The fade stays —
    /// a cross-fade is what that setting asks to be given instead — but the elastic does not.
    public var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// System Settings > Appearance > glass tint slider, 0...1. Scales how much accent
    /// colour the glass takes, so the panel follows the same slider the rest of the OS does.
    public var glassTint = Search.systemGlassTint()
    /// False while the panel is hidden, so the results are not in the view hierarchy at
    /// rest. AppKit's autofill heuristic walks the hosting view's key-view loop, and a few
    /// hundred app cells sitting in it at launch pin the main thread before the panel can
    /// ever be shown.
    public var expanded = false
    /// Set one runloop turn after the panel is ordered in, so the slabs spring from
    /// slightly under their final size to it. The fade itself is the window's alpha.
    public var opened = false
    /// The path being launched. Set for the length of the launch animation only.
    public var launching: String?
    /// Bumped when the system accent changes. NSColor.controlAccentColor is dynamic, but
    /// a SwiftUI Color built from it is resolved once, so the view needs a nudge.
    public var appearanceToken = 0

    private let apps: [Hit]
    private let query = NSMetadataQuery()
    private let warmup = NSMetadataQuery()
    private let frecency: Frecency
    private var startedAt = Date()
    private var lastTerm = ""

    public init(frecency: Frecency = Frecency(),
         apps: [Hit] = Search.installedApps(),
         warm: Bool = true) {
        self.frecency = frecency
        self.apps = apps
        // ponytail: home only. The whole-disk scope dragged in caches, SDKs and system
        // bundles, which cost time and were never what anyone wanted opened. Widen it
        // only if searching outside the home directory turns out to matter.
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        // No sortDescriptors on purpose. Asking Spotlight to sort forces it to fetch the
        // sort attribute for every match — measured at ~650 ms for a broad term against
        // ~140 ms unsorted. Ranking happens locally instead, over the few rows shown.
        query.operationQueue = .main
        query.notificationBatchingInterval = 0.3 // coalesce live-update storms
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] _ in self?.collect() }
        }
        // Through rebuild, not by assigning hits directly: the browse list is not simply
        // `apps` — utilities are split out of the grid and moved to the end.
        rebuild()
        // Opening the metadata-server connection costs ~30 ms once. Paying it at launch
        // keeps it off the first keystroke.
        guard warm else { return }
        warmup.searchScopes = [NSMetadataQueryUserHomeScope]
        warmup.predicate = NSPredicate(format: "kMDItemDisplayName == %@", "\u{1}")
        warmup.start()
        // An NSMetadataQuery must be stopped on the run loop that started it, or it
        // complains on dealloc. The connection it opened stays warm either way.
        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: warmup, queue: .main
        ) { [weak self] _ in self?.warmup.stop() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.appearanceToken += 1
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.glassTint = Search.systemGlassTint()
        }
    }

    // MARK: Results

    /// Apps matching the term, then Spotlight's file hits. Empty term shows every app.
    /// Apps are matched in memory, so they appear on the same keystroke that typed them —
    /// only the file half waits for Spotlight.
    private func rebuild(preserving keepID: String? = nil) {
        if text.isEmpty {
            // The browse grid stays alphabetical: a grid that reshuffles itself is a grid
            // you can no longer point at from memory. Utilities are dropped out of it and
            // listed after, the way Spotlight keeps them out of the way of what you use.
            // Only here: once a term is typed, a utility is just another app and ranks on
            // its name like everything else.
            let byPath = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Only apps still installed: the store keeps a path long after the app is gone.
            let recent = frecency.habitual(limit: Self.recentLimit).compactMap { byPath[$0] }
            // One partition rather than two filters with inverted predicates, which would
            // have to be kept in step by eye. Shelved apps fall out of both, or the same
            // app would appear twice.
            let shelved = Set(recent.map(\.id))
            var grid: [Hit] = []
            var utilities: [Hit] = []
            for app in apps where !shelved.contains(app.id) {
                if app.isUtility { utilities.append(app) } else { grid.append(app) }
            }
            recentCount = recent.count
            appCount = recent.count + grid.count
            hits = recent + grid + utilities
        } else {
            recentCount = 0
            let matching = apps.filter { $0.matches(text) }
            let taken = Set(matching.map(\.id))
            let now = Date()
            let term = text.lowercased()
            let rankedApps = matching
                .map { (hit: $0, rank: rank($0, term: term, now: now)) }
                .sorted { $0.rank > $1.rank }.map(\.hit)
            let rankedFiles = fileHits.filter { !taken.contains($0.id) }
                .map { (hit: $0, rank: rank($0, term: term, now: now)) }
                .sorted { $0.rank > $1.rank }.prefix(40).map(\.hit)
            // Apps stay a contiguous leading block, because the view draws them as a grid.
            appCount = rankedApps.count
            hits = rankedApps + rankedFiles
        }
        selection = keepID.flatMap { id in hits.firstIndex { $0.id == id } } ?? 0
    }

    public var showsWebRow: Bool { !text.isEmpty }
    public var rowCount: Int { hits.count + (showsWebRow ? 1 : 0) }
    public var webRowSelected: Bool { showsWebRow && selection == hits.count }
    public var selectedHit: Hit? { hits.indices.contains(selection) ? hits[selection] : nil }

    public func run(_ term: String) {
        query.stop()
        // Typing forward narrows: the old hits are a superset, so filtering them locally
        // shows a correct interim list instead of blanking the panel on every keystroke.
        // Any other edit invalidates them, and they go — leaving them would let a fast
        // Return open whatever the *previous* term found.
        if term.hasPrefix(lastTerm), !lastTerm.isEmpty {
            fileHits = fileHits.filter { $0.matches(term) }
        } else {
            fileHits = []
        }
        lastTerm = term
        rebuild()
        guard term.count >= 2 else { return }
        startedAt = Date()
        // %@ substitution makes the term a literal, so nothing escapes into the query
        // language. A '*' typed by the user degrades to a wildcard, which is harmless.
        // LIKE, not ==: %@ substitution makes the term a literal, and only LIKE gives the
        // surrounding '*' its wildcard meaning. With == they match asterisks, so nothing hits.
        query.predicate = NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(term)*")
        query.start()
    }

    /// Ranking within a pool, most significant first: what this term has opened before,
    /// then an exact name, then a prefix match over a mere substring, then the shorter
    /// name. Everything unlearned scores the same, so frecency only ever promotes.
    private func rank(_ hit: Hit, term: String, now: Date) -> Double {
        var score = frecency.score(query: text, path: hit.id, now: now) * 1000
        let name = hit.name.lowercased()
        if name == term { score += 50 }
        else if name.hasPrefix(term) { score += 25 }
        // Worth less than a prefix match on purpose: how well the name fits what was typed
        // decides the order, and recency only sorts out the ties underneath it. Same decay
        // as the frecency store, on a shorter half-life — a file touched this week should
        // clearly beat one from last year.
        if let used = hit.used {
            score += 20 * Frecency.decay(since: used, now: now, halfLife: Self.usedHalfLife)
        }
        score += 10 / Double(1 + hit.name.count) // ties break towards the shorter name
        return score
    }

    private static let usedHalfLife: TimeInterval = 14 * 24 * 3600

    /// Called when something is actually opened — the only signal worth learning from.
    public func record(_ hit: Hit) {
        frecency.record(query: text, path: hit.id)
    }

    deinit {
        // Only ever stop a query that was actually started: -stopQuery on an untouched
        // NSMetadataQuery, off the run loop that would have started it, crashes.
        if query.isStarted { query.stop() }
        if warmup.isStarted { warmup.stop() }
    }

    public func reset() {
        query.stop()
        fileHits = []
        lastTerm = ""
        text = ""
        launching = nil
        opened = false
        expanded = false
        rebuild()
    }

    private func collect() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        let previous = selectedHit?.id
        var seen = Set<String>()
        var out: [Hit] = []
        // Unsorted, so this is an arbitrary slice — wide enough that local ranking has
        // something to choose from, small enough to stay cheap: 150 costs ~35 ms of attribute reads, 300 costs ~70 ms.
        for i in 0 ..< query.resultCount where out.count < 150 {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: kMDItemPath as String) as? String,
                  !path.hasSuffix(".app"), // apps come from `apps`, deduped and better ranked
                  !Self.noisyPathFragments.contains(where: path.contains),
                  let name = item.value(forAttribute: kMDItemDisplayName as String) as? String,
                  seen.insert(path).inserted
            else { continue }
            // Read only for the rows actually kept. This is the attribute a sortDescriptor
            // would have made Spotlight fetch for EVERY match, which is what cost ~650 ms;
            // asking for it 150 times here does not.
            let used = item.value(forAttribute: kMDItemLastUsedDate as String) as? Date
                ?? item.value(forAttribute: kMDItemContentModificationDate as String) as? Date
            out.append(Hit(id: path, name: name, used: used))
        }
        fileHits = out
        // A live update must not yank the highlight out from under the arrow keys.
        rebuild(preserving: previous)
        if ProcessInfo.processInfo.environment["SPOTVIBE_TIME"] != nil {
            let ms = Date().timeIntervalSince(startedAt) * 1000
            FileHandle.standardError.write(
                String(format: "query %@: %.0f ms, %d file hits\n", text, ms, out.count).data(using: .utf8)!)
        }
    }

    /// ponytail: a plain directory listing, read once at launch. No FSEvents watcher —
    /// add one only if installing an app mid-session and not finding it becomes a real gripe.
    static func systemGlassTint() -> Double {
        // Absent on a system that does not expose the slider; 0.5 is what it ships at.
        (UserDefaults.standard.object(forKey: "NSGlassTintAmount") as? Double) ?? 0.5
    }

    public static func installedApps() -> [Hit] {
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        let fm = FileManager.default
        var out: [Hit] = []
        var seen = Set<String>()
        for root in roots {
            guard let walker = fm.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "app" {
                walker.skipDescendants()
                guard seen.insert(url.path).inserted else { continue }
                // The name the Finder shows, which is the app's own localisation for the
                // system language when it ships one — "Calendario", not "Calendar". Falls
                // back to the file name for apps that are not localised.
                let shown = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
                let name = (shown as NSString?)?.deletingPathExtension
                    ?? url.deletingPathExtension().lastPathComponent
                out.append(Hit(id: url.path, name: name))
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
