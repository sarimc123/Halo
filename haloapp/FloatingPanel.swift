import AppKit
import SwiftUI

/// Borderless, always-on-top panel that never steals focus from the app you're working in.
final class FloatingPanel: NSPanel {
    private let focusable: Bool

    init(size: CGSize, focusable: Bool = false) {
        self.focusable = focusable
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { focusable }
    override var canBecomeMain: Bool { false }

    func setContent<Content: View>(_ view: Content) {
        let host = FirstMouseHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
}

/// Lets the first click land even though Halo isn't the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
