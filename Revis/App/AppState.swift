import SwiftUI
import Combine

/// App-wide shared state. Each review lives in its own window with its own `ReviewModel`;
/// this holds only what is common to every window.
@MainActor
final class AppState: ObservableObject {
    let appSettings: AppSettings

    /// The frontmost window's model, tracked so menu commands act on what you are looking
    /// at.
    @Published var activeReview: ReviewModel?

    static let shared = AppState()

    init(appSettings: AppSettings = AppSettings()) {
        self.appSettings = appSettings
    }
}
