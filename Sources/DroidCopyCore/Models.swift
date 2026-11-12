import Foundation
import UniformTypeIdentifiers

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

public enum FileSortKey: String, Sendable {
    case name, size, modified, kind
}

public extension Array where Element == FileItem {
    /// Folders first, then Finder-style name order.
    func sortedForDisplay() -> [FileItem] {
        sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Column sort for the file table: folders stay above files, and ties fall back to name order.
    func sorted(by key: FileSortKey, ascending: Bool) -> [FileItem] {
        let byName: (FileItem, FileItem) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Looked up once per item, not once per comparison.
        let kinds = key == .kind ? Dictionary(map { ($0.path, $0.kind) }, uniquingKeysWith: { a, _ in a }) : [:]
        let s = sorted { a, b in
            switch key {
            case .size where a.size != b.size: return ascending ? a.size < b.size : a.size > b.size
            case .modified where a.sortDate != b.sortDate: return ascending ? a.sortDate < b.sortDate : a.sortDate > b.sortDate
            case .kind where kinds[a.path] != kinds[b.path]:
                let order = (kinds[a.path] ?? "").localizedStandardCompare(kinds[b.path] ?? "")
                return ascending ? order == .orderedAscending : order == .orderedDescending
            case .name: return ascending ? byName(a, b) : byName(b, a)
            default: return byName(a, b)
            }
        }
        return s.filter(\.isDirectory) + s.filter { !$0.isDirectory }
    }
}

public extension FileItem {
    /// The type announced to Finder when the item is dragged out.
    var contentType: UTType {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let t = UTType(filenameExtension: ext), t.conforms(to: .data) else { return .data }
        return t
    }

    /// What Finder's Kind column would say: "Folder", "JPEG image", "INF file", "Document".
    var kind: String {
        if isDirectory { return "Folder" }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, !name.hasPrefix(".") || name.dropFirst().contains(".") else { return "Document" }
        if let t = UTType(filenameExtension: ext), !t.isDynamic, let d = t.localizedDescription, !d.isEmpty {
            return d.prefix(1).uppercased() + d.dropFirst()
        }
        return ext.uppercased() + " file"
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
