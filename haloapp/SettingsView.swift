import SwiftUI
import ApplicationServices
import Combine

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var hotkeys: HotkeyManager

    var body: some View {
        TabView {
            GeneralSettings(controller: controller, hotkeys: hotkeys)
                .tabItem { Label("General", systemImage: "gearshape") }
            ResponseSettings()
                .tabItem { Label("Responses", systemImage: "text.bubble") }
        }
        .frame(width: 460)
        .onAppear { NSApp.activate() }
    }
}

struct GeneralSettings: View {
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
                status("Accessibility", ok: accessibilityOK) { Permissions.openAccessibilitySettings() }
                status("Screen Recording", ok: screenOK) { Permissions.openScreenRecordingSettings() }
                LabeledContent("On-device model") {
                    Text(AIEngine.unavailableReason ?? "Ready")
                        .foregroundStyle(AIEngine.unavailableReason == nil ? Color.green : Color.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            accessibilityOK = AXIsProcessTrusted()
            screenOK = CGPreflightScreenCaptureAccess()
        }
        // Switching tabs mid-recording would otherwise swallow the next keypress.
        .onDisappear { hotkeys.isRecording = false }
    }

    private func status(_ title: String, ok: Bool, fix: @escaping @MainActor () -> Void) -> some View {
        LabeledContent(title) {
            if ok {
                Text("Granted").foregroundStyle(.green)
            } else {
                Button("Open Settings", action: fix)
            }
        }
    }
}

struct ResponseSettings: View {
    @AppStorage(StyleKeys.length) private var length: ResponseLength = .medium
    @AppStorage(StyleKeys.format) private var format: ResponseFormat = .auto
    @AppStorage(StyleKeys.tone) private var tone: ResponseTone = .neutral
    @AppStorage(StyleKeys.customInstructions) private var customInstructions = ""

    var body: some View {
        Form {
            Section("Style") {
                Picker("Length", selection: $length) {
                    ForEach(ResponseLength.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Tone", selection: $tone) {
                    ForEach(ResponseTone.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Format") {
                Picker("Format", selection: $format) {
                    ForEach(ResponseFormat.allCases) { option in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.title)
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section("Custom instructions") {
                TextEditor(text: $customInstructions)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 70)
                    .onChange(of: customInstructions) { _, new in
                        if new.count > StyleKeys.customLimit {
                            customInstructions = String(new.prefix(StyleKeys.customLimit))
                        }
                    }
                HStack {
                    Text("Added to every request, e.g. “Use British spelling.”")
                    Spacer()
                    Text("\(customInstructions.count)/\(StyleKeys.customLimit)")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Text("Length and format apply to Explain, Summarize and Custom. Fix Grammar ignores style so it only corrects errors. Changes apply to the next card you open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
