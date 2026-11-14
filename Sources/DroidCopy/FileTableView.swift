import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import DroidCopyCore

extension NSPasteboard.PasteboardType {
    /// Device items dragged from the list, so they can be moved within the device.
    static let droidcopyItems = NSPasteboard.PasteboardType("local.droidcopy.items")
}

extension UTType {
    static let droidcopyItems = UTType(exportedAs: "local.droidcopy.items")
}

/// What the file table asks the rest of the app to do.
struct FileTableActions {
    var open: (FileItem) -> Void
    var copyToMac: ([FileItem]) -> Void
    /// ⌘C: put the items on the clipboard as files Finder can paste.
    var copy: ([FileItem]) -> Void
    /// ⌘X: mark the items to be moved by the next ⌘V.
    var cut: ([FileItem]) -> Void = { _ in }
    /// ⌘V: move cut items here, or copy files copied in Finder.
    var paste: () -> Void = {}
    var canPaste: () -> Bool = { false }
    /// Finish an in-place rename.
    var rename: (FileItem, String) -> Void
    /// The table started the rename the app asked for.
    var renameStarted: () -> Void = {}
    var delete: ([FileItem]) -> Void
    /// Files dropped from Finder: into the folder shown (nil) or onto a folder row.
    var receive: ([URL], String?) -> Void
    /// Device items dragged onto a folder row: moved there, or copied with ⌥.
    var move: ([FileItem], String, Bool) -> Void = { _, _, _ in }
    /// Write a device item to `url` on the Mac (a Finder drop or paste), then call `done`.
    var deliver: (FileItem, URL, @escaping (Error?) -> Void) -> Void
    /// Pull files for Quick Look, then hand their Mac copies to the closure.
    var preview: ([FileItem], @escaping ([URL]) -> Void) -> Void = { _, _ in }
    var getInfo: ([FileItem]) -> Void = { _ in }
    var duplicate: ([FileItem]) -> Void = { _ in }
    var addToSidebar: ([FileItem]) -> Void = { _ in }
    var copyPath: ([FileItem]) -> Void = { _ in }
    var newFolder: () -> Void = {}
}

/// The device file list. An AppKit table because SwiftUI's `Table` can't hand files to Finder:
/// its drags carry only text. Here rows drag out (and copy) as file promises, which Finder
/// fulfils by asking us to pull each item straight into the folder it was dropped on.
struct FileTable: NSViewRepresentable {
    let items: [FileItem]
    @Binding var selection: Set<String>
    /// Cut items, drawn faded like Finder draws items being moved.
    var dimmed: Set<String> = []
    /// A row to start renaming in place.
    var renaming: String?
    let actions: FileTableActions

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DeviceTableView()
        table.coordinator = context.coordinator
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsTypeSelect = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))

        func column(_ id: String, _ title: String, width: CGFloat, min: CGFloat, max: CGFloat, ascending: Bool) {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = min
            c.maxWidth = max
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: ascending)
            table.addTableColumn(c)
        }
        // Finder's list view columns, in Finder's order.
        column("name", "Name", width: 320, min: 120, max: 10_000, ascending: true)
        column("modified", "Date Modified", width: 170, min: 90, max: 260, ascending: false)
        column("size", "Size", width: 80, min: 60, max: 120, ascending: false)
        column("kind", "Kind", width: 150, min: 70, max: 300, ascending: true)
        table.tableColumns.first { $0.identifier.rawValue == "size" }?.headerCell.alignment = .right
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        table.registerForDraggedTypes([.fileURL, .droidcopyItems])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Within the app: onto a folder row (move) or with ⌥ (copy).
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        context.coordinator.update()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                             NSFilePromiseProviderDelegate, NSTextFieldDelegate {
        var parent: FileTable
        weak var table: NSTableView?
        private(set) var rows: [FileItem] = []
        private var shownItems: [FileItem] = []
        private var shownDimmed: Set<String> = []
        private var applyingSelection = false
        /// The row being renamed in place, and whether Esc cancelled it.
        private(set) var editing: FileItem?
        private var editCancelled = false
        private var reloadAfterEditing = false
        let previewSource = PreviewSource()
        private let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.qualityOfService = .userInitiated
            return q
        }()

        init(_ parent: FileTable) { self.parent = parent }

        // MARK: Data

        func update() {
            guard let table else { return }
            if parent.items != shownItems || parent.dimmed != shownDimmed {
                shownItems = parent.items
                shownDimmed = parent.dimmed
                if editing != nil {
                    // Reloading would throw away the name being typed.
                    reloadAfterEditing = true
                } else {
                    rows = sorted(parent.items)
                    table.reloadData()
                }
            }
            if editing == nil { applySelection() }
            if let path = parent.renaming {
                // After this update's layout, so the row's cell exists.
                DispatchQueue.main.async { [weak self] in self?.beginRename(path) }
            }
        }

        private func sorted(_ items: [FileItem]) -> [FileItem] {
            let d = table?.sortDescriptors.first
            return items.sorted(by: d?.key.flatMap(FileSortKey.init(rawValue:)) ?? .name, ascending: d?.ascending ?? true)
        }

        private func applySelection() {
            guard let table else { return }
            let wanted = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].id) })
            guard wanted != table.selectedRowIndexes else { return }
            let added = wanted.subtracting(table.selectedRowIndexes)
            applyingSelection = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            applyingSelection = false
            // Bring rows the app selected (like newly copied files) into view.
            if let row = added.last { table.scrollRowToVisible(row) }
        }

        var selectedItems: [FileItem] {
            guard let table else { return [] }
            return table.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0] }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let selected = Set(selectedItems.map(\.id))
            rows = sorted(shownItems)
            tableView.reloadData()
            applyingSelection = true
            tableView.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }), byExtendingSelection: false)
            applyingSelection = false
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection else { return }
            let ids = Set(selectedItems.map(\.id))
            if ids != parent.selection { parent.selection = ids }
        }

        /// Typing a name jumps to it, as in Finder.
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard tableColumn?.identifier.rawValue == "name", row < rows.count else { return nil }
            return rows[row].name
        }

        // MARK: Cells

        private static var iconCache: [String: NSImage] = [:]

        /// The icon Finder shows for the item's type.
        static func icon(for item: FileItem) -> NSImage {
            let type = item.contentType
            if let cached = iconCache[type.identifier] { return cached }
            let image = NSWorkspace.shared.icon(for: type)
            iconCache[type.identifier] = image
            return image
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
            let item = rows[row]
            let cell = (tableView.makeView(withIdentifier: .init(id), owner: nil) as? NSTableCellView) ?? makeCell(id)
            switch id {
            case "name":
                cell.textField?.stringValue = item.name
                cell.imageView?.image = Self.icon(for: item)
            case "size":
                cell.textField?.stringValue = item.isDirectory ? "--" : Fmt.bytes(item.size)
            case "kind":
                cell.textField?.stringValue = item.kind
            default:
                cell.textField?.stringValue = item.modified.map(Fmt.date) ?? ""
            }
            cell.alphaValue = parent.dimmed.contains(item.path) ? 0.45 : 1
            return cell
        }

        private func makeCell(_ id: String) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = .init(id)
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = id == "name" ? .byTruncatingMiddle : .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if id == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 18),
                    image.heightAnchor.constraint(equalToConstant: 18),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                ])
            } else {
                text.textColor = .secondaryLabelColor
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            if id == "size" {
                text.alignment = .right
                text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        // MARK: Renaming in place

        /// Turns the row's name into a text field with the name (without its extension) selected,
        /// like pressing Return in Finder.
        func beginRename(_ path: String) {
            parent.actions.renameStarted()
            guard editing == nil, let table, let row = rows.firstIndex(where: { $0.id == path }),
                  let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return }
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            editing = rows[row]
            editCancelled = false
            field.isEditable = true
            field.isSelectable = true
            field.isBordered = true
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.textColor = .labelColor
            field.delegate = self
            guard table.window?.makeFirstResponder(field) == true else {
                finishEditing(field)
                return
            }
            let stem = Parse.splitExtension(rows[row].name, isDirectory: rows[row].isDirectory).stem
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            editCancelled = true
            table?.window?.makeFirstResponder(table)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let item = editing else { return }
            let newName = field.stringValue
            let cancelled = editCancelled
            finishEditing(field)
            if cancelled || newName == item.name || newName.isEmpty {
                field.stringValue = item.name
            } else {
                parent.actions.rename(item, newName)
            }
        }

        private func finishEditing(_ field: NSTextField) {
            field.isEditable = false
            field.isSelectable = false
            field.isBordered = false
            field.drawsBackground = false
            field.delegate = nil
            editing = nil
            if reloadAfterEditing {
                reloadAfterEditing = false
                rows = sorted(shownItems)
                table?.reloadData()
                applySelection()
            }
            if let table, table.window?.firstResponder == nil || table.window?.firstResponder === table.window {
                table.window?.makeFirstResponder(table)
            }
        }

        // MARK: Clicks and menu

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < rows.count else { return }
            parent.actions.open(rows[row])
        }

        func openSelection() {
            let items = selectedItems
            if items.count == 1, items[0].isDirectory { parent.actions.open(items[0]) }
            else { items.filter { !$0.isDirectory }.forEach(parent.actions.open) }
        }

        func renameSelection() {
            let items = selectedItems
            if items.count == 1 { beginRename(items[0].path) }
        }

        func deleteSelection() {
            let items = selectedItems
            if !items.isEmpty { parent.actions.delete(items) }
        }

        /// Rows a context menu acts on: the selection if the clicked row is in it, else just that row.
        private func menuTargets() -> [FileItem] {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return [] }
            if table.selectedRowIndexes.contains(table.clickedRow) { return selectedItems }
            return [rows[table.clickedRow]]
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let targets = menuTargets()
            func add(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                     enabled: Bool = true, _ run: @escaping () -> Void) {
                let item = NSMenuItem(title: title, action: enabled ? #selector(ClosureMenuItem.fire(_:)) : nil, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers
                let box = ClosureMenuItem(run)
                item.target = box
                item.representedObject = box
                menu.addItem(item)
            }
            let actions = parent.actions
            // Right-click on empty space: actions on the folder itself, as in Finder.
            guard !targets.isEmpty else {
                add("New Folder", "n", [.command, .shift]) { actions.newFolder() }
                menu.addItem(.separator())
                add("Get Info", "i") { actions.getInfo([]) }
                add("Paste", "v", enabled: actions.canPaste()) { actions.paste() }
                return
            }
            let files = targets.filter { !$0.isDirectory }
            add("Open") {
                if targets.count == 1 { actions.open(targets[0]) } else { files.forEach(actions.open) }
            }
            if !files.isEmpty {
                add(files.count == 1 ? "Quick Look “\(files[0].name)”" : "Quick Look \(files.count) Items") { [weak self] in
                    self?.showPreview(files)
                }
            }
            menu.addItem(.separator())
            add("Get Info", "i") { actions.getInfo(targets) }
            if targets.count == 1 {
                add("Rename") { [weak self] in self?.beginRename(targets[0].path) }
            }
            add("Duplicate", "d") { actions.duplicate(targets) }
            menu.addItem(.separator())
            add("Copy to Mac…") { actions.copyToMac(targets) }
            add(targets.count == 1 ? "Copy “\(targets[0].name)”" : "Copy \(targets.count) Items", "c") { actions.copy(targets) }
            add("Cut", "x") { actions.cut(targets) }
            add("Copy Path", "c", [.command, .option]) { actions.copyPath(targets) }
            if targets.contains(where: \.isDirectory) {
                menu.addItem(.separator())
                add("Add to Sidebar", "t", [.command, .control]) { actions.addToSidebar(targets) }
            }
            menu.addItem(.separator())
            add("Delete…", "\u{8}") { actions.delete(targets) }
        }

        // MARK: Quick Look

        func togglePreview() {
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.orderOut(nil)
                return
            }
            let files = selectedItems.filter { !$0.isDirectory }
            if !files.isEmpty { showPreview(files) }
        }

        private func showPreview(_ files: [FileItem]) {
            parent.actions.preview(files) { [weak self] urls in
                guard let self, !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
                self.previewSource.urls = urls
                self.table?.window?.makeFirstResponder(self.table)
                panel.makeKeyAndOrderFront(nil)
                panel.reloadData()
            }
        }

        // MARK: Drag out (file promises)

        private func promise(for item: FileItem) -> NSFilePromiseProvider {
            let p = DevicePromiseProvider(fileType: item.contentType.identifier, delegate: self)
            p.userInfo = item
            return p
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            row < rows.count ? promise(for: rows[row]) : nil
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (provider.userInfo as? FileItem)?.name ?? "Untitled"
        }

        nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
            promiseQueue
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                             completionHandler: @escaping (Error?) -> Void) {
            guard let item = provider.userInfo as? FileItem else {
                completionHandler(CocoaError(.fileNoSuchFile))
                return
            }
            // Called on `promiseQueue`; Finder waits until `completionHandler` runs.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.parent.actions.deliver(item, url, completionHandler) }
            }
        }

        // MARK: Drop in

        /// Device items carried by a drag from this list.
        static func draggedItems(on pb: NSPasteboard) -> [FileItem] {
            (pb.pasteboardItems ?? []).compactMap { $0.data(forType: .droidcopyItems) }
                .compactMap { try? JSONDecoder().decode(DraggedItem.self, from: $0) }
                .map(\.fileItem)
        }

        /// The folder row a drop is aimed at, if any.
        private func folderTarget(_ row: Int, _ op: NSTableView.DropOperation) -> FileItem? {
            guard op == .on, row >= 0, row < rows.count, rows[row].isDirectory else { return nil }
            return rows[row]
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            let target = folderTarget(row, dropOperation)
            let dragged = Self.draggedItems(on: info.draggingPasteboard)
            if !dragged.isEmpty {
                // Within the device: only onto a folder that isn't one of the dragged items.
                guard let target, !dragged.contains(where: { Parse.isSameOrInside(target.path, $0.path) }) else { return [] }
                return info.draggingSourceOperationMask == .copy ? .copy : .move
            }
            guard !AppModel.fileURLs(on: info.draggingPasteboard).isEmpty else { return [] }
            // Onto a folder row, or else into the folder being shown, highlighted as a whole.
            if target == nil { tableView.setDropRow(-1, dropOperation: .on) }
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let target = folderTarget(row, dropOperation)
            let dragged = Self.draggedItems(on: info.draggingPasteboard)
            if !dragged.isEmpty {
                guard let target else { return false }
                parent.actions.move(dragged, target.path, info.draggingSourceOperationMask == .copy)
                return true
            }
            let urls = AppModel.fileURLs(on: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            parent.actions.receive(urls, target?.path)
            return true
        }
    }
}

/// A row's drag: a file promise for Finder, the device path for moves within the device, and the
/// device path as text, escaped for the shell, which is what Terminal types when it's dropped there.
final class DevicePromiseProvider: NSFilePromiseProvider {
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.droidcopyItems, .string]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard let item = userInfo as? FileItem else { return super.pasteboardPropertyList(forType: type) }
        switch type {
        case .droidcopyItems:
            return try? JSONEncoder().encode(DraggedItem(path: item.path, isDirectory: item.isDirectory))
        case .string:
            return Self.terminalText(for: item.path)
        default:
            return super.pasteboardPropertyList(forType: type)
        }
    }

    /// Like a file dragged from Finder: the escaped path and a space, so several in a row stay apart.
    static func terminalText(for path: String) -> String {
        Parse.shellEscaped(path) + " "
    }
}

/// The files Quick Look shows.
final class PreviewSource: NSObject, QLPreviewPanelDataSource {
    var urls: [URL] = []
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}

/// Keyboard and Edit-menu handling for the device table.
final class DeviceTableView: NSTableView {
    weak var coordinator: FileTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 51 where !command, 117 where !command: coordinator?.deleteSelection() // delete, forward delete
        case 36, 76: coordinator?.renameSelection()                     // return, enter: rename, as in Finder
        case 49: coordinator?.togglePreview()                           // space: Quick Look
        case 125 where command: coordinator?.openSelection()            // ⌘↓
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let coordinator, !coordinator.selectedItems.isEmpty else { return }
        coordinator.parent.actions.copy(coordinator.selectedItems)
    }

    @objc func cut(_ sender: Any?) {
        guard let coordinator, !coordinator.selectedItems.isEmpty else { return }
        coordinator.parent.actions.cut(coordinator.selectedItems)
    }

    @objc func paste(_ sender: Any?) {
        coordinator?.parent.actions.paste()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): return selectedRow >= 0
        case #selector(paste(_:)): return coordinator?.parent.actions.canPaste() ?? false
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // Quick Look asks the responder chain who supplies its files.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = coordinator?.previewSource
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }
}

/// Lets an NSMenuItem run a closure.
final class ClosureMenuItem: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}
