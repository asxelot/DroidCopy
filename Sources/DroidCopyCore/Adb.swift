import Foundation

public struct AdbError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    public static let notRespondingMessage = "The device isn’t responding."
    /// adb was still waiting for the device when its time ran out.
    public static let notResponding = AdbError(notRespondingMessage)
}

public struct RunResult: Sendable {
    public let output: String
    public let error: String
    public let status: Int32

    public var ok: Bool { status == 0 }

    /// The status of a command that was stopped because it took too long.
    public static let timedOutStatus: Int32 = -2
    public var timedOut: Bool { status == Self.timedOutStatus }

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

/// Output collected from a pipe as it arrives.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()
    func append(_ d: Data) { lock.lock(); collected.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return collected }
}

/// Resumes a continuation once, whichever of "finished" and "timed out" comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<RunResult, Never>?
    init(_ cont: CheckedContinuation<RunResult, Never>) { self.cont = cont }
    func resume(_ r: RunResult) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: r)
    }
}

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
    /// With a `timeout`, a command still running after that many seconds is stopped and reported
    /// as `timedOut`, so a device that stops answering can't leave the app waiting forever. Only
    /// this adb client process is stopped; the adb server and the device are left alone.
    ///
    /// Nothing here blocks a thread while adb runs: output arrives through readability handlers
    /// and the end through the termination handler. (Blocking worker threads while waiting on
    /// other worker threads deadlocks once many commands run at once and the pool is used up.)
    public func run(_ args: [String], timeout: TimeInterval? = nil,
                    onStart: (@Sendable (Process) -> Void)? = nil) async -> RunResult {
        await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: self.path)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice

            let outBox = DataBox(), errBox = DataBox()
            let group = DispatchGroup()
            for (pipe, box) in [(out, outBox), (err, errBox)] {
                group.enter()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        group.leave()
                    } else {
                        box.append(data)
                    }
                }
            }
            group.enter()
            p.terminationHandler = { _ in group.leave() }

            do { try p.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                once.resume(RunResult(output: "", error: error.localizedDescription, status: -1))
                return
            }
            onStart?(p)
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard p.isRunning else { return }
                    p.terminate()
                    // Don't wait for its output to close: something it started may hold it open.
                    once.resume(RunResult(output: "", error: AdbError.notRespondingMessage,
                                          status: RunResult.timedOutStatus))
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                once.resume(RunResult(
                    output: String(decoding: outBox.data, as: UTF8.self),
                    error: String(decoding: errBox.data, as: UTF8.self),
                    status: p.terminationStatus))
            }
        }
    }

    /// How long a quick question to the device (a listing, free space, whether a name is taken)
    /// may take before the device counts as not responding.
    public var quickTimeout: TimeInterval = 20
    /// The same for slow questions, like the size of a big folder.
    public var slowTimeout: TimeInterval = 120

    public func devices() async -> [DeviceInfo] {
        Parse.devices(await run(["devices", "-l"], timeout: quickTimeout).output)
    }

    public func shell(_ serial: String, _ command: String, timeout: TimeInterval? = nil) async -> RunResult {
        await run(["-s", serial, "shell", command], timeout: timeout)
    }

    /// Flushes the device's write cache to its storage, so nothing written is lost if the device
    /// is switched off or the card is taken out after unplugging.
    public func sync(_ serial: String) async -> RunResult {
        await shell(serial, "sync")
    }

    public func list(_ serial: String, _ dir: String, showHidden: Bool = false) async throws -> [FileItem] {
        let q = Parse.shellQuote(dir)
        let r = await shell(serial, """
            [ -d \(q) ] || { echo 'Folder not found on the device' >&2; exit 2; }; \
            ls -A \(q) >/dev/null 2>&1 || { echo 'The device doesn’t allow reading this folder' >&2; exit 3; }; \
            find \(q) -mindepth 1 -maxdepth 1 -exec stat -L -c '%F/%s/%Y/%n' {} + 2>/dev/null; true
            """, timeout: quickTimeout)
        if r.timedOut { throw AdbError.notResponding }
        guard r.ok else { throw AdbError(r.message) }
        return Parse.listing(r.output, showHidden: showHidden)
    }

    /// Where Android mounts internal storage and cards. A temp folder in tests.
    public var storageRoot = "/storage"

    public func storages(_ serial: String) async -> [StorageRoot] {
        Parse.storages(await shell(serial, "ls \(Parse.shellQuote(storageRoot))", timeout: quickTimeout).output, root: storageRoot)
    }

    public func freeBytes(_ serial: String, _ dir: String) async -> Int64? {
        Parse.dfAvailableBytes(await shell(serial, "df -k \(Parse.shellQuote(dir))", timeout: quickTimeout).output)
    }

    /// Size in bytes of a file, or disk usage of a folder. nil if it doesn't exist.
    /// Follows a symlink at `path`, like adb push/pull do.
    public func size(_ serial: String, _ path: String) async -> Int64? {
        let q = Parse.shellQuote(path)
        let r = await shell(serial, "if [ -d \(q) ]; then echo D $(du -skH \(q) | cut -f1); elif [ -e \(q) ]; then echo F $(stat -L -c %s \(q)); fi", timeout: slowTimeout)
        return Parse.size(r.output)
    }

    /// How many items are inside a folder, at every depth. nil if that couldn't be counted.
    public func itemCount(_ serial: String, _ path: String) async -> Int? {
        let r = await shell(serial, "find \(Parse.shellQuote(path)) -mindepth 1 | wc -l", timeout: slowTimeout)
        guard r.ok else { return nil }
        return Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func exists(_ serial: String, _ path: String) async -> Bool {
        await shell(serial, "[ -e \(Parse.shellQuote(path)) ] && echo yes", timeout: quickTimeout).output.contains("yes")
    }

    /// Which of `names` already exist in `dir`, checked in one round trip.
    public func existingNames(_ serial: String, in dir: String, _ names: [String]) async -> Set<String> {
        guard !names.isEmpty else { return [] }
        let list = names.map(Parse.shellQuote).joined(separator: " ")
        let r = await shell(serial, "cd \(Parse.shellQuote(dir)) || exit 1; for n in \(list); do [ -e \"$n\" ] && printf '%s\\n' \"$n\"; done; true", timeout: quickTimeout)
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

    /// Moves or renames an item on the device. Without `replace` it fails if `to` exists; with it,
    /// the old item at `to` is kept aside until the move worked.
    public func move(_ serial: String, from: String, to: String, replace: Bool = false) async -> RunResult {
        if replace { return await swapIn(serial, from, as: to, aside: Self.asidePath(for: to)) }
        let (f, t) = (Parse.shellQuote(from), Parse.shellQuote(to))
        let tmp = Parse.shellQuote(Self.asidePath(for: from) + "-rename")
        // SD cards ignore case, so "ROMs" -> "Roms" finds "Roms" already there: it's the same
        // item. Rename it through a temporary name instead of refusing.
        return await shell(serial, """
            if [ -e \(t) ]; then
              if [ \(f) -ef \(t) ]; then mv \(f) \(tmp) && mv \(tmp) \(t); exit; fi
              echo 'An item with that name already exists' >&2; exit 1
            fi
            mv \(f) \(t)
            """)
    }

    /// Copies an item to `to` on the device. Like copies from the Mac, it's written under a hidden
    /// name first and only renamed into place once complete, so a failed copy leaves nothing
    /// under the real name. `replace` works as for `move`.
    public func copy(_ serial: String, from: String, to: String, replace: Bool = false) async -> RunResult {
        let dir = Parse.parent(to), name = (to as NSString).lastPathComponent
        let staging = Parse.join(dir, ".dc~" + name)
        let (f, s) = (Parse.shellQuote(from), Parse.shellQuote(staging))
        let r = await shell(serial, "rm -rf \(s); cp -R \(f) \(s) || { rm -rf \(s); exit 1; }")
        guard r.ok else { return r }
        let placed = await move(serial, from: staging, to: to, replace: replace)
        if !placed.ok { _ = await delete(serial, staging) }
        return placed
    }

    static func asidePath(for path: String) -> String {
        Parse.join(Parse.parent(path), ".dc-old~" + (path as NSString).lastPathComponent)
    }

    public func delete(_ serial: String, _ path: String) async -> RunResult {
        await shell(serial, "rm -rf \(Parse.shellQuote(path))")
    }
}
