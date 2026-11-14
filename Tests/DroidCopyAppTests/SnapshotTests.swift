import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import DroidCopy
import DroidCopyCore
import DroidCopyTestSupport

/// Renders the transfer panel to images, for showing a change. Only runs with DROIDCOPY_SNAPSHOT_DIR.
@Suite @MainActor struct SnapshotTests {
    static let dir = ProcessInfo.processInfo.environment["DROIDCOPY_SNAPSHOT_DIR"]

    struct FakeFolder: View {
        let names = ["01006BB00C6F0000", "no_dof_blur", "Stable-60fps-v2", "Tangle Tower (Update 1.1.0)",
                     "yuzu-mod-archive-main", "Persona 5 Tactica.nsp"]
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                    HStack(spacing: 6) {
                        Image(systemName: n.hasSuffix(".nsp") ? "doc.fill" : "folder.fill")
                            .foregroundStyle(n.hasSuffix(".nsp") ? Color.secondary : Color.accentColor)
                        Text(n)
                        Spacer()
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    func window(_ content: some View, size: CGSize) -> (NSWindow, NSView) {
        let w = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        w.contentView = host
        w.orderFrontRegardless()
        return (w, host)
    }

    func capture(_ view: NSView) -> CGImage {
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage!
    }

    func spin(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    func writePNG(_ image: CGImage, _ path: String) {
        let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, image, nil)
        CGImageDestinationFinalize(d)
    }

    @Test(.enabled(if: dir != nil)) func renderTransferPanel() async throws {
        let dir = Self.dir!
        let fake = try FakeAdb(push: .hang)
        defer { fake.cleanUp() }
        let dev = try fake.deviceDir()
        let mac = try fake.macDir()
        let queue = TransferQueue(adb: fake.adb)
        // Sparse files: they report big sizes without using disk. The fake push writes 3 bytes and
        // hangs; growing the hidden copy on the "device" makes the queue see real progress.
        let src = mac.appendingPathComponent("Fire Emblem Engage.nsp")
        FileManager.default.createFile(atPath: src.path, contents: nil)
        try FileHandle(forWritingTo: src).truncate(atOffset: 4_250_000_000)
        let t = Transfer(direction: .toDevice, serial: "FAKE123", source: src.path, destDir: dev,
                         name: "Fire Emblem Engage.nsp", isDirectory: false, replace: false)
        t.destLabel = "device: /storage/7EF7-7423/ROMs/switch_addons"
        queue.add([t])
        while t.state != .running { try await spin(0.05) }
        let partial = Parse.join(dev, ".dc~Fire Emblem Engage.nsp")
        while !FileManager.default.fileExists(atPath: partial) { try await spin(0.05) }
        var done: UInt64 = 1_850_000_000
        func grow(_ seconds: Double) async throws {
            let steps = Int(seconds / 0.05)
            for _ in 0..<steps {
                done += 3_750_000  // 75 MB/s
                try FileHandle(forWritingAtPath: partial)!.truncate(atOffset: done)
                try await spin(0.05)
            }
        }
        try await grow(2.5)

        let size = CGSize(width: 900, height: 560)
        let before = VStack(spacing: 0) {
            FakeFolder().frame(maxHeight: .infinity)
            Divider()
            TransferList(queue: queue, maxRowsHeight: 10_000).frame(maxHeight: size.height * 0.5)
        }
        let after = VStack(spacing: 0) {
            FakeFolder().frame(maxHeight: .infinity)
            Divider()
            TransferList(queue: queue, maxRowsHeight: size.height * BrowserView.transferShare)
        }
        let (w1, v1) = window(before, size: size)
        try await grow(1.2)
        writePNG(capture(v1), "\(dir)/before.png")
        w1.close()

        let (w2, v2) = window(after, size: size)
        try await grow(1.2)
        writePNG(capture(v2), "\(dir)/after.png")

        // Two sweeps (3 s) at 20 fps.
        let frames = 60
        let gif = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/after.gif") as CFURL,
                                                  UTType.gif.identifier as CFString, frames, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for _ in 0..<frames {
            CGImageDestinationAddImage(gif, capture(v2), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
            try await grow(0.05)
        }
        CGImageDestinationFinalize(gif)
        w2.close()
        await queue.cancelAllAndWait()
    }
}
