import CryptoKit
import Foundation

public enum LocalFS {
    public static func list(_ dir: URL, showHidden: Bool = false) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return FileItem(
                name: url.lastPathComponent,
                path: url.path,
                isDirectory: v?.isDirectory ?? false,
                size: Int64(v?.fileSize ?? 0),
                modified: v?.contentModificationDate)
        }.sortedForDisplay()
    }

    /// Bytes in a file, or the total of all files inside a folder. 0 if missing.
    /// Follows a symlink at `url`, like adb push does.
    public static func size(_ url: URL) -> Int64 {
        let url = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    /// MD5 of a file (keyed "."), or of every file inside a folder (keyed "./sub/name"), the same
    /// shape as `Adb.checksums`. Follows a symlink at `url`, like adb push does. nil if a file
    /// couldn't be read or `cancelled` turned true.
    public static func checksums(_ url: URL, cancelled: @Sendable () -> Bool = { false }) -> [String: String]? {
        let url = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return md5(url, cancelled: cancelled).map { [".": $0] } }
        var sums: [String: String] = [:]
        let base = url.path.hasSuffix("/") ? url.path : url.path + "/"
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let sum = md5(f, cancelled: cancelled) else { return nil }
            let path = f.resolvingSymlinksInPath().path
            sums["./" + (path.hasPrefix(base) ? String(path.dropFirst(base.count)) : f.lastPathComponent)] = sum
        }
        return sums
    }

    static func md5(_ url: URL, cancelled: @Sendable () -> Bool) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hash = Insecure.MD5()
        while true {
            if cancelled() { return nil }
            let chunk: Data
            do { chunk = try h.read(upToCount: 4 << 20) ?? Data() } catch { return nil } // nil at the end
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func freeBytes(_ dir: URL) -> Int64? {
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }
}

public enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        // Like Finder: "13 May 2017 at 14:54", "Today at 09:30".
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    public static func bytes(_ n: Int64) -> String { byteFormatter.string(fromByteCount: n) }
    public static func speed(_ bytesPerSecond: Double) -> String { bytes(Int64(bytesPerSecond)) + "/s" }
    public static func duration(_ seconds: Double) -> String { durationFormatter.string(from: max(1, seconds)) ?? "" }
    public static func date(_ d: Date) -> String { dateFormatter.string(from: d) }
}
