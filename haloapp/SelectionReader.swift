import AppKit
import ApplicationServices

@MainActor
enum SelectionReader {
    /// Apps where the selection dot should never fire ⌘C (it copies shapes, not text).
    private static let watcherBlocklist: Set<String> = [
        "com.figma.Desktop",
    ]
    /// Apps that don't expose selected text via Accessibility but handle ⌘C fine.
    private static let extraCopyFallbackApps: Set<String> = [
        "com.sublimetext.4",
    ]
    /// Focused-element roles where ⌘C is likely to copy text (so it won't beep).
    private static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXStaticText",
    ]
    /// How long to wait for another app to answer an Accessibility request.
    /// The hotkey listener shares this thread, so a hung app must not block it for long.
    private static let axTimeout: Float = 0.3
    private static var axEnabledPIDs: Set<pid_t> = []
    private static var chromiumCache: [String: Bool] = [:]

    private enum AXRead {
        case text(String)               // "" means the app reported no selection
        case unreadable(role: String?)  // couldn't read it via Accessibility
    }

    // MARK: Public

    /// Used by the hotkey.
    static func selectedText() async -> String? {
        guard let app = frontmostOtherApp() else { return nil }
        enableAccessibility(for: app)
        switch readAX() {
        case .text(let text):
            return text.isEmpty ? nil : text
        case .unreadable(let role):
            guard canUseCopyFallback(app, role: role) else { return nil }
            return await copySelection()
        }
    }

    /// Used by the selection dot. Returns trimmed text.
    static func selectionForWatcher() async -> String? {
        guard let app = frontmostOtherApp() else { return nil }
        enableAccessibility(for: app)
        switch readAX() {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .unreadable(let role):
            if let id = app.bundleIdentifier, watcherBlocklist.contains(id) { return nil }
            guard canUseCopyFallback(app, role: role) else { return nil }
            return await copySelection()?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    // MARK: Accessibility

    private static func readAX() -> AXRead {
        let system = AXUIElementCreateSystemWide()
        // Set on the system-wide element, this applies to every Accessibility call Halo makes.
        AXUIElementSetMessagingTimeout(system, axTimeout)
        guard let focused = element(attribute(system, kAXFocusedUIElementAttribute)) else {
            return .unreadable(role: nil)
        }
        let role = attribute(focused, kAXRoleAttribute) as? String
        let plain = attribute(focused, kAXSelectedTextAttribute) as? String

        if let plain, !plain.isEmpty { return .text(plain) }
        // Safari, Mail and other WebKit views expose page selections through text markers instead.
        if let web = webKitSelection(from: focused), !web.isEmpty { return .text(web) }
        if let plain { return .text(plain) }
        return .unreadable(role: role)
    }

    /// Walks up from the focused element looking for a WebKit selection.
    private static func webKitSelection(from start: AXUIElement) -> String? {
        var current: AXUIElement? = start
        for _ in 0..<10 {
            guard let el = current else { return nil }
            if let range = attribute(el, "AXSelectedTextMarkerRange") {
                var value: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    el, "AXStringForTextMarkerRange" as CFString, range, &value
                ) == .success, let text = value as? String {
                    return text
                }
            }
            current = element(attribute(el, kAXParentAttribute))
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// Electron apps (Slack, VS Code, Discord…) only build their accessibility tree when asked.
    private static func enableAccessibility(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !axEnabledPIDs.contains(pid) else { return }
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, axTimeout)
        let result = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result == .success || result == .attributeUnsupported {
            axEnabledPIDs.insert(pid)
        }
    }

    // MARK: ⌘C fallback

    private static func frontmostOtherApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    /// Only fire ⌘C where it's likely to copy text; elsewhere it triggers the system error beep.
    private static func canUseCopyFallback(_ app: NSRunningApplication, role: String?) -> Bool {
        if let id = app.bundleIdentifier, extraCopyFallbackApps.contains(id) { return true }
        if isChromiumBased(app) { return true }
        if let role, textRoles.contains(role) { return true }
        return false
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
}

enum Keyboard {
    static let syntheticTag: Int64 = 0x48414C4F // "HALO"

    static func press(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        // Private state keeps keys the user is physically holding (like the ⌥ hotkey) out of the event.
        let source = CGEventSource(stateID: .privateState)
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
