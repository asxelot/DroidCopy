import Foundation

public struct AdbError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct RunResult: Sendable {
    public let output: String
    public let error: String
    public let status: Int32

    public var ok: Bool { status == 0 }

    /// The most useful single line to show a person when the command failed.
    public var message: String {
        let lines = (error + "\n" + output)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last(where: { $0.lowercased().contains("error") || $0.lowercased().contains("fail") })
            ?? lines.last
            ?? "adb exited with status \(status)"
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

public final class Adb: @unchecked Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    /// Apps launched from Finder don't get the shell PATH, so look in the usual places.
    /// `DROIDCOPY_ADB` in the environment overrides the search (used to test the "not installed" screen).
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> Adb? {
        if let forced = environment["DROIDCOPY_ADB"] {
            return FileManager.default.isExecutableFile(atPath: forced) ? Adb(path: forced) : nil
        }
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(Adb.init(path:))
    }

    /// Runs adb to completion. `onStart` receives the process so callers can terminate it.
    public func run(_ args: [String], onStart: (@Sendable (Process) -> Void)? = nil) async -> RunResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: self.path)
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: RunResult(output: "", error: error.localizedDescription, status: -1))
                    return
                }
                onStart?(p)
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: RunResult(
                    output: String(decoding: outData, as: UTF8.self),
                    error: String(decoding: errBox.data, as: UTF8.self),
                    status: p.terminationStatus))
            }
        }
    }

    public func devices() async -> [DeviceInfo] {
        Parse.devices(await run(["devices", "-l"]).output)
    }

    public func shell(_ serial: String, _ command: String) async -> RunResult {
        await run(["-s", serial, "shell", command])
    }

    public func list(_ serial: String, _ dir: String, showHidden: Bool = false) async throws -> [FileItem] {
        let q = Parse.shellQuote(dir)
        let r = await shell(serial, """
            [ -d \(q) ] || { echo 'Folder not found on the device' >&2; exit 2; }; \
            ls -A \(q) >/dev/null 2>&1 || { echo 'The device doesn’t allow reading this folder' >&2; exit 3; }; \
            find \(q) -mindepth 1 -maxdepth 1 -exec stat -L -c '%F/%s/%Y/%n' {} + 2>/dev/null; true
            """)
        guard r.ok else { throw AdbError(r.message) }
        return Parse.listing(r.output, showHidden: showHidden)
    }

    public func storages(_ serial: String) async -> [StorageRoot] {
        Parse.storages(await shell(serial, "ls /storage").output)
    }

    public func freeBytes(_ serial: String, _ dir: String) async -> Int64? {
        Parse.dfAvailableBytes(await shell(serial, "df -k \(Parse.shellQuote(dir))").output)
    }

    /// Size in bytes of a file, or disk usage of a folder. nil if it doesn't exist.
    /// Follows a symlink at `path`, like adb push/pull do.
    public func size(_ serial: String, _ path: String) async -> Int64? {
        let q = Parse.shellQuote(path)
        let r = await shell(serial, "if [ -d \(q) ]; then echo D $(du -skH \(q) | cut -f1); elif [ -e \(q) ]; then echo F $(stat -L -c %s \(q)); fi")
        return Parse.size(r.output)
    }

    public func exists(_ serial: String, _ path: String) async -> Bool {
        await shell(serial, "[ -e \(Parse.shellQuote(path)) ] && echo yes").output.contains("yes")
    }

    /// Which of `names` already exist in `dir`, checked in one round trip.
    public func existingNames(_ serial: String, in dir: String, _ names: [String]) async -> Set<String> {
        guard !names.isEmpty else { return [] }
        let list = names.map(Parse.shellQuote).joined(separator: " ")
        let r = await shell(serial, "cd \(Parse.shellQuote(dir)) || exit 1; for n in \(list); do [ -e \"$n\" ] && printf '%s\\n' \"$n\"; done; true")
        let found = Set(r.output.split(separator: "\n").map(String.init))
        return found.intersection(names)
    }

    /// Puts `staging` at `dest`, keeping the old `dest` at `aside` until that worked.
    /// If the swap fails, the old item is moved back.
    public func swapIn(_ serial: String, _ staging: String, as dest: String, aside: String) async -> RunResult {
        let (s, d, a) = (Parse.shellQuote(staging), Parse.shellQuote(dest), Parse.shellQuote(aside))
        return await shell(serial, "rm -rf \(a); mv \(d) \(a) || exit 1; if mv \(s) \(d); then rm -rf \(a); else mv \(a) \(d); exit 1; fi")
    }

    public func makeDirectory(_ serial: String, _ path: String) async -> RunResult {
        await shell(serial, "mkdir \(Parse.shellQuote(path))")
    }

    public func move(_ serial: String, from: String, to: String) async -> RunResult {
        let t = Parse.shellQuote(to)
        return await shell(serial, "if [ -e \(t) ]; then echo 'An item with that name already exists' >&2; exit 1; fi; mv \(Parse.shellQuote(from)) \(t)")
    }

    public func delete(_ serial: String, _ path: String) async -> RunResult {
        await shell(serial, "rm -rf \(Parse.shellQuote(path))")
    }
}
