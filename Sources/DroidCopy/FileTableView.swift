import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DroidCopyCore

/// What the file table asks the rest of the app to do.
struct FileTableActions {
    var open: (FileItem) -> Void
    var copyToMac: ([FileItem]) -> Void
    /// ⌘C: put the items on the clipboard as files Finder can paste.
    var copy: ([FileItem]) -> Void
    var rename: (FileItem) -> Void
    var delete: ([FileItem]) -> Void
    /// Files dropped or pasted from Finder.
    var receive: ([URL]) -> Void
    /// Write a device item to `url` on the Mac (a Finder drop or paste), then call `done`.
    var deliver: (FileItem, URL, @escaping (Error?) -> Void) -> Void
}

/// The device file list. An AppKit table because SwiftUI's `Table` can't hand files to Finder:
/// its drags carry only text. Here rows drag out (and copy) as file promises, which Finder
/// fulfils by asking us to pull each item straight into the folder it was dropped on.
struct FileTable: NSViewRepresentable {
    let items: [FileItem]
    @Binding var selection: Set<String>
    let actions: FileTableActions

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DeviceTableView()
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.rowHeight = 22
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
        column("name", "Name", width: 400, min: 120, max: 10_000, ascending: true)
        column("size", "Size", width: 85, min: 60, max: 120, ascending: false)
        column("modified", "Modified", width: 130, min: 80, max: 170, ascending: false)
        table.tableColumns[1].headerCell.alignment = .right
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)

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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSFilePromiseProviderDelegate {
        var parent: FileTable
        weak var table: NSTableView?
        private(set) var rows: [FileItem] = []
        private var shownItems: [FileItem] = []
        private var applyingSelection = false
        private let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.qualityOfService = .userInitiated
            return q
        }()

        init(_ parent: FileTable) { self.parent = parent }

        // MARK: Data

        func update() {
            guard let table else { return }
            if parent.items != shownItems {
                shownItems = parent.items
                rows = sorted(parent.items)
                table.reloadData()
            }
            applySelection()
        }

        private func sorted(_ items: [FileItem]) -> [FileItem] {
            let d = table?.sortDescriptors.first
            return items.sorted(by: d?.key.flatMap(FileSortKey.init(rawValue:)) ?? .name, ascending: d?.ascending ?? true)
        }

        private func applySelection() {
            guard let table else { return }
            let wanted = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].id) })
            guard wanted != table.selectedRowIndexes else { return }
            applyingSelection = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            applyingSelection = false
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

        // MARK: Cells

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
            let item = rows[row]
            let cell = (tableView.makeView(withIdentifier: .init(id), owner: nil) as? NSTableCellView) ?? makeCell(id)
            switch id {
            case "name":
                cell.textField?.stringValue = item.name
                let symbol = item.isDirectory ? "folder.fill" : "doc"
                cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                cell.imageView?.contentTintColor = item.isDirectory ? .controlAccentColor : .secondaryLabelColor
            case "size":
                cell.textField?.stringValue = item.isDirectory ? "--" : Fmt.bytes(item.size)
            default:
                cell.textField?.stringValue = item.modified.map(Fmt.date) ?? ""
            }
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
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
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

        // MARK: Clicks and menu

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < rows.count else { return }
            parent.actions.open(rows[row])
        }

        func openSelection() {
            let items = selectedItems
            if items.count == 1 { parent.actions.open(items[0]) }
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
            guard !targets.isEmpty else { return }
            func add(_ title: String, _ key: String = "", _ run: @escaping () -> Void) {
                let item = NSMenuItem(title: title, action: #selector(ClosureMenuItem.fire(_:)), keyEquivalent: key)
                let box = ClosureMenuItem(run)
                item.target = box
                item.representedObject = box
                menu.addItem(item)
            }
            add("Copy to Mac…") { [weak self] in self?.parent.actions.copyToMac(targets) }
            add("Copy", "c") { [weak self] in self?.parent.actions.copy(targets) }
            if targets.count == 1 {
                add("Rename…") { [weak self] in self?.parent.actions.rename(targets[0]) }
            }
            menu.addItem(.separator())
            add("Delete…") { [weak self] in self?.parent.actions.delete(targets) }
        }

        // MARK: Copy and paste

        func pasteFromPasteboard() {
            let urls = Self.fileURLs(on: .general)
            if !urls.isEmpty { parent.actions.receive(urls) }
        }

        static func fileURLs(on pb: NSPasteboard) -> [URL] {
            pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        // MARK: Drag out (file promises)

        private func promise(for item: FileItem) -> NSFilePromiseProvider {
            let p = NSFilePromiseProvider(fileType: item.contentType.identifier, delegate: self)
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

        // MARK: Drop in (files from Finder)

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            if (info.draggingSource as? NSTableView) === tableView { return [] }
            guard !Self.fileURLs(on: info.draggingPasteboard).isEmpty else { return [] }
            // Always into the folder being shown, highlighted as a whole.
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = Self.fileURLs(on: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            parent.actions.receive(urls)
            return true
        }
    }
}

/// Keyboard and Edit-menu handling for the device table.
final class DeviceTableView: NSTableView {
    weak var coordinator: FileTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: coordinator?.deleteSelection()                 // delete, forward delete
        case 36, 76: coordinator?.openSelection()                    // return, enter
        case 125 where event.modifierFlags.contains(.command): coordinator?.openSelection() // ⌘↓
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let coordinator, !coordinator.selectedItems.isEmpty else { return }
        coordinator.parent.actions.copy(coordinator.selectedItems)
    }

    @objc func paste(_ sender: Any?) {
        coordinator?.pasteFromPasteboard()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return selectedRow >= 0
        case #selector(paste(_:)): return !FileTable.Coordinator.fileURLs(on: .general).isEmpty
        default: return super.validateUserInterfaceItem(item)
        }
    }
}

/// Lets an NSMenuItem run a closure.
final class ClosureMenuItem: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}
