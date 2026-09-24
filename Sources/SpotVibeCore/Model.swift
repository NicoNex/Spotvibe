import Foundation

// MARK: - Model

public struct Hit: Identifiable, Hashable {
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public let id: String // absolute path
    public let name: String
    public var url: URL { URL(fileURLWithPath: id) }
    public var isApp: Bool { id.hasSuffix(".app") }
}

/// Wraps an index in 0..<count for any delta, positive or negative.
public func wrap(_ index: Int, by delta: Int, count: Int) -> Int {
    count <= 0 ? 0 : ((index + delta % count) + count) % count
}

/// Anchored at the start: a plain replace would rewrite a second "/Users/me" mid-path.
public func prettyPath(_ path: String, home: String = NSHomeDirectory()) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
