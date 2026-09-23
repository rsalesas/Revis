import Foundation
import UpdateKit

/// Everything that makes UpdateKit's updater Revis's.
///
/// The checking, the verified install and the UI all live in the package; what lives here
/// is the four answers only this app can give — where the manifest is, whose signature to
/// demand, who performs the swap, and where the preference is kept.
enum RevisUpdates {

    /// `releases/latest/download/appcast.json`, which GitHub redirects to the newest
    /// release's asset of that name — so this URL never has to change, and nothing here has
    /// to know the GitHub API exists. `UpdateTests` checks it against `release.sh`.
    static let manifestURL =
        URL(string: "https://github.com/rsalesas/Revis/releases/latest/download/appcast.json")!

    /// Pinned deliberately: a signature check that accepts *any* valid Developer ID accepts
    /// every paid developer account, which is not a meaningful gate.
    static let teamIdentifier = "42SSLNY3WS"
    static let bundleIdentifier = "app.revis.app"

    /// Where the app target's post-build script puts the helper. Spelled out rather than
    /// looked up: `url(forAuxiliaryExecutable:)` searches only `Contents/MacOS`.
    static let helperPath = "Contents/Helpers/revis-updater"

    static func configuration(defaults: UserDefaults = .standard) -> UpdaterConfiguration {
        UpdaterConfiguration(
            appName: "Revis",
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            manifestURL: manifestURL,
            // Revis's own helper rather than UpdateKit's shell script: one atomic
            // `replaceItemAt` instead of two renames, and `release.sh` already signs,
            // timestamps and verifies it.
            swap: .helper(relativePath: helperPath, arguments: ["apply-update"]),
            defaults: defaults,
            // The keys Revis stored these under before the package existed, so that
            // someone who turned the check off does not find it back on after updating.
            // `AppSettings` still owns the toggle; the checker reads the same key live.
            automaticChecksKey: AppSettings.checkForUpdatesKey,
            lastCheckKey: AppSettings.lastUpdateCheckKey)
    }
}
