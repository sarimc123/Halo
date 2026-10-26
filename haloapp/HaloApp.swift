import SwiftUI

@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: AppController.shared)
        } label: {
            MenuBarIcon(controller: AppController.shared)
        }
        Settings {
            SettingsView(controller: AppController.shared, hotkeys: AppController.shared.hotkeys)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
    }
}

struct MenuBarIcon: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Image(systemName: controller.accessibilityGranted ? "circle.circle" : "exclamationmark.circle")
    }
}

struct MenuContent: View {
    @ObservedObject var controller: AppController

    var body: some View {
        if !controller.accessibilityGranted {
            Button("Grant Accessibility Access…") { Permissions.openAccessibilitySettings() }
            Divider()
        }
        Button("Read Screen Region…") { controller.readScreenFromMenu() }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Halo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
