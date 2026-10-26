import AppKit
import ScreenCaptureKit
import Vision

struct ScreenRegion: Sendable {
    let rect: CGRect              // display-local points, top-left origin
    let displayID: CGDirectDisplayID
    let scale: CGFloat
}

// MARK: Region selection overlay

@MainActor
enum RegionSelector {
    private static var overlay: RegionOverlayPanel?

    static func select() async -> ScreenRegion? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }

        let frame = screen.frame
        let scale = screen.backingScaleFactor

        let rect: CGRect? = await withCheckedContinuation { continuation in
            let panel = RegionOverlayPanel(frame: frame) { rect in
                overlay?.orderOut(nil)
                overlay = nil
                continuation.resume(returning: rect)
            }
            overlay = panel
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.contentView)
        }

        guard let rect else { return nil }
        let local = CGRect(
            x: rect.minX - frame.minX,
            y: frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        return ScreenRegion(rect: local, displayID: number.uint32Value, scale: scale)
    }
}

final class RegionOverlayPanel: NSPanel {
    init(frame: CGRect, completion: @escaping (CGRect?) -> Void) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: frame.size))
        view.onFinish = { [weak self] localRect in
            guard let self else { return }
            completion(localRect.map { self.convertToScreen($0) })
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
}

final class RegionSelectionView: NSView {
    var onFinish: ((NSRect?) -> Void)?

    private var start: NSPoint?
    private var selection: NSRect?
    private var finished = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                           width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let selection, selection.width > 4, selection.height > 4 {
            finish(selection)
        } else {
            start = nil
            selection = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) { finish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) }
    }

    private func finish(_ rect: NSRect?) {
        guard !finished else { return }
        finished = true
        onFinish?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        if let selection {
            // Near-transparent (not fully clear) so clicks still land on the overlay.
            NSColor.white.withAlphaComponent(0.02).setFill()
            selection.fill(using: .copy)
            let path = NSBezierPath(roundedRect: selection, xRadius: 4, yRadius: 4)
            path.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }

        let hint = "Drag over the text you want to read  ·  Esc to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attributes)
        hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 80), withAttributes: attributes)
    }
}

// MARK: Capture + OCR

enum ScreenOCR {
    nonisolated static func capture(_ region: ScreenRegion) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw OCRError.displayNotFound
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let config = SCStreamConfiguration()
        config.sourceRect = region.rect
        config.width = max(1, Int(region.rect.width * region.scale))
        config.height = max(1, Int(region.rect.height * region.scale))
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    nonisolated static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

enum OCRError: LocalizedError {
    case displayNotFound
    var errorDescription: String? { "Couldn’t find that display." }
}
