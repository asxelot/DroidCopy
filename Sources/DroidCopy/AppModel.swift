import AppKit
import DroidCopyCore

struct Crumb {
    let title: String
    let action: () -> Void
}

@MainActor
final class AppModel: ObservableObject {
    struct Plan {
        let direction: Transfer.Direction
        let source: String
        let name: String
        let isDirectory: Bool
        let conflict: Bool
    }

    struct PendingBatch: Identifiable {
        let id = UUID()
        let plans: [Plan]
        let serial: String
        let destDir: String
        var conflicts: [Plan] { plans.filter(\.conflict) }
    }

    let adb: Adb?
    let queue: TransferQueue

    // Device side
    @Published var device: DeviceInfo?
    @Published var deviceStatus = "Looking for a device…"
    @Published var adbMissing = false
    static let adbInstallCommand = "brew install android-platform-tools"
    @Published var storages: [StorageRoot] = []
    @Published var storage: StorageRoot?
    @Published var deviceDir = ""
    @Published var deviceItems: [FileItem] = []
    @Published var deviceSelection = Set<String>()
    @Published var deviceError: String?
    @Published var deviceFree: Int64?
    @Published var deviceLoading = false
    /// The device that was ejected. It isn't reconnected until it's unplugged or the person asks.
    @Published var ejectedSerial: String?
    @Published var ejecting = false

    /// The delete in progress: which item, and where it is in the batch. `rm` reports nothing
    /// while it runs, and a big file on an SD card can take a while, so the UI shows this.
    struct DeleteProgress: Equatable {
        let name: String
        let index: Int
        let count: Int
        let started: Date
    }
    @Published var deleteProgress: DeleteProgress?

    @Published var pending: PendingBatch?
    @Published var alertMessage: String?

    private var started = false
    /// The clipboard ⌘C writes to, and the folder it pulls into first. Injected so tests don't
    /// touch the real clipboard or caches.
    let pasteboard: NSPasteboard
    let clipboardCache: URL

    nonisolated static let defaultClipboardCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DroidCopy/Clipboard")

    init(adb: Adb? = Adb.locate(), pasteboard: NSPasteboard = .general, clipboardCache: URL = AppModel.defaultClipboardCache) {
        self.adb = adb
        self.pasteboard = pasteboard
        self.clipboardCache = clipboardCache
        self.queue = TransferQueue(adb: adb ?? Adb(path: "/usr/bin/false"))
        queue.onFinished = { [weak self] t in self?.transferFinished(t) }
    }

    func start() {
        guard !started else { return }
        started = true
        removeStaleClipboardCopies()
        Task { await monitorDevices() }
    }

    // MARK: - Device side

    private func monitorDevices() async {
        guard let adb else {
            adbMissing = true
            return
        }
        while true {
            await pollDevices()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// One look at what's plugged in: connects the first ready device, notices unplugging.
    func pollDevices() async {
        guard let adb else { return }
        let list = await adb.devices()
        let ready = list.filter(\.isReady)
        if let current = device, !ready.contains(where: { $0.serial == current.serial }) {
            disconnect()
        }
        // An ejected device counts as gone until it really is unplugged.
        if let ejected = ejectedSerial, !list.contains(where: { $0.serial == ejected }) {
            ejectedSerial = nil
        }
        guard device == nil else { return }
        if let first = ready.first(where: { $0.serial != ejectedSerial }) {
            await connect(first)
        } else if ejectedSerial != nil {
            deviceStatus = "It’s safe to unplug the device."
        } else if list.contains(where: { $0.state == "unauthorized" }) {
            deviceStatus = "Device found but not authorized.\nUnlock it and tap “Allow” on the USB debugging prompt."
        } else if list.contains(where: { $0.state == "offline" }) {
            deviceStatus = "The device is offline.\nTry unplugging and reconnecting the cable."
        } else {
            deviceStatus = "No device connected.\nConnect your Android device with USB debugging turned on."
        }
    }

    /// Makes the device safe to unplug: refuses while copies are running, flushes the device's
    /// writes to storage, then stops using it. `adb` itself is left running for other apps.
    func eject() async {
        guard let adb, let d = device, !ejecting else { return }
        guard !queue.hasActive else {
            alertMessage = "Wait for the copies to finish, or cancel them, before ejecting."
            return
        }
        guard deleteProgress == nil else {
            alertMessage = "Wait for the delete to finish before ejecting."
            return
        }
        ejecting = true
        defer { ejecting = false }
        let r = await adb.sync(d.serial)
        guard r.ok else {
            alertMessage = "Couldn’t eject “\(d.displayName)”: \(r.message)"
            return
        }
        // A copy may have been started while syncing; keep the device until it's done.
        guard !queue.hasActive, device?.serial == d.serial else {
            alertMessage = "Wait for the copies to finish, or cancel them, before ejecting."
            return
        }
        ejectedSerial = d.serial
        disconnect()
        deviceStatus = "It’s safe to unplug the device."
    }

    /// Uses the ejected device again without unplugging it.
    func reconnect() async {
        ejectedSerial = nil
        await pollDevices()
    }

    private func connect(_ d: DeviceInfo) async {
        guard let adb else { return }
        device = d
        storages = await adb.storages(d.serial)
        if let initial = storages.first(where: { $0.name.hasPrefix("SD") }) ?? storages.first {
            selectStorage(initial)
        }
    }

    private func disconnect() {
        device = nil
        storages = []
        storage = nil
        deviceDir = ""
        deviceItems = []
        deviceSelection = []
        deviceFree = nil
        deviceError = nil
    }

    func selectStorage(_ s: StorageRoot) {
        storage = s
        goDevice(s.path)
    }

    func goDevice(_ path: String) {
        deviceDir = path
        deviceSelection = []
        deviceItems = []
        Task { await loadDevice() }
    }

    /// Loads are numbered as they start. A result is shown only if no newer load's result already
    /// is, so an older, slower load of the same folder can't put back a stale listing, and a caller
    /// that awaits a load always sees a listing at least that fresh.
    private var loadsStarted = 0
    private var loadShown = 0

    func loadDevice() async {
        guard let adb, let d = device, !deviceDir.isEmpty else { return }
        let dir = deviceDir
        loadsStarted += 1
        let generation = loadsStarted
        deviceLoading = true
        let listing: Result<[FileItem], Error>
        do { listing = .success(try await adb.list(d.serial, dir)) } catch { listing = .failure(error) }
        let free = await adb.freeBytes(d.serial, dir)
        guard dir == deviceDir, generation > loadShown else { return }
        loadShown = generation
        switch listing {
        case .success(let items):
            deviceItems = items
            deviceError = nil
            let ids = Set(items.map(\.id))
            deviceSelection = deviceSelection.filter { ids.contains($0) }
        case .failure(let error):
            deviceItems = []
            deviceError = error.localizedDescription
        }
        deviceFree = free
        // Still loading if a newer load is on its way.
        deviceLoading = generation != loadsStarted
    }

    var deviceCanGoUp: Bool {
        guard let storage else { return false }
        return deviceDir.count > storage.path.count && deviceDir.hasPrefix(storage.path)
    }

    func deviceUp() {
        guard deviceCanGoUp else { return }
        goDevice((deviceDir as NSString).deletingLastPathComponent)
    }

    func openDevice(_ item: FileItem) {
        if item.isDirectory { goDevice(item.path) }
    }

    var deviceCrumbs: [Crumb] {
        guard let storage else { return [] }
        var crumbs = [Crumb(title: storage.name) { [weak self] in self?.goDevice(storage.path) }]
        guard deviceDir.hasPrefix(storage.path) else { return crumbs }
        var acc = storage.path
        for comp in deviceDir.dropFirst(storage.path.count).split(separator: "/") {
            acc = Parse.join(acc, String(comp))
            let target = acc
            crumbs.append(Crumb(title: String(comp)) { [weak self] in self?.goDevice(target) })
        }
        return crumbs
    }

    func makeFolder(_ name: String) async {
        guard let adb, let d = device, validName(name) else { return }
        let r = await adb.makeDirectory(d.serial, Parse.join(deviceDir, name))
        if !r.ok { alertMessage = "Couldn’t create the folder: \(r.message)" }
        await loadDevice()
    }

    func rename(_ item: FileItem, to newName: String) async {
        guard let adb, let d = device, validName(newName), newName != item.name else { return }
        let parent = (item.path as NSString).deletingLastPathComponent
        let r = await adb.move(d.serial, from: item.path, to: Parse.join(parent, newName))
        if !r.ok { alertMessage = "Couldn’t rename: \(r.message)" }
        await loadDevice()
    }

    func delete(_ items: [FileItem]) async {
        guard let adb, let d = device, deleteProgress == nil, !items.isEmpty else { return }
        defer { deleteProgress = nil }
        for (i, item) in items.enumerated() {
            deleteProgress = DeleteProgress(name: item.name, index: i + 1, count: items.count, started: Date())
            let r = await adb.delete(d.serial, item.path)
            if !r.ok {
                alertMessage = "Couldn’t delete “\(item.name)”: \(r.message)"
                break
            }
        }
        await loadDevice()
    }

    private func validName(_ name: String) -> Bool {
        let ok = !name.isEmpty && !name.contains("/") && name != "." && name != ".."
        if !ok { alertMessage = "“\(name)” isn’t a valid name." }
        return ok
    }

    // MARK: - Copying

    /// Files dropped from Finder onto the device pane.
    func dropOnDevice(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        copyToDevice(files)
        return true
    }

    func copyToDevice(_ urls: [URL]) {
        guard let adb, let d = device, !deviceDir.isEmpty else {
            alertMessage = "Connect a device first."
            return
        }
        let dir = deviceDir
        Task {
            // Ask the device, not the listing: the listing hides dot-files and may still be loading.
            let existing = await adb.existingNames(d.serial, in: dir, urls.map(\.lastPathComponent))
            let plans = urls.map { url -> Plan in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return Plan(direction: .toDevice, source: url.path, name: url.lastPathComponent,
                            isDirectory: isDir.boolValue, conflict: existing.contains(url.lastPathComponent))
            }
            submit(PendingBatch(plans: plans, serial: d.serial, destDir: dir))
        }
    }

    private static let macFolderKey = "macDestinationFolder"

    /// Asks where on the Mac to put `items`, starting in the last folder used (Downloads at first).
    func copyToMac(_ items: [FileItem]) {
        guard let d = device, !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = items.count == 1 ? "Choose where to copy “\(items[0].name)”." : "Choose where to copy \(items.count) items."
        panel.directoryURL = UserDefaults.standard.url(forKey: Self.macFolderKey)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        UserDefaults.standard.set(dir, forKey: Self.macFolderKey)
        let plans = items.map { item in
            Plan(direction: .toMac, source: item.path, name: item.name, isDirectory: item.isDirectory,
                 conflict: FileManager.default.fileExists(atPath: dir.appendingPathComponent(item.name).path))
        }
        submit(PendingBatch(plans: plans, serial: d.serial, destDir: dir.path))
    }

    /// Fulfils a Finder drop or paste: pulls `item` to exactly `url`, through the queue so it gets
    /// progress, a size check and the usual safety. `done` gets nil on success.
    func deliver(_ item: FileItem, to url: URL, done: @escaping (Error?) -> Void) {
        guard let d = device else {
            done(AdbError("The device isn’t connected."))
            return
        }
        let t = Transfer(direction: .toMac, serial: d.serial, source: item.path,
                         destDir: url.deletingLastPathComponent().path, name: url.lastPathComponent,
                         isDirectory: item.isDirectory, replace: false)
        t.onComplete = { t in
            switch t.state {
            case .done: done(nil)
            case .failed(let message): done(AdbError(message))
            default: done(CocoaError(.userCancelled))
            }
        }
        queue.add([t])
    }

    // MARK: Clipboard

    /// Finder only pastes real files, and something (clipboard history) reads the clipboard as soon
    /// as it changes, so a lazy promise wouldn't stay lazy. Instead ⌘C pulls the items into a cache
    /// folder (with progress in the transfer list) and then puts those files on the clipboard.
    private var clipboardCopy: (token: UUID, dir: URL, transfers: [Transfer])?

    func copyToClipboard(_ items: [FileItem]) {
        guard let d = device, !items.isEmpty else { return }
        let fm = FileManager.default

        // Drop the previous clipboard copy: cancel it if still running, else delete its files.
        if let previous = clipboardCopy {
            let running = previous.transfers.filter { !$0.state.isFinished }
            if running.isEmpty { try? fm.removeItem(at: previous.dir) } else { running.forEach(queue.cancel) }
        }

        let token = UUID()
        let dir = clipboardCache.appendingPathComponent(token.uuidString)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            alertMessage = "Couldn’t prepare the copy: \(error.localizedDescription)"
            return
        }
        // Nothing stale gets pasted while the files are on their way.
        pasteboard.clearContents()

        let transfers = items.map { item -> Transfer in
            let t = Transfer(direction: .toMac, serial: d.serial, source: item.path, destDir: dir.path,
                             name: item.name, isDirectory: item.isDirectory, replace: false)
            t.destLabel = "Clipboard"
            t.onComplete = { [weak self] _ in self?.clipboardTransferFinished(token) }
            return t
        }
        clipboardCopy = (token, dir, transfers)
        queue.add(transfers)
    }

    private func clipboardTransferFinished(_ token: UUID) {
        guard let copy = clipboardCopy else { return }
        if copy.token != token {
            // A newer ⌘C replaced it. Once none of the replaced copies is still running, remove them.
            let olderRunning = queue.items.contains {
                $0.destLabel == "Clipboard" && !$0.state.isFinished && $0.destDir != copy.dir.path
            }
            if !olderRunning { removeStaleClipboardCopies() }
            return
        }
        guard copy.transfers.allSatisfy(\.state.isFinished) else { return }
        let urls = copy.transfers.filter { $0.state == .done }.map { URL(fileURLWithPath: $0.destPath) }
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// Clipboard copies left over from earlier runs, except the current one.
    func removeStaleClipboardCopies() {
        let fm = FileManager.default
        let keep = clipboardCopy?.dir.lastPathComponent
        for name in (try? fm.contentsOfDirectory(atPath: clipboardCache.path)) ?? [] where name != keep {
            try? fm.removeItem(at: clipboardCache.appendingPathComponent(name))
        }
    }

    private func submit(_ batch: PendingBatch) {
        guard !batch.plans.isEmpty else { return }
        if batch.conflicts.isEmpty {
            enqueue(batch, replace: false)
        } else {
            pending = batch
        }
    }

    func enqueue(_ batch: PendingBatch, replace: Bool) {
        let transfers = batch.plans.compactMap { p -> Transfer? in
            if p.conflict && !replace { return nil }
            return Transfer(direction: p.direction, serial: batch.serial, source: p.source, destDir: batch.destDir,
                            name: p.name, isDirectory: p.isDirectory, replace: p.conflict && replace)
        }
        if transfers.contains(where: { $0.direction == .toDevice }) {
            arrivals = Set(transfers.map(\.id))
            arrivalsShown = false
        }
        queue.add(transfers)
    }

    /// The latest batch copied to the device. Each item is selected as it lands, so you can see
    /// what arrived; the first one replaces whatever was selected before.
    private var arrivals: Set<UUID> = []
    private var arrivalsShown = false

    private func showArrival(_ t: Transfer) {
        guard arrivals.contains(t.id), t.destDir == deviceDir else { return }
        let path = Parse.join(t.destDir, t.name)
        guard deviceItems.contains(where: { $0.id == path }) else { return }
        if !arrivalsShown {
            deviceSelection = []
            arrivalsShown = true
        }
        deviceSelection.insert(path)
    }

    private var failedInBatch: [Transfer] = []

    private func transferFinished(_ t: Transfer) {
        // One alert per batch, listing every failure, once nothing is left to copy.
        if t.state.isFailed { failedInBatch.append(t) }
        if !queue.hasActive {
            if let summary = TransferQueue.failureSummary(failedInBatch) { alertMessage = summary }
            failedInBatch = []
        }
        if t.direction == .toDevice, t.destDir == deviceDir {
            Task {
                await loadDevice()
                if t.state == .done { showArrival(t) }
            }
        }
    }
}
