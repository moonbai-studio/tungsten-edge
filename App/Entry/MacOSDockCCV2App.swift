import SwiftUI

@main
struct MacOSDockCCV2App: App {
    @StateObject private var runtime = AppRuntime()

    var body: some Scene {
        WindowGroup("任务条调试台") {
            ContentView(
                snapshot: runtime.snapshot,
                hasRequiredPermissions: runtime.hasRequiredPermissions,
                observationStatusText: runtime.observationStatusText,
                feedbackEntriesByWindowID: runtime.feedbackEntriesByWindowID,
                onToggle: runtime.toggle(windowID:),
                onActivate: runtime.activate(windowID:),
                onMinimize: runtime.minimize(windowID:),
                onHide: runtime.hide(windowID:),
                onClose: runtime.close(windowID:)
            )
                .frame(minWidth: 720, minHeight: 240)
                .navigationTitle("任务条调试台")
                .task {
                    runtime.start()
                }
                .onDisappear {
                    runtime.stop()
                }
        }
    }
}
