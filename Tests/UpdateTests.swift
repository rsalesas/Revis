import Testing
import Foundation
import UpdateKit
import UpdateKitUI
@testable import Revis

// The updater itself — version ordering, the checksum, the signing requirement, the
// checker's outcomes, the swap — is UpdateKit's, and is tested there. What is left here is
// what only this app can get wrong: the seams between UpdateKit, `release.sh`, `project.yml`
// and the preferences Revis already had.
//
// Two types share the name: Revis's `AppVersion` answers "what am I", UpdateKit's answers
// "which is newer". In this file it means the second.
private typealias AppVersion = UpdateKit.AppVersion

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
        #expect(AppVersion(manifest.version) != nil)
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
        let manifestURL = RevisUpdates.manifestURL.absoluteString
        #expect(manifestURL == "https://github.com/rsalesas/Revis/releases/latest/download/appcast.json")
        #expect(Self.releaseScript.contains(#"REPO="rsalesas/Revis""#),
                "release.sh publishes somewhere other than where the app looks")
        // The one place `latest` is right: the manifest itself, which must always resolve
        // to the newest release rather than to a tag frozen at build time.
        #expect(manifestURL.contains("/releases/latest/download/appcast.json"))
    }
}

@Suite("Revis's updater configuration")
struct RevisUpdatesTests {

    private static let project: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Team alone is not enough — a Debug build carries the same team under an "Apple
    /// Development" leaf. UpdateKit adds the Developer ID clauses; this checks they are
    /// built around OUR identity.
    @Test func theRequirementPinsOurTeamAndTheDeveloperIDChain() {
        let requirement = AppUpdater.requirementString(for: RevisUpdates.configuration())
        #expect(requirement.contains("identifier \"app.revis.app\""))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"42SSLNY3WS\""))
        #expect(requirement.contains("1.2.840.113635.100.6.2.6"), "Developer ID CA marker")
        #expect(requirement.contains("1.2.840.113635.100.6.1.13"), "Developer ID leaf marker")
    }

    /// The identifier and team in the requirement have to be the ones the app actually
    /// ships with, or every update fails verification after it has been downloaded.
    @Test func theRequirementNamesWhatTheProjectSignsWith() {
        #expect(Self.project.contains("PRODUCT_BUNDLE_IDENTIFIER: \(RevisUpdates.bundleIdentifier)"))
        #expect(Self.project.contains("DEVELOPMENT_TEAM: \(RevisUpdates.teamIdentifier)"))
    }

    /// The sharpest test of the updater. The test host is the Debug build, which is signed
    /// "Apple Development" with OUR team identifier — so a requirement pinning only the
    /// team would accept it, and with it anything a team member could sign locally,
    /// notarized or not. It must be refused.
    @Test func aDevelopmentSignedBuildOfOurOwnTeamIsRefused() {
        let failure = AppUpdater.verifySignature(
            of: Bundle.main.bundleURL,
            requirement: AppUpdater.requirementString(for: RevisUpdates.configuration()))
        #expect(failure != nil,
                "a development-signed build must not pass, even though it carries our team")
    }

    /// …and the same bundle DOES pass a requirement that asks only for a valid signature
    /// from our team, so the refusal above is the Developer ID clauses doing their job —
    /// not the API failing on everything, or the test host being unsigned.
    @Test func theSameBuildPassesATeamOnlyRequirement() {
        let teamOnly = "anchor apple generic"
            + " and identifier \"\(RevisUpdates.bundleIdentifier)\""
            + " and certificate leaf[subject.OU] = \"\(RevisUpdates.teamIdentifier)\""
        #expect(AppUpdater.verifySignature(of: Bundle.main.bundleURL, requirement: teamOnly) == nil,
                "the test host should be signed Apple Development by our team")
    }

    /// The helper path handed to UpdateKit and the path the post-build script copies it
    /// to are two strings that nothing else compares.
    @Test func theHelperPathMatchesWhereTheBuildPutsIt() {
        let swap = RevisUpdates.configuration().swap
        let bundle = URL(fileURLWithPath: "/Applications/Revis.app")
        #expect(swap.helperURL(inBundle: bundle)?.path
                == "/Applications/Revis.app/Contents/Helpers/revis-updater")
        #expect(swap == .helper(relativePath: "Contents/Helpers/revis-updater",
                                arguments: ["apply-update"]),
                "revis-updater answers only to apply-update")
        #expect(Self.project.contains("$HELPERS/revis-updater"),
                "the post-build script no longer bundles the helper where the updater looks")
        // …and in the real bundle, not only on paper: a missing helper fails the update at
        // its very last step, with the app already committed to quitting.
        let real = swap.helperURL(inBundle: Bundle.main.bundleURL)!
        #expect(FileManager.default.isExecutableFile(atPath: real.path),
                "no executable helper at \(real.path)")
    }

    /// Settings and the checker read one key. Turned off in Settings, the automatic check
    /// must actually stop — and a preference set by a build older than UpdateKit must
    /// still be honoured.
    @MainActor
    @Test func theSettingsToggleIsThePreferenceTheCheckerReads() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let checker = UpdateChecker(configuration: RevisUpdates.configuration(defaults: defaults),
                                    fetch: { _ in Data() }, currentVersion: "0.3.8")
        #expect(checker.automaticallyChecks, "on unless someone turned it off")

        settings.checkForUpdates = false
        #expect(!checker.automaticallyChecks, "Settings and the checker disagree")

        defaults.set(true, forKey: "checkForUpdates")
        #expect(checker.automaticallyChecks, "the key earlier builds stored it under")
    }

    @MainActor
    @Test func anAutomaticCheckRespectsTheSetting() async {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        AppSettings(defaults: defaults).checkForUpdates = false
        var calls = 0
        let checker = UpdateChecker(configuration: RevisUpdates.configuration(defaults: defaults),
                                    fetch: { _ in calls += 1; return Data() },
                                    currentVersion: "0.3.8")
        await checker.checkIfDue()
        #expect(calls == 0)
    }
}
