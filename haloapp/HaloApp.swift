import SwiftUI

@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Halo", systemImage: "circle.circle") {
            MenuContent(controller: AppController.shared)
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

struct MenuContent: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Button("Read Screen Region…") { controller.readScreenFromMenu() }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Halo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
