import AppKit
import Combine
import DroidCopyCore

/// Shows copy progress on the Dock icon, like Finder: a bar under the icon and the number of
/// items left as a badge.
@MainActor
final class DockProgress {
    private let queue: TransferQueue
    private var watch: AnyCancellable?
    private var timer: Timer?
    private let view = DockProgressView()

    init(queue: TransferQueue) {
        self.queue = queue
        watch = queue.$activeCount.sink { [weak self] count in
            // After the value is stored, so `hasActive` agrees with it.
            DispatchQueue.main.async { self?.activeChanged(count) }
        }
    }

    private func activeChanged(_ count: Int) {
        if count > 0 && timer == nil {
            NSApp.dockTile.contentView = view
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        } else if count == 0 {
            timer?.invalidate()
            timer = nil
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.badgeLabel = nil
            NSApp.dockTile.display()
        }
    }

    private func refresh() {
        let p = queue.batchProgress
        view.fraction = p.fraction
        let left = p.count - p.finished
        NSApp.dockTile.badgeLabel = left > 1 ? "\(left)" : nil
        NSApp.dockTile.display()
    }
}

private final class DockProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let bar = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.08, width: bounds.width * 0.8, height: bounds.height * 0.1)
        let radius = bar.height / 2
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        let inset = bar.insetBy(dx: 2, dy: 2)
        var filled = inset
        filled.size.width = max(inset.height, inset.width * min(max(fraction, 0), 1))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
    }
}
