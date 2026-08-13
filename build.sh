#!/bin/bash
# Build and install the personal Amethyst fork.
#
# Signed with the "Ivo Market Dev" identity so the Accessibility grant in
# System Settings survives rebuilds -- an ad-hoc signature changes on every
# build and macOS revokes the grant, which for a window manager means it
# silently stops managing anything.
#
# NO_DEPLOY=1 ./build.sh   builds without touching /Applications
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Amethyst"
IDENTITY="Ivo Market Dev"
DERIVED="${TMPDIR:-/tmp}/AmethystFork-build"
BUILT="$DERIVED/Build/Products/Release/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

echo "==> Building $APP_NAME (Release)"
set -o pipefail
xcodebuild \
    -workspace "$APP_NAME.xcworkspace" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    build 2>&1 | grep -E "error:|warning: .*(deprecated|unused)|BUILD" || true
build_status=${PIPESTATUS[0]}
set +o pipefail

if [ "$build_status" -ne 0 ]; then
    echo "!! Build failed (xcodebuild exit $build_status); refusing to install" >&2
    exit "$build_status"
fi

if [ ! -d "$BUILT" ]; then
    echo "!! Build produced no app at $BUILT" >&2
    exit 1
fi

echo "==> Verifying signature"
codesign --verify --deep --strict "$BUILT"
codesign -dv "$BUILT" 2>&1 | grep -E "Authority|Identifier"

if [ "${NO_DEPLOY:-0}" = "1" ]; then
    echo "==> NO_DEPLOY set; built app left at $BUILT"
    exit 0
fi

if pgrep -x "$APP_NAME" >/dev/null; then
    echo "==> Quitting running $APP_NAME"
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || pkill -x "$APP_NAME" || true
    sleep 1
fi

echo "==> Installing to $DEST"
# Overwrite in place with ditto rather than rm -rf + cp. Deleting and recreating the bundle
# churns the record TCC keys the Accessibility grant against; doing it repeatedly gets the grant
# revoked outright, and a window manager without Accessibility silently manages nothing.
# For the same reason: don't loop this script. Rebuild, then test the running app.
ditto "$BUILT" "$DEST"

echo "==> Done. Launch with: open -a $APP_NAME"
