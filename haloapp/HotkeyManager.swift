import AppKit
import CoreGraphics
import Combine

struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64      // CGEventFlags raw value (⌃⌥⇧⌘ only)
    var modifierOnly: Bool     // e.g. "Right ⌥" by itself
    var label: String

    static let standard = Hotkey(keyCode: 61, modifiers: 0, modifierOnly: true, label: "Right ⌥")
}

enum ModifierKeys {
    static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    /// Modifiers that make a combo safe to use as a hotkey (⇧ alone would swallow capital letters).
    static let combining: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    /// `device` is the left/right-specific bit (NX_DEVICE…KEYMASK), so Left ⌥ and Right ⌥ are told apart.
    static let byKeyCode: [UInt16: (flag: CGEventFlags, device: UInt64, name: String)] = [
        54: (.maskCommand, 0x10, "Right ⌘"), 55: (.maskCommand, 0x08, "Left ⌘"),
        56: (.maskShift, 0x02, "Left ⇧"), 60: (.maskShift, 0x04, "Right ⇧"),
        58: (.maskAlternate, 0x20, "Left ⌥"), 61: (.maskAlternate, 0x40, "Right ⌥"),
        59: (.maskControl, 0x01, "Left ⌃"), 62: (.maskControl, 0x2000, "Right ⌃"),
        63: (.maskSecondaryFn, 0, "Fn"),
    ]

    /// True if this exact physical modifier key is down.
    static func isDown(_ keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard let info = byKeyCode[keyCode] else { return false }
        if info.device != 0 { return flags.rawValue & info.device != 0 }
        return flags.contains(info.flag)
    }

    static func symbols(_ flags: CGEventFlags) -> String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s
    }
}

enum KeyNames {
    static let special: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// F-keys are the only keys allowed as a hotkey without ⌃, ⌥ or ⌘.
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    static func name(for keyCode: UInt16, event: CGEvent) -> String {
        if let name = special[keyCode] { return name }
        if let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.uppercased()
        }
        return "Key \(keyCode)"
    }
}

@MainActor
final class HotkeyManager: ObservableObject {
    @Published var hotkey: Hotkey {
        didSet {
            if let data = try? JSONEncoder().encode(hotkey) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }
    @Published var isRecording = false {
        didSet { recordingModifier = nil; isHeld = false }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    private static let defaultsKey = "hotkey"
    private var tap: CFMachPort?
    private var isHeld = false
    private var recordingModifier: UInt16?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Hotkey.self, from: data) {
            hotkey = saved
        } else {
            hotkey = .standard
        }
    }

    /// Returns false until Accessibility permission is granted.
    @discardableResult
    func start() -> Bool {
        if let tap {
            // Re-arm if macOS disabled the tap (e.g. permission toggled off and back on).
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        guard AXIsProcessTrusted() else { return false }

        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// Returns true to swallow the event.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        // Ignore the ⌘C / ⌘V that Halo posts itself.
        if event.getIntegerValueField(.eventSourceUserData) == Keyboard.syntheticTag { return false }

        // A click while the hotkey is held means it's being used for something else (e.g. ⌥-drag) → cancel.
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            if isHeld && !isRecording {
                isHeld = false
                onCancel?()
            }
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if isRecording { return record(type: type, keyCode: keyCode, flags: flags, event: event) }

        if hotkey.modifierOnly {
            guard ModifierKeys.byKeyCode[hotkey.keyCode] != nil else { return false }
            if type == .flagsChanged && keyCode == hotkey.keyCode {
                let down = ModifierKeys.isDown(keyCode, flags: flags)
                if down && !isHeld { isHeld = true; onPress?() }
                else if !down && isHeld { isHeld = false; onRelease?() }
                return false
            }
            // Modifier used as part of a normal shortcut → cancel the wheel.
            if type == .keyDown && isHeld {
                isHeld = false
                onCancel?()
            }
            return false
        }

        switch type {
        case .keyDown where keyCode == hotkey.keyCode
            && flags.intersection(ModifierKeys.relevant).rawValue == hotkey.modifiers:
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 && !isHeld {
                isHeld = true
                onPress?()
            }
            return true
        case .keyUp where keyCode == hotkey.keyCode && isHeld:
            isHeld = false
            onRelease?()
            return true
        default:
            return false
        }
    }

    private func record(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, event: CGEvent) -> Bool {
        switch type {
        case .keyDown:
            if keyCode == 53 { isRecording = false; return true } // Esc cancels
            let mods = flags.intersection(ModifierKeys.relevant)
            // A plain key (or ⇧ + key) would be swallowed everywhere and break typing; keep recording instead.
            guard !mods.intersection(ModifierKeys.combining).isEmpty || KeyNames.functionKeys.contains(keyCode) else {
                return true
            }
            hotkey = Hotkey(
                keyCode: keyCode,
                modifiers: mods.rawValue,
                modifierOnly: false,
                label: ModifierKeys.symbols(mods) + KeyNames.name(for: keyCode, event: event)
            )
            isRecording = false
            return true
        case .flagsChanged:
            guard let info = ModifierKeys.byKeyCode[keyCode] else { return false }
            if ModifierKeys.isDown(keyCode, flags: flags) {
                recordingModifier = keyCode
            } else if recordingModifier == keyCode {
                hotkey = Hotkey(keyCode: keyCode, modifiers: 0, modifierOnly: true, label: info.name)
                isRecording = false
            }
            return false
        case .keyUp:
            return true
        default:
            return false
        }
    }
}

nonisolated private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { manager.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
