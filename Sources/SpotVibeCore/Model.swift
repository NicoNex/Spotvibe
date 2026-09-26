import Foundation

// MARK: - Model

public struct Hit: Identifiable, Hashable {
    public init(id: String, name: String, used: Date? = nil) {
        self.id = id
        self.name = name
        self.used = used
    }

    public let id: String // absolute path
    public let name: String
    /// When the file was last opened, as Spotlight recorded it. Nil for apps, which rank
    /// on the frecency this app learned itself rather than on the system's account.
    public let used: Date?
    public var url: URL { URL(fileURLWithPath: id) }
    public var isApp: Bool { id.hasSuffix(".app") }
    /// The name on disk, under whatever the system chose to display. On an Italian Mac
    /// Calendar.app shows as "Calendario", and someone typing "calendar" still has to find
    /// it — so both names are matched.
    public var fileName: String {
        ((id as NSString).lastPathComponent as NSString).deletingPathExtension
    }

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
