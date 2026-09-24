import AppKit

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
