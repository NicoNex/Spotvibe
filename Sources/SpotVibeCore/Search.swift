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
    /// How many leading entries of `hits` are apps. They render as a grid, the rest as a list.
    public private(set) var appCount = 0
    private var fileHits: [Hit] = []
    public var selection = 0
    /// Visible state drives the present/dismiss animation; the panel itself is ordered
    /// out only once that animation has finished.
    public var visible = false
    /// Bumped on every show so the view can re-assert first responder.
    public var focusToken = 0
    /// Mirrors System Settings > Accessibility > Display > Reduce transparency.
    public var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    /// System Settings > Appearance > glass tint slider, 0...1. Scales how much accent
    /// colour the glass takes, so the panel follows the same slider the rest of the OS does.
    public var glassTint = Search.systemGlassTint()
    /// False while the panel is hidden, so the results are not in the view hierarchy at
    /// rest. AppKit's autofill heuristic walks the hosting view's key-view loop, and a few
    /// hundred app cells sitting in it at launch pin the main thread before the panel can
    /// ever be shown.
    public var expanded = false
    /// Drives the gap between the field and the results. False overlaps them into a single
    /// droplet; true is the resting gap. Everything liquid comes out of animating this: the
    /// union bridge the system draws between two glass shapes thins as they pull apart, and
    /// snaps when the gap passes the container's merge distance.
    public var separated = false
    /// Width of this display's notch, 0 when it has none. The drop is born the width of
    /// the notch, so it reads as having come out of it.
    public var notchWidth: CGFloat = 0
    /// True from the snap until the drop has braked: air resistance draws it out into a
    /// teardrop while it is moving fast.
    public var stretched = false
    /// Set when it comes to rest in mid-air. Releasing the stretch against a barely damped
    /// spring is the wobble — the mass above falls onto the mass below and rings out.
    public var arrived = false
    /// A stationary drop that is perfectly still reads as a frozen bug, so it breathes.
    public var breathing = false
    /// The exit: once the two have flowed back into one drop, it swells for an instant and
    /// bursts. A bubble does not fade — it is there and then it is not — so this drives a
    /// quick swell and the window's alpha is cut rather than faded.
    public var popping = false
    /// First phase of the entrance: the drop hangs from the notch, stretched by its own
    /// weight, then falls and rounds out where the panel will be.
    public var dripped = false
    /// Second phase of the entrance: the two droplets stretch into the search bar and the
    /// panel. Kept apart from `separated` so the split reads first and the shapes after —
    /// driven together, the drops are already slabs by the time the gap opens.
    public var shaped = false
    /// The results' contents fade in once the two bodies have finished separating.
    /// Animating the glass shapes while they are full of icons and text reads as busy;
    /// empty slabs separating, then content arriving, reads as liquid.
    public var contentVisible = false
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
        hits = apps
        appCount = apps.count
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
            // you can no longer point at from memory.
            hits = apps
            appCount = apps.count
        } else {
            let matching = apps.filter { $0.name.localizedCaseInsensitiveContains(text) }
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

    /// Grid while browsing every app, list the moment a term narrows things down.
    public var grid: Bool { text.isEmpty }
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
            fileHits = fileHits.filter { $0.name.localizedCaseInsensitiveContains(term) }
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
        score += 10 / Double(1 + hit.name.count) // ties break towards the shorter name
        return score
    }

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
        dripped = false
        popping = false
        stretched = false
        arrived = false
        breathing = false
        separated = false
        shaped = false
        contentVisible = false
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
            out.append(Hit(id: path, name: name))
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
                out.append(Hit(id: url.path, name: url.deletingPathExtension().lastPathComponent))
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
