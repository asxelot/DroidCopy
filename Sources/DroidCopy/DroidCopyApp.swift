import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

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

    var body: some Scene {
        Window("DroidCopy", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    delegate.model = model
                    model.start()
                }
        }
        .defaultSize(width: 1150, height: 740)
    }
}
