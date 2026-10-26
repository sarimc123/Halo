import AppKit

/// Watches for drag-selections / double-clicks in other apps to show the dot.
@MainActor
final class SelectionWatcher {
    var onSelection: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private var monitors: [Any] = []
    private var downPoint = NSPoint.zero

    func start() {
        guard monitors.isEmpty else { return }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.downPoint = NSEvent.mouseLocation
                self?.onDismiss?()
            }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            let clicks = event.clickCount
            MainActor.assumeIsolated { self?.mouseUp(clickCount: clicks) }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss?() }
        }) { monitors.append(m) }
    }

    private func mouseUp(clickCount: Int) {
        let up = NSEvent.mouseLocation
        let dragged = hypot(up.x - downPoint.x, up.y - downPoint.y) > 6
        guard dragged || clickCount >= 2 else { return }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let text = SelectionReader.axSelectedText()?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            self?.onSelection?(text)
        }
    }
}
