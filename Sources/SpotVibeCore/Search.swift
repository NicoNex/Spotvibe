// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

import AppKit
import Foundation
import Observation

// MARK: - Search
// ponytail: no custom file index. Spotlight's index is already built, already live,
// already fast, so NSMetadataQuery reads it directly. Apps are the exception: three
// directory listings beat any query, and they let apps always outrank loose files.

private final class WeakSearch {
    weak var search: Search?
    init(_ search: Search) { self.search = search }
}

@MainActor @Observable
public final class Search {
    /// Package caches and build output: thousands of files nobody ever means to open by name.
    /// ponytail: a literal list, because that is what it is. Add a fragment when one annoys you.
    // ponytail: a static, not a module-level global. A global in an executable target
    // is not initialised when a test bundle loads that module, and reads as null memory.
    public nonisolated static let noisyPathFragments = [
        "/node_modules/", "/.git/", "/go/pkg/mod/", "/.build/", "/.venv/", "/site-packages/",
        "/.cargo/registry/", "/__pycache__/",
        // Any interpreter's own standard library, wherever it was installed from: idlelib,
        // encodings, the lot. Typing three letters otherwise fills the list with modules.
        "/lib/python3",
        "/Library/", // app support, caches, containers — Spotlight hides all of it too
    ]

    /// The one definition of the rule. Public so the tests exercise this and not a copy
    /// of it — a suite that re-implements the predicate passes whatever the predicate does.
    public nonisolated static func isNoisy(_ path: String) -> Bool {
        noisyPathFragments.contains(where: path.contains)
    }

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
    /// What Spotlight found, with the term it was found for. One fact, so it can never be
    /// updated without the other: `run` narrows these by prefix and needs both.
    private var files: (term: String, hits: [Hit]) = ("", [])
    public var selection = 0
    /// Visible state drives the present/dismiss animation; the panel itself is ordered
    /// out only once that animation has finished.
    public var visible = false
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
    /// The whole panel becomes the settings screen, which is why this lives here rather
    /// than in the view: hiding the panel has to clear it.
    public var showingSettings = false
    /// The path being launched. Set for the length of the launch animation only.
    public var launching: String?
    /// The pending launch, so `reset()` can cancel it instead of the launch checking, when
    /// it finally fires, whether anyone still wants it.
    public var launchTask: Task<Void, Never>?
    /// Bumped when the system accent changes. NSColor.controlAccentColor is dynamic, but
    /// a SwiftUI Color built from it is resolved once, so the view needs a nudge.
    public var appearanceToken = 0

    private var apps: [Hit]
    /// Built once beside `apps`: both are immutable, and this was being rebuilt — a
    /// dictionary plus a throwaway array of several hundred tuples — every time the field
    /// was emptied or the panel was hidden.
    private var appsByPath: [String: Hit]
    @ObservationIgnored private var stream: FSEventStreamRef?
    private let query = NSMetadataQuery()
    private let frecency: Frecency
    private var startedAt = Date()

    public let settings: Preferences

    public init(frecency: Frecency = Frecency(),
         apps: [Hit] = Search.installedApps(),
         warm: Bool = true,
         settings: Preferences = Preferences()) {
        self.frecency = frecency
        self.apps = apps
        appsByPath = Search.index(apps)
        self.settings = settings
        // Home by default: the whole-disk scope drags in caches, SDKs and system bundles,
        // which cost time and are never what anyone meant to open by name. Settings can
        // widen it, and `run` re-reads it on every search.
        query.searchScopes = [settings.scope.metadataScope]
        // No sortDescriptors on purpose. Asking Spotlight to sort forces it to fetch the
        // sort attribute for every match — measured at ~650 ms for a broad term against
        // ~140 ms unsorted. Ranking happens locally instead, over the few rows shown.
        query.operationQueue = .main
        // One gather per search, then the query is stopped (see below): a live query keeps
        // re-reading up to 150 results on the main thread for every index change on the
        // disk, and nobody watches the list long enough for a new file to matter.
        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.collect()
                self.query.stop()
            }
        }
        // Through rebuild, not by assigning hits directly: the browse list is not simply
        // `apps` — utilities are split out of the grid and moved to the end.
        rebuild()
        guard warm else { return }
        watchAppRoots()
        observeSystemSettings()
    }

    /// Accessibility, accent and the glass-tint slider. Observed only to be noted: while the
    /// panel is hidden nothing draws, so a change is applied when it is next shown, not
    /// re-rendered into a window nobody can see.
    private var systemStale = false

    private func observeSystemSettings() {
        for (center, name) in [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification),
            (NotificationCenter.default, NSColor.systemColorsDidChangeNotification),
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    if self.visible { self.syncSystem() } else { self.systemStale = true }
                }
            }
        }
    }

    /// Reads the system's appearance settings and publishes only what differs: @Observable
    /// notifies on every assignment, equal or not, and each notification is a full
    /// re-evaluation of a panel full of glass. Called when the panel is shown.
    public func syncSystem() {
        let transparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let motion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let tint = Search.systemGlassTint()
        if transparency != reduceTransparency { reduceTransparency = transparency }
        if motion != reduceMotion { reduceMotion = motion }
        if tint != glassTint { glassTint = tint }
        if systemStale { systemStale = false; appearanceToken += 1 }
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
            // Only apps still installed: the store keeps a path long after the app is gone,
            // and files opened through the panel are in the same habit list. Both are
            // dropped here, which is why more than a shelf's worth is asked for — taking
            // exactly seven and then discarding some left the shelf short.
            let recent = settings.showRecents
                ? frecency.habitual(limit: Self.recentLimit * 4)
                    .compactMap { appsByPath[$0] }.prefix(Self.recentLimit)
                : []
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
            hits = Array(recent) + grid + utilities
        } else {
            recentCount = 0
            let now = Date()
            let term = text.lowercased()
            let rankedApps = ranked(apps, term: term, now: now) { $0.matches(text) }
            let taken = Set(rankedApps.map(\.id))
            // `$0.matches(text)` and not merely "not already an app hit": run() narrows
            // the interim hits, but it is debounced by 120 ms, and for that window this is
            // the only thing standing between a fast Return and a file the term no longer
            // matches at all.
            let rankedFiles = Array(ranked(files.hits, term: term, now: now) {
                !taken.contains($0.id) && $0.matches(text)
            }.prefix(40))
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
        let had = files.hits.count
        let narrowed = term.hasPrefix(files.term) && !files.term.isEmpty
        files = (term, narrowed ? files.hits.filter { $0.matches(term) } : [])
        // `text`'s own didSet has already rebuilt for this term. Doing it again is only
        // worth a full re-rank and re-sort of every app when the file half actually moved,
        // which for a term under two characters it never has.
        if files.hits.count != had { rebuild() }
        guard term.count >= 2 else { return }
        startedAt = Date()
        // %@ substitution makes the term a literal, so nothing escapes into the query
        // language. A '*' typed by the user degrades to a wildcard, which is harmless.
        // LIKE, not ==: %@ substitution makes the term a literal, and only LIKE gives the
        // surrounding '*' its wildcard meaning. With == they match asterisks, so nothing hits.
        query.predicate = NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(term)*")
        query.searchScopes = [settings.scope.metadataScope]
        query.start()
    }

    /// Republishes the list against the current preferences, keeping the highlight where
    /// it was. The recents shelf is built in `rebuild`, so turning it off has to run this
    /// or nothing changes until the panel is next opened.
    public func refresh() {
        rebuild(preserving: selectedHit?.id)
    }

    /// The scope changed under a live query. Whatever it had gathered is for the old scope,
    /// so it is thrown away and the same term is asked again.
    public func rescope() {
        guard !text.isEmpty else { return }
        invalidateFileHits()
        run(text)
    }

    private func invalidateFileHits() { files = ("", []) }

    /// For `hide()`: a query must not outlive the panel it was feeding.
    public func stopQuery() { query.stop() }

    /// Filter, score and sort in one pass. Written out rather than chained because the
    /// chained form allocated an array for the filter, another for the scored tuples and a
    /// third for the sorted result — three copies of the app list on every keystroke.
    private func ranked(_ pool: [Hit], term: String, now: Date,
                        where include: (Hit) -> Bool) -> [Hit] {
        var scored: [(hit: Hit, rank: Double)] = []
        scored.reserveCapacity(pool.count)
        for hit in pool where include(hit) {
            scored.append((hit, rank(hit, term: term, now: now)))
        }
        scored.sort { $0.rank > $1.rank }
        return scored.map(\.hit)
    }

    /// Ranking within a pool, most significant first: what this term has opened before,
    /// then an exact name, then a prefix match over a mere substring, then the shorter
    /// name. Everything unlearned scores the same, so frecency only ever promotes.
    private func rank(_ hit: Hit, term: String, now: Date) -> Double {
        var score = frecency.score(query: term, path: hit.id, now: now) * 1000
        // Both names, the same pair `matches` admits. Scoring the displayed name alone
        // meant an app found through its name on disk — Impostazioni di Sistema, matched by
        // typing "system" — earned no bonus at all and was ordered purely on length.
        let name = hit.nameLower
        let onDisk = hit.fileNameLower
        if name == term || onDisk == term { score += 50 }
        else if name.hasPrefix(term) || onDisk.hasPrefix(term) { score += 25 }
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
    #if DEBUG
    /// Read once. `ProcessInfo.environment` builds the whole dictionary on every access,
    /// and this was tested once per Spotlight batch. Debug builds only: `make run`.
    private static let timing = ProcessInfo.processInfo.environment["SPOTVIBE_TIME"] != nil
    #endif

    /// Called when something is actually opened — the only signal worth learning from.
    public func record(_ hit: Hit) {
        frecency.record(query: text, path: hit.id)
    }

    deinit {
        // Only ever stop a query that was actually started: -stopQuery on an untouched
        // NSMetadataQuery, off the run loop that would have started it, crashes.
        if query.isStarted { query.stop() }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    public func reset() {
        query.stop()
        invalidateFileHits()
        text = ""
        launching = nil
        showingSettings = false
        launchTask?.cancel()
        launchTask = nil
        expanded = false
        rebuild()
    }

    private func collect() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        let previous = selectedHit?.id
        // `selectedHit` is nil when the web row is highlighted, so preserving by id alone
        // dropped that selection back to 0 on every Spotlight batch — and a batch arrives
        // every 0.3 s while a query is live. Return then launched an app instead of
        // opening the browser.
        let wasWebRow = webRowSelected
        var seen = Set<String>()
        var out: [Hit] = []
        // Unsorted, so this is an arbitrary slice — wide enough that local ranking has
        // something to choose from, small enough to stay cheap: 150 costs ~35 ms of attribute reads, 300 costs ~70 ms.
        // `while`, not `for … where`: the filtered form kept walking every remaining
        // index after the slice was full, and a broad term has tens of thousands.
        var i = 0
        while i < query.resultCount, out.count < 150 {
            defer { i += 1 }
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: kMDItemPath as String) as? String,
                  !path.hasSuffix(".app"), // apps come from `apps`, deduped and better ranked
                  !Self.isNoisy(path),
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
        files.hits = out
        // A live update must not yank the highlight out from under the arrow keys.
        rebuild(preserving: previous)
        if wasWebRow { selection = hits.count }
        #if DEBUG
        if Self.timing {
            let ms = Date().timeIntervalSince(startedAt) * 1000
            FileHandle.standardError.write(
                String(format: "query %@: %.0f ms, %d file hits\n", text, ms, out.count).data(using: .utf8)!)
        }
        #endif
    }

    nonisolated static func systemGlassTint() -> Double {
        // Absent on a system that does not expose the slider; 0.5 is what it ships at.
        (UserDefaults.standard.object(forKey: "NSGlassTintAmount") as? Double) ?? 0.5
    }

    private nonisolated static let appRoots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]

    private static func index(_ apps: [Hit]) -> [String: Hit] {
        Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// FSEvents is recursive, so one stream covers every subfolder of the three roots. Events
    /// are per directory, so anything under `Foo.app/` — updaters write there all day — is
    /// dropped and only an install or removal reaches `relistApps`. The 5 s latency lets the
    /// kernel coalesce a burst into one wakeup.
    /// ponytail: a root that does not exist yet (~/Applications) is not noticed once created.
    private func watchAppRoots() {
        // The stream retains the box and releases it on invalidation, and the box holds
        // `Search` weakly: a callback already queued when `Search` goes away finds nil
        // instead of freed memory.
        let box = Unmanaged.passRetained(WeakSearch(self))
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil,
            release: { Unmanaged<WeakSearch>.fromOpaque($0!).release() },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            let changed = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
            guard changed.contains(where: { !$0.contains(".app/") }) else { return }
            let search = Unmanaged<WeakSearch>.fromOpaque(info!).takeUnretainedValue().search
            MainActor.assumeIsolated { search?.relistApps() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, Search.appRoots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else {
            box.release() // the stream never took ownership
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// The walk asks LaunchServices for a name per bundle, so it runs off the main thread
    /// and only the finished list is published — nothing for the hotkey path to wait on.
    private func relistApps() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Search.installedApps()
            DispatchQueue.main.async {
                guard let self, found != self.apps else { return }
                self.apps = found
                self.appsByPath = Search.index(found)
                self.rebuild(preserving: self.selectedHit?.id)
            }
        }
    }

    /// A plain directory listing of the app folders.
    public nonisolated static func installedApps() -> [Hit] {
        let roots = appRoots
        let fm = FileManager.default
        var out: [Hit] = []
        var seen = Set<String>()
        for root in roots {
            guard let walker = fm.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                // Not .skipsHiddenFiles: on macOS 26 Safari is a symlink into a cryptex that
                // carries the `hidden` flag, and that option dropped it from the list.
                options: [.skipsPackageDescendants]
            ) else { continue }
            for case let listed as URL in walker where listed.pathExtension == "app"
                && !listed.lastPathComponent.hasPrefix(".") {
                walker.skipDescendants()
                // The real path: through the symlink the icon carries an alias arrow, and
                // the same app reached by two routes would be listed twice.
                let url = listed.resolvingSymlinksInPath()
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
