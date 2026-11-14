import AppKit
import SwiftUI
import DroidCopyCore

/// Looks for a newer DroidCopy on GitHub: once a day when automatic checks are on (the default),
/// and whenever the person picks Check for Updates….
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: Self.automaticKey) } }
    @Published private(set) var checking = false

    static let automaticKey = "checkForUpdates"
    static let lastCheckKey = "lastUpdateCheck"
    /// The newest version already announced, so each version is announced once.
    static let announcedKey = "announcedVersion"
    static let interval: TimeInterval = 24 * 60 * 60

    let defaults: UserDefaults
    let appVersion: String
    /// Asks GitHub. Replaced in tests.
    var fetch: (String) async -> Release.Info? = { await Release.fetchLatest(appVersion: $0) }
    /// Shows what was found. Replaced in tests.
    var present: (UpdateResult) -> Void = UpdateChecker.alert

    enum UpdateResult: Equatable {
        case available(Release.Info, current: String)
        case upToDate(String)
        case failed
    }

    init(defaults: UserDefaults = .standard,
         appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.defaults = defaults
        self.appVersion = appVersion
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    /// At launch: checks if automatic checks are on and the last check was a day or more ago.
    /// Says something only when there's a version it hasn't announced yet.
    func checkIfDue(now: Date = Date()) async {
        guard automatic else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, now.timeIntervalSince(last) < Self.interval { return }
        guard let latest = await fetch(appVersion) else { return } // offline: try again next launch
        defaults.set(now, forKey: Self.lastCheckKey)
        guard Release.isNewer(latest.version, than: appVersion) else { return }
        if let announced = defaults.string(forKey: Self.announcedKey), !Release.isNewer(latest.version, than: announced) { return }
        defaults.set(latest.version, forKey: Self.announcedKey)
        present(.available(latest, current: appVersion))
    }

    /// Check for Updates…: always says what it found.
    func checkNow() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        guard let latest = await fetch(appVersion) else { return present(.failed) }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        if Release.isNewer(latest.version, than: appVersion) {
            defaults.set(latest.version, forKey: Self.announcedKey)
            present(.available(latest, current: appVersion))
        } else {
            present(.upToDate(appVersion))
        }
    }

    static func alert(_ result: UpdateResult) {
        let alert = NSAlert()
        switch result {
        case .available(let info, let current):
            alert.messageText = "DroidCopy \(info.version) is available"
            alert.informativeText = "You have \(current). Download the disk image from the release page, quit DroidCopy and drag the new one onto Applications."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(info.page) }
        case .upToDate(let current):
            alert.messageText = "DroidCopy is up to date"
            alert.informativeText = "\(current) is the latest version."
            alert.runModal()
        case .failed:
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = "GitHub didn’t answer. Check the internet connection, or look at the releases page."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Releases Page")
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Release.pageURL) }
        }
    }
}

/// DroidCopy ▸ Settings… (⌘,).
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        Form {
            Section("Copying") {
                Toggle("Check copies by content", isOn: $model.checkContents)
                Text("After each copy, compare checksums of the copy and the original, not just their sizes. This catches copies damaged by a failing card or cable, but reads everything a second time, so copies take longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updates.automatic)
                Text("Once a day, DroidCopy asks GitHub whether there’s a newer release, and tells you about each new version once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Check Now") { Task { await updates.checkNow() } }
                        .disabled(updates.checking)
                    if updates.checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("Version \(updates.appVersion)").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
