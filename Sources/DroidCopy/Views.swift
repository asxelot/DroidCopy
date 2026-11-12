import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DroidCopyCore


struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        MainLayout(queue: model.queue)
        .frame(minWidth: 520, minHeight: 460)
        .navigationTitle(model.device.map { "DroidCopy — \($0.displayName)" } ?? "DroidCopy")
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
            let names = batch.conflicts.prefix(6).map(\.name).joined(separator: "\n")
            let more = batch.conflicts.count > 6 ? "\n…and \(batch.conflicts.count - 6) more" : ""
            Text(names + more)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }),
            presenting: model.alertMessage
        ) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }

    private var conflictTitle: String {
        let n = model.pending?.conflicts.count ?? 0
        return n == 1 ? "This item already exists. Replace it?" : "\(n) items already exist. Replace them?"
    }
}

/// The device pane, plus the transfer list while something is copying or waiting, or failed and
/// not yet retried or cleared.
struct MainLayout: View {
    @ObservedObject var queue: TransferQueue

    var body: some View {
        if queue.activeCount > 0 || queue.failedCount > 0 {
            VSplitView {
                DevicePane().frame(minHeight: 280, maxHeight: .infinity)
                TransferList(queue: queue)
                    .frame(minHeight: 120, idealHeight: 200, maxHeight: .infinity)
            }
        } else {
            DevicePane()
        }
    }
}

let defaultSortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)]

// MARK: - Device pane

final class DevicePaneState: ObservableObject {
    @Published var dropTargeted = false
    @Published var creatingFolder = false
    @Published var renaming: FileItem?
    @Published var deleting: [FileItem] = []
    @Published var newName = ""
    @Published var sortOrder = defaultSortOrder
}

struct DevicePane: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = DevicePaneState()

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: model.device?.displayName ?? "Device", systemImage: "externaldrive.connected.to.line.below", free: model.deviceFree) {
                if model.storages.count > 1 {
                    Picker("Storage", selection: Binding(get: { model.storage }, set: { if let s = $0 { model.selectStorage(s) } })) {
                        ForEach(model.storages) { Text($0.name).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Button { ui.newName = "New Folder"; ui.creatingFolder = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(model.device == nil)
                Button { model.copySelectedToMac() } label: {
                    Label("Copy to Mac…", systemImage: "arrow.down.circle")
                }
                .disabled(model.deviceSelection.isEmpty)
                .help("Copy the selected items to a folder on your Mac")
            }
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
                    Label("No Device", systemImage: "cable.connector.slash")
                } description: {
                    Text(model.deviceStatus)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavBar(canGoUp: model.deviceCanGoUp, up: model.deviceUp, crumbs: model.deviceCrumbs,
                       refresh: { Task { await model.loadDevice() } })
                Divider()
                FileTable(
                    items: model.deviceItems,
                    selection: $model.deviceSelection,
                    sortOrder: $ui.sortOrder,
                    open: model.openDevice
                ) { ids in
                    let items = model.deviceItems.filter { ids.contains($0.id) }
                    Button("Copy to Mac…") { model.copyToMac(items) }
                    if items.count == 1, let item = items.first {
                        Button("Rename…") { ui.newName = item.name; ui.renaming = item }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { ui.deleting = items }
                }
                .overlay {
                    if let error = model.deviceError {
                        ContentUnavailableView("Can’t open this folder", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else if model.deviceLoading && model.deviceItems.isEmpty {
                        ProgressView()
                    }
                }
                .dropHighlight(ui.dropTargeted)
                .dropDestination(for: URL.self) { urls, _ in
                    model.dropOnDevice(urls)
                } isTargeted: { ui.dropTargeted = $0 }
                .overlay(alignment: .bottom) {
                    if !model.deviceLoading && model.deviceError == nil {
                        Text("Drop files from Finder to copy them here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                .onDeleteCommand {
                    let items = model.deviceItems.filter { model.deviceSelection.contains($0.id) }
                    if !items.isEmpty { ui.deleting = items }
                }
            }
        }
        .alert("New Folder", isPresented: $ui.creatingFolder) {
            TextField("Name", text: $ui.newName)
            Button("Create") { let name = ui.newName; Task { await model.makeFolder(name) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename",
               isPresented: Binding(get: { ui.renaming != nil }, set: { if !$0 { ui.renaming = nil } }),
               presenting: ui.renaming) { item in
            TextField("Name", text: $ui.newName)
            Button("Rename") { let name = ui.newName; Task { await model.rename(item, to: name) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            ui.deleting.count == 1 ? "Delete “\(ui.deleting[0].name)” from the device?" : "Delete \(ui.deleting.count) items from the device?",
            isPresented: Binding(get: { !ui.deleting.isEmpty }, set: { if !$0 { ui.deleting = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { let items = ui.deleting; Task { await model.delete(items) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
    }
}

// MARK: - Shared pieces

struct PaneHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    let free: Int64?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline).lineLimit(1)
            if let free {
                Text("\(Fmt.bytes(free)) free").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10)
        // Fixed, so both panes line up whatever controls they hold (a segmented picker is taller than a menu).
        .frame(height: 40)
    }
}

struct NavBar: View {
    let canGoUp: Bool
    let up: () -> Void
    let crumbs: [Crumb]
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: up) { Image(systemName: "chevron.up") }
                .disabled(!canGoUp)
                .help("Enclosing folder")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button(crumb.title, action: crumb.action)
                            .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                    }
                }
            }
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

struct FileTable<MenuContent: View>: View {
    let items: [FileItem]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<FileItem>]
    let open: (FileItem) -> Void
    @ViewBuilder let menu: (Set<String>) -> MenuContent

    /// Column sort, with folders kept above files.
    private var sortedItems: [FileItem] {
        let sorted = items.sorted(using: sortOrder)
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    var body: some View {
        Table(of: FileItem.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("Size", value: \.size) { item in
                Text(item.isDirectory ? "--" : Fmt.bytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 85, max: 120)
            TableColumn("Modified", value: \.sortDate) { item in
                Text(item.modified.map(Fmt.date) ?? "").foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 130, max: 170)
        } rows: {
            ForEach(sortedItems) { TableRow($0) }
        }
        .contextMenu(forSelectionType: String.self, menu: menu) { ids in
            guard ids.count == 1, let id = ids.first, let item = items.first(where: { $0.id == id }) else { return }
            open(item)
        }
    }
}

extension View {
    func dropHighlight(_ on: Bool) -> some View {
        overlay {
            if on {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Transfers

struct TransferList: View {
    @ObservedObject var queue: TransferQueue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(queue.items.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if queue.items.isEmpty {
                Text("Drop files from Finder onto the device to copy them.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(queue.items) { TransferRow(transfer: $0, queue: queue) }
                }
                .listStyle(.inset)
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
                .font(.title2)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transfer.name).lineLimit(1).truncationMode(.middle)
                    Text("→ \(transfer.direction == .toDevice ? "device" : "Mac"): \(transfer.destDir)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if transfer.state == .running {
                    ProgressView(value: transfer.fraction).progressViewStyle(.linear)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
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
        .padding(.vertical, 3)
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
