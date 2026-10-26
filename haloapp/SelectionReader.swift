import AppKit
import ApplicationServices

@MainActor
enum SelectionReader {
    /// Apps where the selection dot should never fire ⌘C (it copies shapes, not text).
    private static let watcherBlocklist: Set<String> = [
        "com.figma.Desktop",
    ]
    /// Non-Chromium apps that don't expose selected text via Accessibility but handle ⌘C fine.
    private static let extraCopyFallbackApps: Set<String> = [
        "com.sublimetext.4",
    ]
    private static var axEnabledPIDs: Set<pid_t> = []
    private static var chromiumCache: [String: Bool] = [:]

    /// Used by the hotkey.
    static func selectedText() async -> String? {
        guard let app = frontmostOtherApp() else { return nil }
        enableAccessibility(for: app)
        if let axText = axSelectedText() {
            return axText.isEmpty ? nil : axText
        }
        guard canUseCopyFallback(app) else { return nil }
        return await copySelection()
    }

    /// Used by the selection dot. Returns trimmed text.
    static func selectionForWatcher() async -> String? {
        guard let app = frontmostOtherApp() else { return nil }
        enableAccessibility(for: app)
        if let axText = axSelectedText() {
            let trimmed = axText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let id = app.bundleIdentifier, watcherBlocklist.contains(id) { return nil }
        guard canUseCopyFallback(app) else { return nil }
        return await copySelection()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frontmostOtherApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    /// Only fire a simulated ⌘C where it's needed; elsewhere it triggers the system error beep.
    private static func canUseCopyFallback(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, extraCopyFallbackApps.contains(id) { return true }
        return isChromiumBased(app)
    }

    /// Chrome, Edge, Brave, Arc and Electron apps all ship a "<Name> Framework.framework".
    private static func isChromiumBased(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, let url = app.bundleURL else { return false }
        if let cached = chromiumCache[id] { return cached }
        let frameworks = url.appendingPathComponent("Contents/Frameworks").path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks)) ?? []
        let result = names.contains { $0.hasSuffix(" Framework.framework") }
        chromiumCache[id] = result
        return result
    }

    /// Electron apps (Slack, VS Code, Discord…) only build their accessibility tree when asked.
    private static func enableAccessibility(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !axEnabledPIDs.contains(pid) else { return }
        let element = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result == .success || result == .attributeUnsupported {
            axEnabledPIDs.insert(pid)
        }
    }

    /// nil means the focused element doesn't expose selected text.
    static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        let before = pasteboard.changeCount

        Keyboard.press(8, flags: .maskCommand) // C
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }

        let text = pasteboard.string(forType: .string)
        snapshot.restore(to: pasteboard)
        return text
    }

    static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Keyboard.press(9, flags: .maskCommand) // V
        try? await Task.sleep(for: .milliseconds(400))
        snapshot.restore(to: pasteboard)
    }
}

enum Keyboard {
    static let syntheticTag: Int64 = 0x48414C4F // "HALO"

    static func press(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
            event.post(tap: .cghidEventTap)
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = pasteboard.pasteboardItems?.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        } ?? []
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
