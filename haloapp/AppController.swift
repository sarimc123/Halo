import AppKit
import SwiftUI
import Combine

enum TextSource { case selection, screen }

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let hotkeys = HotkeyManager()
    private let watcher = SelectionWatcher()

    @Published var showSelectionDot: Bool = UserDefaults.standard.object(forKey: "showSelectionDot") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSelectionDot, forKey: "showSelectionDot") }
    }
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    private var wheel: WheelController?
    private var cardPanel: FloatingPanel?
    private var cardModel: CardModel?
    private var cardKeyMonitor: Any?
    private var dotPanel: FloatingPanel?
    private var dotHideTask: Task<Void, Never>?

    private var targetApp: NSRunningApplication?
    private var pendingText: Task<String?, Never>?
    private var pendingSource: TextSource = .selection
    /// True while the drag-to-select screen overlay is up, so a second one can't open on top of it.
    private var isSelectingRegion = false

    // MARK: Startup

    func start() {
        Permissions.promptAccessibility()
        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onCancel = { [weak self] in self?.closeWheel() }
        watcher.onSelection = { [weak self] text in self?.showDot(for: text) }
        watcher.onDismiss = { [weak self] in self?.hideDot() }
        monitorPermissions()
    }

    /// Starts Halo as soon as Accessibility is granted, and tracks denial/revocation for the menu bar.
    private func monitorPermissions() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != self.accessibilityGranted { self.accessibilityGranted = trusted }
                if trusted && self.hotkeys.start() { self.watcher.start() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Hotkey (hold → wheel → release)

    private func hotkeyPressed() {
        guard wheel == nil, !isSelectingRegion else { return }
        hideDot()
        rememberTargetApp()
        pendingSource = .selection
        pendingText = Task { await SelectionReader.selectedText() }
        showWheel(at: NSEvent.mouseLocation, mode: .hold)
    }

    private func hotkeyReleased() {
        guard let wheel, wheel.mode == .hold else { return }
        let action = wheel.model.hovered
        closeWheel()
        if let action { perform(action) }
    }

    // MARK: Wheel

    private func showWheel(at point: NSPoint, mode: WheelController.Mode) {
        closeWheel()
        let wheel = WheelController(center: point, mode: mode)
        wheel.onPick = { [weak self] action in
            self?.closeWheel()
            if let action { self?.perform(action) }
        }
        self.wheel = wheel
    }

    private func closeWheel() {
        wheel?.close()
        wheel = nil
    }

    private func perform(_ action: HaloAction) {
        let textTask = pendingText
        let source = pendingSource
        pendingText = nil

        Task {
            let raw: String? = await textTask?.value ?? nil
            let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                await readScreen(then: action)
            } else {
                showCard(action: action, text: text, source: source)
            }
        }
    }

    // MARK: Screen reading

    func readScreenFromMenu() {
        rememberTargetApp()
        Task {
            try? await Task.sleep(for: .milliseconds(200)) // let the menu close
            await readScreen(then: nil)
        }
    }

    private func readScreen(then action: HaloAction?) async {
        guard !isSelectingRegion else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            showNotice("Allow Screen Recording for Halo in System Settings, then relaunch it.")
            return
        }

        hideDot()
        isSelectingRegion = true
        let selected = await RegionSelector.select()
        isSelectingRegion = false
        guard let region = selected else { return }
        try? await Task.sleep(for: .milliseconds(80))

        do {
            let image = try await ScreenOCR.capture(region)
            let text = try await ScreenOCR.recognizeText(in: image)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                showNotice("No text found in that area.")
                return
            }
            pendingSource = .screen
            if let action {
                showCard(action: action, text: text, source: .screen)
            } else {
                pendingText = Task { text }
                showWheel(at: NSEvent.mouseLocation, mode: .click)
            }
        } catch {
            showNotice("Couldn’t read the screen: \(error.localizedDescription)")
        }
    }

    // MARK: Selection dot

    private func showDot(for text: String) {
        guard showSelectionDot, wheel == nil, !isSelectingRegion else { return }
        hideDot()
        rememberTargetApp()

        let mouse = NSEvent.mouseLocation
        let size = CGSize(width: 28, height: 28)
        let panel = FloatingPanel(size: size)
        panel.setContent(SelectionDotView { [weak self] in self?.dotClicked(text: text) })
        let origin = NSPoint(x: mouse.x + 6, y: mouse.y - size.height - 6)
        panel.setFrameOrigin(ScreenGeometry.clampOrigin(origin, size: size, near: mouse))
        panel.orderFrontRegardless()
        dotPanel = panel

        dotHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.hideDot()
        }
    }

    private func hideDot() {
        dotHideTask?.cancel()
        dotHideTask = nil
        dotPanel?.orderOut(nil)
        dotPanel = nil
    }

    private func dotClicked(text: String) {
        let center = dotPanel.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSEvent.mouseLocation
        hideDot()
        pendingSource = .selection
        pendingText = Task { text }
        showWheel(at: center, mode: .click)
    }

    // MARK: Result card

    private func showCard(action: HaloAction, text: String, source: TextSource, notice: String? = nil) {
        closeCard()
        let model = CardModel(action: action, input: text, source: source, notice: notice)
        let size = ResultCardView.panelSize
        let panel = FloatingPanel(size: size, focusable: true)
        panel.setContent(ResultCardView(
            model: model,
            onApply: { [weak self] in self?.apply(model.output, source: source) },
            onClose: { [weak self] in self?.closeCard() }
        ))
        panel.setFrameOrigin(placement(for: size, near: NSEvent.mouseLocation))
        panel.makeKeyAndOrderFront(nil)
        cardPanel = panel
        cardModel = model

        cardKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            MainActor.assumeIsolated { self?.closeCard() }
            return nil
        }

        if notice == nil && action != .custom { model.run() }
    }

    private func showNotice(_ message: String) {
        showCard(action: .explain, text: "", source: .screen, notice: message)
    }

    private func closeCard() {
        cardModel?.cancel()
        cardModel = nil
        cardPanel?.orderOut(nil)
        cardPanel = nil
        if let monitor = cardKeyMonitor {
            NSEvent.removeMonitor(monitor)
            cardKeyMonitor = nil
        }
    }

    /// Replace: paste over the selection, or copy if the text came from the screen.
    private func apply(_ text: String, source: TextSource) {
        closeCard()
        guard !text.isEmpty else { return }
        guard source == .selection else {
            Clipboard.copy(text)
            return
        }
        let app = targetApp
        Task {
            app?.activate()
            try? await Task.sleep(for: .milliseconds(150))
            await SelectionReader.paste(text)
        }
    }

    // MARK: Helpers

    private func rememberTargetApp() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApp = app
        }
    }

    private func placement(for size: CGSize, near point: NSPoint) -> NSPoint {
        let origin = NSPoint(x: point.x + 4, y: point.y - size.height - 4)
        return ScreenGeometry.clampOrigin(origin, size: size, near: point)
    }
}
