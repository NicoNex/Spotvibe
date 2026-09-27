// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

import Foundation

// MARK: - Model

public struct Hit: Identifiable, Hashable {
    public init(id: String, name: String, used: Date? = nil) {
        self.id = id
        self.name = name
        self.used = used
        // Derived once here, not per call: `matches` runs over every app on every
        // keystroke, and computing it there cost two NSString bridges a time.
        fileName = ((id as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public let id: String // absolute path
    public let name: String
    /// When the file was last opened, as Spotlight recorded it. Nil for apps, which rank
    /// on the frecency this app learned itself rather than on the system's account.
    public let used: Date?
    /// `isDirectory` spelled out: the one-argument initialiser stats the path to decide,
    /// and this is called per launch, not per frame, but there is no reason to pay it.
    public var url: URL { URL(fileURLWithPath: id, isDirectory: false) }
    /// The name on disk, under whatever the system chose to display. On an Italian Mac
    /// Calendar.app shows as "Calendario", and someone typing "calendar" still has to find
    /// it — so both names are matched.
    public let fileName: String

    public func matches(_ term: String) -> Bool {
        name.localizedCaseInsensitiveContains(term) || fileName.localizedCaseInsensitiveContains(term)
    }
    /// Disk Utility, Terminal, Console and the rest live in a Utilities folder, and that
    /// folder is the whole convention — there is no Info.plist key for "this is a utility".
    /// Spotlight keeps them out of the app grid too, so they go to the end under "other".
    public var isUtility: Bool { id.contains("/Utilities/") }
}

/// Wraps an index in 0..<count for any delta, positive or negative.
public func wrap(_ index: Int, by delta: Int, count: Int) -> Int {
    count <= 0 ? 0 : ((index + delta % count) + count) % count
}

/// Anchored at the start: a plain replace would rewrite a second "/Users/me" mid-path.
public func prettyPath(_ path: String, home: String = NSHomeDirectory()) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
