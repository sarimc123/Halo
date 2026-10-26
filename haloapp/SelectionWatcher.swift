import AppKit

/// Watches for text selections in other apps (drag, double/triple-click, shift-click) to show the dot.
@MainActor
final class SelectionWatcher {
    var onSelection: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    static let minimumLength = 2

    private var monitors: [Any] = []
    private var downPoint = NSPoint.zero
    /// Bumped on every click/keypress so a slow read can't show a dot for an outdated selection.
    private var generation = 0

    func start() {
        guard monitors.isEmpty else { return }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.generation += 1
                self.downPoint = NSEvent.mouseLocation
                self.onDismiss?()
            }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            let clicks = event.clickCount
            let shift = event.modifierFlags.contains(.shift)
            MainActor.assumeIsolated { self?.mouseUp(clickCount: clicks, shift: shift) }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let tag = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            MainActor.assumeIsolated {
                // Ignore the ⌘C Halo posts itself while reading a selection.
                guard let self, tag != Keyboard.syntheticTag else { return }
                self.generation += 1
                self.onDismiss?()
            }
        }) { monitors.append(m) }
    }

    private func mouseUp(clickCount: Int, shift: Bool) {
        let up = NSEvent.mouseLocation
        let dragged = hypot(up.x - downPoint.x, up.y - downPoint.y) > 6
        guard dragged || clickCount >= 2 || shift else { return }

        let current = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, self.generation == current else { return }
            guard let text = await SelectionReader.selectionForWatcher(),
                  Self.isMeaningful(text),
                  self.generation == current else { return }
            self.onSelection?(text)
        }
    }

    private static func isMeaningful(_ text: String) -> Bool {
        text.count >= minimumLength && text.contains { $0.isLetter || $0.isNumber }
    }
}
