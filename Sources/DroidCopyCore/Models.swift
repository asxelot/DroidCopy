import Foundation

public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?

    /// Sortable stand-in for `modified` (Optional isn't Comparable).
    public var sortDate: Date { modified ?? .distantPast }

    public init(name: String, path: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

public extension Array where Element == FileItem {
    /// Folders first, then Finder-style name order.
    func sortedForDisplay() -> [FileItem] {
        sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

public struct DeviceInfo: Hashable, Sendable {
    public let serial: String
    public let state: String
    public let model: String?

    public init(serial: String, state: String, model: String?) {
        self.serial = serial
        self.state = state
        self.model = model
    }

    public var isReady: Bool { state == "device" }
    public var displayName: String { model?.replacingOccurrences(of: "_", with: " ") ?? serial }
}

public struct StorageRoot: Hashable, Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}
