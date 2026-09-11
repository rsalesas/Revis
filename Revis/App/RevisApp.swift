import SwiftUI
import AppKit

@main
struct RevisApp: App {
    /// **This app does not do window tabs.**
    ///
    /// Set here rather than in `applicationDidFinishLaunching`, because state restoration
    /// reopens last session's documents before the delegate is told the app has launched —
    /// and a window that has already joined a tab group does not leave it when tabbing is
    /// switched off afterwards. The `App`'s initialiser runs before any of that.
    ///
    /// It is a real preference and not tidiness. A tab is for several views of ONE thing;
    /// two reviews are two documents, of two different files, each with its own margin,
    /// its own pane and its own outline — and stacked as tabs they share one title bar, so
    /// the answer to "which document am I marking up" moves from the window you are looking
    /// at into a strip you have to read. Worse, the panes are per-window furniture: the
    /// annotation pane and the outline belong to the document, and a tab group makes them
    /// look like one set of controls over whichever document is in front.
    ///
    /// This also takes Show Tab Bar and Merge All Windows out of the Window menu, which is
    /// the honest result: they are commands this app has no answer for.
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the update check, not after: a copy running from the mounted disk image
        // cannot install anything, and offering it an update it will refuse at the last
        // step is worse than saying so now.
        RunLocationGuard.enforce()
        // Throttled to once a day, and skipped entirely when the preference is off.
        Task { @MainActor in await AppState.shared.updateChecker.checkIfDue() }
    }
}
