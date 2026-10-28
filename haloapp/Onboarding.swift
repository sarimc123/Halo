import SwiftUI
import ApplicationServices
import Combine

struct OnboardingView: View {
    let hotkeyLabel: String
    let onFinish: () -> Void
    @State private var step = 0
    private let lastStep = 2

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: PermissionsStep()
                case 1: StyleStep()
                default: IntroStep(hotkeyLabel: hotkeyLabel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            HStack {
                StepDots(count: lastStep + 1, current: step)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == lastStep ? "Get Started" : "Continue") {
                    if step == lastStep { onFinish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 540)
    }
}

// MARK: Steps

private struct PermissionsStep: View {
    @State private var accessibilityOK = AXIsProcessTrusted()
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(symbol: "lock.shield", title: "Permissions",
                       subtitle: "Halo needs these to read the text you're working with. Nothing leaves your Mac.")
            PermissionRow(title: "Accessibility",
                          detail: "Required. Reads highlighted text and listens for the shortcut.",
                          granted: accessibilityOK) {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }
            PermissionRow(title: "Screen Recording",
                          detail: "Optional. Reads text from part of the screen when nothing is highlighted. Halo may need a relaunch after granting.",
                          granted: screenOK) {
                if !CGRequestScreenCaptureAccess() { Permissions.openScreenRecordingSettings() }
            }
        }
        .padding(24)
        .onReceive(refresh) { _ in
            accessibilityOK = AXIsProcessTrusted()
            screenOK = CGPreflightScreenCaptureAccess()
        }
    }
}

private struct StyleStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StepHeader(symbol: "text.bubble", title: "Response Style",
                       subtitle: "Pick how Halo should answer. You can change this anytime in Settings.")
                .padding([.horizontal, .top], 24)
            ResponseSettings()
        }
    }
}

private struct IntroStep: View {
    let hotkeyLabel: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("You're all set")
                .font(.title2.weight(.semibold))
            Text("Halo is an on-device AI assistant that works on any text, in any app. Highlight something, hold \(hotkeyLabel), move toward an action and let go. With nothing highlighted, Halo lets you drag over part of the screen instead.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Spacer()
        }
        .padding(24)
    }
}

// MARK: Pieces

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Allow…", action: action) }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }
}
