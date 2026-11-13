import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var dock: DockProgress?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.prepare()
    }

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        dock = DockProgress(queue: model.queue)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.queue.hasActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Copies are still running"
        alert.informativeText = "Quitting cancels them and deletes the unfinished copies."
        alert.addButton(withTitle: "Keep Copying")
        alert.addButton(withTitle: "Quit Anyway")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task {
            await model.queue.cancelAllAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct DroidCopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var ui = WindowState()

    var body: some Scene {
        Window("DroidCopy", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(ui)
                .onAppear {
                    delegate.attach(model)
                    model.start()
                }
        }
        .defaultSize(width: 1150, height: 740)
        .commands { FinderCommands(model: model, ui: ui) }
    }
}

/// Finder's menu commands and shortcuts, for the device.
struct FinderCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: WindowState

    /// While a text field is being typed in (search, rename), shortcuts like ⌘⌫ and ⌘↑ belong to it.
    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    private func unlessTyping(_ textAction: Selector, _ run: () -> Void) {
        if typing { NSApp.sendAction(textAction, to: nil, from: nil) } else { run() }
    }

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { Task { await model.newFolder() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.device == nil)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open") { model.openSelection() }
                .keyboardShortcut("o")
                .disabled(model.selectedItems.isEmpty)
            Button("Get Info") { model.getInfo(model.selectedItems) }
                .keyboardShortcut("i")
                .disabled(model.device == nil)
            Button("Rename") { model.renamingPath = model.selectedItems.first?.path }
                .disabled(model.selectedItems.count != 1)
            Button("Duplicate") { Task { await model.duplicate(model.selectedItems) } }
                .keyboardShortcut("d")
                .disabled(model.selectedItems.isEmpty)
            Button("Copy to Mac…") { model.copyToMac(model.selectedItems) }
                .disabled(model.selectedItems.isEmpty)
            Divider()
            Button("Add to Sidebar") { model.addToSidebar(model.selectedItems) }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(model.device == nil)
            Divider()
            Button("Delete…") {
                unlessTyping(#selector(NSResponder.deleteToBeginningOfLine(_:))) { ui.deleting = model.selectedItems }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selectedItems.isEmpty)
            Divider()
            Button(model.device.map { "Eject “\($0.displayName)”" } ?? "Eject") { Task { await model.eject() } }
                .keyboardShortcut("e")
                .disabled(model.device == nil || model.queue.hasActive || model.activity != nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Path") { model.copyPaths(model.selectedItems) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.device == nil)
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { focusSearch() }
                .keyboardShortcut("f")
        }
        CommandGroup(before: .sidebar) {
            Button(model.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { model.showHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button(ui.showPathBar ? "Hide Path Bar" : "Show Path Bar") { ui.showPathBar.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button(ui.showStatusBar ? "Hide Status Bar" : "Show Status Bar") { ui.showStatusBar.toggle() }
                .keyboardShortcut("/")
            Divider()
            Button("Refresh") { Task { await model.loadDevice() } }
                .keyboardShortcut("r")
                .disabled(model.device == nil)
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Button("Enclosing Folder") {
                unlessTyping(#selector(NSResponder.moveToBeginningOfDocument(_:))) { model.deviceUp() }
            }
            .keyboardShortcut(.upArrow)
            .disabled(!model.deviceCanGoUp)
            Divider()
            ForEach(model.storages) { s in
                Button(s.name) { model.selectStorage(s) }
            }
            if !model.favorites.isEmpty {
                Divider()
                ForEach(model.favorites) { f in
                    Button(f.name) { model.goDevice(f.path) }
                }
            }
            Divider()
            Button("Go to Folder…") {
                ui.goToPath = ""
                ui.goingToFolder = true
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(model.device == nil)
        }
    }

    /// ⌘F: puts the cursor in the toolbar's search field.
    private func focusSearch() {
        guard let toolbar = NSApp.keyWindow?.toolbar else { return }
        if let search = toolbar.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            search.beginSearchInteraction()
        }
    }
}
