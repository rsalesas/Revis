import SwiftUI
import Combine

/// App-wide shared state. Each review lives in its own window with its own `ReviewModel`;
/// this holds only what is common to every window.
@MainActor
final class AppState: ObservableObject {
    let appSettings: AppSettings

    /// Watches the releases page for a newer build. Shared rather than per-window: two
    /// reviews open at once must not each offer the same update, and an install started
    /// from one of them has to survive that window closing.
    let updateChecker: UpdateChecker

    /// The frontmost window's model, tracked so menu commands act on what you are looking
    /// at.
    @Published var activeReview: ReviewModel?

    static let shared = AppState()

    init(appSettings: AppSettings = AppSettings(), updateChecker: UpdateChecker? = nil) {
        self.appSettings = appSettings
        self.updateChecker = updateChecker ?? UpdateChecker(settings: appSettings)
    }
}
