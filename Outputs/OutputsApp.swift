import SwiftUI

@main
struct OutputsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { delegate.router.openSettings(.outputs) }
                    .keyboardShortcut(",")
            }
        }
    }
}
