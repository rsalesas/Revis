import SwiftUI
import UpdateKit
import UpdateKitUI

/// UpdateKit's banner, in Revis's colours and on Revis's motion.
///
/// A wrapper rather than the package's view used directly, for the animation: it has to be
/// applied HERE, and it has to be ours. `.animation(value:)` only fires for a view that can
/// see the value change, and the review window observes `AppState`, not the checker inside
/// it — attached one level up from the banner, it re-runs whenever this view's own body
/// does. And the package's banner brings a transition but no animation, so without this it
/// would arrive on SwiftUI's default curve rather than on `Motion.reveal`.
struct UpdateBar: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        UpdateBanner(checker: checker, accent: Theme.accent, hairline: Theme.hairline)
            .motion(.reveal, value: checker.pendingUpdate?.version)
    }
}
