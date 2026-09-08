import AppKit

/// Revis refuses to launch from a disk image or other read-only / translocated location,
/// and asks to be moved to Applications first.
///
/// Run straight from the mounted DMG the app cannot update itself in place, and — worse
/// for this app in particular — the copy the user keeps opening is a copy on a volume they
/// will eject, so every fix shipped after it never arrives. Both are avoided by the move
/// every Mac user already knows to make.
enum RunLocationGuard {

    /// Whether a bundle at `url` is somewhere the app should not run from:
    ///
    /// - **App Translocation** — a quarantined app opened outside a trusted location
    ///   (Applications). macOS runs it from a randomized, read-only path under
    ///   `/AppTranslocation/`, so `Bundle.main.bundleURL` is not where the user thinks the
    ///   app lives. This is what happens when you double-click the app inside a freshly
    ///   downloaded DMG, or run it from ~/Downloads.
    /// - **A read-only volume** — the mounted disk image itself (the compressed DMG we ship
    ///   is read-only), caught for the case where translocation does not apply, e.g.
    ///   quarantine was stripped.
    static func isUnsuitable(_ url: URL) -> Bool {
        if url.path.contains("/AppTranslocation/") { return true }
        if let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return true
        }
        return false
    }

    /// Show the alert and quit if we are running from an unsuitable location. A no-op
    /// under the unit-test harness, which runs from a writable DerivedData path and must
    /// not be interrupted by a modal.
    @MainActor
    static func enforce(bundleURL: URL = Bundle.main.bundleURL) {
        guard NSClassFromString("XCTestCase") == nil, isUnsuitable(bundleURL) else { return }

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
