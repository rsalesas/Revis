import SwiftUI

@main
struct RevisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        DocumentGroup(newDocument: ReviewDocument()) { config in
            ReviewRootView(document: config.$document, fileURL: config.fileURL)
                .environmentObject(appState)
                .environmentObject(appState.appSettings)
                .frame(minWidth: 860, minHeight: 560)
                .tint(Theme.accent)
                // New windows open at the size the last one was left at; `.defaultSize`
                // below is only the first-run fallback.
                .background(WindowSizeMemory())
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 780)
        .commands { RevisCommands() }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.appSettings)
                .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Documents open through DocumentGroup, so there is nothing to intercept here — but
    /// a review app with no windows and no document should offer the open panel rather
    /// than sitting there with an empty Dock icon.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
}
