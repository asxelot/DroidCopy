import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DroidCopyCore

/// Window-level UI state: dialogs, and which bars are shown. Shared with the menu commands.
/// (An ObservableObject because `@State` needs a macro plugin the Command Line Tools lack.)
@MainActor
final class WindowState: ObservableObject {
    @Published var deleting: [FileItem] = []
    @Published var goingToFolder = false
    @Published var goToPath = ""
    @Published var showPathBar: Bool { didSet { defaults.set(showPathBar, forKey: "showPathBar") } }
    @Published var showStatusBar: Bool { didSet { defaults.set(showStatusBar, forKey: "showStatusBar") } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Off unless turned on in the View menu, as in Finder.
        showPathBar = defaults.object(forKey: "showPathBar") as? Bool ?? false
        showStatusBar = defaults.object(forKey: "showStatusBar") as? Bool ?? false
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: WindowState

    var body: some View {
        NavigationSplitView {
            Sidebar(queue: model.queue)
                .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 320)
        } detail: {
            BrowserView(queue: model.queue)
                .navigationSplitViewColumnWidth(min: 420, ideal: 860)
        }
        .navigationTitle(model.folderTitle)
        .toolbar { BrowserToolbar() }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .frame(minWidth: 680, minHeight: 440)
        .confirmationDialog(
            conflictTitle,
            isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } }),
            titleVisibility: .visible,
            presenting: model.pending
        ) { batch in
            Button("Replace") { model.enqueue(batch, replace: true) }
            if batch.conflicts.count < batch.plans.count {
                Button("Skip Existing") { model.enqueue(batch, replace: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { batch in
            Text(Self.nameList(batch.conflicts.map(\.name)))
        }
        .confirmationDialog(
            moveTitle,
            isPresented: Binding(get: { model.pendingMove != nil }, set: { if !$0 { model.pendingMove = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingMove
        ) { move in
            Button("Replace") { Task { await model.resolve(move, replace: true) } }
            if move.clashes.count < move.items.count {
                Button("Skip Existing") { Task { await model.resolve(move, replace: false) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { move in
            Text(Self.nameList(move.clashes))
        }
        .confirmationDialog(
            ui.deleting.count == 1 ? "Delete “\(ui.deleting[0].name)” from the device?" : "Delete \(ui.deleting.count) items from the device?",
            isPresented: Binding(get: { !ui.deleting.isEmpty }, set: { if !$0 { ui.deleting = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { let items = ui.deleting; Task { await model.delete(items) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Android has no Trash, so this can’t be undone.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }),
            presenting: model.alertMessage
        ) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .sheet(item: $model.info) { info in
            InfoSheet(info: info) { model.info = nil }
        }
        .sheet(isPresented: $ui.goingToFolder) {
            GoToFolderSheet()
        }
    }

    private var conflictTitle: String {
        let n = model.pending?.conflicts.count ?? 0
        return n == 1 ? "This item already exists. Replace it?" : "\(n) items already exist. Replace them?"
    }

    private var moveTitle: String {
        guard let move = model.pendingMove else { return "" }
        let folder = (move.destDir as NSString).lastPathComponent
        return move.clashes.count == 1
            ? "An item named “\(move.clashes[0])” already exists in “\(folder)”. Replace it?"
            : "\(move.clashes.count) items already exist in “\(folder)”. Replace them?"
    }

    static func nameList(_ names: [String]) -> String {
        let shown = names.prefix(6).joined(separator: "\n")
        return names.count > 6 ? shown + "\n…and \(names.count - 6) more" : shown
    }
}

// MARK: - Toolbar

struct BrowserToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("See folders you viewed previously")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("See folders you viewed next")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await model.newFolder() } } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .disabled(model.device == nil)
                .help("New Folder")
            ActionMenu()
        }
    }
}

/// Finder's Action (…) button: what you can do with the selection.
struct ActionMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: WindowState

    var body: some View {
        let items = model.selectedItems
        Menu {
            Button("New Folder") { Task { await model.newFolder() } }
            Divider()
            Button("Open") { model.openSelection() }.disabled(items.isEmpty)
            Button("Get Info") { model.getInfo(items) }
            Button("Rename") { model.renamingPath = items.first?.path }.disabled(items.count != 1)
            Button("Duplicate") { Task { await model.duplicate(items) } }.disabled(items.isEmpty)
            Divider()
            Button("Copy to Mac…") { model.copyToMac(items) }.disabled(items.isEmpty)
            Button("Copy Path") { model.copyPaths(items) }
            Button("Add to Sidebar") { model.addToSidebar(items) }
            Divider()
            Button("Delete…") { ui.deleting = items }.disabled(items.isEmpty)
        } label: {
            Label("Action", systemImage: "ellipsis.circle")
        }
        .disabled(model.device == nil)
        .help("Perform tasks with the selected items")
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var queue: TransferQueue

    var body: some View {
        List(selection: Binding(get: { model.sidebarSelection }, set: { if let path = $0 { model.goDevice(path) } })) {
            if let device = model.device {
                Section("Favourites") {
                    if model.favorites.isEmpty {
                        Text("Right-click a folder and choose Add to Sidebar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.favorites) { f in
                        Label(f.name, systemImage: Self.symbol(forFavorite: f))
                            .tag(f.path)
                            .help(f.path)
                            .contextMenu {
                                Button("Open") { model.goDevice(f.path) }
                                Button("Remove from Sidebar") { model.removeFromSidebar(f) }
                            }
                            .onDrop(of: SidebarDrop.types, isTargeted: nil) { SidebarDrop.handle($0, into: f.path, model: model) }
                    }
                    .onMove { model.moveFavorites(from: $0, to: $1) }
                }
                Section {
                    ForEach(model.storages) { s in
                        Label(s.name, systemImage: Self.symbol(for: s))
                            .tag(s.path)
                            .help(s.path)
                            .onDrop(of: SidebarDrop.types, isTargeted: nil) { SidebarDrop.handle($0, into: s.path, model: model) }
                    }
                } header: {
                    HStack {
                        Text(device.displayName)
                        Spacer()
                        EjectButton(queue: queue)
                    }
                }
            } else {
                Section("Locations") {
                    Label(model.ejectedSerial != nil ? "Ejected" : "No Device",
                          systemImage: model.ejectedSerial != nil ? "eject" : "cable.connector.slash")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Finder's sidebar icons for the standard folders; a plain folder for anything else.
    static func symbol(forFavorite f: Favorite) -> String {
        switch f.name.lowercased() {
        case "download", "downloads": return "arrow.down.circle"
        case "documents": return "doc"
        case "dcim": return "camera"
        case "pictures": return "photo"
        case "movies": return "film"
        case "music": return "music.note"
        case "roms": return "gamecontroller"
        default: return "folder"
        }
    }

    static func symbol(for storage: StorageRoot) -> String {
        storage.name.hasPrefix("SD") ? "sdcard" : "internaldrive"
    }
}

/// Drops onto a sidebar location: device items move there (copy with ⌥), Finder files copy there.
@MainActor
enum SidebarDrop {
    static let types: [UTType] = [.droidcopyItems, .fileURL]

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [DraggedItem] = []
        private(set) var urls: [URL] = []
        func add(_ item: DraggedItem) { lock.lock(); items.append(item); lock.unlock() }
        func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    }

    static func handle(_ providers: [NSItemProvider], into dir: String, model: AppModel) -> Bool {
        let copy = NSEvent.modifierFlags.contains(.option)
        let collected = Collected()
        let group = DispatchGroup()
        let internalID = UTType.droidcopyItems.identifier
        let fromDevice = providers.filter { $0.hasItemConformingToTypeIdentifier(internalID) }
        if !fromDevice.isEmpty {
            for p in fromDevice {
                group.enter()
                p.loadDataRepresentation(forTypeIdentifier: internalID) { data, _ in
                    if let data, let item = try? JSONDecoder().decode(DraggedItem.self, from: data) { collected.add(item) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let items = collected.items.map(\.fileItem)
                Task { @MainActor in await model.move(items, to: dir, copy: copy) }
            }
            return true
        }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for p in files {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { _ = model.dropOnDevice(collected.urls, into: dir) }
        }
        return true
    }
}

/// Ejects the device; unavailable while copies or a delete/move run, since ejecting would cut them off.
struct EjectButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var queue: TransferQueue

    var body: some View {
        Group {
            if model.ejecting {
                ProgressView().controlSize(.mini)
            } else {
                Button { Task { await model.eject() } } label: {
                    Image(systemName: "eject")
                }
                .buttonStyle(.borderless)
                .disabled(queue.hasActive || model.activity != nil)
                .help(queue.hasActive ? "Wait for the copies to finish before ejecting" : "Eject: make the device safe to unplug")
                .accessibilityLabel("Eject")
            }
        }
    }
}

// MARK: - Browser

/// The folder, Finder's path and status bars, and the transfer list while copying has taken
/// more than a moment, or while failed items wait to be retried or cleared.
struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: WindowState
    @ObservedObject var queue: TransferQueue
    static let transferShare: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                FolderView().frame(maxHeight: .infinity)
                if model.device != nil {
                    if ui.showPathBar {
                        Divider()
                        PathBar(crumbs: model.deviceCrumbs, storageSymbol: model.storage.map(Sidebar.symbol(for:)) ?? "internaldrive")
                    }
                    if ui.showStatusBar {
                        Divider()
                        Text(model.statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                    }
                }
                if queue.showsProgress || queue.failedCount > 0 {
                    Divider()
                    // As tall as its rows, but never more than half the window.
                    TransferList(queue: queue)
                        .frame(maxHeight: geo.size.height * Self.transferShare)
                }
            }
        }
    }
}

struct FolderView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: WindowState

    var body: some View {
        if model.adbMissing {
            ContentUnavailableView {
                Label("adb Isn’t Installed", systemImage: "terminal")
            } description: {
                Text("DroidCopy needs adb to talk to your device.\nInstall it by running this command in Terminal:")
            } actions: {
                VStack(spacing: 10) {
                    CopyableCommand(command: AppModel.adbInstallCommand)
                    Text("Then quit and reopen DroidCopy.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.device == nil {
            ContentUnavailableView {
                if model.ejectedSerial != nil {
                    Label("Ejected", systemImage: "eject")
                } else {
                    Label("No Device", systemImage: "cable.connector.slash")
                }
            } description: {
                Text(model.deviceStatus)
            } actions: {
                if model.ejectedSerial != nil {
                    Button("Reconnect") { Task { await model.reconnect() } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FileTable(
                items: model.visibleItems,
                selection: $model.deviceSelection,
                dimmed: model.cutPaths,
                renaming: model.renamingPath,
                actions: actions
            )
            .overlay {
                if let error = model.deviceError {
                    ContentUnavailableView {
                        Label("Can’t Open This Folder", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error == AdbError.notRespondingMessage
                             ? "\(error) It may still be finishing a big write. Wait a moment, then try again."
                             : error)
                    } actions: {
                        Button("Try Again") { Task { await model.loadDevice() } }
                    }
                } else if model.deviceLoading && model.deviceItems.isEmpty {
                    ProgressView()
                } else if !model.deviceLoading && model.deviceItems.isEmpty {
                    Text("Drag files here from Finder, or paste them with ⌘V")
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                } else if model.visibleItems.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
            .overlay(alignment: .bottom) {
                if let activity = model.activity {
                    ActivityStatus(activity: activity)
                }
            }
        }
    }

    private var actions: FileTableActions {
        let model = self.model
        let ui = self.ui
        return FileTableActions(
            open: model.openDevice,
            copyToMac: model.copyToMac,
            copy: model.copyToClipboard,
            cut: model.cutItems,
            paste: model.paste,
            canPaste: { model.canPaste },
            rename: { item, name in Task { await model.rename(item, to: name) } },
            renameStarted: { DispatchQueue.main.async { if model.renamingPath != nil { model.renamingPath = nil } } },
            delete: { items in ui.deleting = items },
            receive: { urls, folder in _ = model.dropOnDevice(urls, into: folder) },
            move: { items, dir, copy in Task { await model.move(items, to: dir, copy: copy) } },
            deliver: model.deliver,
            preview: model.preview,
            getInfo: model.getInfo,
            duplicate: { items in Task { await model.duplicate(items) } },
            addToSidebar: model.addToSidebar,
            copyPath: model.copyPaths,
            newFolder: { Task { await model.newFolder() } }
        )
    }
}

/// Finder's path bar: the storage and each folder down to the one shown. Click one to go there.
struct PathBar: View {
    let crumbs: [Crumb]
    let storageSymbol: String
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button(action: crumb.action) {
                        HStack(spacing: 4) {
                            if crumb.isStorage {
                                Image(systemName: storageSymbol).frame(width: 14)
                            } else {
                                Image(nsImage: Self.folderIcon).resizable().frame(width: 14, height: 14)
                            }
                            Text(crumb.title).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                    .help(crumb.path)
                }
            }
            .padding(.horizontal, 10)
        }
        .font(.system(size: 11))
        .frame(height: 24)
    }
}

/// "Moving “x” · 2 of 5 · 14 s" with a bar for batches, over the bottom of the file list.
struct ActivityStatus: View {
    let activity: AppModel.DeviceActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(activity.verb) “\(activity.name)”").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                // Ticks every second, so a slow one visibly hasn't stalled.
                TimelineView(.periodic(from: activity.started, by: 1)) { context in
                    Text(detail(at: context.date)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if activity.count > 1 {
                ThinBar(fraction: Double(activity.index - 1) / Double(activity.count))
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        .padding(10)
    }

    private func detail(at now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(activity.started))
        let elapsed = seconds >= 2 ? Fmt.duration(Double(seconds)) : ""
        let position = activity.count > 1 ? "\(activity.index) of \(activity.count)" : ""
        return [position, elapsed].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Sheets

/// Get Info: what Finder's info window shows that the device can tell us.
struct InfoSheet: View {
    let info: AppModel.ItemInfo
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(2).truncationMode(.middle)
                    Text(sizeText).foregroundStyle(.secondary)
                }
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                if info.items.count == 1 {
                    row("Kind:", info.items[0].kind)
                }
                row("Size:", sizeDetail)
                if info.items.contains(where: \.isDirectory) {
                    row("Contains:", info.loading ? "Counting…" : info.count.map { $0 == 1 ? "1 item" : "\($0) items" } ?? "Unknown")
                }
                GridRow {
                    Text("Where:").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    HStack(alignment: .firstTextBaseline) {
                        Text(whereText).textSelection(.enabled).lineLimit(3)
                        CopyButton(text: whereText)
                    }
                }
                if info.items.count == 1, let modified = info.items[0].modified {
                    row("Modified:", Fmt.date(modified))
                }
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    private var title: String {
        info.items.count == 1 ? info.items[0].name : "\(info.items.count) items"
    }

    private var icon: NSImage {
        info.items.count == 1 ? FileTable.Coordinator.icon(for: info.items[0]) : NSWorkspace.shared.icon(for: .data)
    }

    private var sizeText: String {
        if info.loading { return "Calculating size…" }
        return info.size.map(Fmt.bytes) ?? "Size unknown"
    }

    private var sizeDetail: String {
        if info.loading { return "Calculating…" }
        guard let size = info.size else { return "Unknown" }
        let exact = size.formatted(.number)
        let onDisk = info.items.contains(where: \.isDirectory) ? " on disk" : ""
        return "\(Fmt.bytes(size)) (\(exact) bytes)\(onDisk)"
    }

    private var whereText: String {
        info.items.count == 1 ? info.items[0].path : Parse.parent(info.items[0].path)
    }
}

/// A small copy-to-clipboard button that briefly shows a tick.
struct CopyButton: View {
    let text: String
    @StateObject private var feedback = CopyFeedback()

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            feedback.copied = true
            Task { @MainActor [feedback] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                feedback.copied = false
            }
        } label: {
            Image(systemName: feedback.copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy path")
    }
}

/// ⇧⌘G, like Finder's Go to Folder.
struct GoToFolderSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ui: WindowState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Go to Folder").font(.headline)
            TextField("ROMs/switch or /storage/emulated/0/Download", text: $ui.goToPath)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit(go)
            Text("A path inside \(model.storage?.name ?? "the current storage"), or a full path.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { ui.goingToFolder = false }.keyboardShortcut(.cancelAction)
                Button("Go", action: go).keyboardShortcut(.defaultAction)
                    .disabled(ui.goToPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func go() {
        model.goToFolder(ui.goToPath)
        ui.goingToFolder = false
    }
}

// MARK: - Transfers

struct TransferList: View {
    @ObservedObject var queue: TransferQueue

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Transfers").font(.subheadline.weight(.semibold))
                if queue.hasActive {
                    BatchProgress(queue: queue)
                }
                Spacer()
                Button("Clear Finished") { queue.clearFinished() }
                    .controlSize(.small)
                    .disabled(queue.items.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            // As tall as its rows when they fit in the space offered; otherwise the rows scroll.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(queue.items.enumerated()), id: \.element.id) { i, t in
                if i > 0 { Divider().padding(.leading, 36) }
                TransferRow(transfer: t, queue: queue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
    }
}

/// A slim progress bar like Finder's copy window, instead of the system's tall one.
struct ThinBar: View {
    let fraction: Double
    static let height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Color.accentColor)
                    .frame(width: max(Self.height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent")
    }
}

/// "3 of 7" and a bar for the whole batch, next to the Transfers heading.
struct BatchProgress: View {
    @ObservedObject var queue: TransferQueue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let p = queue.batchProgress
            if p.count > 1 {
                HStack(spacing: 8) {
                    Text("\(min(p.finished + 1, p.count)) of \(p.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    ThinBar(fraction: p.fraction).frame(width: 120)
                }
            }
        }
    }
}

struct TransferRow: View {
    @ObservedObject var transfer: Transfer
    let queue: TransferQueue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .toDevice ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transfer.name).lineLimit(1).truncationMode(.middle)
                    Text(transfer.destLabel.map { "→ \($0)" } ?? "→ \(transfer.direction == .toDevice ? "device" : "Mac"): \(transfer.destDir)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if transfer.state == .running {
                    ThinBar(fraction: transfer.fraction)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .font(.callout)
            Spacer(minLength: 8)
            switch transfer.state {
            case .waiting, .running:
                Button { queue.cancel(transfer) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Cancel and delete the unfinished copy")
            case .failed, .cancelled:
                Button { queue.retry(transfer) } label: { Image(systemName: "arrow.clockwise.circle") }
                    .buttonStyle(.borderless)
                    .help("Try again")
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = transfer.state { return true }
        return false
    }

    private var iconColor: Color {
        switch transfer.state {
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var detail: String {
        switch transfer.state {
        case .waiting:
            return "Waiting"
        case .running:
            guard transfer.total > 0 else { return "Preparing…" }
            var parts = ["\(Fmt.bytes(transfer.transferred)) of \(Fmt.bytes(transfer.total))"]
            if transfer.bytesPerSecond > 0 {
                parts.append(Fmt.speed(transfer.bytesPerSecond))
                let left = Double(transfer.total - transfer.transferred) / transfer.bytesPerSecond
                parts.append("\(Fmt.duration(left)) left")
            }
            return parts.joined(separator: " · ")
        case .done:
            let elapsed = (transfer.finishedAt ?? Date()).timeIntervalSince(transfer.startedAt ?? Date())
            let avg = elapsed > 0 ? " · avg \(Fmt.speed(Double(transfer.total) / elapsed))" : ""
            return "\(Fmt.bytes(transfer.total)) · done in \(Fmt.duration(elapsed))\(avg)"
        case .failed(let message):
            return "Failed: \(message)"
        case .cancelled:
            return "Cancelled. The unfinished copy was deleted."
        }
    }
}

/// Briefly true after a copy, so the button can say "Copied".
/// (An ObservableObject because `@State` needs a macro plugin the Command Line Tools lack.)
final class CopyFeedback: ObservableObject {
    @Published var copied = false
}

/// A shell command styled like a GitHub code block, with a small copy button inside it.
struct CopyableCommand: View {
    let command: String
    @StateObject private var feedback = CopyFeedback()

    var body: some View {
        HStack(spacing: 12) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
                .textSelection(.enabled)
            Button(action: copy) {
                Image(systemName: feedback.copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(feedback.copied ? Color.green : Color.secondary)
                    .frame(width: 24, height: 22)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(feedback.copied ? "Copied!" : "Copy to clipboard")
            .accessibilityLabel(feedback.copied ? "Copied" : "Copy")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize()
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        feedback.copied = true
        Task { @MainActor [feedback] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            feedback.copied = false
        }
    }
}
