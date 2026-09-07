#!/bin/bash
set -euo pipefail

# Build Revis's release artifact — a notarized, stapled app in a ZIP — and publish it
# as a GitHub release.
#
# Vaelora next door ships a DMG to Cloudflare R2 because it has an in-app updater to
# feed. Revis has neither, and a ZIP is the artifact GitHub Releases is built around,
# so there is no disk image here: no background art to maintain, no second
# notarization, and no mounting the image afterwards to check what is inside it.
#
# What matters for a download is that the APP carries its own stapled ticket. A
# stapled app proves it was notarized without asking Apple anything, so it opens
# offline, behind a captive portal, or on a machine that cannot reach the notary
# service. The ZIP is only a container; it needs no ticket of its own.
#
# Usage: ./scripts/release.sh [options]
#
#   -v, --verbose        Stream xcodebuild output instead of logging it
#   --version X.Y.Z      Release exactly this version (default: bump the patch)
#   --notes "…"          One-line summary for the release body
#   --skip-tests         Do not run the suite first (you had better have a reason)
#   --dry-run            Build, sign and verify, then stop. Nothing leaves the Mac:
#                        no notarization, no tag, no release.
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
        *) echo "Unknown option: $1"; sed -n '17,27p' "$0"; exit 1 ;;
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
        echo "      people who can already see the repository."
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

# --- 3a. The two claims this app makes, checked on the artifact ---------------
# Vaelora's release script asserts the opposite of the first one — it must NOT be
# sandboxed, because the sandbox stopped it replacing itself in /Applications. Revis
# has no updater and no reason to leave the sandbox, and it is reading untrusted
# HTML, so here the sandbox is the point.
#
# Checked on the exported bundle rather than on the entitlements file, because what
# ships is what was signed, and the two have disagreed before: a config that names
# the wrong entitlements file builds and signs perfectly happily.
echo "→ Verifying entitlements on the signed bundle..."
ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)
echo "$ENTS" | grep -q "com.apple.security.app-sandbox" || {
    echo "❌ The signed app is NOT sandboxed. Revis renders untrusted HTML; it ships"
    echo "   sandboxed or it does not ship."
    exit 1
}
if echo "$ENTS" | grep -q "com.apple.security.network"; then
    echo "❌ The signed app carries a network entitlement. Deliberately absent: the"
    echo "   document under review is untrusted, and the app it renders in should not"
    echo "   be able to reach the network whatever the page asks for."
    exit 1
fi
codesign --verify --deep --strict "$APP" || { echo "❌ Signature invalid"; exit 1; }
echo "✓ Sandboxed, no network entitlement, signature valid"

if $DRY_RUN; then
    echo ""
    echo "=== Dry run complete — nothing left this Mac ==="
    echo "  Would notarize, staple, zip to: $ZIP_PATH"
    echo "  Would tag:                      $TAG"
    echo "  Would publish to:               $REPO"
    echo "  Built app is at:                $APP"
    exit 0
fi

# --- 4. Notarize, staple, prove ----------------------------------------------
echo "→ Notarizing (this can take a few minutes)..."
NOTARIZE_ZIP="$BUILD_DIR/notarize.zip"
rm -f "$NOTARIZE_ZIP"
# ditto, not zip: it preserves symlinks, resource forks and extended attributes, so
# the copy that comes out the other side still satisfies its own code signature.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$NOTARIZE_ZIP"

echo "→ Stapling..."
xcrun stapler staple "$APP" || { echo "❌ Could not staple the app"; exit 1; }

# On the artifact, not on the sequence above. Every step reporting success and the
# ticket still being absent is exactly the failure this guards, and it is invisible
# from the outside — the app runs fine on the Mac that built it either way.
xcrun stapler validate "$APP" >/dev/null 2>&1 || {
    echo "❌ The app has no stapled ticket after stapling"; exit 1; }
spctl -a -vv -t install "$APP" 2>&1 | grep -q "accepted" || {
    echo "❌ Gatekeeper rejects the app"; exit 1; }
echo "✓ Notarized, stapled, accepted by Gatekeeper"

echo "→ Building the release ZIP..."
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"
echo "  $(shasum -a 256 "$ZIP_PATH" | cut -d' ' -f1)"

# The exported app has done its job. Left in build/, Launch Services registers it and
# Finder's "Open With" grows a second Revis beside the installed one — which then
# goes stale the moment the versions diverge.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$APP" 2>/dev/null || true
rm -rf "$EXPORT_DIR"

# --- 5. Publish --------------------------------------------------------------
echo ""
echo "Ready to publish:"
echo "  Version: $VERSION (build $BUILD_NUMBER)"
echo "  Tag:     $TAG  → $(git rev-parse --short HEAD)"
echo "  Asset:   $(basename "$ZIP_PATH")  ($(du -h "$ZIP_PATH" | cut -f1))"
echo "  Repo:    $REPO ($VISIBILITY)"
if ! $ASSUME_YES; then
    printf "Publish? [y/N] "
    read -r REPLY
    case "$REPLY" in
        y|Y|yes|YES) ;;
        *) echo "Stopped. The ZIP is at $ZIP_PATH if you want it by hand."; exit 0 ;;
    esac
fi

echo "→ Tagging and pushing..."
git tag -a "$TAG" -m "Revis $VERSION"
git push origin HEAD
git push origin "$TAG"

BODY_FILE="$BUILD_DIR/release-notes.md"
{
    [ -n "$NOTES" ] && { echo "$NOTES"; echo ""; }
    cat <<'EOF'
### Installing

Download the ZIP, unpack it, and drag `Revis.app` to `/Applications`.

The app is signed with a Developer ID certificate and notarized by Apple, and the
ticket is stapled to the bundle — so it opens normally, with no right-click dance,
and without needing to reach Apple at first launch.

### What it is

Revis reviews HTML and Markdown documents that came out of a language model and turns
the marks you make on them into instructions the model can act on. Nothing leaves the
app as a coordinate: every annotation carries the words it is about.

The document is treated as untrusted. Its markup and stylesheet are scrubbed before a
byte reaches WebKit, the page it lands in is denied script, network and storage at the
browser's own level, and the app itself ships sandboxed with no network entitlement.

Revis is source-available, and free for any noncommercial use. See `LICENSE`.
EOF
} > "$BODY_FILE"

echo "→ Creating the GitHub release..."
gh release create "$TAG" "$ZIP_PATH" \
    --repo "$REPO" \
    --title "Revis $VERSION" \
    --notes-file "$BODY_FILE"

echo ""
echo "=== Released ==="
echo "  $(gh release view "$TAG" --repo "$REPO" --json url -q .url)"
