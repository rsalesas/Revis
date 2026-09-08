#!/bin/bash
set -euo pipefail

# Build Revis's release artifacts and publish them as a GitHub release.
#
# Three things go out, and each has a job:
#
#   revis-<version>.dmg   what a person downloads. A disk image because that is what a
#                         Mac download looks like: mount it, drag the app to the alias
#                         beside it, done. Notarized and stapled in its OWN right.
#   revis-<version>.zip   what the in-app updater installs. No disk image to attach,
#                         detach or leak on failure — just expand and verify.
#   appcast.json          what the in-app updater READS, fetched from
#                         releases/latest/download/appcast.json, which GitHub redirects
#                         to the newest release's asset of that name. That is why the
#                         manifest URL in UpdateChecker never has to change.
#
# The app is notarized and stapled BEFORE the DMG is built around it, and the DMG is
# then notarized and stapled itself. Both, deliberately: a ticket on the disk image says
# nothing about the app inside it, and an app without its own ticket can only prove it
# was notarized by asking Apple at first launch — which stalls or fails offline, behind
# a captive portal, or whenever that endpoint is unreachable. Vaelora shipped exactly
# that bug for many releases; see section 5.
#
# Usage: ./scripts/release.sh [options]
#
#   -v, --verbose        Stream xcodebuild output instead of logging it
#   --version X.Y.Z      Release exactly this version (default: bump the patch)
#   --notes "…"          One-line summary for the release body and the update banner
#   --skip-tests         Do not run the suite first (you had better have a reason)
#   --dry-run            Build, sign and verify, then stop. Nothing leaves the Mac:
#                        no notarization, no disk image, no tag, no release.
#   --yes                Do not ask before publishing
#
# Prerequisites (one-time):
#   • "Developer ID Application" certificate in the login keychain (team 42SSLNY3WS)
#   • A stored notarization profile named "notarytool":
#       xcrun notarytool store-credentials notarytool \
#         --apple-id you@example.com --team-id 42SSLNY3WS
#   • `gh` authenticated, and the repository public if the release is meant to be
#     downloadable by anyone.

VERBOSE=false
DRY_RUN=false
SKIP_TESTS=false
ASSUME_YES=false
EXPLICIT_VERSION=""
NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=true ;;
        --dry-run) DRY_RUN=true ;;
        --skip-tests) SKIP_TESTS=true ;;
        --yes) ASSUME_YES=true ;;
        --version) shift; EXPLICIT_VERSION="${1:-}" ;;
        --version=*) EXPLICIT_VERSION="${1#*=}" ;;
        --notes) shift; NOTES="${1:-}" ;;
        --notes=*) NOTES="${1#*=}" ;;
        *) echo "Unknown option: $1"; sed -n '27,33p' "$0"; exit 1 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="Revis"
PROJECT="Revis.xcodeproj"
APP_NAME="Revis.app"
TEAM_ID="42SSLNY3WS"
NOTARY_PROFILE="notarytool"
REPO="rsalesas/Revis"

BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Revis.xcarchive"
EXPORT_DIR="$BUILD_DIR/export-developerid"
mkdir -p "$BUILD_DIR"

run_logged() {
    local logfile="$1"; shift
    rm -f "$logfile"
    if $VERBOSE; then "$@" 2>&1 | tee "$logfile"; else "$@" > "$logfile" 2>&1; fi
}

# --- 0. Preflight ------------------------------------------------------------
# Everything that can be known before a five-minute build is checked here, because
# discovering there is no signing identity after the archive is a five-minute lesson
# in something you could have been told immediately.
echo "=== Preflight ==="

cd "$PROJECT_DIR"
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "❌ Working tree is dirty. A release is a claim about a commit, so commit or"
    echo "   stash first — otherwise the tag names something that was never built."
    git status --short
    exit 1
fi

DID_IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/') || true
[ -n "${DID_IDENTITY:-}" ] || {
    echo "❌ No \"Developer ID Application\" identity in the keychain."
    exit 1
}
echo "  Signing identity: $DID_IDENTITY"

if ! $DRY_RUN; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
        echo "❌ No notarization profile named \"$NOTARY_PROFILE\". Create it once with:"
        echo "     xcrun notarytool store-credentials $NOTARY_PROFILE \\"
        echo "       --apple-id <your-apple-id> --team-id $TEAM_ID"
        exit 1
    }
    command -v gh >/dev/null 2>&1 || { echo "❌ gh is required to publish"; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "❌ gh is not authenticated"; exit 1; }

    # Not fatal. A release on a private repository is a perfectly good way to hand a
    # build to people who already have access — it is just not publishing, and the
    # difference is worth saying out loud before the tag exists.
    VISIBILITY=$(gh repo view "$REPO" --json visibility -q .visibility 2>/dev/null || echo "?")
    if [ "$VISIBILITY" != "PUBLIC" ]; then
        echo "  ⚠️  $REPO is $VISIBILITY — the release will only be downloadable by"
        echo "      people who can already see the repository, and the in-app update"
        echo "      check will fail for everybody else."
    fi
fi
echo "✓ Preflight passed"

# --- 1. Version --------------------------------------------------------------
#   --version X.Y.Z : release exactly this (for a minor or major bump)
#   (default)       : increment the patch component
OLD_VERSION=$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")
if [ -n "$EXPLICIT_VERSION" ]; then
    echo "$EXPLICIT_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || {
        echo "❌ --version must be X.Y.Z (got '$EXPLICIT_VERSION')"; exit 1; }
    VERSION="$EXPLICIT_VERSION"
else
    MAJOR=$(echo "$OLD_VERSION" | cut -d. -f1)
    MINOR=$(echo "$OLD_VERSION" | cut -d. -f2)
    PATCH=$(echo "$OLD_VERSION" | cut -d. -f3)
    VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
fi
TAG="v${VERSION}"
ZIP_PATH="$BUILD_DIR/revis-${VERSION}.zip"
DMG_PATH="$BUILD_DIR/revis-${VERSION}.dmg"
LATEST_DMG_PATH="$BUILD_DIR/revis-latest.dmg"
APPCAST_PATH="$BUILD_DIR/appcast.json"

if ! $DRY_RUN && git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "❌ Tag $TAG already exists. Pass --version with the next one."
    exit 1
fi

# Written before the build, so the version in the bundle is the version being tagged
# rather than the one from last time.
echo "$VERSION" > "$PROJECT_DIR/VERSION"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" "$PROJECT_DIR/project.yml"
if ! git diff --quiet -- VERSION project.yml; then
    if $DRY_RUN; then
        echo "  (dry run) would commit the version bump → $VERSION"
        # Restored on the way OUT, not here. The target's postBuildScript stamps the
        # bundle from the VERSION file, and it runs after the command line is read —
        # so it beats the MARKETING_VERSION passed to xcodebuild. Reverting the file
        # before the build therefore made the dry run produce a differently-versioned
        # app from the one a real run would, which is the one thing a dry run must not
        # do. Caught exactly that way: the run said 0.2.0 and the bundle said 0.1.0.
        trap 'git -C "$PROJECT_DIR" checkout -- VERSION project.yml 2>/dev/null || true' EXIT
    else
        git add VERSION project.yml
        git commit -m "Revis $VERSION" --quiet
        echo "  Committed version bump → $VERSION"
    fi
else
    echo "  Version already $VERSION"
fi

BUILD_NUMBER=$(git rev-list --count HEAD)
echo "=== Building Revis $VERSION (build $BUILD_NUMBER) ==="

# --- 2. Generate, test, clean ------------------------------------------------
echo "→ Generating Xcode project..."
xcodegen generate 2>&1 | if ! $VERBOSE; then cat > /dev/null; else cat; fi

if ! $SKIP_TESTS; then
    echo "→ Running the suite..."
    if ! run_logged "$BUILD_DIR/release-test.log" \
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" test; then
        echo "❌ Tests failed — see $BUILD_DIR/release-test.log"
        exit 1
    fi
    echo "✓ Tests passed"
fi

echo "→ Cleaning..."
DERIVED_DATA=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | grep -m1 BUILD_DIR | awk '{print $3}' | sed 's|/Build/Products||')
if [ -n "$DERIVED_DATA" ] && [ -d "$DERIVED_DATA/Build" ]; then
    rm -rf "$DERIVED_DATA/Build" "$DERIVED_DATA/Index.noindex" 2>/dev/null || {
        echo "❌ Could not clean build artifacts. Quit Xcode first, then retry."; exit 1; }
fi

# --- 3. Archive and export ---------------------------------------------------
echo "→ Archiving..."
if ! run_logged "$BUILD_DIR/archive.log" xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"; then
    echo "❌ Archive failed — see $BUILD_DIR/archive.log"; exit 1
fi
echo "✓ Archive created"

echo "→ Exporting Developer ID app..."
rm -rf "$EXPORT_DIR"; mkdir -p "$EXPORT_DIR"
OPTS="$BUILD_DIR/ExportOptions-DeveloperID.plist"
cat > "$OPTS" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>${TEAM_ID}</string>
<key>signingStyle</key><string>automatic</string>
<key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF
if ! run_logged "$BUILD_DIR/export.log" xcodebuild -exportArchive \
    -allowProvisioningUpdates -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" -exportOptionsPlist "$OPTS"; then
    echo "❌ Export failed — see $BUILD_DIR/export.log"; exit 1
fi
rm -f "$OPTS"
APP="$EXPORT_DIR/$APP_NAME"
[ -d "$APP" ] || { echo "❌ Export produced no app — see $BUILD_DIR/export.log"; exit 1; }
echo "✓ Developer ID app exported"

# --- 3a. Re-sign the helper with a secure timestamp --------------------------
# The app target's post-build script signs the helper with --timestamp=none, which
# keeps every Debug build offline and fast but is not acceptable to the notary
# service. So it is re-signed here, after export and before notarizing. Re-signing a
# nested executable invalidates the app's own signature, so the bundle is re-sealed
# after it.
echo "→ Re-signing the updater helper with a timestamp, re-sealing the app..."
HELPER="$APP/Contents/Helpers/revis-updater"
[ -f "$HELPER" ] || {
    echo "❌ No helper at Contents/Helpers/revis-updater — the app target's bundling"
    echo "   step did not run, and an app that ships without it cannot update itself."
    exit 1
}
codesign --force --sign "$DID_IDENTITY" --options runtime --timestamp \
    --entitlements "$PROJECT_DIR/Updater/revis-updater.DeveloperID.entitlements" "$HELPER"
codesign --force --sign "$DID_IDENTITY" --options runtime --timestamp \
    --entitlements "$PROJECT_DIR/Revis/Revis.DeveloperID.entitlements" "$APP"
echo "✓ Helper re-signed, app re-sealed"

# --- 3b. The claims this app makes, checked on the artifact ------------------
# Checked on the exported bundle rather than on the entitlements file, because what
# ships is what was signed, and the two have disagreed before: a config that names the
# wrong entitlements file builds and signs perfectly happily.
#
# These assertions were the opposite way round until 0.3.0. Revis shipped sandboxed
# with no network entitlement at all, and the release refused to go out otherwise. The
# in-app updater is what changed it: a sandboxed app cannot replace itself in
# /Applications, so an in-place update could only ever be refused at its last step.
# What replaced the sandbox is written up in Revis.DeveloperID.entitlements.
echo "→ Verifying entitlements on the signed bundle..."
ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)
if echo "$ENTS" | grep -q "com.apple.security.app-sandbox"; then
    echo "❌ The signed app IS sandboxed. It cannot replace itself in /Applications from"
    echo "   inside a container, so every in-app update would fail at the last step."
    exit 1
fi
# Load-bearing, and silent when absent: without it the update check simply never finds
# anything, which looks exactly like being up to date.
echo "$ENTS" | grep -q "com.apple.security.network.client" || {
    echo "❌ The signed app has no network entitlement, so it can neither check for"
    echo "   updates nor download one — and would report itself up to date forever."
    exit 1
}
# And nothing else. The README makes this claim to the reader, so it is checked rather
# than trusted: an entitlement acquired by accident — a capability ticked in Xcode, a
# stray key in the plist — would otherwise ship without anyone reading the diff.
UNEXPECTED=$(echo "$ENTS" | sed -n 's/.*<key>\(.*\)<\/key>.*/\1/p' \
    | grep -v '^com\.apple\.security\.network\.client$' \
    | grep -v '^com\.apple\.application-identifier$' \
    | grep -v '^com\.apple\.developer\.team-identifier$' || true)
if [ -n "$UNEXPECTED" ]; then
    echo "❌ The signed app carries entitlements beyond the network client:"
    echo "$UNEXPECTED" | sed 's/^/     /'
    echo "   Revis renders untrusted HTML. Every one of these has to be argued for in"
    echo "   Revis.DeveloperID.entitlements before it ships."
    exit 1
fi
HELPER_ENTS=$(codesign -d --entitlements - --xml "$HELPER" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)
if echo "$HELPER_ENTS" | grep -q "com.apple.security.app-sandbox"; then
    echo "❌ The updater helper is sandboxed and could not perform the swap."
    exit 1
fi
codesign --verify --deep --strict "$APP" || { echo "❌ Signature invalid"; exit 1; }
echo "✓ Un-sandboxed, network client only, helper present, signature valid"

if $DRY_RUN; then
    echo ""
    echo "=== Dry run complete — nothing left this Mac ==="
    echo "  Would notarize and staple the app, then build and notarize:"
    echo "    $DMG_PATH"
    echo "    $ZIP_PATH"
    echo "    $APPCAST_PATH"
    echo "  Would tag:        $TAG"
    echo "  Would publish to: $REPO"
    echo "  Built app is at:  $APP"
    exit 0
fi

# --- 4. Notarize and staple the APP, before it goes into anything ------------
# The order is the whole point. Notarize the app first, staple it, and build the disk
# image around a copy that already carries its ticket. A stapled app proves it was
# notarized without asking Apple anything, so it opens offline, behind a captive
# portal, or on a machine that cannot reach the notary service.
echo "→ Notarizing the app (this can take a few minutes)..."
NOTARIZE_ZIP="$BUILD_DIR/notarize-app.zip"
rm -f "$NOTARIZE_ZIP"
# ditto, not zip: it preserves symlinks, resource forks and extended attributes, so
# the copy that comes out the other side still satisfies its own code signature.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$NOTARIZE_ZIP"

echo "→ Stapling the app..."
# Fatal: everything downstream is built from this bundle, so an unstapled app here is
# the bug this ordering exists to prevent.
xcrun stapler staple "$APP" || {
    echo "❌ Could not staple the app — refusing to build a disk image around an"
    echo "   unstapled copy"; exit 1; }
xcrun stapler validate "$APP" >/dev/null 2>&1 || {
    echo "❌ The app has no stapled ticket after stapling"; exit 1; }
spctl -a -vv -t install "$APP" 2>&1 | grep -q "accepted" || {
    echo "❌ Gatekeeper rejects the app"; exit 1; }
echo "✓ Notarized, stapled, accepted by Gatekeeper"

# --- 5. The disk image -------------------------------------------------------
echo "→ Creating the disk image..."
DMG_LOG="$BUILD_DIR/dmg.log"
if ! run_logged "$DMG_LOG" "$SCRIPT_DIR/create-dmg.sh" "$APP"; then
    echo "❌ DMG creation failed — see $DMG_LOG"; exit 1
fi
[ -f "$DMG_PATH" ] || { echo "❌ DMG creation failed — see $DMG_LOG"; exit 1; }

# The disk image is a separate file and needs its own ticket, or macOS refuses to open
# the download itself — regardless of what the app inside carries.
echo "→ Notarizing the disk image (this can take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
echo "→ Stapling the disk image..."
xcrun stapler staple "$DMG_PATH"
cp "$DMG_PATH" "$LATEST_DMG_PATH"   # re-copy latest WITH the stapled ticket

# On the artifact, not on the sequence above. The failure this guards was invisible in
# Vaelora for many releases: every step reported success and the DMG validated fine,
# because the DMG *was* stapled. What was missing could only be seen by looking inside.
echo "→ Verifying the app inside the disk image is stapled..."
VERIFY_MOUNT=$(hdiutil attach "$DMG_PATH" -nobrowse -readonly | grep -o '/Volumes/.*' | tail -1)
[ -n "$VERIFY_MOUNT" ] || { echo "❌ Could not mount $DMG_PATH to verify it"; exit 1; }
if xcrun stapler validate "$VERIFY_MOUNT/$APP_NAME" >/dev/null 2>&1; then
    STAPLED_INSIDE=true
else
    STAPLED_INSIDE=false
fi
hdiutil detach "$VERIFY_MOUNT" -quiet || true
$STAPLED_INSIDE || { echo "❌ The app inside the disk image has no stapled ticket"; exit 1; }
echo "✓ Disk image notarized, stapled, and stapled inside"

# --- 6. The updater's archive ------------------------------------------------
echo "→ Building the updater ZIP..."
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"
ZIP_SHA=$(shasum -a 256 "$ZIP_PATH" | cut -d' ' -f1)
ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
echo "  $ZIP_SHA  $(basename "$ZIP_PATH")"

# The exported app has done its job. Left in build/, Launch Services registers it and
# Finder's "Open With" grows a second Revis beside the installed one — which then goes
# stale the moment the versions diverge.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$APP" 2>/dev/null || true
rm -rf "$EXPORT_DIR"

# --- 7. The manifest ---------------------------------------------------------
# What the in-app update check reads (see UpdateChecker). Every URL in it is the
# IMMUTABLE per-tag one, never releases/latest/, so a download that starts now cannot
# be swapped underneath by the next release — the checksum the client is holding would
# then be for different bytes.
#
# The OS floor is read from the project rather than repeated here: the updater refuses
# an update whose minimum is above the system it is running on, so a stale number would
# offer people a build that cannot launch.
MIN_MACOS=$(awk '/deploymentTarget:/{f=1;next} f&&/macOS:/{v=$2; gsub(/"/,"",v); print v; exit}' \
    "$PROJECT_DIR/project.yml")
[ -n "$MIN_MACOS" ] || { echo "❌ Could not read the macOS deployment target from project.yml"; exit 1; }

DOWNLOAD_BASE="https://github.com/${REPO}/releases/download/${TAG}"
python3 - "$APPCAST_PATH" "$VERSION" "$DOWNLOAD_BASE" "$NOTES" "$ZIP_SHA" "$ZIP_SIZE" \
    "$MIN_MACOS" <<'PY'
import json, sys
path, version, base, notes, zip_sha, zip_size, min_macos = sys.argv[1:8]
manifest = {
    "version": version,
    "url": f"{base}/revis-{version}.dmg",
    "minimumSystemVersion": min_macos,
}
if notes:
    manifest["notes"] = notes
# What the in-app updater installs. Both fields or neither: the checksum is the only
# thing standing between "we fetched bytes" and "we ran them", so an archive URL
# without one must never be published.
if zip_sha and zip_size:
    manifest["archive"] = f"{base}/revis-{version}.zip"
    manifest["sha256"] = zip_sha
    manifest["archiveSize"] = int(zip_size)
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
echo "✓ Manifest written"

# --- 8. Publish --------------------------------------------------------------
echo ""
echo "Ready to publish:"
echo "  Version: $VERSION (build $BUILD_NUMBER)"
echo "  Tag:     $TAG  → $(git rev-parse --short HEAD)"
echo "  Assets:  $(basename "$DMG_PATH")  ($(du -h "$DMG_PATH" | cut -f1))"
echo "           $(basename "$LATEST_DMG_PATH")  (the stable download link)"
echo "           $(basename "$ZIP_PATH")  ($(du -h "$ZIP_PATH" | cut -f1))"
echo "           $(basename "$APPCAST_PATH")"
echo "  Repo:    $REPO ($VISIBILITY)"
if ! $ASSUME_YES; then
    printf "Publish? [y/N] "
    read -r REPLY
    case "$REPLY" in
        y|Y|yes|YES) ;;
        *) echo "Stopped. The artifacts are in $BUILD_DIR if you want them by hand."; exit 0 ;;
    esac
fi

echo "→ Tagging and pushing..."
git tag -a "$TAG" -m "Revis $VERSION"
# Explicitly to main, not `git push origin HEAD`. This is normally run from a
# worktree on a topic branch, and pushing HEAD there publishes a branch nobody
# asked for — while the version-bump commit the tag names still never reaches main.
git push origin HEAD:main
git push origin "$TAG"

BODY_FILE="$BUILD_DIR/release-notes.md"
{
    [ -n "$NOTES" ] && { echo "$NOTES"; echo ""; }
    cat <<'EOF'
### Installing

Open `revis-<version>.dmg` and drag `Revis.app` onto the Applications folder beside it.

Both the disk image and the app inside it are signed with a Developer ID certificate,
notarized by Apple, and carry their own stapled ticket — so each opens normally, with no
right-click dance, and without needing to reach Apple at first launch.

Install it into `/Applications` rather than running it from the disk image: from there
Revis can update itself, and it will say so if you try it the other way.

### Updating

Revis checks once a day for a newer build and offers it on a bar across the top of the
window; *Revis ▸ Check for Updates…* asks immediately. An update is downloaded, checked
against the SHA-256 published here, checked to be signed by the same Developer ID, and
only then installed in place — the app replaces itself and relaunches. The check can be
turned off in Settings; nothing about the document you are reviewing is ever sent
anywhere.

`revis-<version>.zip` is what that updater installs, and `appcast.json` is what it reads.
Neither needs downloading by hand.

### What it is

Revis reviews HTML and Markdown documents that came out of a language model and turns
the marks you make on them into instructions the model can act on. Nothing leaves the
app as a coordinate: every annotation carries the words it is about.

The document is treated as untrusted. Its markup and stylesheet are scrubbed before a
byte reaches WebKit, and the page it lands in is denied script, network and storage at
the browser's own level.

Revis is source-available, and free for any noncommercial use. See `LICENSE`.
EOF
} > "$BODY_FILE"

echo "→ Creating the GitHub release..."
# The manifest LAST would be safer if these were separate uploads, but `gh release
# create` publishes the release and its assets as one act — there is no window in which
# appcast.json is readable and the bytes it names are not.
gh release create "$TAG" \
    "$DMG_PATH" "$LATEST_DMG_PATH" "$ZIP_PATH" "$APPCAST_PATH" \
    --repo "$REPO" \
    --title "Revis $VERSION" \
    --notes-file "$BODY_FILE"

echo ""
echo "=== Released ==="
echo "  $(gh release view "$TAG" --repo "$REPO" --json url -q .url)"
echo "  Download:  https://github.com/${REPO}/releases/latest/download/revis-latest.dmg"
echo "  Manifest:  https://github.com/${REPO}/releases/latest/download/appcast.json"
