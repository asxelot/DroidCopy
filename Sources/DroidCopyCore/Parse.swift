import Foundation

/// Parsers for adb / toybox output. Kept pure so they can be unit tested.
public enum Parse {
    /// `adb devices -l`
    public static func devices(_ output: String) -> [DeviceInfo] {
        var result: [DeviceInfo] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("*") || line.hasPrefix("List of devices") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let model = parts.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }
            result.append(DeviceInfo(serial: parts[0], state: parts[1], model: model))
        }
        return result
    }

    /// Lines of `stat -c '%F/%s/%Y/%n'`. "/" cannot appear in a file name, so it is a safe separator.
    public static func listing(_ output: String, showHidden: Bool = false) -> [FileItem] {
        var items: [FileItem] = []
        for raw in output.split(separator: "\n") {
            let parts = raw.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let size = Int64(parts[1]) else { continue }
            let path = String(parts[3])
            let name = (path as NSString).lastPathComponent
            if name.isEmpty || (!showHidden && name.hasPrefix(".")) { continue }
            let modified = Double(parts[2]).map { Date(timeIntervalSince1970: $0) }
            items.append(FileItem(name: name, path: path, isDirectory: parts[0] == "directory", size: size, modified: modified))
        }
        return items.sortedForDisplay()
    }

    /// `df -k <dir>`: the "Available" column of the last line, in bytes.
    public static func dfAvailableBytes(_ output: String) -> Int64? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard cols.count >= 4, let kb = Int64(cols[3]) else { return nil }
        return kb * 1024
    }

    /// Output of `Adb.size`: "F <bytes>" for a file, "D <kilobytes>" for a folder.
    public static func size(_ output: String) -> Int64? {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, let n = Int64(parts[1]) else { return nil }
        return parts[0] == "D" ? n * 1024 : n
    }

    /// `ls /storage` -> internal storage plus one root per removable card.
    public static func storages(_ lsOutput: String) -> [StorageRoot] {
        var roots = [StorageRoot(name: "Internal", path: "/storage/emulated/0")]
        let cards = lsOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "emulated" && $0 != "self" }
        for (i, id) in cards.enumerated() {
            roots.append(StorageRoot(name: cards.count == 1 ? "SD card" : "SD card \(i + 1)", path: "/storage/\(id)"))
        }
        return roots
    }

    /// Quote for the device's /bin/sh.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}
