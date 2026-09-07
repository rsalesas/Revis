#!/bin/bash
set -euo pipefail

# Quick Debug build of Revis (no signing needed) to verify it compiles end to end.
#
# Usage: ./scripts/build.sh [-v|--verbose] [-r|--run]
#
#   -v, --verbose   Stream xcodebuild output instead of logging it
#   -r, --run       Relaunch the app when the build succeeds

VERBOSE=false
RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=true ;;
        -r|--run) RUN=true ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [-v|--verbose] [-r|--run]"; exit 1 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_LOG="$PROJECT_DIR/build/debug-build.log"
mkdir -p "$PROJECT_DIR/build"
cd "$PROJECT_DIR"

echo "→ Generating Xcode project..."
xcodegen generate 2>&1 | if ! $VERBOSE; then cat > /dev/null; else cat; fi

echo "→ Building (Debug)..."
rm -f "$BUILD_LOG"
BUILD_CMD=(xcodebuild -project Revis.xcodeproj -scheme Revis -configuration Debug build)
if $VERBOSE; then
    "${BUILD_CMD[@]}" 2>&1 | tee "$BUILD_LOG"
else
    if ! "${BUILD_CMD[@]}" > "$BUILD_LOG" 2>&1; then
        echo "❌ Build failed"
        grep -E "error:" "$BUILD_LOG" | head -30
        echo "See full log: $BUILD_LOG"
        exit 1
    fi
fi

echo "✓ Build succeeded"

# Where Xcode actually put it — the DerivedData path is hashed per checkout, so ask
# rather than guess.
APP_DIR=$(xcodebuild -project Revis.xcodeproj -scheme Revis -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
APP="$APP_DIR/Revis.app"
echo "  $APP"

if $RUN; then
    # Quit any copy still running, or `open` just brings the OLD binary forward and you
    # review the previous build without realising it.
    if pgrep -f "Revis.app/Contents/MacOS/Revis" > /dev/null; then
        echo "→ Quitting the running copy..."
        osascript -e 'tell application "Revis" to quit' 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -f "Revis.app/Contents/MacOS/Revis" > /dev/null || break
            sleep 0.3
        done
        pkill -f "Revis.app/Contents/MacOS/Revis" 2>/dev/null || true
    fi
    echo "→ Launching..."
    open "$APP"
fi
