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
        public var failure: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
        public var isFailed: Bool { failure != nil }
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
    /// Shown instead of the destination folder, e.g. "Clipboard".
    public var destLabel: String?
    /// Called once when the transfer ends in any way (done, failed or cancelled).
    public var onComplete: ((Transfer) -> Void)?

    public init(direction: Direction, serial: String, source: String, destDir: String, name: String, isDirectory: Bool, replace: Bool) {
        self.direction = direction
        self.serial = serial
        self.source = source
        self.destDir = destDir
        self.name = name
        self.isDirectory = isDirectory
        self.replace = replace
    }

    public var destPath: String { inDestDir(name) }

    /// Hidden name the copy is written under until it is verified, so a failed or cancelled copy
    /// never takes the real name.
    public var stagingPath: String { inDestDir(".dc~" + name) }

    /// Where a replaced item waits while the new copy is moved into place.
    public var asidePath: String { inDestDir(".dc-old~" + name) }

    private func inDestDir(_ file: String) -> String {
        direction == .toDevice
            ? Parse.join(destDir, file)
            : URL(fileURLWithPath: destDir).appendingPathComponent(file).path
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
    /// Transfers waiting or running.
    @Published public private(set) var activeCount = 0
    /// Failed transfers still in the list. The UI shows the list while this or `activeCount` is above 0.
    @Published public private(set) var failedCount = 0
    public var onFinished: ((Transfer) -> Void)?

    private let adb: Adb
    private var busy = false

    /// True once copying has gone on for `progressDelay` without a break, so quick copies of small
    /// files don't flash the progress list on screen. False again when nothing is left to copy.
    @Published public private(set) var showsProgress = false
    public var progressDelay: TimeInterval = 2
    /// Bumped whenever the queue goes busy or idle, so a stale delayed reveal does nothing.
    private var busyPeriod = 0

    public init(adb: Adb) { self.adb = adb }

    public var hasActive: Bool { activeCount > 0 }

    /// The transfers added since the queue was last idle.
    public private(set) var batch: [Transfer] = []

    /// How far the current batch has got: finished items, items in it (cancelled ones don't
    /// count), and the fraction done, counting the running item's progress.
    public var batchProgress: (finished: Int, count: Int, fraction: Double) {
        let live = batch.filter { $0.state != .cancelled }
        guard !live.isEmpty else { return (0, 0, 0) }
        let finished = live.filter(\.state.isFinished).count
        let done = live.reduce(0.0) { $0 + ($1.state.isFinished ? 1 : $1.fraction) }
        return (finished, live.count, done / Double(live.count))
    }

    public func add(_ transfers: [Transfer]) {
        guard !transfers.isEmpty else { return }
        // A new batch after the queue went idle drops the finished items, but failures stay until
        // they are retried or cleared.
        if activeCount == 0 {
            items.removeAll { $0.state.isFinished && !$0.state.isFailed }
            batch = []
        }
        batch.append(contentsOf: transfers)
        items.append(contentsOf: transfers)
        updateActive()
        pump()
    }

    private func updateActive() {
        let wasActive = activeCount > 0
        activeCount = items.filter { !$0.state.isFinished }.count
        failedCount = items.filter(\.state.isFailed).count
        if activeCount == 0 {
            if wasActive { busyPeriod += 1 }
            showsProgress = false
        } else if !wasActive {
            busyPeriod += 1
            let period = busyPeriod
            let delay = progressDelay
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.busyPeriod == period, self.activeCount > 0 else { return }
                self.showsProgress = true
            }
        }
    }

    /// One alert's worth of text about failed transfers, or nil if none failed.
    public static func failureSummary(_ transfers: [Transfer]) -> String? {
        let failed = transfers.compactMap { t in t.state.failure.map { (name: t.name, message: $0) } }
        guard let first = failed.first else { return nil }
        if failed.count == 1 { return "Couldn’t copy “\(first.name)”.\n\n\(first.message)" }
        let shown = failed.prefix(5).map { "“\($0.name)”: \($0.message)" }.joined(separator: "\n")
        let more = failed.count > 5 ? "\n…and \(failed.count - 5) more" : ""
        return "\(failed.count) items couldn’t be copied.\n\n\(shown)\(more)\n\nThey stay in the transfer list, where you can retry them."
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

    /// Replaces a finished transfer with a fresh copy of it, in the same place in the list.
    public func retry(_ t: Transfer) {
        guard t.state.isFinished else { return }
        let copy = t.retryCopy()
        if let i = items.firstIndex(where: { $0 === t }) {
            if activeCount == 0 { batch = [] }
            batch.removeAll { $0 === t }
            batch.append(copy)
            items[i] = copy
            updateActive()
            pump()
        } else {
            add([copy])
        }
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
        let done = t.onComplete
        t.onComplete = nil
        done?(t)
    }

    private func execute(_ t: Transfer) async {
        // Cancelled while it waited for its turn.
        guard t.state == .waiting else { return }
        t.state = .running
        t.startedAt = Date()
        let dest = t.destPath
        let staging = t.stagingPath

        // Never touch something that was already there unless the person said "Replace".
        let exists = t.direction == .toDevice
            ? await adb.exists(t.serial, dest)
            : FileManager.default.fileExists(atPath: dest)
        if exists && !t.replace {
            return finish(t, .failed("“\(t.name)” already exists there"))
        }

        // Size and free space, checked before anything is deleted. Space freed by a replaced item counts.
        let free: Int64?
        let reclaimed: Int64
        if t.direction == .toDevice {
            let src = t.source
            t.total = await Task.detached { LocalFS.size(URL(fileURLWithPath: src)) }.value
            reclaimed = exists ? (await adb.size(t.serial, dest) ?? 0) : 0
            free = await adb.freeBytes(t.serial, t.destDir)
        } else {
            guard let size = await adb.size(t.serial, t.source) else {
                return finish(t, .failed("Couldn’t find “\(t.name)” on the device"))
            }
            t.total = size
            reclaimed = exists ? LocalFS.size(URL(fileURLWithPath: dest)) : 0
            free = LocalFS.freeBytes(URL(fileURLWithPath: t.destDir))
        }
        if let free, free + reclaimed < t.total {
            let place = t.direction == .toDevice ? "on the device" : "on this Mac"
            return finish(t, .failed("Not enough space \(place): needs \(Fmt.bytes(t.total)), only \(Fmt.bytes(free + reclaimed)) free"))
        }
        if t.cancelRequested { return finish(t, .cancelled) }

        // A replaced item stays until its replacement is verified. Only when the new copy fits
        // just because the old one goes is the old one deleted first.
        let deleteFirst = exists && (free.map { $0 < t.total } ?? false)

        await remove(t, staging) // left over from a copy that was interrupted earlier
        if deleteFirst, let error = await remove(t, dest) {
            return finish(t, .failed("Couldn’t replace the existing item: \(error)"))
        }

        // Copy, polling the copy's size for progress.
        let poller = Task { await self.poll(t, staging) }
        let args = t.direction == .toDevice
            ? ["-s", t.serial, "push", t.source, staging]
            : ["-s", t.serial, "pull", t.source, staging]
        let result = await adb.run(args) { process in
            DispatchQueue.main.async {
                t.process = process
                if t.cancelRequested { process.terminate() }
            }
        }
        poller.cancel()

        if t.cancelRequested {
            await remove(t, staging)
            return finish(t, .cancelled)
        }
        guard result.ok else {
            await remove(t, staging)
            return finish(t, .failed(result.message))
        }

        // Verify single files byte-for-byte by size.
        if !t.isDirectory {
            let final: Int64? = t.direction == .toDevice
                ? await adb.size(t.serial, staging)
                : LocalFS.size(URL(fileURLWithPath: staging))
            if final != t.total {
                await remove(t, staging)
                return finish(t, .failed("Size check failed: expected \(t.total) bytes, got \(final ?? 0). The copy was removed."))
            }
        }

        if let error = await moveIntoPlace(t, replacing: exists && !deleteFirst) {
            await remove(t, staging)
            return finish(t, .failed("Couldn’t put the copy in place: \(error)"))
        }
        t.transferred = t.total
        finish(t, .done)
    }

    /// Deletes `path` on the transfer's destination side. Returns an error message, or nil.
    @discardableResult
    private func remove(_ t: Transfer, _ path: String) async -> String? {
        if t.direction == .toDevice {
            let r = await adb.delete(t.serial, path)
            return r.ok ? nil : r.message
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do { try FileManager.default.removeItem(atPath: path) } catch { return error.localizedDescription }
        return nil
    }

    /// Renames the verified copy to its real name, swapping out the old item when replacing.
    /// Returns an error message, or nil. On failure the old item is back under its own name.
    private func moveIntoPlace(_ t: Transfer, replacing: Bool) async -> String? {
        if t.direction == .toDevice {
            let r = replacing
                ? await adb.swapIn(t.serial, t.stagingPath, as: t.destPath, aside: t.asidePath)
                : await adb.move(t.serial, from: t.stagingPath, to: t.destPath)
            return r.ok ? nil : r.message
        }
        let fm = FileManager.default
        do {
            guard replacing else {
                try fm.moveItem(atPath: t.stagingPath, toPath: t.destPath)
                return nil
            }
            try? fm.removeItem(atPath: t.asidePath)
            try fm.moveItem(atPath: t.destPath, toPath: t.asidePath)
            do {
                try fm.moveItem(atPath: t.stagingPath, toPath: t.destPath)
            } catch {
                try? fm.moveItem(atPath: t.asidePath, toPath: t.destPath)
                throw error
            }
            try? fm.removeItem(atPath: t.asidePath)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func poll(_ t: Transfer, _ path: String) async {
        var lastBytes: Int64 = 0
        var lastTime = Date()
        // Measuring a folder walks all of it (`du` on the device), so do that less often.
        let interval: UInt64 = t.isDirectory ? 5_000_000_000 : 1_000_000_000
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: interval)
            if Task.isCancelled { break }
            let current: Int64? = t.direction == .toDevice
                ? await adb.size(t.serial, path)
                : await Task.detached { LocalFS.size(URL(fileURLWithPath: path)) }.value
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
