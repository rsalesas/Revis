import Testing
import Foundation
@testable import Revis

@Suite("version comparison")
struct SemanticVersionTests {
    @Test func parsesDottedNumbers() {
        #expect(SemanticVersion("0.2.5")?.components == [0, 2, 5])
        #expect(SemanticVersion("1")?.components == [1])
        #expect(SemanticVersion(" 0.2.5 ")?.components == [0, 2, 5], "should tolerate whitespace")
    }

    /// Fails closed: anything unparseable is nil, and `resolve` turns nil into a reported
    /// failure rather than into "newer".
    @Test func rejectsNonNumeric() {
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("0.2.5-beta") == nil)
        #expect(SemanticVersion("v0.2.5") == nil)
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("0..5") == nil)
    }

    /// The whole reason the type exists: string ordering gets this backwards.
    @Test func doubleDigitComponentsOrderNumerically() {
        #expect(SemanticVersion("0.2.10")! > SemanticVersion("0.2.9")!)
        #expect(SemanticVersion("0.10.0")! > SemanticVersion("0.9.9")!)
        #expect(SemanticVersion("1.0.0")! > SemanticVersion("0.99.99")!)
        // …and the naive comparison it replaces would be wrong here.
        #expect("0.2.10" < "0.2.9")
    }

    @Test func missingComponentsAreZero() {
        #expect(SemanticVersion("0.2")! == SemanticVersion("0.2.0")!)
        #expect(SemanticVersion("0.2.1")! > SemanticVersion("0.2")!)
    }

    @Test func equalAndOrdering() {
        #expect(SemanticVersion("0.2.5")! == SemanticVersion("0.2.5")!)
        #expect(SemanticVersion("0.2.4")! < SemanticVersion("0.2.5")!)
        #expect(!(SemanticVersion("0.2.5")! < SemanticVersion("0.2.5")!))
    }
}

@MainActor
@Suite("the update checker")
struct UpdateCheckerTests {
    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    }

    nonisolated private func manifestData(version: String, minimumSystem: String? = nil) -> Data {
        var json: [String: Any] = [
            "version": version,
            "url": "https://github.com/rsalesas/Revis/releases/download/v\(version)/revis-\(version).dmg",
        ]
        if let minimumSystem { json["minimumSystemVersion"] = minimumSystem }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func checker(current: String = "0.2.5",
                         serves: @escaping UpdateChecker.Fetch,
                         system: OperatingSystemVersion = .init(majorVersion: 15, minorVersion: 5,
                                                                patchVersion: 0),
                         settings s: AppSettings? = nil) -> UpdateChecker {
        UpdateChecker(settings: s ?? settings(), fetch: serves,
                      currentVersion: current, systemVersion: system)
    }

    // MARK: - Outcomes

    @Test func newerVersionIsOffered() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.3.0") })
        await c.check()

        guard case .available(let update) = c.state else {
            Issue.record("expected an update, got \(c.state)"); return
        }
        #expect(update.version == "0.3.0")
        #expect(c.pendingUpdate?.version == "0.3.0")
    }

    @Test func sameVersionIsUpToDate() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.2.5") })
        await c.check()
        #expect(c.state == .upToDate)
        #expect(c.pendingUpdate == nil)
    }

    /// A rolled-back manifest must never walk anyone backwards.
    @Test func olderVersionIsUpToDate() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.1.0") })
        await c.check()
        #expect(c.state == .upToDate)
    }

    @Test func networkFailureIsReportedNotOffered() async {
        struct Boom: Error {}
        let c = checker(serves: { _ in throw Boom() })
        await c.check()

        guard case .failed = c.state else { Issue.record("expected failure, got \(c.state)"); return }
        #expect(c.pendingUpdate == nil)
    }

    /// Garbage must not be read as "newer".
    @Test func malformedManifestIsNotAnUpdate() async {
        let c = checker(serves: { _ in Data("not json".utf8) })
        await c.check()
        guard case .failed = c.state else { Issue.record("expected failure, got \(c.state)"); return }
        #expect(c.pendingUpdate == nil)
    }

    @Test func unparseableVersionIsNotAnUpdate() async {
        let c = checker(serves: { _ in self.manifestData(version: "latest") })
        await c.check()
        guard case .failed = c.state else { Issue.record("expected failure, got \(c.state)"); return }
        #expect(c.pendingUpdate == nil)
    }

    /// A 404 — the manifest not published yet, or the repository private — must be a quiet
    /// failure and never an update. `URLSession` hands back the error page's body rather
    /// than throwing, which is exactly what the explicit status check exists for.
    @Test func httpErrorStatusIsAFailure() async {
        let c = checker(serves: { _ in throw UpdateChecker.HTTPError(status: 404) })
        await c.check()
        guard case .failed(let message) = c.state else {
            Issue.record("expected failure, got \(c.state)"); return
        }
        #expect(message.contains("404"), "message should name the status: \(message)")
        #expect(c.pendingUpdate == nil)
    }

    // MARK: - Minimum system version

    @Test func buildNeedingNewerMacOSIsNotOffered() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.3.0", minimumSystem: "16.0") },
                        system: .init(majorVersion: 15, minorVersion: 5, patchVersion: 0))
        await c.check()
        #expect(c.state == .upToDate, "shouldn't offer a build this Mac can't run")
    }

    @Test func buildWithinReachIsOffered() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.3.0", minimumSystem: "15.0") },
                        system: .init(majorVersion: 15, minorVersion: 5, patchVersion: 0))
        await c.check()
        guard case .available = c.state else {
            Issue.record("expected an update, got \(c.state)"); return
        }
    }

    // MARK: - Throttling

    @Test func automaticCheckIsThrottled() async {
        var calls = 0
        let s = settings()
        let c = checker(serves: { _ in calls += 1; return self.manifestData(version: "0.3.0") },
                        settings: s)

        let start = Date()
        await c.checkIfDue(now: start)
        #expect(calls == 1)

        await c.checkIfDue(now: start.addingTimeInterval(3600))   // an hour later
        #expect(calls == 1, "shouldn't check again within the interval")

        await c.checkIfDue(now: start.addingTimeInterval(UpdateChecker.checkInterval + 60))
        #expect(calls == 2, "should check again once a day has passed")
    }

    @Test func manualCheckIgnoresThrottleAndPreference() async {
        var calls = 0
        let s = settings()
        s.checkForUpdates = false
        let c = checker(serves: { _ in calls += 1; return self.manifestData(version: "0.3.0") },
                        settings: s)

        await c.checkIfDue()
        #expect(calls == 0, "automatic check should respect the preference")

        await c.check()
        #expect(calls == 1, "an explicit check should run anyway")
    }

    // MARK: - Dismissal

    @Test func dismissHidesThisVersionOnly() async {
        let c = checker(serves: { _ in self.manifestData(version: "0.3.0") })
        await c.check()
        #expect(c.pendingUpdate != nil)

        c.dismissCurrent()
        #expect(c.pendingUpdate == nil, "dismissed version should stay hidden")
        guard case .available = c.state else {
            Issue.record("state itself should still know about it"); return
        }

        // A later release is a different version string, so it surfaces again.
        let c2 = checker(serves: { _ in self.manifestData(version: "0.4.0") })
        await c2.check()
        #expect(c2.pendingUpdate != nil)
    }
}

/// The seam between `scripts/release.sh` and the app.
///
/// These two live in different languages and different files, and the failure when they
/// drift is the quietest one this app has: an unreadable manifest is a failed check, and a
/// failed check looks from the outside exactly like being up to date. Nothing else would
/// catch it — so the script itself is read here, out of the source tree.
@Suite("the update manifest format")
struct UpdateManifestFormatTests {

    private static var releaseScript: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/release.sh")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Byte-for-byte the shape scripts/release.sh emits.
    private let published = """
    {
      "version": "0.3.0",
      "url": "https://github.com/rsalesas/Revis/releases/download/v0.3.0/revis-0.3.0.dmg",
      "minimumSystemVersion": "15.0",
      "notes": "Ships a disk image, and updates itself.",
      "archive": "https://github.com/rsalesas/Revis/releases/download/v0.3.0/revis-0.3.0.zip",
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "archiveSize": 5242880
    }
    """

    @Test func decodesWhatTheReleaseScriptPublishes() throws {
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(published.utf8))
        #expect(manifest.version == "0.3.0")
        #expect(manifest.minimumSystemVersion == "15.0")
        #expect(manifest.notes == "Ships a disk image, and updates itself.")
        #expect(manifest.archiveSize == 5_242_880)
        #expect(SemanticVersion(manifest.version) != nil)
        #expect(manifest.installableArchive != nil, "a full manifest must be installable")
    }

    /// Everything but `version` and `url` is omitted when unset — that must still decode.
    @Test func decodesMinimalManifest() throws {
        let minimal = """
        {"version":"0.3.0","url":"https://github.com/rsalesas/Revis/releases/download/v0.3.0/revis-0.3.0.dmg"}
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(minimal.utf8))
        #expect(manifest.version == "0.3.0")
        #expect(manifest.notes == nil)
        #expect(manifest.minimumSystemVersion == nil)
        #expect(manifest.installableArchive == nil,
                "no archive means fall back to the disk image, not install nothing")
    }

    /// An archive with no checksum is the one combination that must never be installable:
    /// the hash is the only thing between "we fetched bytes" and "we ran them".
    @Test func archiveWithoutAChecksumIsNotInstallable() throws {
        let noHash = """
        {"version":"0.3.0",
         "url":"https://example.com/revis-0.3.0.dmg",
         "archive":"https://example.com/revis-0.3.0.zip"}
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(noHash.utf8))
        #expect(manifest.installableArchive == nil)

        let shortHash = """
        {"version":"0.3.0",
         "url":"https://example.com/revis-0.3.0.dmg",
         "archive":"https://example.com/revis-0.3.0.zip",
         "sha256":"abc123"}
        """
        let truncated = try JSONDecoder().decode(UpdateManifest.self, from: Data(shortHash.utf8))
        #expect(truncated.installableArchive == nil, "a hash that isn't 64 hex digits is no hash")
    }

    /// Both URLs must name the tag, never `releases/latest/` — a download in flight must
    /// not be swapped by the next release, or the checksum the client holds is for
    /// different bytes.
    @Test func urlsAreVersionPinnedNotLatest() throws {
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(published.utf8))
        for url in [manifest.url, manifest.archive].compactMap({ $0 }) {
            #expect(url.path.contains(manifest.version), "\(url) does not name the version")
            #expect(!url.path.contains("latest"), "\(url) points at a mutable path")
        }
        // The script builds both from one base, so pin that too.
        #expect(Self.releaseScript.contains(
            #"DOWNLOAD_BASE="https://github.com/${REPO}/releases/download/${TAG}""#),
                "release.sh no longer builds the manifest URLs from the immutable tag path")
    }

    /// The script writes exactly the keys the app reads. A key added on one side only is
    /// either an unread field or — for a required one — a manifest that fails to decode.
    @Test func theScriptWritesOnlyKeysTheAppReads() {
        let known = ["version", "url", "minimumSystemVersion", "notes",
                     "archive", "sha256", "archiveSize"]
        let script = Self.releaseScript
        #expect(!script.isEmpty, "could not read scripts/release.sh")

        // The python heredoc that writes the manifest, and nothing else.
        guard let start = script.range(of: "manifest = {"),
              let end = script.range(of: "with open(path,", range: start.upperBound..<script.endIndex)
        else { Issue.record("the manifest-writing block has moved"); return }
        let block = String(script[start.lowerBound..<end.lowerBound])

        for match in block.matches(of: /manifest\["([A-Za-z]+)"\]|"([A-Za-z]+)":/) {
            let key = String(match.1 ?? match.2 ?? "")
            #expect(known.contains(key),
                    "release.sh writes \"\(key)\", which UpdateManifest does not decode")
        }
        // …and the other direction, for the two that are not optional.
        #expect(block.contains("\"version\":") && block.contains("\"url\":"),
                "the manifest must always carry version and url")
    }

    /// The app fetches from the repository the script publishes to. Two constants, in two
    /// languages, that have to name the same place.
    @Test func theCheckerReadsTheRepositoryTheScriptPublishesTo() {
        let manifestURL = UpdateChecker.manifestURL.absoluteString
        #expect(manifestURL == "https://github.com/rsalesas/Revis/releases/latest/download/appcast.json")
        #expect(Self.releaseScript.contains(#"REPO="rsalesas/Revis""#),
                "release.sh publishes somewhere other than where the app looks")
        // The one place `latest` is right: the manifest itself, which must always resolve
        // to the newest release rather than to a tag frozen at build time.
        #expect(manifestURL.contains("/releases/latest/download/appcast.json"))
    }
}

@Suite("the installer's checks")
struct AppUpdaterTests {

    // MARK: - The checksum

    @Test func hashMatchesItsOwnDigest() {
        let data = Data("the quick brown fox".utf8)
        #expect(AppUpdater.hashMatches(data, expected: AppUpdater.sha256(of: data)))
        #expect(AppUpdater.hashMatches(data, expected: AppUpdater.sha256(of: data).uppercased()),
                "a published hash in upper case is the same hash")
        #expect(!AppUpdater.hashMatches(Data("something else".utf8),
                                        expected: AppUpdater.sha256(of: data)))
    }

    /// Anything that is not a full digest fails closed, including the empty string — which
    /// is what a manifest written without a checksum would hand over.
    @Test func aMalformedHashNeverMatches() {
        let data = Data("x".utf8)
        for bad in ["", "abc", String(repeating: "f", count: 63),
                    String(repeating: "f", count: 65)] {
            #expect(!AppUpdater.hashMatches(data, expected: bad), "\"\(bad)\" should not match")
        }
    }

    // MARK: - The signing requirement

    /// Team alone is not enough, and this is the clause that says so: a Debug build carries
    /// the same team under an "Apple Development" leaf, so a team-only requirement would
    /// accept anything anyone on the team could produce, notarized or not.
    @Test func theRequirementPinsTheDeveloperIDChainAndNotJustTheTeam() {
        let requirement = AppUpdater.requirementString()
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("identifier \"app.revis.app\""))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"42SSLNY3WS\""))
        #expect(requirement.contains("1.2.840.113635.100.6.2.6"), "Developer ID CA marker")
        #expect(requirement.contains("1.2.840.113635.100.6.1.13"), "Developer ID leaf marker")
    }

    /// The identifier in the requirement has to be the identifier the app actually ships
    /// with, or every update fails verification after it has been downloaded.
    @Test func theRequirementNamesThisAppsBundleIdentifier() {
        let projectFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = (try? String(contentsOf: projectFile, encoding: .utf8)) ?? ""
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: app.revis.app"))
        #expect(AppUpdater.requirementString().contains("\"app.revis.app\""))
    }

    /// The app carries the helper at a path spelled out in `AppUpdater` and produced by a
    /// build script — two strings that nothing else compares.
    @Test func theHelperPathMatchesWhereTheBuildPutsIt() {
        let bundle = URL(fileURLWithPath: "/Applications/Revis.app")
        #expect(AppUpdater.helperURL(inBundle: bundle).path
                == "/Applications/Revis.app/Contents/Helpers/revis-updater")

        let projectFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = (try? String(contentsOf: projectFile, encoding: .utf8)) ?? ""
        #expect(project.contains("$HELPERS/revis-updater"),
                "the post-build script no longer bundles the helper where AppUpdater looks")
    }

    // MARK: - Eligibility

    @Test func aSandboxedBuildSaysSoRatherThanFailingLate() {
        let reason = AppUpdater.ineligibilityReason(
            bundleURL: URL(fileURLWithPath: "/Applications/Revis.app"), isSandboxed: true)
        #expect(reason?.contains("sandboxed") == true,
                "the reason should name the cause, not read as a permissions problem")
    }

    @Test func aTranslocatedCopyIsRefused() {
        let translocated = URL(fileURLWithPath:
            "/private/var/folders/AppTranslocation/ABC-123/d/Revis.app")
        #expect(RunLocationGuard.isUnsuitable(translocated))
        #expect(AppUpdater.ineligibilityReason(bundleURL: translocated, isSandboxed: false) != nil)
    }

    @Test func anUnwritableLocationIsRefused() {
        let readOnly = URL(fileURLWithPath: "/usr/bin/Revis.app")
        #expect(AppUpdater.ineligibilityReason(bundleURL: readOnly, isSandboxed: false) != nil)
    }

    @Test func anOrdinaryInstallIsEligible() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("revis-eligibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = directory.appendingPathComponent("Revis.app")
        #expect(AppUpdater.ineligibilityReason(bundleURL: bundle, isSandboxed: false) == nil)
    }

    // MARK: - What gets offered

    /// The banner and the menu ask this same question. Asked separately they drifted in
    /// Vaelora — one offering the in-place install, the other quietly sending people to the
    /// disk image — which is why it is one function with a test rather than two branches.
    @MainActor
    @Test func anInstallIsOnlyOfferedWhenItCanActuallyFinish() {
        let installable = UpdateManifest(
            version: "0.3.0",
            url: URL(string: "https://example.com/revis-0.3.0.dmg")!,
            archive: URL(string: "https://example.com/revis-0.3.0.zip")!,
            sha256: String(repeating: "a", count: 64),
            archiveSize: 100)
        let downloadOnly = UpdateManifest(
            version: "0.3.0",
            url: URL(string: "https://example.com/revis-0.3.0.dmg")!)

        #expect(UpdateAlert.offer(for: .available(installable), canInstallInPlace: true)
                == .install(installable))
        #expect(UpdateAlert.offer(for: .available(installable), canInstallInPlace: false)
                == .download(installable),
                "nowhere to install it means offer the disk image, not a button that fails")
        #expect(UpdateAlert.offer(for: .available(downloadOnly), canInstallInPlace: true)
                == .download(downloadOnly),
                "no archive means offer the disk image")
        #expect(UpdateAlert.offer(for: .upToDate, canInstallInPlace: true) == .upToDate)
        #expect(UpdateAlert.offer(for: .checking, canInstallInPlace: true) == .none)
        #expect(UpdateAlert.offer(for: .idle, canInstallInPlace: true) == .none)
    }
}
