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
    public static func storages(_ lsOutput: String, root: String = "/storage") -> [StorageRoot] {
        var roots = [StorageRoot(name: "Internal", path: Parse.join(root, "emulated/0"))]
        let cards = lsOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "emulated" && $0 != "self" }
        for (i, id) in cards.enumerated() {
            roots.append(StorageRoot(name: cards.count == 1 ? "SD card" : "SD card \(i + 1)", path: Parse.join(root, id)))
        }
        return roots
    }

    /// Quote for the device's /bin/sh.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `path` escaped the way Terminal types a file dropped onto it: a backslash before each
    /// character the shell treats specially. A name with a line break is single-quoted instead,
    /// because a backslash before a newline would join the lines.
    public static func shellEscaped(_ path: String) -> String {
        if path.contains(where: \.isNewline) { return shellQuote(path) }
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,:@%^=~"))
        var out = ""
        for ch in path {
            let isPlain = ch.unicodeScalars.allSatisfy { plain.contains($0) }
            // A leading ~ would expand to the Mac's home folder.
            if !isPlain || (ch == "~" && out.isEmpty) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// The folder that holds `path`.
    public static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Whether `path` is `folder` itself or somewhere inside it.
    public static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// `path` with `old` at its start replaced by `new`, for items inside a moved or renamed folder.
    public static func rebase(_ path: String, from old: String, to new: String) -> String? {
        guard isSameOrInside(path, old) else { return nil }
        return new + path.dropFirst(old.count)
    }

    /// Finder's name for a duplicate: "a copy.txt", then "a copy 2.txt", and so on. Duplicating
    /// "a copy.txt" gives "a copy 2.txt", not "a copy copy.txt".
    public static func copyName(_ name: String, isDirectory: Bool, taken: Set<String>) -> String {
        let (stem, ext) = splitExtension(name, isDirectory: isDirectory)
        var base = stem
        if let r = base.range(of: #" copy( \d+)?$"#, options: .regularExpression) { base.removeSubrange(r) }
        let dotExt = ext.isEmpty ? "" : "." + ext
        var candidate = "\(base) copy\(dotExt)"
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base) copy \(n)\(dotExt)"
            n += 1
        }
        return candidate
    }

    /// Finder's name for a new folder: "untitled folder", then "untitled folder 2", and so on.
    public static func untitledFolderName(taken: Set<String>) -> String {
        var candidate = "untitled folder"
        var n = 2
        while taken.contains(candidate) {
            candidate = "untitled folder \(n)"
            n += 1
        }
        return candidate
    }

    /// "game.nsp" -> ("game", "nsp"). Folders, dotfiles like ".nomedia" and names without a dot
    /// have no extension.
    public static func splitExtension(_ name: String, isDirectory: Bool) -> (stem: String, ext: String) {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
