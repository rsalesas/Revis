import AppKit
import UpdateKit

/// Revis refuses to launch from a disk image or other read-only / translocated location,
/// and asks to be moved to Applications first.
///
/// Run straight from the mounted DMG the app cannot update itself in place, and — worse
/// for this app in particular — the copy the user keeps opening is a copy on a volume they
/// will eject, so every fix shipped after it never arrives. Both are avoided by the move
/// every Mac user already knows to make.
///
/// What counts as unsuitable is UpdateKit's `RunLocation` — the same test its updater uses
/// to decline an in-place install, so the refusal here and the one there cannot disagree.
enum RunLocationGuard {

    /// Show the alert and quit if we are running from an unsuitable location. A no-op
    /// under the unit-test harness, which runs from a writable DerivedData path and must
    /// not be interrupted by a modal.
    @MainActor
    static func enforce(bundleURL: URL = Bundle.main.bundleURL) {
        guard NSClassFromString("XCTestCase") == nil, RunLocation.isUnsuitable(bundleURL) else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Move Revis to your Applications folder"
        alert.informativeText = """
            Revis is running from a disk image and can't update itself here. Drag Revis \
            into your Applications folder, then open it from there.
            """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(0)
    }
}
