import SwiftUI

@main
struct ClashRemoteApp: App {
    @State private var state: AppState
    @State private var preferences: AppPreferences

    init() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"),
           CommandLine.arguments.indices.contains(index + 1) {
            WorkspacePreviewRenderer.render(to: CommandLine.arguments[index + 1])
            exit(0)
        }
        #endif
        let preferences = AppPreferences()
        _preferences = State(initialValue: preferences)
        _state = State(initialValue: AppState(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup("Clash Remote") {
            RootView()
                .environment(state)
                .environment(preferences)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            AppearanceSettingsWindow()
                .environment(preferences)
                .background(WindowPreferences(alwaysOnTop: preferences.alwaysOnTop))
        }
    }
}
