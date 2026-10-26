import AppKit
import ApplicationServices

@MainActor
enum SelectionReader {
    /// Accessibility first; falls back to a simulated ⌘C for apps that don't expose selected text.
    static func selectedText() async -> String? {
        if let axText = axSelectedText() {
            return axText.isEmpty ? nil : axText
        }
        return await copySelection()
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
