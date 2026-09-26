// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

import AppKit

/// Looked up in the .app bundle's `.lproj` folders. The key IS the English text, so a
/// binary run outside the bundle — `swift run`, a test host — still shows English rather
/// than a raw key.
func loc(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// ponytail: unbounded process-lifetime cache. A few hundred 32 KB icons is nothing,
/// and NSWorkspace.icon(forFile:) hits the disk — far too slow to call from a view body.
enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func icon(forPath path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        // Without this the icon reports 32pt and SwiftUI scales that rep up into mush.
        image.size = NSSize(width: 128, height: 128)
        cache[path] = image
        return image
    }
}
