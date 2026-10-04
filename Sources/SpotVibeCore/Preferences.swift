// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

// MARK: - Settings
// ponytail: UserDefaults, not a settings file of our own. It is already there, already
// atomic, already survives a crash, and these are a handful of scalars.

@Observable
public final class Preferences {
    /// Spotlight's own scope constants. Home is the default because the whole-disk scope
    /// drags in caches, SDKs and system bundles that nobody means to open by name.
    public enum Scope: String, CaseIterable, Identifiable {
        case home, everywhere
        public var id: String { rawValue }
        public var metadataScope: String {
            self == .home ? NSMetadataQueryUserHomeScope : NSMetadataQueryLocalComputerScope
        }
    }

    /// macOS exposes no API for the browser's chosen engine, so the choice has to be ours.
    public enum Engine: String, CaseIterable, Identifiable {
        case duckduckgo, google, bing, ecosia
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .duckduckgo: "DuckDuckGo"
            case .google: "Google"
            case .bing: "Bing"
            case .ecosia: "Ecosia"
            }
        }

        private static let unreserved = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))

        public func url(for term: String) -> URL? {
            // Unreserved characters only: .urlQueryAllowed lets & + = # through, and
            // "c++ & rust" would then end the query at the ampersand.
            let q = term.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
            switch self {
            case .duckduckgo: return URL(string: "https://duckduckgo.com/?q=\(q)")
            case .google: return URL(string: "https://www.google.com/search?q=\(q)")
            case .bing: return URL(string: "https://www.bing.com/search?q=\(q)")
            case .ecosia: return URL(string: "https://www.ecosia.org/search?q=\(q)")
            }
        }
    }

    private let store: UserDefaults

    public init(store: UserDefaults = .standard) {
        self.store = store
        // The three-step "thickness" this replaced is read once, so nobody's panel changes.
        opacity = store.object(forKey: Key.opacity) as? Double
            ?? ["thin": 0.25, "thick": 0.9][store.string(forKey: Key.thickness) ?? ""] ?? Self.defaultOpacity
        scope = Self.stored(store, Key.scope, or: .home)
        engine = Self.stored(store, Key.engine, or: .duckduckgo)
        showRecents = store.object(forKey: Key.showRecents) as? Bool ?? true
        hotKeyCode = store.object(forKey: Key.hotKeyCode) as? UInt32 ?? UInt32(kVK_Space)
        hotKeyModifiers = store.object(forKey: Key.hotKeyModifiers) as? UInt32 ?? UInt32(optionKey)
        hotKeyLabel = store.string(forKey: Key.hotKeyLabel) ?? "⌥Space"
    }

    private static func stored<T: RawRepresentable>(_ store: UserDefaults, _ key: String,
                                                    or fallback: T) -> T where T.RawValue == String {
        T(rawValue: store.string(forKey: key) ?? "") ?? fallback
    }

    private enum Key {
        static let thickness = "thickness" // legacy, only read for the migration
        static let opacity = "opacity"
        static let scope = "scope"
        static let engine = "engine"
        static let showRecents = "showRecents"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
    }

    /// How much of the backdrop the window hides, 0 (most of it shows through) to 1 (least).
    /// The system has no such knob — `.clear` and `.regular` are the whole family — so the
    /// slider picks the clear material at its low end, the regular one from there up, and a
    /// scrim over either. The middle is the default and the slider snaps to it.
    public var opacity: Double { didSet { store.set(opacity, forKey: Key.opacity) } }

    public static let defaultOpacity = 0.5
    /// How close a drag has to come to the middle for it to stick there.
    public static let snapRange = 0.04

    public static func snapped(_ value: Double) -> Double {
        abs(value - defaultOpacity) < snapRange ? defaultOpacity : value
    }

    /// Below this the glass is the clear material, above it the regular one.
    public static let clearBelow = 0.3
    public var usesClearGlass: Bool { opacity < Self.clearBelow }

    /// Opacity of the window-background fill under the glass. Clear glass takes up to 0.12;
    /// the regular glass is already the heavier material, so the scrim eases back to nothing
    /// as it takes over, then grows quadratically — fine control around the default, where
    /// the regular glass on its own is the look the app shipped with, and a firm one at the top.
    public var scrim: Double {
        if usesClearGlass { return 0.12 * opacity / Self.clearBelow }
        let t = (opacity - Self.clearBelow) / (1 - Self.clearBelow)
        return 0.5 * t * t
    }
    public var engine: Engine { didSet { store.set(engine.rawValue, forKey: Key.engine) } }
    /// Announced like the scope is: the shelf is built inside the search's rebuild, so
    /// without telling it, turning this off changed nothing until the panel was next
    /// opened — the row stayed on screen and kept shifting every index behind it.
    public var showRecents: Bool {
        didSet {
            store.set(showRecents, forKey: Key.showRecents)
            onRecentsChanged?()
        }
    }

    /// Changing the scope invalidates whatever the live query was gathering, so the search
    /// has to be told rather than picking it up on the next keystroke.
    public var scope: Scope {
        didSet {
            store.set(scope.rawValue, forKey: Key.scope)
            onScopeChanged?()
        }
    }

    public var hotKeyCode: UInt32 { didSet { store.set(hotKeyCode, forKey: Key.hotKeyCode) } }
    public var hotKeyLabel: String { didSet { store.set(hotKeyLabel, forKey: Key.hotKeyLabel) } }

    /// Carbon modifier mask. Re-registering is the controller's job — it owns the Carbon
    /// handler — so the change is announced rather than acted on here.
    public var hotKeyModifiers: UInt32 {
        didSet {
            store.set(hotKeyModifiers, forKey: Key.hotKeyModifiers)
            onHotKeyChanged?()
        }
    }

    /// True while the settings screen is waiting for a chord. The controller releases the
    /// global hotkey for as long as it is: a registered hotkey is consumed by the system
    /// before any app sees the keys, so pressing the CURRENT chord to confirm it would
    /// reach the toggle and close the panel instead of being recorded.
    public var recording = false { didSet { onHotKeyChanged?() } }

    /// Fired when the chord or the recording state changes: both end in the same re-bind.
    public var onHotKeyChanged: (() -> Void)?
    public var onScopeChanged: (() -> Void)?
    public var onRecentsChanged: (() -> Void)?

    /// Both halves land together, so the handler runs once with a consistent pair.
    public func setHotKey(code: UInt32, modifiers: UInt32, label: String) {
        hotKeyCode = code
        hotKeyLabel = label
        hotKeyModifiers = modifiers // last, because its didSet is what re-registers
    }
}
