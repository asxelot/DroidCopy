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
    @Published var storages: [StorageRoot] = []
    @Published var storage: StorageRoot?
    @Published var deviceDir = ""
    @Published var deviceItems: [FileItem] = []
    @Published var deviceSelection = Set<String>()
    @Published var deviceError: String?
    @Published var deviceFree: Int64?
    @Published var deviceLoading = false

    @Published var pending: PendingBatch?
    @Published var alertMessage: String?

    private var started = false

    init() {
        let adb = Adb.locate()
        self.adb = adb
        self.queue = TransferQueue(adb: adb ?? Adb(path: "/usr/bin/false"))
        queue.onFinished = { [weak self] t in self?.transferFinished(t) }
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await monitorDevices() }
    }

    // MARK: - Device side

    private func monitorDevices() async {
        guard let adb else {
            deviceStatus = "adb wasn’t found.\nInstall it with:  brew install android-platform-tools"
            return
        }
        while true {
            let list = await adb.devices()
            let ready = list.filter(\.isReady)
            if let current = device, !ready.contains(where: { $0.serial == current.serial }) {
                disconnect()
            }
            if device == nil {
                if let first = ready.first {
                    await connect(first)
                } else if list.contains(where: { $0.state == "unauthorized" }) {
                    deviceStatus = "Device found but not authorized.\nUnlock it and tap “Allow” on the USB debugging prompt."
                } else if list.contains(where: { $0.state == "offline" }) {
                    deviceStatus = "The device is offline.\nTry unplugging and reconnecting the cable."
                } else {
                    deviceStatus = "No device connected.\nConnect your Android device with USB debugging turned on."
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
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

    func loadDevice() async {
        guard let adb, let d = device, !deviceDir.isEmpty else { return }
        let dir = deviceDir
        deviceLoading = true
        do {
            let items = try await adb.list(d.serial, dir)
            if dir == deviceDir {
                deviceItems = items
                deviceError = nil
                let ids = Set(items.map(\.id))
                deviceSelection = deviceSelection.filter { ids.contains($0) }
            }
        } catch {
            if dir == deviceDir {
                deviceItems = []
                deviceError = error.localizedDescription
            }
        }
        let free = await adb.freeBytes(d.serial, dir)
        if dir == deviceDir {
            deviceFree = free
            deviceLoading = false
        }
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
        guard let adb, let d = device else { return }
        for item in items {
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

    func copySelectedToMac() {
        copyToMac(deviceItems.filter { deviceSelection.contains($0.id) })
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
        queue.add(transfers)
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
            Task { await loadDevice() }
        }
    }
}
