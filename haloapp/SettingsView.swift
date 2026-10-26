import SwiftUI
import ApplicationServices

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var hotkeys: HotkeyManager

    @State private var accessibilityOK = AXIsProcessTrusted()
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent("Wheel shortcut") {
                    Button(hotkeys.isRecording ? "Press a key…" : hotkeys.hotkey.label) {
                        hotkeys.isRecording.toggle()
                    }
                }
                Text("Hold the shortcut, move toward an action, and release. A lone modifier like Right ⌥ or a combo like ⌃Space both work. Esc cancels recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show a dot when you highlight text", isOn: $controller.showSelectionDot)
            }

            Section("Status") {
                status("Accessibility", ok: accessibilityOK, fix: Permissions.openAccessibilitySettings)
                status("Screen Recording", ok: screenOK, fix: Permissions.openScreenRecordingSettings)
                LabeledContent("On-device model") {
                    Text(AIEngine.unavailableReason ?? "Ready")
                        .foregroundStyle(AIEngine.unavailableReason == nil ? Color.green : Color.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { NSApp.activate() }
        .onReceive(refresh) { _ in
            accessibilityOK = AXIsProcessTrusted()
            screenOK = CGPreflightScreenCaptureAccess()
        }
    }

    private func status(_ title: String, ok: Bool, fix: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if ok {
                Text("Granted").foregroundStyle(.green)
            } else {
                Button("Open Settings", action: fix)
            }
        }
    }
}

enum Permissions {
    static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
