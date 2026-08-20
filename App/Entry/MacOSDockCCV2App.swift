import SwiftUI

@main
struct MacOSDockCCV2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettings(nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
