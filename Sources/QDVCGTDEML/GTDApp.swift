import AppKit
import SwiftUI

@main
struct GTDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // One main window, like Mail's viewer window.
        Window("QDVC GTD EML", id: AppModel.viewerWindowID) {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 560)
                .onAppear { model.startUp() }
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            GTDCommands(model: model)
        }

        // Message windows, opened as tabs of the window they were asked from
        // (Open in New Tab); one dragged out of the tab bar is a standalone
        // message window.
        WindowGroup("Message", id: AppModel.messageWindowID, for: MessageRef.self) { $ref in
            MessageWindow(ref: $ref)
                .environment(model)
        }
        .defaultSize(width: 900, height: 760)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than
        // from the .app bundle, so the app gets a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
