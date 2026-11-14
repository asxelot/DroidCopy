import AppKit
import DroidCopyCore

struct Crumb {
    let title: String
    let path: String
    /// The storage root at the start of the path, not a folder.
    let isStorage: Bool
    let action: () -> Void
}

/// A device folder pinned to the sidebar.
struct Favorite: Codable, Hashable, Identifiable {
    var id: String { path }
    var name: String
    var path: String
}

/// What a dragged device row carries besides its Finder file promise, so it can be moved within
/// the device (onto a folder row or a sidebar location).
struct DraggedItem: Codable, Hashable {
    let path: String
    let isDirectory: Bool

    var fileItem: FileItem {
        FileItem(name: (path as NSString).lastPathComponent, path: path, isDirectory: isDirectory, size: 0, modified: nil)
    }
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

    /// The delete, move or on-device copy in progress: which item, and where it is in the batch.
    /// `rm`, `mv` and `cp` report nothing while they run, and big files on an SD card can take a
    /// while, so the UI shows this. One runs at a time.
    struct DeviceActivity: Equatable {
        /// "Deleting", "Moving", "Copying", "Duplicating".
        let verb: String
        /// "delete", "move", "copy": for "Wait for the move to finish".
        let noun: String
        let name: String
        let index: Int
        let count: Int
        let started: Date
    }
    @Published var activity: DeviceActivity?

    // Navigation
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    /// Narrows the folder being shown to names containing this.
    @Published var searchText = ""
    @Published var showHidden: Bool {
        didSet {
            guard showHidden != oldValue else { return }
            defaults.set(showHidden, forKey: Self.showHiddenKey)
            Task { await loadDevice() }
        }
    }
    @Published var favorites: [Favorite] = []
    /// Set to a path to start renaming that row in place; the table clears it once editing starts.
    @Published var renamingPath: String?
    /// Items cut with ⌘X, shown dimmed until they're pasted somewhere or the clipboard changes.
    @Published var cutPaths: Set<String> = []

    /// A move or on-device copy whose names clash with items already in the destination.
    struct PendingMove: Identifiable {
        let id = UUID()
        let items: [FileItem]
        let destDir: String
        let copy: Bool
        let clashes: [String]
    }
    @Published var pendingMove: PendingMove?

    /// What Get Info shows. Sizes of folders and counts come from the device, so they fill in later.
    struct ItemInfo: Identifiable {
        let id = UUID()
        let items: [FileItem]
        var size: Int64?
        var count: Int?
        var loading = true
    }
    @Published var info: ItemInfo?

    @Published var pending: PendingBatch?
    @Published var alertMessage: String?

    private var started = false
    /// The clipboard ⌘C writes to, and the folder it pulls into first. Injected so tests don't
    /// touch the real clipboard or caches.
    let pasteboard: NSPasteboard
    let clipboardCache: URL
    /// Where files are pulled to be opened or previewed on the Mac.
    let openCache: URL
    /// Settings: hidden files, favourites, the last folder per device.
    let defaults: UserDefaults
    /// Opens a pulled file in its Mac app. Replaced in tests.
    var openOnMac: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Tells the person a batch finished while they were in another app. Replaced in tests.
    var notify: (String, String) -> Void = Notifier.post

    nonisolated static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DroidCopy")
    nonisolated static let defaultClipboardCache = cacheRoot.appendingPathComponent("Clipboard")
    private static let showHiddenKey = "showHiddenFiles"

    init(adb: Adb? = Adb.locate(), pasteboard: NSPasteboard = .general,
         clipboardCache: URL = AppModel.defaultClipboardCache,
         openCache: URL = AppModel.cacheRoot.appendingPathComponent("Open"),
         defaults: UserDefaults = .standard) {
        self.adb = adb
        self.pasteboard = pasteboard
        self.clipboardCache = clipboardCache
        self.openCache = openCache
        self.defaults = defaults
        self.showHidden = defaults.bool(forKey: Self.showHiddenKey)
        self.queue = TransferQueue(adb: adb ?? Adb(path: "/usr/bin/false"))
        queue.onFinished = { [weak self] t in self?.transferFinished(t) }
    }

    func start() {
        guard !started else { return }
        started = true
        removeStaleClipboardCopies()
        try? FileManager.default.removeItem(at: openCache)
        Task { await monitorDevices() }
    }

    // MARK: - Device side

    private func monitorDevices() async {
        guard let adb else {
            adbMissing = true
            return
        }
        // Start adb's server where it won't count as part of DroidCopy (see `Adb.startServer`).
        _ = await adb.startServer { await AdbHelper.startServer(adbPath: adb.path) }
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
        if let activity {
            alertMessage = "Wait for the \(activity.noun) to finish before ejecting."
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
        if let saved = loadFavorites(d.serial) {
            favorites = saved
        } else {
            // First time with this device: start with the usual folders, like Finder's Favourites.
            favorites = await standardFavorites(d.serial)
            if device?.serial == d.serial { saveFavorites() }
        }
        // Back where you were last time, if that folder is still there.
        if let last = defaults.string(forKey: lastFolderKey(d.serial)),
           let s = storageContaining(last), await adb.exists(d.serial, last), device?.serial == d.serial {
            storage = s
            goDevice(last, recordHistory: false)
        } else if let initial = storages.first(where: { $0.name.hasPrefix("SD") }) ?? storages.first {
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
        backStack = []
        forwardStack = []
        favorites = []
        searchText = ""
        cutPaths = []
        cut = nil
        undoManager?.removeAllActions(withTarget: self)
        refreshUndoMenu()
    }

    func selectStorage(_ s: StorageRoot) {
        storage = s
        goDevice(s.path)
    }

    /// The storage a path is on: the one with the longest root that contains it.
    func storageContaining(_ path: String) -> StorageRoot? {
        storages.filter { Parse.isSameOrInside(path, $0.path) }.max { $0.path.count < $1.path.count }
    }

    /// Opens a device folder. Like Finder, it remembers where you were for Back.
    func goDevice(_ path: String, recordHistory: Bool = true) {
        if recordHistory, !deviceDir.isEmpty, path != deviceDir {
            backStack.append(deviceDir)
            forwardStack = []
        }
        if let s = storageContaining(path), s != storage { storage = s }
        deviceDir = path
        deviceSelection = []
        deviceItems = []
        searchText = ""
        renamingPath = nil
        Task { await loadDevice() }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(deviceDir)
        goDevice(previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(deviceDir)
        goDevice(next, recordHistory: false)
    }

    /// ⇧⌘G: a full path, or one inside the current storage ("ROMs/switch").
    func goToFolder(_ input: String) {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, device != nil else { return }
        if !path.hasPrefix("/") { path = Parse.join(storage?.path ?? deviceDir, path) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        goDevice(path)
    }

    /// Items in the folder, narrowed by the search field.
    var visibleItems: [FileItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? deviceItems : deviceItems.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// Selected items, in list order.
    var selectedItems: [FileItem] {
        visibleItems.filter { deviceSelection.contains($0.id) }
    }

    /// The folder's name, for the window title.
    var folderTitle: String {
        guard device != nil, !deviceDir.isEmpty else { return "DroidCopy" }
        if let storage, deviceDir == storage.path { return storage.name }
        return (deviceDir as NSString).lastPathComponent
    }

    /// The sidebar row for the folder being shown, if it has one.
    var sidebarSelection: String? {
        if favorites.contains(where: { $0.path == deviceDir }) || storages.contains(where: { $0.path == deviceDir }) {
            return deviceDir
        }
        return nil
    }

    /// Finder's status bar: "12 items, 22 GB available" or "2 of 12 selected, 22 GB available".
    var statusText: String {
        let shown = visibleItems.count
        let selected = selectedItems.count
        var text = selected > 0 ? "\(selected) of \(shown) selected" : (shown == 1 ? "1 item" : "\(shown) items")
        if let deviceFree { text += ", \(Fmt.bytes(deviceFree)) available" }
        return text
    }

    /// Loads are numbered as they start. A result is shown only if no newer load's result already
    /// is, so an older, slower load of the same folder can't put back a stale listing, and a caller
    /// that awaits a load always sees a listing at least that fresh.
    private var loadsStarted = 0
    private var loadShown = 0
    /// Selected once the next listing arrives: the folder you came up from, like Finder's ⌘↑.
    private var selectAfterLoad: Set<String> = []

    func loadDevice() async {
        guard let adb, let d = device, !deviceDir.isEmpty else { return }
        let dir = deviceDir
        loadsStarted += 1
        let generation = loadsStarted
        deviceLoading = true
        let listing: Result<[FileItem], Error>
        do { listing = .success(try await adb.list(d.serial, dir, showHidden: showHidden)) } catch { listing = .failure(error) }
        let free = await adb.freeBytes(d.serial, dir)
        guard dir == deviceDir, generation > loadShown else { return }
        loadShown = generation
        switch listing {
        case .success(let items):
            deviceItems = items
            deviceError = nil
            let ids = Set(items.map(\.id))
            deviceSelection = deviceSelection.union(selectAfterLoad).filter { ids.contains($0) }
            selectAfterLoad = []
            defaults.set(dir, forKey: lastFolderKey(d.serial))
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

    /// ⌘↑: the enclosing folder, with the folder you came from selected.
    func deviceUp() {
        guard deviceCanGoUp else { return }
        let from = deviceDir
        goDevice(Parse.parent(deviceDir))
        selectAfterLoad = [from]
    }

    /// Double-click or ⌘O: folders open in the list; files are pulled to the Mac and opened there.
    func openDevice(_ item: FileItem) {
        if item.isDirectory {
            goDevice(item.path)
        } else {
            fetch([item], label: "Opening") { [weak self] urls in urls.forEach { self?.openOnMac($0) } }
        }
    }

    func openSelection() {
        let items = selectedItems
        if items.count == 1, items[0].isDirectory { openDevice(items[0]) }
        else { items.filter { !$0.isDirectory }.forEach(openDevice) }
    }

    var deviceCrumbs: [Crumb] {
        guard let storage else { return [] }
        var crumbs = [Crumb(title: storage.name, path: storage.path, isStorage: true) { [weak self] in self?.goDevice(storage.path) }]
        guard deviceDir.hasPrefix(storage.path) else { return crumbs }
        var acc = storage.path
        for comp in deviceDir.dropFirst(storage.path.count).split(separator: "/") {
            acc = Parse.join(acc, String(comp))
            let target = acc
            crumbs.append(Crumb(title: String(comp), path: target, isStorage: false) { [weak self] in self?.goDevice(target) })
        }
        return crumbs
    }

    func makeFolder(_ name: String) async {
        guard let adb, let d = device, validName(name) else { return }
        let r = await adb.makeDirectory(d.serial, Parse.join(deviceDir, name))
        if !r.ok { alertMessage = "Couldn’t create the folder: \(r.message)" }
        await loadDevice()
    }

    /// ⇧⌘N, like Finder: makes "untitled folder", selects it and starts renaming it.
    func newFolder() async {
        guard let adb, let d = device, !deviceDir.isEmpty else { return }
        let dir = deviceDir
        let taken = Set(((try? await adb.list(d.serial, dir, showHidden: true)) ?? []).map(\.name))
        let name = Parse.untitledFolderName(taken: taken)
        let path = Parse.join(dir, name)
        let r = await adb.makeDirectory(d.serial, path)
        guard r.ok else {
            alertMessage = "Couldn’t create the folder: \(r.message)"
            return
        }
        record(DeviceChange(name: "New Folder", serial: d.serial, op: .makeFolder(path)))
        await loadDevice()
        guard dir == deviceDir else { return }
        searchText = ""
        deviceSelection = [path]
        renamingPath = path
    }

    func rename(_ item: FileItem, to newName: String) async {
        guard let adb, let d = device, newName != item.name, validName(newName) else { return }
        let newPath = Parse.join(Parse.parent(item.path), newName)
        let r = await adb.move(d.serial, from: item.path, to: newPath)
        if r.ok {
            pathMoved(from: item.path, to: newPath)
            if deviceSelection.contains(item.path) { selectAfterLoad.insert(newPath) }
            record(DeviceChange(name: "Rename", serial: d.serial, op: .move([(item.path, newPath)])))
        } else {
            alertMessage = "Couldn’t rename: \(r.message)"
        }
        await loadDevice()
    }

    /// Refuses to start a second delete, move or copy on the device while one runs.
    private func deviceIsFree() -> Bool {
        guard let activity else { return true }
        alertMessage = "Wait for the \(activity.noun) to finish."
        return false
    }

    func delete(_ items: [FileItem]) async {
        guard let adb, let d = device, !items.isEmpty, deviceIsFree() else { return }
        defer { activity = nil }
        for (i, item) in items.enumerated() {
            activity = DeviceActivity(verb: "Deleting", noun: "delete", name: item.name, index: i + 1, count: items.count, started: Date())
            let r = await adb.delete(d.serial, item.path)
            if !r.ok {
                alertMessage = "Couldn’t delete “\(item.name)”: \(r.message)"
                break
            }
            pathDeleted(item.path)
        }
        activity = nil
        await loadDevice()
    }

    // MARK: - Moving and copying on the device

    /// Moves (or with `copy`, copies) items into another device folder: a drag onto a folder row
    /// or sidebar location, or ⌘X then ⌘V. Name clashes are asked about first.
    func move(_ items: [FileItem], to dir: String, copy: Bool = false) async {
        guard let adb, let d = device, !items.isEmpty, deviceIsFree() else { return }
        if let folder = items.first(where: { $0.isDirectory && Parse.isSameOrInside(dir, $0.path) }) {
            alertMessage = "“\(folder.name)” can’t be \(copy ? "copied" : "moved") into itself."
            return
        }
        // Copying into its own folder is Duplicate; moving there does nothing.
        let here = items.filter { Parse.parent($0.path) == dir }
        let elsewhere = items.filter { Parse.parent($0.path) != dir }
        if copy && !here.isEmpty { await duplicate(here) }
        guard !elsewhere.isEmpty else { return }
        let clashes = await adb.existingNames(d.serial, in: dir, elsewhere.map(\.name))
        if clashes.isEmpty {
            await performMove(elsewhere, to: dir, copy: copy, replacing: [])
        } else {
            pendingMove = PendingMove(items: elsewhere, destDir: dir, copy: copy,
                                      clashes: elsewhere.map(\.name).filter(clashes.contains))
        }
    }

    /// The answer to a clash: replace the existing items, or leave them and move the rest.
    func resolve(_ p: PendingMove, replace: Bool) async {
        pendingMove = nil
        let clashing = Set(p.clashes)
        let items = replace ? p.items : p.items.filter { !clashing.contains($0.name) }
        await performMove(items, to: p.destDir, copy: p.copy, replacing: replace ? clashing : [])
    }

    private func performMove(_ items: [FileItem], to dir: String, copy: Bool, replacing: Set<String>) async {
        guard let adb, let d = device, !items.isEmpty, deviceIsFree() else { return }
        var landed: Set<String> = []
        var undoable: [(String, String)] = []
        for (i, item) in items.enumerated() {
            activity = DeviceActivity(verb: copy ? "Copying" : "Moving", noun: copy ? "copy" : "move",
                                      name: item.name, index: i + 1, count: items.count, started: Date())
            let dest = Parse.join(dir, item.name)
            let replace = replacing.contains(item.name)
            let r = copy ? await adb.copy(d.serial, from: item.path, to: dest, replace: replace)
                         : await adb.move(d.serial, from: item.path, to: dest, replace: replace)
            if !r.ok {
                alertMessage = "Couldn’t \(copy ? "copy" : "move") “\(item.name)”: \(r.message)"
                break
            }
            if !copy { pathMoved(from: item.path, to: dest) }
            landed.insert(dest)
            // A replaced item is gone for good, so that one can't be put back.
            if !replace { undoable.append((item.path, dest)) }
        }
        activity = nil
        if !undoable.isEmpty {
            record(DeviceChange(name: copy ? "Copy" : "Move", serial: d.serial, op: copy ? .copy(undoable) : .move(undoable)))
        }
        cutPaths.subtract(items.map(\.path))
        if dir == deviceDir { selectAfterLoad = landed; deviceSelection = [] }
        await loadDevice()
    }

    /// ⌘D: copies each item next to itself as "name copy", like Finder, and selects the copies.
    func duplicate(_ items: [FileItem]) async {
        guard let adb, let d = device, !items.isEmpty, deviceIsFree() else { return }
        var made: Set<String> = []
        var copies: [(String, String)] = []
        var takenByDir: [String: Set<String>] = [:]
        for (i, item) in items.enumerated() {
            let dir = Parse.parent(item.path)
            if takenByDir[dir] == nil {
                takenByDir[dir] = Set(((try? await adb.list(d.serial, dir, showHidden: true)) ?? []).map(\.name))
            }
            let name = Parse.copyName(item.name, isDirectory: item.isDirectory, taken: takenByDir[dir] ?? [])
            takenByDir[dir]?.insert(name)
            activity = DeviceActivity(verb: "Duplicating", noun: "copy", name: item.name, index: i + 1, count: items.count, started: Date())
            let dest = Parse.join(dir, name)
            let r = await adb.copy(d.serial, from: item.path, to: dest)
            if !r.ok {
                alertMessage = "Couldn’t duplicate “\(item.name)”: \(r.message)"
                break
            }
            made.insert(dest)
            copies.append((item.path, dest))
        }
        activity = nil
        if !copies.isEmpty { record(DeviceChange(name: "Duplicate", serial: d.serial, op: .copy(copies))) }
        selectAfterLoad = made
        deviceSelection = []
        await loadDevice()
    }

    // MARK: Undo

    /// A change on the device that ⌘Z can reverse. Deletes aren't undoable (Android has no Trash),
    /// and neither are copies from the Mac.
    struct DeviceChange {
        enum Op {
            case move([(from: String, to: String)])
            case copy([(source: String, copy: String)])
            case removeCopies([(source: String, copy: String)])
            case makeFolder(String)
            case removeFolder(String)
        }
        /// For the Edit menu: "Undo Rename".
        let name: String
        let serial: String
        let op: Op

        var inverse: DeviceChange {
            let back: Op
            switch op {
            case .move(let pairs): back = .move(pairs.reversed().map { ($0.to, $0.from) })
            case .copy(let pairs): back = .removeCopies(pairs)
            case .removeCopies(let pairs): back = .copy(pairs)
            case .makeFolder(let path): back = .removeFolder(path)
            case .removeFolder(let path): back = .makeFolder(path)
            }
            return DeviceChange(name: name, serial: serial, op: back)
        }
    }

    /// The window's undo manager, which the Edit menu's Undo and Redo use. Set by the window.
    weak var undoManager: UndoManager? { didSet { observeUndo() } }
    /// The Edit menu's titles, "Undo Rename" and so on, like Finder. Text fields' typing shows too,
    /// since they share the window's undo manager.
    @Published private(set) var undoTitle = "Undo"
    @Published private(set) var redoTitle = "Redo"
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoObservers: [NSObjectProtocol] = []

    private func observeUndo() {
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        let names: [Notification.Name] = [.NSUndoManagerCheckpoint, .NSUndoManagerDidCloseUndoGroup,
                                          .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange]
        // Posted on the main thread, so handled right there (queue nil), before the menu is next drawn.
        undoObservers = names.map {
            NotificationCenter.default.addObserver(forName: $0, object: undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUndoMenu() }
            }
        }
        refreshUndoMenu()
    }

    private func refreshUndoMenu() {
        let um = undoManager
        if canUndo != (um?.canUndo ?? false) { canUndo = um?.canUndo ?? false }
        if canRedo != (um?.canRedo ?? false) { canRedo = um?.canRedo ?? false }
        let u = um?.undoMenuItemTitle ?? "Undo", r = um?.redoMenuItemTitle ?? "Redo"
        if undoTitle != u { undoTitle = u }
        if redoTitle != r { redoTitle = r }
    }
    /// The undo or redo running on the device. Tests wait for it.
    private(set) var undoTask: Task<Void, Never>?

    /// Makes `done` the next thing ⌘Z reverses.
    private func record(_ done: DeviceChange) {
        guard let um = undoManager else { return }
        // Device changes finish outside any event, where the undo manager's automatic group
        // would stay open (and the Edit menu unaware) until something else closes it.
        let opened = um.groupingLevel == 0
        if opened { um.beginUndoGrouping() }
        registerReversal(of: done)
        if opened { um.endUndoGrouping() }
    }

    private func registerReversal(of done: DeviceChange) {
        undoManager?.registerUndo(withTarget: self) { $0.run(done.inverse) }
        undoManager?.setActionName(done.name)
    }

    /// Runs an undo or redo. Its own reversal is registered right away, while the undo manager
    /// is undoing (or redoing), so it lands on the other stack; the device work follows.
    private func run(_ change: DeviceChange) {
        let verb = undoManager?.isRedoing == true ? "redo" : "undo"
        registerReversal(of: change)
        undoTask = Task { await perform(change, verb: verb) }
    }

    private func perform(_ change: DeviceChange, verb: String) async {
        func fail(_ why: String) {
            alertMessage = "Couldn’t \(verb) \(change.name.lowercased()): \(why)"
            // What's on the device no longer matches the history.
            undoManager?.removeAllActions(withTarget: self)
            refreshUndoMenu()
        }
        guard let adb, let d = device, d.serial == change.serial else { return fail("the device isn’t connected.") }
        guard activity == nil else { return fail("wait for the \(activity!.noun) to finish.") }
        var touched: [String] = []
        var failure: String?
        let label = verb == "undo" ? "Undoing" : "Redoing"
        func step(_ path: String, _ i: Int, _ n: Int) {
            activity = DeviceActivity(verb: label, noun: verb, name: (path as NSString).lastPathComponent,
                                      index: i + 1, count: n, started: Date())
        }
        switch change.op {
        case .move(let pairs):
            for (i, p) in pairs.enumerated() {
                step(p.from, i, pairs.count)
                let r = await adb.move(d.serial, from: p.from, to: p.to)
                if !r.ok { failure = r.message; break }
                pathMoved(from: p.from, to: p.to)
                touched.append(p.to)
            }
        case .copy(let pairs):
            for (i, p) in pairs.enumerated() {
                step(p.source, i, pairs.count)
                let r = await adb.copy(d.serial, from: p.source, to: p.copy)
                if !r.ok { failure = r.message; break }
                touched.append(p.copy)
            }
        case .removeCopies(let pairs):
            for (i, p) in pairs.enumerated() {
                step(p.copy, i, pairs.count)
                // Without the original, the copy is the only one left; keep it.
                guard await adb.exists(d.serial, p.source) else {
                    failure = "“\((p.source as NSString).lastPathComponent)” is gone, so its copy is kept."
                    break
                }
                let r = await adb.delete(d.serial, p.copy)
                if !r.ok { failure = r.message; break }
                pathDeleted(p.copy)
            }
        case .makeFolder(let path):
            let r = await adb.makeDirectory(d.serial, path)
            if r.ok { touched.append(path) } else { failure = r.message }
        case .removeFolder(let path):
            let r = await adb.removeEmptyDirectory(d.serial, path)
            if !r.ok { failure = "“\((path as NSString).lastPathComponent)” isn’t empty any more." }
        }
        activity = nil
        if let failure { fail(failure) }
        selectAfterLoad = Set(touched.filter { Parse.parent($0) == deviceDir })
        deviceSelection = []
        await loadDevice()
    }

    // MARK: Cut and paste

    /// ⌘X marks items to move; ⌘V in another folder moves them there. The clipboard gets their
    /// paths as text, and the cut is forgotten once anything else is copied.
    private var cut: (serial: String, items: [FileItem], changeCount: Int)?

    func cutItems(_ items: [FileItem]) {
        guard let d = device, !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
        cut = (d.serial, items, pasteboard.changeCount)
        cutPaths = Set(items.map(\.path))
    }

    /// The cut items, if the clipboard still holds the cut.
    private var activeCut: [FileItem]? {
        guard let cut, cut.serial == device?.serial, cut.changeCount == pasteboard.changeCount else { return nil }
        return cut.items
    }

    var canPaste: Bool {
        device != nil && (activeCut != nil || !Self.fileURLs(on: pasteboard).isEmpty)
    }

    /// ⌘V: moves cut items here, or copies files copied in Finder.
    func paste() {
        if let items = activeCut {
            cut = nil
            let dir = deviceDir
            Task { await move(items, to: dir) }
            return
        }
        if !cutPaths.isEmpty { cutPaths = [] }
        let urls = Self.fileURLs(on: pasteboard)
        if !urls.isEmpty { copyToDevice(urls) }
    }

    nonisolated static func fileURLs(on pb: NSPasteboard) -> [URL] {
        pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// ⌥⌘C: the items' device paths as text.
    func copyPaths(_ items: [FileItem]) {
        let paths = items.isEmpty ? [deviceDir] : items.map(\.path)
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: Favourites and remembered places

    private func favoritesKey(_ serial: String) -> String { "favorites.\(serial)" }
    private func lastFolderKey(_ serial: String) -> String { "lastFolder.\(serial)" }

    /// nil if favourites were never saved for this device (not even an empty list).
    private func loadFavorites(_ serial: String) -> [Favorite]? {
        guard let data = defaults.data(forKey: favoritesKey(serial)) else { return nil }
        return (try? JSONDecoder().decode([Favorite].self, from: data)) ?? []
    }

    /// Folders that start in the sidebar, in this order, if the device has them: game folders
    /// on each card, then Android's standard folders in internal storage.
    static let standardCardFolders = ["ROMs"]
    static let standardInternalFolders = ["Download", "Documents", "DCIM", "Pictures", "Movies", "Music"]

    private func standardFavorites(_ serial: String) async -> [Favorite] {
        guard let adb else { return [] }
        var result: [Favorite] = []
        let cards = storages.filter { $0.name.hasPrefix("SD") }
        let phone = storages.filter { !$0.name.hasPrefix("SD") }
        for (roots, names) in [(cards, Self.standardCardFolders), (phone, Self.standardInternalFolders)] {
            for root in roots {
                let present = await adb.existingNames(serial, in: root.path, names)
                for name in names where present.contains(name) {
                    result.append(Favorite(name: name, path: Parse.join(root.path, name)))
                }
            }
        }
        return result
    }

    private func saveFavorites() {
        guard let d = device, let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: favoritesKey(d.serial))
    }

    /// ⌃⌘T: pins the selected folders to the sidebar, or the folder being shown if none is selected.
    func addToSidebar(_ items: [FileItem]) {
        let folders = items.filter(\.isDirectory)
        let new: [Favorite]
        if folders.isEmpty {
            guard device != nil, !deviceDir.isEmpty, storage?.path != deviceDir else { return }
            new = [Favorite(name: (deviceDir as NSString).lastPathComponent, path: deviceDir)]
        } else {
            new = folders.map { Favorite(name: $0.name, path: $0.path) }
        }
        for f in new where !favorites.contains(where: { $0.path == f.path }) { favorites.append(f) }
        saveFavorites()
    }

    func removeFromSidebar(_ favorite: Favorite) {
        favorites.removeAll { $0.path == favorite.path }
        saveFavorites()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        saveFavorites()
    }

    /// Keeps favourites pointing at a folder that was renamed or moved, or anything inside it.
    private func pathMoved(from old: String, to new: String) {
        var changed = false
        for i in favorites.indices {
            if let moved = Parse.rebase(favorites[i].path, from: old, to: new) {
                favorites[i].path = moved
                if favorites[i].path == new { favorites[i].name = (new as NSString).lastPathComponent }
                changed = true
            }
        }
        if changed { saveFavorites() }
    }

    private func pathDeleted(_ path: String) {
        let before = favorites.count
        favorites.removeAll { Parse.isSameOrInside($0.path, path) }
        if favorites.count != before { saveFavorites() }
        cutPaths.remove(path)
    }

    // MARK: Get Info

    /// ⌘I: kind, size, item count, where it is and when it changed. Folder sizes and counts come
    /// from the device, so they appear a moment later.
    func getInfo(_ items: [FileItem]) {
        guard let adb, let d = device else { return }
        let targets = items.isEmpty
            ? [FileItem(name: folderTitle, path: deviceDir, isDirectory: true, size: 0, modified: nil)]
            : items
        let start = ItemInfo(items: targets)
        info = start
        Task {
            var size: Int64 = 0
            var count = 0
            var known = true
            for item in targets {
                if item.isDirectory {
                    async let s = adb.size(d.serial, item.path)
                    async let c = adb.itemCount(d.serial, item.path)
                    let (bytes, n) = await (s, c)
                    if let bytes, let n { size += bytes; count += n } else { known = false }
                } else {
                    size += item.size
                    count += 1
                }
            }
            guard info?.id == start.id else { return }
            info?.size = known ? size : nil
            info?.count = known ? count : nil
            info?.loading = false
        }
    }

    private func validName(_ name: String) -> Bool {
        let ok = !name.isEmpty && !name.contains("/") && name != "." && name != ".."
        if !ok { alertMessage = "“\(name)” isn’t a valid name." }
        return ok
    }

    // MARK: - Copying

    /// Files dropped from Finder onto the device pane.
    /// Files dropped from Finder onto the list (into the folder shown, or onto a folder row with
    /// `into`) or onto a sidebar location.
    func dropOnDevice(_ urls: [URL], into folder: String? = nil) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        copyToDevice(files, into: folder)
        return true
    }

    func copyToDevice(_ urls: [URL], into folder: String? = nil) {
        guard let adb, let d = device, !deviceDir.isEmpty else {
            alertMessage = "Connect a device first."
            return
        }
        let dir = folder ?? deviceDir
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
        t.expectedBytes = item.isDirectory ? nil : item.size
        t.onComplete = { t in
            switch t.state {
            case .done: done(nil)
            case .failed(let message): done(AdbError(message))
            default: done(CocoaError(.userCancelled))
            }
        }
        queue.add([t])
    }

    // MARK: Opening on the Mac

    /// Pulls device files into a temporary folder (with progress in the transfer list) and hands
    /// the ones that arrived to `done`. Used to open files and to preview them with Quick Look.
    func fetch(_ items: [FileItem], label: String, done: @escaping ([URL]) -> Void) {
        guard let d = device, !items.isEmpty else { return }
        let dir = openCache.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            alertMessage = "Couldn’t prepare the file: \(error.localizedDescription)"
            return
        }
        let transfers = items.map { item -> Transfer in
            let t = Transfer(direction: .toMac, serial: d.serial, source: item.path, destDir: dir.path,
                             name: item.name, isDirectory: item.isDirectory, replace: false)
            t.destLabel = label
            t.expectedBytes = item.isDirectory ? nil : item.size
            return t
        }
        for t in transfers {
            t.onComplete = { _ in
                guard transfers.allSatisfy(\.state.isFinished) else { return }
                done(transfers.filter { $0.state == .done }.map { URL(fileURLWithPath: $0.destPath) })
            }
        }
        queue.add(transfers)
    }

    /// Quick Look needs the files on the Mac, so very big ones are left out.
    static let previewLimit: Int64 = 1 << 30

    /// Space: pulls the selected files and shows them in Quick Look.
    func preview(_ items: [FileItem], show: @escaping ([URL]) -> Void) {
        let files = items.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        let small = files.filter { $0.size <= Self.previewLimit }
        guard !small.isEmpty else {
            alertMessage = "“\(files[0].name)” is too big to preview. Copy it to the Mac to open it."
            return
        }
        fetch(small, label: "Quick Look", done: show)
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
        cut = nil
        cutPaths = []

        let transfers = items.map { item -> Transfer in
            let t = Transfer(direction: .toMac, serial: d.serial, source: item.path, destDir: dir.path,
                             name: item.name, isDirectory: item.isDirectory, replace: false)
            t.destLabel = "Clipboard"
            t.expectedBytes = item.isDirectory ? nil : item.size
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

    /// The notification for a finished batch, or nil when there's nothing worth saying (files
    /// pulled only to open or preview them).
    static func batchNotification(done: [Transfer], failed: [Transfer]) -> (String, String)? {
        let quiet: Set<String> = ["Opening", "Quick Look"]
        let done = done.filter { !quiet.contains($0.destLabel ?? "") }
        let failed = failed.filter { !quiet.contains($0.destLabel ?? "") }
        guard !done.isEmpty || !failed.isEmpty else { return nil }
        let toDevice = (done + failed).allSatisfy { $0.direction == .toDevice }
        let place = toDevice ? "the device" : "the Mac"
        let title = failed.isEmpty ? "Copying finished" : "Copying finished with problems"
        var parts: [String] = []
        if !done.isEmpty {
            parts.append(done.count == 1 ? "“\(done[0].name)” was copied to \(place)." : "\(done.count) items were copied to \(place).")
        }
        if !failed.isEmpty {
            parts.append(failed.count == 1 ? "“\(failed[0].name)” couldn’t be copied." : "\(failed.count) items couldn’t be copied.")
        }
        return (title, parts.joined(separator: " "))
    }

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
    private var doneInBatch: [Transfer] = []

    private func transferFinished(_ t: Transfer) {
        // One alert per batch, listing every failure, once nothing is left to copy.
        if t.state.isFailed { failedInBatch.append(t) }
        if t.state == .done { doneInBatch.append(t) }
        if !queue.hasActive {
            if let summary = TransferQueue.failureSummary(failedInBatch) { alertMessage = summary }
            if let (title, body) = Self.batchNotification(done: doneInBatch, failed: failedInBatch),
               !(NSApp?.isActive ?? false) {
                notify(title, body)
            }
            failedInBatch = []
            doneInBatch = []
        }
        if t.direction == .toDevice, t.destDir == deviceDir {
            Task {
                await loadDevice()
                if t.state == .done { showArrival(t) }
            }
        }
    }
}
