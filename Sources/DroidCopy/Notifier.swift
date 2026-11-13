import AppKit
import UserNotifications

/// Posts "Copying finished" notifications. Only inside the real app bundle: the notification
/// center needs one, and tests run without.
enum Notifier {
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Asks once, at launch, whether DroidCopy may show notifications.
    static func prepare() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
