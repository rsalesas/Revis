import Foundation
import Combine

/// What `appcast.json` on the releases page carries.
struct UpdateManifest: Codable, Equatable, Sendable {
    let version: String
    /// The disk image a human downloads. Used when the app cannot install in place.
    let url: URL
    /// Oldest macOS the new build runs on. A build that needs more than this Mac has is
    /// not offered — pointing someone at a download they cannot run is worse than staying
    /// quiet.
    var minimumSystemVersion: String?
    var notes: String?

    /// The ZIP the in-app updater installs, and its SHA-256. Optional so a manifest
    /// published without one (or read by an older build) simply falls back to opening the
    /// disk image. Both or neither: an archive without a checksum must never be installed,
    /// so `installableArchive` only reports one when the hash is there too.
    var archive: URL?
    var sha256: String?
    var archiveSize: Int?

    var installableArchive: (url: URL, sha256: String)? {
        guard let archive, let sha256, sha256.count == 64 else { return nil }
        return (archive, sha256)
    }
}

/// Checks whether a newer build has been published to the GitHub releases page.
///
/// The manifest is fetched from `releases/latest/download/appcast.json`, which GitHub
/// redirects to the newest release's asset of that name — so the URL below never has to
/// change, and nothing here has to know the GitHub API exists.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Set aside by the user for this version; cleared when a newer one appears.
    @Published private(set) var dismissedVersion: String?

    nonisolated static let manifestURL =
        URL(string: "https://github.com/rsalesas/Revis/releases/latest/download/appcast.json")!
    /// How long an automatic check waits before looking again. Manual checks ignore it.
    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Not `@Sendable`: the checker is main-actor isolated, so the closure is stored and
    /// awaited there. Keeping it un-sendable lets tests use a plain stub.
    typealias Fetch = (URL) async throws -> Data

    struct HTTPError: LocalizedError {
        let status: Int
        var errorDescription: String? { "The update server returned status \(status)." }
    }

    /// `URLSession.data(for:)` does NOT throw on an HTTP error status — it hands back the
    /// error page's body. Without this check a 404 or a captive-portal login page would be
    /// fed to the JSON decoder, so the status is validated up front.
    nonisolated static func defaultFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
        return data
    }

    private let settings: AppSettings
    private let fetch: Fetch
    private let currentVersion: String
    private let systemVersion: OperatingSystemVersion

    init(settings: AppSettings,
         fetch: @escaping Fetch = UpdateChecker.defaultFetch,
         currentVersion: String = AppVersion.marketing,
         systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        self.settings = settings
        self.fetch = fetch
        self.currentVersion = currentVersion
        self.systemVersion = systemVersion
    }

    /// The update to show, if there is one the user has not set aside.
    var pendingUpdate: UpdateManifest? {
        guard case .available(let manifest) = state,
              manifest.version != dismissedVersion else { return nil }
        return manifest
    }

    /// The version on offer, whether or not the banner is showing it.
    ///
    /// Read from `state` rather than `pendingUpdate`, which goes nil once the notice has
    /// been set aside — an install started before that would otherwise lose the number it
    /// is installing halfway through.
    var availableVersion: String? {
        if case .available(let manifest) = state { return manifest.version }
        return nil
    }

    /// Stop showing the banner for this version. A later version brings it back.
    func dismissCurrent() {
        if case .available(let manifest) = state { dismissedVersion = manifest.version }
    }

    // MARK: - Installing

    /// What the running install is doing, or nil when none is.
    ///
    /// Held here rather than in the banner because an install can be started from the
    /// banner or from "Check for Updates…", and the second can happen with no review
    /// window open at all.
    @Published private(set) var installStage: AppUpdater.InstallStage?
    /// The last install failure, shown in the banner.
    @Published private(set) var installFailure: String?

    var isInstalling: Bool { installStage != nil }

    /// The running install, kept so it can be cancelled. Everything before the hand-off is
    /// reversible — nothing is staged and the installed copy is untouched — so cancelling
    /// is safe right up to the last step.
    private var installTask: Task<AppUpdater.Failure?, Never>?

    func cancelInstall() { installTask?.cancel() }

    /// Download, verify and install the available update in place.
    ///
    /// On success this never returns — the helper relaunches the new copy. Returns the
    /// failure otherwise, for a caller that has nowhere to show `installFailure`.
    @discardableResult
    func installAvailableUpdate() async -> AppUpdater.Failure? {
        guard case .available(let manifest) = state, installStage == nil else { return nil }
        installFailure = nil
        installStage = .downloading(receivedBytes: 0, totalBytes: manifest.archiveSize)

        let task = Task { @MainActor [weak self] in
            await AppUpdater.installUpdate(manifest) { stage in self?.installStage = stage }
        }
        installTask = task
        let failure = await task.value
        installTask = nil
        installStage = nil
        // Cancelling is the user's own instruction, not a fault to report back at them.
        installFailure = failure == .cancelled ? nil : failure?.errorDescription
        return failure
    }

    /// The launch-time check: skipped when the user has turned it off, or when we already
    /// looked recently.
    func checkIfDue(now: Date = Date()) async {
        guard settings.checkForUpdates else { return }
        if let last = settings.lastUpdateCheck,
           now.timeIntervalSince(last) < Self.checkInterval { return }
        await check(now: now)
    }

    /// An explicit "Check for Updates…" — ignores both the interval and the preference,
    /// since the user just asked for it directly.
    func check(now: Date = Date()) async {
        state = .checking
        do {
            let data = try await fetch(Self.manifestURL)
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            settings.lastUpdateCheck = now
            state = resolve(manifest)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Decide what a fetched manifest means for this copy of the app.
    private func resolve(_ manifest: UpdateManifest) -> State {
        guard let offered = SemanticVersion(manifest.version) else {
            return .failed("Unreadable version in the update manifest.")
        }
        guard let running = SemanticVersion(currentVersion) else {
            return .failed("Unreadable version in this build.")
        }
        guard offered > running else { return .upToDate }
        guard meetsMinimumSystem(manifest) else { return .upToDate }
        // A dismissal is keyed to its version string, so a newer release surfaces on its
        // own without needing to clear anything here.
        return .available(manifest)
    }

    /// A build that needs a newer macOS than this Mac runs is not an update we can offer.
    private func meetsMinimumSystem(_ manifest: UpdateManifest) -> Bool {
        guard let required = manifest.minimumSystemVersion,
              let needed = SemanticVersion(required) else { return true }
        let running = SemanticVersion(
            "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)")
        guard let running else { return true }
        return running >= needed
    }
}
