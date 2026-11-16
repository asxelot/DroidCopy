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
    /// "How do I turn on Wireless debugging?" is open.
    @Published var showSetup = false

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

/// File ▸ Connect over Wi-Fi…: pick a device found on the network, switch a cabled device to
/// Wi-Fi, connect to an address, or pair (Android 11's Wireless debugging).
struct WiFiSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = WiFiForm()
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect over Wi-Fi").font(.headline)
            Text("The device and this Mac need to be on the same Wi-Fi network. Copying over Wi-Fi is slower than over a cable.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.foundDevices, id: \.self) { d in
                        HStack {
                            Image(systemName: "smartphone")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: model.deviceName(at: d.host) ?? d.host)
                                Text(verbatim: Self.detail(d, named: model.deviceName(at: d.host) != nil))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.device?.serial == d.address {
                                Text("Connected").foregroundStyle(.secondary)
                            } else if model.pairTarget != d {
                                Button("Connect") { connectFound(d) }
                                    .disabled(form.busy)
                            }
                        }
                        if model.pairTarget == d { pairingPanel(d) }
                    }
                    if model.scanning {
                        HStack {
                            ProgressView(value: model.scanProgress)
                                .frame(width: 140)
                            Text(model.foundDevices.isEmpty ? "Looking for devices…" : "Still looking…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(alignment: .top) {
                            if model.foundDevices.isEmpty {
                                note("No devices found. Turn on Wireless debugging on the device (below), or switch it to Wi-Fi with the cable once. DroidCopy also needs to be allowed under System Settings ▸ Privacy & Security ▸ Local Network.")
                            }
                            Spacer()
                            Button("Search Again") { Task { await model.findWiFiDevices() } }
                        }
                    }
                    DisclosureGroup("How do I turn on Wireless debugging?", isExpanded: $form.showSetup) {
                        VStack(alignment: .leading, spacing: 6) {
                            step(1, "Turn on Developer options, once: open Settings ▸ About phone (or About device, About tablet) and tap “Build number” seven times. Enter your screen lock if asked, until it says “You are now a developer”.")
                            step(2, "Open Settings ▸ System ▸ Developer options. Turn on “USB debugging” too, so DroidCopy works over a cable.")
                            step(3, "Turn on “Wireless debugging” (Android 11 or later), and allow it on this Wi-Fi network when asked.")
                            step(4, "Click Search Again. The first time, DroidCopy asks you to pair: it shows how.")
                            note("Where things are differs a little between makers: “Build number” may be under Software information, and Developer options may be directly in Settings. Search Settings for “Build number” or “Wireless debugging” if you can’t find them.")
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text("On this network") }

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

            // Hidden while the pairing steps show under a found device.
            if !model.foundDevices.contains(where: { $0 == model.pairTarget }) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "On the device, open Settings ▸ System ▸ Developer options, tap the words “Wireless debugging” (not its switch), then “Pair device with pairing code”. Keep the code on screen.")
                    step(2, canPairWithoutAddress
                         ? "Type the “Wi-Fi pairing code” it shows. The IP address & port can stay empty: DroidCopy finds them."
                         : "Type the “IP address & Port” and the “Wi-Fi pairing code” it shows, then click Pair.")
                    HStack {
                        TextField(canPairWithoutAddress ? "IP address & port (optional)" : "IP address & port", text: $form.pairAddress)
                            .textFieldStyle(.roundedBorder)
                        TextField("Pairing code", text: $form.code)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .onSubmit(pair)
                        Button("Pair", action: pair)
                            .disabled(form.busy || (form.pairAddress.isEmpty && !canPairWithoutAddress) || form.code.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text("Pair (Android 11 or later)") }
            }

            HStack {
                if form.busy {
                    ProgressView().controlSize(.small)
                } else if let message = form.message, !message.isEmpty {
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
        .onChange(of: model.scanning) { _, scanning in
            // Nothing found: the setup steps are probably what's missing.
            if !scanning && model.foundDevices.isEmpty { form.showSetup = true }
        }
        .onChange(of: model.pairTarget) { _, target in
            if target != nil { codeFocused = true }
        }
        .onAppear {
            if form.address.isEmpty { form.address = model.lastWiFiAddress }
            if !model.scanning { Task { await model.findWiFiDevices() } }
        }
    }

    /// Steps for pairing a device found on the network that this Mac isn't paired with yet, with
    /// the code field right there.
    private func pairingPanel(_ d: FoundDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: "Pair this Mac with the device first. You only do this once.")
                    .font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: "link")
            }
            step(1, "On the device, open Settings ▸ System ▸ Developer options, and tap the words “Wireless debugging” (not its switch) to open its screen.")
            step(2, "Tap “Pair device with pairing code”. Keep the code on screen until pairing is done.")
            step(3, "Type the 6-digit “Wi-Fi pairing code” it shows. The IP address & port on that screen aren’t needed: DroidCopy finds the device that shows the code.")
            HStack {
                TextField("Pairing code", text: $form.code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .focused($codeFocused)
                    .onSubmit(pairFound)
                Button("Pair & Connect", action: pairFound)
                    .buttonStyle(.borderedProminent)
                    .disabled(form.busy || form.code.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Cancel") {
                    model.pairTarget = nil
                    form.message = nil
                }
                .disabled(form.busy)
            }
            note("After pairing, Connect works straight away from now on. To undo it, remove this Mac under “Paired devices” on the device.")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(n).")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Connects to a found device. One that needs pairing first opens the pairing steps under it
    /// instead of an error.
    private func connectFound(_ d: FoundDevice) {
        form.run {
            let r = await model.connectFound(d)
            return model.pairTarget == d ? (true, "") : r
        }
    }

    private func pairFound() {
        let code = form.code
        form.run {
            let r = await model.pairWiFi("", code: code)
            if r.ok { form.code = "" }
            return r
        }
    }

    /// "192.168.0.125 · Wireless debugging, port 49362" (the address only when the name is shown
    /// above it). Ports are written plainly: "49362", not "49,362".
    static func detail(_ d: FoundDevice, named: Bool) -> String {
        let what = d.kind == .adb ? "adb, port \(String(d.port))" : "Wireless debugging, port \(String(d.port))"
        return named ? "\(d.host) · \(what)" : what
    }

    /// Pairing can find the address itself when there's one Wireless debugging device to pair.
    private var canPairWithoutAddress: Bool {
        model.pairTarget != nil || Set(model.foundDevices.filter { $0.kind == .wirelessDebugging }.map(\.host)).count == 1
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
            if r.ok, !r.message.hasPrefix("Paired and connected"), let host = address.split(separator: ":").first,
               form.address.isEmpty || form.address == model.lastWiFiAddress {
                form.address = "\(host):"
            }
            return r
        }
    }
}
