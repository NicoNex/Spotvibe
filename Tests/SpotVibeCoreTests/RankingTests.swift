// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

import Foundation
import Testing

@testable import SpotVibeCore

// Helpers ---------------------------------------------------------------------

private func app(_ name: String) -> Hit { Hit(id: "/Applications/\(name).app", name: name) }

private func utility(_ name: String) -> Hit {
    Hit(id: "/System/Applications/Utilities/\(name).app", name: name)
}

private func scratchURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("spotvibe-test-\(UUID().uuidString).json")
}

/// An isolated store, or a suite would read and rewrite the real preferences.
private func scratchDefaults() -> UserDefaults {
    let name = "spotvibe.tests.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: name)!
    store.removePersistentDomain(forName: name)
    return store
}

/// A Search that never touches Spotlight or the real preferences: a fixed app list, no
/// warm-up query, a scratch store.
@MainActor
private func makeSearch(apps: [Hit], frecency: Frecency = Frecency(url: scratchURL())) -> Search {
    Search(frecency: frecency, apps: apps, warm: false,
           settings: Preferences(store: scratchDefaults()))
}

// Index wrapping --------------------------------------------------------------

@Suite("Selection wrapping")
struct WrapTests {
    @Test("moving back from the first row lands on the last")
    func backwardsFromFirst() {
        #expect(wrap(0, by: -1, count: 5) == 4)
    }

    @Test("moving forward from the last row lands on the first")
    func forwardsFromLast() {
        #expect(wrap(4, by: 1, count: 5) == 0)
    }

    @Test("a delta bigger than the list still lands in range")
    func largeDeltaStaysInRange() {
        for delta in [7, 12, 103] {
            let result = wrap(0, by: delta, count: 5)
            #expect((0 ..< 5).contains(result))
            #expect(result == delta % 5)
        }
    }

    @Test("a large negative delta stays in range too")
    func largeNegativeDelta() {
        #expect(wrap(0, by: -7, count: 5) == 3)
    }

    @Test("an empty list has no index to move to")
    func emptyList() {
        #expect(wrap(0, by: 1, count: 0) == 0)
        #expect(wrap(3, by: -2, count: 0) == 0)
    }
}

// Path display ----------------------------------------------------------------

@Suite("Path abbreviation")
struct PrettyPathTests {
    @Test("the home directory becomes a tilde")
    func home() {
        #expect(prettyPath("/Users/me/notes.txt", home: "/Users/me") == "~/notes.txt")
    }

    @Test("only the leading home directory is abbreviated")
    func onlyTheLeadingOne() {
        #expect(prettyPath("/Users/me/b/Users/me/x", home: "/Users/me") == "~/b/Users/me/x")
    }

    @Test("a sibling whose name starts with the home name is not under home")
    func siblingPrefix() {
        #expect(prettyPath("/Users/me2/x", home: "/Users/me") == "/Users/me2/x")
    }

    @Test("a search term cannot end its own query")
    func termIsEscaped() {
        #expect(Preferences.Engine.google.url(for: "c++ & rust")?.absoluteString
                == "https://www.google.com/search?q=c%2B%2B%20%26%20rust")
    }

    @Test("a path outside home is left alone")
    func outsideHome() {
        #expect(prettyPath("/Applications/Safari.app", home: "/Users/me") == "/Applications/Safari.app")
    }
}

// Frecency --------------------------------------------------------------------

@Suite("Frecency")
struct FrecencyTests {
    @Test("nothing is known before anything is opened")
    func coldStart() {
        let f = Frecency(url: scratchURL())
        #expect(f.score(query: "saf", path: "/A.app") == 0)
    }

    @Test("opening after a term also teaches every prefix of it")
    func prefixLearning() {
        let f = Frecency(url: scratchURL())
        let now = Date()
        f.record(query: "safari", path: "/A.app", now: now)
        for prefix in ["s", "sa", "saf", "safa", "safar", "safari"] {
            #expect(f.score(query: prefix, path: "/A.app", now: now) > 0,
                    "typing \"\(prefix)\" should already suggest it")
        }
    }

    @Test("a longer prefix than was typed is not invented")
    func noOverreach() {
        let f = Frecency(url: scratchURL())
        let now = Date()
        f.record(query: "saf", path: "/A.app", now: now)
        let typed = f.score(query: "saf", path: "/A.app", now: now)
        let longer = f.score(query: "safari", path: "/A.app", now: now)
        #expect(longer < typed, "an unseen longer term falls back to the global habit only")
    }

    @Test("the typed term outweighs the global habit")
    func typedBeatsGlobal() {
        let f = Frecency(url: scratchURL())
        let now = Date()
        f.record(query: "safari", path: "/A.app", now: now)
        #expect(f.score(query: "safari", path: "/A.app", now: now)
            > f.score(query: "unrelated", path: "/A.app", now: now))
    }

    @Test("a score halves over one half-life")
    func decay() {
        let f = Frecency(url: scratchURL())
        let now = Date()
        f.record(query: "saf", path: "/A.app", now: now)
        let fresh = f.score(query: "saf", path: "/A.app", now: now)
        let later = f.score(query: "saf", path: "/A.app", now: now.addingTimeInterval(30 * 24 * 3600))
        #expect(abs(later - fresh / 2) < 0.0001)
    }

    @Test("one recent open beats an older one")
    func recencyBeatsAge() {
        let f = Frecency(url: scratchURL())
        let now = Date()
        let muchLater = now.addingTimeInterval(120 * 24 * 3600)
        f.record(query: "x", path: "/Old.app", now: now)
        f.record(query: "x", path: "/New.app", now: muchLater)
        #expect(f.score(query: "x", path: "/New.app", now: muchLater)
            > f.score(query: "x", path: "/Old.app", now: muchLater))
    }

    @Test("repeated opens accumulate")
    func frequencyAccumulates() {
        let f = Frecency(url: scratchURL())
        let now = Date()
        f.record(query: "x", path: "/Once.app", now: now)
        for _ in 0 ..< 5 { f.record(query: "x", path: "/Often.app", now: now) }
        #expect(f.score(query: "x", path: "/Often.app", now: now)
            > f.score(query: "x", path: "/Once.app", now: now))
    }

    @Test("what was learned survives a restart")
    func persistence() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        Frecency(url: url).record(query: "saf", path: "/A.app", now: now)
        let reopened = Frecency(url: url)
        #expect(reopened.score(query: "saf", path: "/A.app", now: now) > 0)
    }
}

// Ranking and sections --------------------------------------------------------

@Suite("Result ranking")
@MainActor
struct SearchTests {
    private let apps = [app("Calendar"), app("Calculator"), app("Calc"), app("Safari")]

    @Test("an empty term lists every app, in the order given")
    func emptyTerm() {
        let search = makeSearch(apps: apps, frecency: Frecency(url: scratchURL()))
        #expect(search.hits.count == apps.count)
        #expect(search.appCount == apps.count)
        #expect(!search.showsWebRow)
        #expect(search.rowCount == apps.count)
    }

    @Test("the browse screen opens with a shelf of what gets used, most-used first")
    func recentShelf() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let frecency = Frecency(url: url)
        // Safari twice, Calc once: frequency breaks the tie between two same-day opens.
        frecency.record(query: "saf", path: "/Applications/Safari.app")
        frecency.record(query: "", path: "/Applications/Safari.app")
        frecency.record(query: "cal", path: "/Applications/Calc.app")

        let search = makeSearch(apps: apps, frecency: frecency)
        #expect(search.recentCount == 2)
        #expect(search.hits.prefix(2).map(\.name) == ["Safari", "Calc"])
        // Shelved apps leave the grid below, so neither appears twice.
        #expect(search.hits.count == apps.count)
        #expect(search.appCount == apps.count)

        // Typing retires the shelf: ranking already folds frecency in.
        search.text = "cal"
        #expect(search.recentCount == 0)
    }

    @Test("files used more than any app do not starve the shelf")
    func shelfSkipsFiles() {
        let frecency = Frecency(url: scratchURL())
        for n in 0..<Search.recentLimit {
            for _ in 0..<3 { frecency.record(query: "", path: "/Users/me/doc\(n).txt") }
        }
        frecency.record(query: "", path: "/Applications/Safari.app")
        let search = makeSearch(apps: apps, frecency: frecency)
        #expect(search.recentCount == 1)
        #expect(search.hits.first?.name == "Safari")
    }

    @Test("turning recents off drops the shelf on refresh")
    func recentsToggle() {
        let frecency = Frecency(url: scratchURL())
        frecency.record(query: "", path: "/Applications/Safari.app")
        let search = makeSearch(apps: apps, frecency: frecency)
        #expect(search.recentCount == 1)
        search.settings.showRecents = false
        search.refresh()
        #expect(search.recentCount == 0)
        #expect(search.hits.count == apps.count)
    }

    @Test("utilities leave the browse grid, but rank as plain apps once a term is typed")
    func utilitiesOnlySplitWhileBrowsing() {
        let mixed = [utility("Console"), app("Calendar"), utility("Calculator")]
        let search = makeSearch(apps: mixed, frecency: Frecency(url: scratchURL()))
        #expect(search.appCount == 1) // Calendar alone
        #expect(search.hits.map(\.name) == ["Calendar", "Console", "Calculator"])

        // Typing drops the distinction: an exact match wins the top spot even though it
        // is a utility, and both land inside the grid.
        search.text = "calculator"
        #expect(search.appCount == 1)
        #expect(search.hits.first?.name == "Calculator")
    }

    @Test("a term keeps only the apps that contain it")
    func filtering() {
        let search = makeSearch(apps: apps, frecency: Frecency(url: scratchURL()))
        search.text = "cal"
        #expect(search.hits.map(\.name).sorted() == ["Calc", "Calculator", "Calendar"])
    }

    @Test("an exact name outranks a prefix match, which outranks a longer name")
    func matchQuality() {
        let search = makeSearch(apps: apps, frecency: Frecency(url: scratchURL()))
        search.text = "calc"
        #expect(search.hits.map(\.name) == ["Calc", "Calculator"])
    }

    @Test("what was opened for this term before is promoted to the top")
    func learningPromotes() {
        let frecency = Frecency(url: scratchURL())
        let search = makeSearch(apps: apps, frecency: frecency)
        search.text = "cal"
        #expect(search.hits.first?.name == "Calc", "shortest name wins while nothing is learned")

        // Open Calendar for this term a few times, as a user would.
        for _ in 0 ..< 3 { search.record(app("Calendar")) }
        search.text = ""
        search.text = "cal"
        #expect(search.hits.first?.name == "Calendar", "the learned choice now leads")
    }

    @Test("the web row exists exactly when a term does")
    func webRowConsistency() {
        let search = makeSearch(apps: apps, frecency: Frecency(url: scratchURL()))
        #expect(search.rowCount == search.hits.count, "no term, no web row")

        search.text = "zzzzz-nothing"
        #expect(search.hits.isEmpty)
        #expect(search.rowCount == 1, "the web row is the only thing left")
        #expect(search.webRowSelected)

        search.text = "cal"
        #expect(search.rowCount == search.hits.count + 1)
        #expect(!search.webRowSelected, "a real hit is selected instead")
    }

    @Test("selection returns to the top when the term changes")
    func selectionResets() {
        let search = makeSearch(apps: apps, frecency: Frecency(url: scratchURL()))
        search.selection = 3
        search.text = "cal"
        #expect(search.selection == 0)
    }

    @Test("selectedHit never reads past the end of the list")
    func selectionStaysInBounds() {
        let search = makeSearch(apps: apps, frecency: Frecency(url: scratchURL()))
        search.text = "cal"
        search.selection = search.hits.count // the web row
        #expect(search.selectedHit == nil)
        #expect(search.webRowSelected)
    }

    @Test("resetting clears the term and restores the full list")
    func reset() {
        let search = makeSearch(apps: apps, frecency: Frecency(url: scratchURL()))
        search.text = "cal"
        search.reset()
        #expect(search.text.isEmpty)
        #expect(search.hits.count == apps.count)
        #expect(search.selection == 0)
    }
}

// Noise filtering -------------------------------------------------------------

@Suite("Noise filtering")
struct NoiseTests {
    private func isNoisy(_ path: String) -> Bool { Search.isNoisy(path) }

    @Test("developer and library clutter is excluded")
    func excluded() {
        for path in [
            "/Users/me/code/app/node_modules/react/index.js",
            "/Users/me/Library/Caches/whatever.txt",
            "/Users/me/go/pkg/mod/cache/x",
            "/Users/me/project/.build/debug/thing",
            "/Users/me/.venv/lib/site-packages/x.py",
            "/Users/me/env/lib/python3.13/idlelib/calltip.py",
            "/Users/me/env/lib/python3.13/__pycache__/calendar.cpython-313.pyc",
        ] {
            #expect(isNoisy(path), "\(path) should be filtered out")
        }
    }

    @Test("real documents are kept")
    func kept() {
        for path in [
            "/Users/me/Documents/taxes.pdf",
            "/Users/me/Desktop/screenshot.png",
            "/Users/me/code/app/src/main.swift",
        ] {
            #expect(!isNoisy(path), "\(path) should survive filtering")
        }
    }
}

@Suite("Hot-key recording")
struct RecordingTests {
    @Test("recording is announced, so the controller can let go of the chord")
    func announced() {
        let settings = Preferences(store: scratchDefaults())
        // What the controller sees on each re-bind: whether it must hold the chord or not.
        var seen: [Bool] = []
        settings.onHotKeyChanged = { seen.append(settings.recording) }

        settings.recording = true
        // The chord already bound, pressed again to confirm itself: it only ever reaches the
        // recorder because the controller released it on the `true` above.
        settings.setHotKey(code: settings.hotKeyCode,
                           modifiers: settings.hotKeyModifiers,
                           label: settings.hotKeyLabel)
        settings.recording = false

        #expect(seen.first == true)
        #expect(seen.last == false)
        #expect(settings.hotKeyLabel == "⌥Space")
    }
}

@Suite("Window opacity")
struct OpacityTests {
    private func settings(_ opacity: Double) -> Preferences {
        let settings = Preferences(store: scratchDefaults())
        settings.opacity = opacity
        return settings
    }

    @Test("within each material the scrim grows with the slider")
    func scrimGrowsWithinAMaterial() {
        for range in [0.0 ..< Preferences.clearBelow, Preferences.clearBelow ..< 1.0] {
            let steps = stride(from: range.lowerBound, to: range.upperBound, by: 0.01).map { settings($0).scrim }
            #expect(zip(steps, steps.dropFirst()).allSatisfy { $1 >= $0 })
        }
    }

    @Test("at the material switch the scrim eases off, because the regular glass is the heavier one")
    func scrimEasesAtTheSwitch() {
        let below = settings(Preferences.clearBelow - 0.001).scrim
        let above = settings(Preferences.clearBelow).scrim
        #expect(above < below && below - above < 0.15)
    }

    @Test("the clear material is the low end only")
    func clearAtTheLowEnd() {
        #expect(settings(0).usesClearGlass)
        #expect(!settings(0.5).usesClearGlass)
    }

    @Test("a stored three-step thickness becomes the matching opacity")
    func legacyThickness() {
        let store = scratchDefaults()
        store.set("thin", forKey: "thickness")
        #expect(Preferences(store: store).usesClearGlass)
        let thick = scratchDefaults()
        thick.set("thick", forKey: "thickness")
        #expect(Preferences(store: thick).scrim > 0.3)
        #expect(Preferences(store: scratchDefaults()).opacity == Preferences.defaultOpacity)
    }

    @Test("a drag near the middle sticks to the default, and only there")
    func snapsToTheDefault() {
        #expect(Preferences.snapped(0.5 + Preferences.snapRange / 2) == Preferences.defaultOpacity)
        #expect(Preferences.snapped(0.5 - Preferences.snapRange / 2) == Preferences.defaultOpacity)
        #expect(Preferences.snapped(0.5 + Preferences.snapRange * 2) == 0.5 + Preferences.snapRange * 2)
        #expect(Preferences.snapped(0.1) == 0.1)
    }
}
