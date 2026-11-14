import SwiftUI
import DroidCopyCore

/// What's typed in the Wi-Fi sheet and what it last said.
/// (An ObservableObject because `@State` needs a macro plugin the Command Line Tools lack.)
@MainActor
final class WiFiForm: ObservableObject {
    @Published var address = ""
    @Published var pairAddress = ""
    @Published var code = ""
    @Published var busy = false
    @Published var message: String?
    @Published var failed = false

    func run(_ action: @escaping () async -> (ok: Bool, message: String)) {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            let r = await action()
            message = r.message
            failed = !r.ok
            busy = false
        }
    }
}

/// File ▸ Connect over Wi-Fi…: switch a cabled device to Wi-Fi, connect to an address, or pair
/// (Android 11's Wireless debugging).
struct WiFiSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = WiFiForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect over Wi-Fi").font(.headline)
            Text("The device and this Mac need to be on the same Wi-Fi network. Copying over Wi-Fi is slower than over a cable.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let d = model.device, !d.isNetwork {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Switch “\(d.displayName)” to Wi-Fi") { form.run { await model.switchToWiFi() } }
                            .disabled(form.busy)
                        note("Uses the cable to turn on adb over Wi-Fi, then connects to it there. Afterwards you can unplug the cable. Restarting the device turns it off again.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("With the cable plugged in") }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("192.168.1.20:5555", text: $form.address)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(connect)
                        Button("Connect", action: connect)
                            .disabled(form.busy || form.address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    note("A device switched to Wi-Fi before uses port 5555. On Android 11 or later you can instead turn on Developer options ▸ Wireless debugging and use the IP address & port it shows (pair first, below, the first time).")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text("Connect to an address") }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    note("On the device, open Wireless debugging and tap “Pair device with pairing code”, then enter what it shows.")
                    HStack {
                        TextField("IP address & port", text: $form.pairAddress)
                            .textFieldStyle(.roundedBorder)
                        TextField("Pairing code", text: $form.code)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .onSubmit(pair)
                        Button("Pair", action: pair)
                            .disabled(form.busy || form.pairAddress.isEmpty || form.code.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text("Pair (Android 11 or later)") }

            HStack {
                if form.busy {
                    ProgressView().controlSize(.small)
                } else if let message = form.message {
                    Label(message, systemImage: form.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(form.failed ? Color.red : Color.green)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { if form.address.isEmpty { form.address = model.lastWiFiAddress } }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func connect() {
        let address = form.address
        form.run { await model.connectWiFi(address) }
    }

    private func pair() {
        let address = form.pairAddress, code = form.code
        form.run {
            let r = await model.pairWiFi(address, code: code)
            if r.ok, let host = address.split(separator: ":").first, form.address.isEmpty || form.address == model.lastWiFiAddress {
                form.address = "\(host):"
            }
            return r
        }
    }
}
