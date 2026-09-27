// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

import AppKit
import Foundation
import Observation

// MARK: - Settings
// ponytail: UserDefaults, not a settings file of our own. It is already there, already
// atomic, already survives a crash, and these are a handful of scalars.

@Observable
public final class Preferences {
    /// How much of the backdrop the glass lets through. The system has no thickness knob —
    /// `.clear` and `.regular` are the whole family — so the middle of the three is the
    /// material on its own and the outer two add or remove a scrim over it.
    public enum Thickness: String, CaseIterable, Identifiable {
        case thin, medium, thick
        public var id: String { rawValue }
    }

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

        public func url(for term: String) -> URL? {
            let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
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
        thickness = Self.stored(store, Key.thickness, or: .medium)
        scope = Self.stored(store, Key.scope, or: .home)
        engine = Self.stored(store, Key.engine, or: .duckduckgo)
        showRecents = store.object(forKey: Key.showRecents) as? Bool ?? true
        // 49 is kVK_Space and 2048 is Carbon's optionKey — spelled as numbers because
        // Carbon.HIToolbox is not available to this module.
        hotKeyCode = store.object(forKey: Key.hotKeyCode) as? UInt32 ?? 49
        hotKeyModifiers = store.object(forKey: Key.hotKeyModifiers) as? UInt32 ?? 2048
        hotKeyLabel = store.string(forKey: Key.hotKeyLabel) ?? "⌥Space"
    }

    private static func stored<T: RawRepresentable>(_ store: UserDefaults, _ key: String,
                                                    or fallback: T) -> T where T.RawValue == String {
        T(rawValue: store.string(forKey: key) ?? "") ?? fallback
    }

    private enum Key {
        static let thickness = "thickness"
        static let scope = "scope"
        static let engine = "engine"
        static let showRecents = "showRecents"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
    }

    public var thickness: Thickness { didSet { store.set(thickness.rawValue, forKey: Key.thickness) } }
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
    public var recording = false { didSet { onRecordingChanged?(recording) } }

    public var onHotKeyChanged: (() -> Void)?
    public var onScopeChanged: (() -> Void)?
    public var onRecentsChanged: (() -> Void)?
    public var onRecordingChanged: ((Bool) -> Void)?

    /// Both halves land together, so the handler runs once with a consistent pair.
    public func setHotKey(code: UInt32, modifiers: UInt32, label: String) {
        hotKeyCode = code
        hotKeyLabel = label
        hotKeyModifiers = modifiers // last, because its didSet is what re-registers
    }
}
