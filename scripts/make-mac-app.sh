#!/bin/bash
# Builds "Charness.app": a self-contained native Swift app. The Charness server runs inside it (no Node, no
# browser) and it carries its own copy of Claude Code (Contents/MacOS/claude), so once built the app doesn't need
# this folder: move it, copy it to another Mac (same chip family), delete the repo, it keeps working.
# Run this on your Mac:
#     ./scripts/make-mac-app.sh                  # installs to ~/Applications
#     ./scripts/make-mac-app.sh /some/folder     # or somewhere else
# Needs the Xcode Command Line Tools for Swift (xcode-select --install); full Xcode is not required.
#
# Claude Code: the exact build the app has always run (Claude Code 2.1.331, from the npm package
# @anthropic-ai/claude-agent-sdk-darwin-<arch>@0.3.331), downloaded once from the npm registry with curl and
# refused unless its SHA-512 matches the one pinned below (the same "integrity" npm itself checks). Cached in
# mac/.build/claude-code/. HARNESS_CLAUDE_BIN=/path/to/claude bundles that binary instead (not checked).
# To move to a newer Claude Code: see "Updating Claude Code" in README.md.
set -eu

CLAUDE_CODE_PACKAGE_VERSION="0.3.331"
CLAUDE_CODE_SHA512_ARM64="sha512-PQrn7YTiSV5Bg+ueF2hNvswc+wI7YKC2c32XNedvs6vfMCUUnIlq93VEbZiRY23b+JIVkEm8gb1VhkJTjsYISQ=="
CLAUDE_CODE_SHA512_X64="sha512-dc3iB+CY3jDpKpDpmvYc4V+UKSkudY29iJ62p0s5TK3h+b7Wqa2Hv0bPow0LUs4ZzDUXxEtCEHzk9X29VfLovw=="

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$HERE/mac"
BUNDLE_ID="local.charness.app"
APP_VERSION="1.0.0"

xml() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }

info_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Charness</string>
  <key>CFBundleDisplayName</key><string>Charness</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Charness</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>CharnessClaudeCode</key><string>$(xml "$1")</string>
</dict>
</plist>
PLIST
}

if [ "${1:-}" = "--print-plist" ]; then info_plist "npm @anthropic-ai/claude-agent-sdk-darwin-arm64@$CLAUDE_CODE_PACKAGE_VERSION"; exit 0; fi

if [ "$(uname)" != Darwin ]; then echo "This builds a macOS app, so run it on your Mac." >&2; exit 1; fi
if ! xcrun --sdk macosx --find swift >/dev/null 2>&1; then
  echo "Swift not found. Install the Xcode Command Line Tools first:  xcode-select --install" >&2; exit 1
fi

DEST="${1:-$HOME/Applications}"
APP="$DEST/Charness.app"
if pgrep -f "$APP/Contents/MacOS/Charness" >/dev/null 2>&1; then
  echo "Charness is running. Quit it (Cmd-Q) and run this again." >&2; exit 1
fi

TMP="$(mktemp -d -t charness-app)"
trap 'rm -rf "$TMP"' EXIT

# --- Claude Code ------------------------------------------------------------------------------------------
case "$(uname -m)" in
  arm64) ARCH=arm64; WANT="$CLAUDE_CODE_SHA512_ARM64" ;;
  x86_64) ARCH=x64; WANT="$CLAUDE_CODE_SHA512_X64" ;;
  *) echo "Unsupported Mac: $(uname -m)" >&2; exit 1 ;;
esac
CACHE="$PKG/.build/claude-code"
if [ -n "${HARNESS_CLAUDE_BIN:-}" ]; then
  CLAUDE_BIN="$HARNESS_CLAUDE_BIN"; CLAUDE_LICENSE=""; CLAUDE_FROM="$HARNESS_CLAUDE_BIN (HARNESS_CLAUDE_BIN, not checked)"
  [ -x "$CLAUDE_BIN" ] || { echo "HARNESS_CLAUDE_BIN is not an executable: $CLAUDE_BIN" >&2; exit 1; }
else
  NAME="claude-agent-sdk-darwin-$ARCH"
  CLAUDE_FROM="npm @anthropic-ai/$NAME@$CLAUDE_CODE_PACKAGE_VERSION ($WANT)"
  CLAUDE_BIN="$CACHE/claude"; CLAUDE_LICENSE="$CACHE/LICENSE.md"
  if [ ! -x "$CLAUDE_BIN" ] || [ "$(cat "$CACHE/integrity" 2>/dev/null)" != "$WANT" ]; then
    URL="https://registry.npmjs.org/@anthropic-ai/$NAME/-/$NAME-$CLAUDE_CODE_PACKAGE_VERSION.tgz"
    echo "Downloading Claude Code ($NAME $CLAUDE_CODE_PACKAGE_VERSION, about 170 MB)…"
    curl -fL --proto '=https' --tlsv1.2 --retry 2 -o "$TMP/claude-code.tgz" "$URL"
    GOT="sha512-$(openssl dgst -sha512 -binary "$TMP/claude-code.tgz" | base64 | tr -d '\n')"
    if [ "$GOT" != "$WANT" ]; then
      echo "Claude Code download does not match the pinned checksum. Refusing to use it." >&2
      echo "  expected $WANT" >&2
      echo "  got      $GOT" >&2
      exit 1
    fi
    mkdir -p "$TMP/claude-code"
    tar -xzf "$TMP/claude-code.tgz" -C "$TMP/claude-code" package/claude package/LICENSE.md
    rm -rf "$CACHE"; mkdir -p "$CACHE"
    mv "$TMP/claude-code/package/claude" "$CLAUDE_BIN"
    mv "$TMP/claude-code/package/LICENSE.md" "$CLAUDE_LICENSE"
    chmod 755 "$CLAUDE_BIN"
    printf '%s' "$WANT" > "$CACHE/integrity"
    echo "Claude Code checksum OK."
  fi
fi

# --- the app ----------------------------------------------------------------------------------------------
OUT="$TMP/Charness.app/Contents"
mkdir -p "$OUT/MacOS" "$OUT/Resources"

echo "Building the Swift package in mac/ (release)…"
xcrun --sdk macosx swift build -c release --package-path "$PKG" --product Charness
cp "$(xcrun --sdk macosx swift build -c release --package-path "$PKG" --show-bin-path)/Charness" "$OUT/MacOS/Charness"
cp "$CLAUDE_BIN" "$OUT/MacOS/claude"
chmod 755 "$OUT/MacOS/claude"
# Anthropic signs Claude Code; a binary from HARNESS_CLAUDE_BIN might not be, and the app's signature needs it signed
codesign -v "$OUT/MacOS/claude" >/dev/null 2>&1 || codesign --force --sign - "$OUT/MacOS/claude" >/dev/null 2>&1 || true
[ -n "$CLAUDE_LICENSE" ] && cp "$CLAUDE_LICENSE" "$OUT/Resources/ClaudeCode-LICENSE.md"

# the icon: every size macOS wants, made from the one 1024 px picture
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$PKG/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$PKG/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/Resources/AppIcon.icns"

info_plist "$CLAUDE_FROM" > "$OUT/Info.plist"
printf 'APPL????' > "$OUT/PkgInfo"
# Ad-hoc signature so macOS treats the bundle as one app (window position, Keychain prompts, etc.). Claude Code
# keeps Anthropic's own signature (it is signed already; --deep is not used).
codesign --force --sign - "$TMP/Charness.app" >/dev/null 2>&1 || echo "Note: ad-hoc codesign failed; the app should still run." >&2

mkdir -p "$DEST"
rm -rf "$APP"
mv "$TMP/Charness.app" "$APP"
echo "Built: $APP"
echo "Claude Code inside: $CLAUDE_FROM"
echo "Open it from Finder/Spotlight. First launch may ask permission to access folders; that's macOS."
