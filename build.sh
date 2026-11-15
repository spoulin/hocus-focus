#!/bin/bash
# Build HocusFocus.app, sign it and install it in ~/Applications.
# A stable signing identity keeps the Accessibility permission across rebuilds.
#
# VERSION=1.2.0 ./build.sh  sets the version shown in the app; without it, the latest git tag
#                           (v1.2.0 gives 1.2.0), else the version in Info.plist.
# UNIVERSAL=1               builds for both Apple silicon and Intel Macs, as releases do.
# NO_INSTALL=1              builds build/HocusFocus.app only.
# SIGN_KEYCHAIN=<path>      the keychain holding SIGN_ID, when it isn't the login one.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# Use SIGN_ID, else the first "Apple Development" identity, else an ad-hoc signature
# (ad-hoc means granting Accessibility again after each rebuild).
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}"
SIGN_ID="${SIGN_ID:--}"
APP="build/HocusFocus.app"
DEST="$HOME/Applications/HocusFocus.app"

if [[ -n "${UNIVERSAL:-}" ]]; then
	# One build per architecture, joined with lipo: a Swift 6 package can fail on GitHub's Xcode
	# with `swift build --arch arm64 --arch x86_64` (seen with Talk to me Bro).
	parts=()
	for arch in arm64 x86_64; do
		swift build -c release --product HocusFocusApp --arch "$arch"
		parts+=("$(swift build -c release --arch "$arch" --show-bin-path)/HocusFocusApp")
	done
	mkdir -p build
	BINARY="build/HocusFocusApp-universal"
	lipo -create -output "$BINARY" "${parts[@]}"
else
	swift build -c release --product HocusFocusApp
	BINARY="$(swift build -c release --show-bin-path)/HocusFocusApp"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/HocusFocus"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign "$SIGN_ID" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"
echo "Built $APP $VERSION ($BUILD)"
[[ -n "${NO_INSTALL:-}" ]] && exit 0

pkill -x HocusFocus || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
