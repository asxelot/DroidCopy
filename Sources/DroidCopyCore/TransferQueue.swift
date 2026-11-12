import Foundation

@MainActor
public final class Transfer: ObservableObject, Identifiable {
    public enum Direction { case toDevice, toMac }

    public enum State: Equatable {
        case waiting, running, done, failed(String), cancelled
        public var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            case .waiting, .running: return false
            }
        }
    }

    public let id = UUID()
    public let direction: Direction
    public let serial: String
    /// Mac path for uploads, device path for downloads.
    public let source: String
    public let destDir: String
    public let name: String
    public let isDirectory: Bool
    /// The person agreed to replace an existing item at the destination.
    public let replace: Bool

    @Published public var state: State = .waiting
    @Published public var total: Int64 = 0
    @Published public var transferred: Int64 = 0
    @Published public var bytesPerSecond: Double = 0
    public var startedAt: Date?
    public var finishedAt: Date?
    public var process: Process?
    public var cancelRequested = false

    public init(direction: Direction, serial: String, source: String, destDir: String, name: String, isDirectory: Bool, replace: Bool) {
        self.direction = direction
        self.serial = serial
        self.source = source
        self.destDir = destDir
        self.name = name
        self.isDirectory = isDirectory
        self.replace = replace
    }

    public var destPath: String {
        direction == .toDevice
            ? Parse.join(destDir, name)
            : URL(fileURLWithPath: destDir).appendingPathComponent(name).path
    }

    public var fraction: Double {
        total > 0 ? min(1, Double(transferred) / Double(total)) : 0
    }

    public func retryCopy() -> Transfer {
        Transfer(direction: direction, serial: serial, source: source, destDir: destDir, name: name, isDirectory: isDirectory, replace: replace)
    }
}

/// Runs transfers one at a time with `adb push` / `adb pull`.
@MainActor
public final class TransferQueue: ObservableObject {
    @Published public private(set) var items: [Transfer] = []
    /// Transfers waiting or running. The UI hides the list when this is 0.
    @Published public private(set) var activeCount = 0
    public var onFinished: ((Transfer) -> Void)?

    private let adb: Adb
    private var busy = false

    public init(adb: Adb) { self.adb = adb }

    public var hasActive: Bool { activeCount > 0 }

    public func add(_ transfers: [Transfer]) {
        guard !transfers.isEmpty else { return }
        // A new batch after the queue went idle starts with a clean list.
        if activeCount == 0 { items.removeAll() }
        items.append(contentsOf: transfers)
        updateActive()
        pump()
    }

    private func updateActive() {
        activeCount = items.filter { !$0.state.isFinished }.count
    }

    public func cancel(_ t: Transfer) {
        switch t.state {
        case .waiting:
            finish(t, .cancelled)
        case .running:
            t.cancelRequested = true
            t.process?.terminate()
        default:
            break
        }
    }

    public func retry(_ t: Transfer) {
        add([t.retryCopy()])
    }

    public func clearFinished() {
        items.removeAll { $0.state.isFinished }
        updateActive()
    }

    /// Cancels everything and waits (up to a few seconds) for partial copies to be removed.
    public func cancelAllAndWait() async {
        for t in items { cancel(t) }
        for _ in 0..<50 where busy {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func pump() {
        guard !busy, let next = items.first(where: { $0.state == .waiting }) else { return }
        busy = true
        Task {
            await execute(next)
            busy = false
            onFinished?(next)
            pump()
        }
    }

    private func finish(_ t: Transfer, _ state: Transfer.State) {
        t.state = state
        t.finishedAt = Date()
        t.bytesPerSecond = 0
        t.process = nil
        updateActive()
    }

    private func execute(_ t: Transfer) async {
        t.state = .running
        t.startedAt = Date()
        let dest = t.destPath

        // Never touch something that was already there unless the person said "Replace".
        let exists = t.direction == .toDevice
            ? await adb.exists(t.serial, dest)
            : FileManager.default.fileExists(atPath: dest)
        if exists && !t.replace {
            return finish(t, .failed("“\(t.name)” already exists there"))
        }

        // Size and free space, checked before anything is deleted. Space freed by a replaced item counts.
        if t.direction == .toDevice {
            let src = t.source
            t.total = await Task.detached { LocalFS.size(URL(fileURLWithPath: src)) }.value
            let reclaimed = exists ? (await adb.size(t.serial, dest) ?? 0) : 0
            if let free = await adb.freeBytes(t.serial, t.destDir), free + reclaimed < t.total {
                return finish(t, .failed("Not enough space on the device: needs \(Fmt.bytes(t.total)), only \(Fmt.bytes(free + reclaimed)) free"))
            }
        } else {
            guard let size = await adb.size(t.serial, t.source) else {
                return finish(t, .failed("Couldn’t find “\(t.name)” on the device"))
            }
            t.total = size
            let reclaimed = exists ? LocalFS.size(URL(fileURLWithPath: dest)) : 0
            if let free = LocalFS.freeBytes(URL(fileURLWithPath: t.destDir)), free + reclaimed < t.total {
                return finish(t, .failed("Not enough space on this Mac: needs \(Fmt.bytes(t.total)), only \(Fmt.bytes(free + reclaimed)) free"))
            }
        }
        if t.cancelRequested { return finish(t, .cancelled) }

        if exists {
            if t.direction == .toDevice {
                let r = await adb.delete(t.serial, dest)
                if !r.ok { return finish(t, .failed("Couldn’t replace the existing item: \(r.message)")) }
            } else {
                do { try FileManager.default.removeItem(atPath: dest) } catch {
                    return finish(t, .failed("Couldn’t replace the existing item: \(error.localizedDescription)"))
                }
            }
        }

        // Copy, polling the destination size for progress.
        let poller = Task { await self.poll(t) }
        let args = t.direction == .toDevice
            ? ["-s", t.serial, "push", t.source, dest]
            : ["-s", t.serial, "pull", t.source, dest]
        let result = await adb.run(args) { process in
            DispatchQueue.main.async {
                t.process = process
                if t.cancelRequested { process.terminate() }
            }
        }
        poller.cancel()

        if t.cancelRequested {
            await removePartial(t)
            return finish(t, .cancelled)
        }
        guard result.ok else {
            await removePartial(t)
            return finish(t, .failed(result.message))
        }

        // Verify single files byte-for-byte by size.
        if !t.isDirectory {
            let final: Int64? = t.direction == .toDevice
                ? await adb.size(t.serial, dest)
                : LocalFS.size(URL(fileURLWithPath: dest))
            if final != t.total {
                await removePartial(t)
                return finish(t, .failed("Size check failed: expected \(t.total) bytes, got \(final ?? 0). The copy was removed."))
            }
        }
        t.transferred = t.total
        finish(t, .done)
    }

    private func removePartial(_ t: Transfer) async {
        if t.direction == .toDevice {
            _ = await adb.delete(t.serial, t.destPath)
        } else {
            try? FileManager.default.removeItem(atPath: t.destPath)
        }
    }

    private func poll(_ t: Transfer) async {
        var lastBytes: Int64 = 0
        var lastTime = Date()
        let dest = t.destPath
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { break }
            let current: Int64? = t.direction == .toDevice
                ? await adb.size(t.serial, dest)
                : await Task.detached { LocalFS.size(URL(fileURLWithPath: dest)) }.value
            guard let current, !Task.isCancelled, t.state == .running else { continue }
            let now = Date()
            let dt = now.timeIntervalSince(lastTime)
            if dt > 0, current >= lastBytes {
                let instant = Double(current - lastBytes) / dt
                t.bytesPerSecond = t.bytesPerSecond == 0 ? instant : t.bytesPerSecond * 0.7 + instant * 0.3
            }
            lastBytes = current
            lastTime = now
            // Folder sizes come from `du` (block-rounded), so never show 100% before adb is done.
            t.transferred = min(current, t.isDirectory ? Int64(Double(t.total) * 0.99) : t.total)
        }
    }
}
