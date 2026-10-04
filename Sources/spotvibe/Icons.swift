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

/// NSWorkspace.icon(forFile:) hits the disk — far too slow to call from a view body — so
/// icons are cached. NSCache evicts under memory pressure, which matters for a daemon that
/// sits resident all day and sees every file icon a search ever showed.
enum Icons {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    static func icon(forPath path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        // Without this the icon reports 32pt and SwiftUI scales that rep up into mush.
        image.size = NSSize(width: 128, height: 128)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
