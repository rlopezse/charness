#!/bin/bash
# Builds "Charness.app": a native Swift app (Swift package in mac/). The Charness server runs inside the app
# (no Node at run time), the UI is shown in ONE window of its own (WKWebView, no browser involved), and
# quitting stops it. Claude Code itself is the binary `npm install` puts in node_modules (or HARNESS_CLAUDE_BIN).
# Run this on your Mac:
#     ./scripts/make-mac-app.sh                  # installs to ~/Applications
#     ./scripts/make-mac-app.sh /some/folder     # or somewhere else
# Needs the Xcode Command Line Tools for Swift (xcode-select --install); full Xcode is not required.
# The app points at THIS folder, so keep the folder where it is (re-run this script if you move it).
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$HERE/mac"
BUNDLE_ID="local.charness.app"

xml() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }

info_plist() {
  local version
  version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$HERE/package.json" | head -n 1)"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Charness</string>
  <key>CFBundleDisplayName</key><string>Charness</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Charness</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(xml "${version:-0.0.0}")</string>
  <key>CFBundleVersion</key><string>$(xml "${version:-0.0.0}")</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>CharnessRoot</key><string>$(xml "$HERE")</string>
</dict>
</plist>
PLIST
}

if [ "${1:-}" = "--print-plist" ]; then info_plist; exit 0; fi

if [ "$(uname)" != Darwin ]; then echo "This builds a macOS app, so run it on your Mac." >&2; exit 1; fi
if ! xcrun --sdk macosx --find swift >/dev/null 2>&1; then
  echo "Swift not found. Install the Xcode Command Line Tools first:  xcode-select --install" >&2; exit 1
fi
if ! ls "$HERE"/node_modules/@anthropic-ai/claude-agent-sdk-darwin-*/claude >/dev/null 2>&1; then
  echo "Run 'npm install' in $HERE first: it downloads the Claude Code binary the app runs." >&2; exit 1
fi

DEST="${1:-$HOME/Applications}"
APP="$DEST/Charness.app"
if pgrep -f "$APP/Contents/MacOS/" >/dev/null 2>&1; then
  echo "Charness is running. Quit it (Cmd-Q) and run this again." >&2; exit 1
fi

TMP="$(mktemp -d -t charness-app)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/Charness.app/Contents"
mkdir -p "$OUT/MacOS"

echo "Building the Swift package in mac/ (release)…"
xcrun --sdk macosx swift build -c release --package-path "$PKG" --product Charness
cp "$(xcrun --sdk macosx swift build -c release --package-path "$PKG" --show-bin-path)/Charness" "$OUT/MacOS/Charness"
info_plist > "$OUT/Info.plist"
printf 'APPL????' > "$OUT/PkgInfo"
# Ad-hoc signature so macOS treats the bundle as one app (window position, Keychain prompts, etc.).
codesign --force --sign - "$TMP/Charness.app" >/dev/null 2>&1 || echo "Note: ad-hoc codesign failed; the app should still run." >&2

mkdir -p "$DEST"
rm -rf "$APP"
mv "$TMP/Charness.app" "$APP"
echo "Built: $APP"
echo "Open it from Finder/Spotlight. First launch may ask permission to access folders; that's macOS."
