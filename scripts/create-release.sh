#!/bin/bash
# Create a release: notarize, create DMG, sign for Sparkle, upload to GitHub, update website
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="$PROJECT_DIR/releases"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"

# GitHub repository (owner/repo format)
GITHUB_REPO="BogdanTaranenko/vibe-notch"

# The appcast is served straight out of this repo on the default branch —
# there is no separate website project. Must match SUFeedURL in Info.plist.
APPCAST_BRANCH="main"
REPO_APPCAST="$PROJECT_DIR/appcast.xml"

APP_PATH="$EXPORT_PATH/Vibe Notch.app"
APP_NAME="VibeNotch"
KEYCHAIN_PROFILE="ClaudeIsland"

echo "=== Creating Release ==="
echo ""

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    echo "Run ./scripts/build.sh first"
    exit 1
fi

# Get version from app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo "Version: $VERSION (build $BUILD)"
echo ""

# The exported app must carry the same Sparkle feed and key as the current
# source tree. Exporting a stale archive silently ships the wrong key, which
# makes generate_appcast emit an UNSIGNED appcast that every client rejects.
SRC_PLIST="$PROJECT_DIR/ClaudeIsland/Info.plist"
APP_PLIST="$APP_PATH/Contents/Info.plist"
for k in SUPublicEDKey SUFeedURL; do
    want=$(/usr/libexec/PlistBuddy -c "Print :$k" "$SRC_PLIST" 2>/dev/null || echo "")
    got=$(/usr/libexec/PlistBuddy -c "Print :$k" "$APP_PLIST" 2>/dev/null || echo "")
    if [ "$want" != "$got" ]; then
        echo "ERROR: $k in the built app does not match the source tree."
        echo "  source: $want"
        echo "  app:    $got"
        echo "The archive is stale — re-run ./scripts/build.sh."
        exit 1
    fi
done
echo "Sparkle feed and key match the source tree."
echo ""

mkdir -p "$RELEASE_DIR"

# ============================================
# Step 1: Notarize the app
# ============================================
echo "=== Step 1: Notarizing ==="

# Check if keychain profile exists
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
    echo ""
    echo "No keychain profile found. Set up credentials with:"
    echo ""
    echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
    echo "      --apple-id \"your@email.com\" \\"
    echo "      --team-id \"36U788QB6S\" \\"
    echo "      --password \"xxxx-xxxx-xxxx-xxxx\""
    echo ""
    echo "Create an app-specific password at: https://appleid.apple.com"
    echo ""
    read -p "Skip notarization for now? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    SKIP_NOTARIZATION=true
    echo "WARNING: Skipping notarization. Users will see Gatekeeper warnings!"
else
    # Create zip for notarization
    ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
    echo "Creating zip for notarization..."
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    echo "Submitting for notarization..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"

    rm "$ZIP_PATH"
    echo "Notarization complete!"
fi

echo ""

# ============================================
# Step 2: Create DMG
# ============================================
echo "=== Step 2: Creating DMG ==="

DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

# Remove existing DMG if present
if [ -f "$DMG_PATH" ]; then
    echo "Removing existing DMG..."
    rm -f "$DMG_PATH"
fi

# One code path on purpose. This used to prefer create-dmg and fall back to a
# bare `hdiutil create -srcfolder <app>` when it was missing, which is what the
# release machine actually did: every shipped DMG held the app alone, with no
# /Applications alias and no window layout, so the only thing to do on opening
# it was run the app off the disk image.
"$SCRIPT_DIR/make-dmg.sh" "$APP_PATH" "$DMG_PATH" "Vibe Notch"
echo ""

# hdiutil emits an UNSIGNED disk image. Notarizing and stapling one
# still works and the app inside validates, but `spctl -t open` then reports
# "no usable signature". Sign it with the same Developer ID as the app.
#
# Requires the certificate in the login keychain: an Xcode-managed cert lives
# in the data-protection keychain where codesign cannot see it, so export it
# from Xcode (Manage Certificates -> Export Certificate) and import the .p12.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" \
    | grep "$(codesign -dvv "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')" \
    | head -1 | sed -E 's/.*"(.*)"/\1/')

if [ -n "$SIGN_ID" ]; then
    echo "Signing DMG as: $SIGN_ID"
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG_PATH"
    codesign --verify --strict "$DMG_PATH" && echo "DMG signature verified."
else
    echo "WARNING: no Developer ID Application identity in the login keychain."
    echo "The DMG will be notarized but left unsigned — the app inside still"
    echo "validates, so this is cosmetic. Import your .p12 to fix it."
fi
echo ""

# ============================================
# Step 3: Notarize the DMG
# ============================================
if [ -z "$SKIP_NOTARIZATION" ]; then
    echo "=== Step 3: Notarizing DMG ==="

    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    xcrun stapler staple "$DMG_PATH"
    echo "DMG notarized!"
    echo ""
fi

# ============================================
# Step 4: Sign for Sparkle and generate appcast
# ============================================
echo "=== Step 4: Signing for Sparkle ==="

# Find Sparkle tools
SPARKLE_SIGN=""
GENERATE_APPCAST=""

POSSIBLE_PATHS=(
    "$HOME/Library/Developer/Xcode/DerivedData/ClaudeIsland-*/SourcePackages/artifacts/sparkle/Sparkle/bin"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    for path in $path_pattern; do
        if [ -x "$path/sign_update" ]; then
            SPARKLE_SIGN="$path/sign_update"
            GENERATE_APPCAST="$path/generate_appcast"
            break 2
        fi
    done
done

if [ -z "$SPARKLE_SIGN" ]; then
    echo "WARNING: Could not find Sparkle tools."
    echo "Build the project in Xcode first to download Sparkle package."
    echo ""
    echo "Skipping Sparkle signing. You'll need to manually:"
    echo "1. Sign the DMG with sign_update"
    echo "2. Generate appcast with generate_appcast"
else
    # Check for private key
    if [ ! -f "$KEYS_DIR/eddsa_private_key" ]; then
        echo "WARNING: No private key found at $KEYS_DIR/eddsa_private_key"
        echo "Run ./scripts/generate-keys.sh first"
        echo ""
        echo "Skipping Sparkle signing."
    else
        # Generate signature
        echo "Signing DMG for Sparkle..."
        SIGNATURE=$("$SPARKLE_SIGN" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$DMG_PATH")

        echo ""
        echo "Sparkle signature:"
        echo "$SIGNATURE"
        echo ""

        # Generate/update appcast
        echo "Generating appcast..."
        APPCAST_DIR="$RELEASE_DIR/appcast"
        mkdir -p "$APPCAST_DIR"

        # Copy DMG to appcast directory
        cp "$DMG_PATH" "$APPCAST_DIR/"

        # Generate appcast.xml
        "$GENERATE_APPCAST" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$APPCAST_DIR"

        if ! grep -q "edSignature" "$APPCAST_DIR/appcast.xml"; then
            echo "ERROR: appcast.xml has no sparkle:edSignature."
            echo "generate_appcast refused to sign — the app's SUPublicEDKey"
            echo "likely does not match $KEYS_DIR/eddsa_private_key."
            echo "Sparkle would reject every update from this feed."
            exit 1
        fi

        echo "Appcast generated at: $APPCAST_DIR/appcast.xml"
    fi
fi

echo ""

# ============================================
# Step 5: Create GitHub Release
# ============================================
echo "=== Step 5: Creating GitHub Release ==="

if ! command -v gh &> /dev/null; then
    echo "WARNING: gh CLI not found. Install with: brew install gh"
    echo "Skipping GitHub release."
else
    # Check if release already exists
    if gh release view "v$VERSION" --repo "$GITHUB_REPO" &>/dev/null; then
        echo "Release v$VERSION already exists. Updating..."
        gh release upload "v$VERSION" "$DMG_PATH" --repo "$GITHUB_REPO" --clobber
    else
        echo "Creating release v$VERSION..."
        gh release create "v$VERSION" "$DMG_PATH" \
            --repo "$GITHUB_REPO" \
            --title "Vibe Notch v$VERSION" \
            --notes "## Vibe Notch v$VERSION

### Installation
1. Download \`$APP_NAME-$VERSION.dmg\`
2. Open the DMG and drag Vibe Notch to Applications
3. Launch Vibe Notch from Applications

### Auto-updates
After installation, Vibe Notch will automatically check for updates."
    fi

    # The deltas generate_appcast just produced belong on this release too.
    # They used to be advertised from raw.githubusercontent.com on the default
    # branch, where they never existed -- releases/ is gitignored -- so every
    # delta 404'd and every client silently fell back to the full DMG.
    #
    # Upload them space-free: GitHub rewrites a space in an asset name to a dot,
    # which would not match the URL written into the appcast.
    DELTA_STAGE="$BUILD_DIR/deltas"
    rm -rf "$DELTA_STAGE"
    mkdir -p "$DELTA_STAGE"

    shopt -s nullglob
    for delta in "$RELEASE_DIR/appcast/Vibe Notch$BUILD-"*.delta; do
        base="$(basename "$delta")"
        cp "$delta" "$DELTA_STAGE/${base/#Vibe Notch/$APP_NAME-}"
    done
    staged=("$DELTA_STAGE"/*.delta)
    shopt -u nullglob

    if [ ${#staged[@]} -gt 0 ]; then
        echo "Uploading ${#staged[@]} delta(s) to v$VERSION..."
        gh release upload "v$VERSION" "${staged[@]}" --repo "$GITHUB_REPO" --clobber
    else
        echo "No deltas for build $BUILD -- clients will take the full DMG."
    fi

    GITHUB_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"
    echo "GitHub release created: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
    echo "Download URL: $GITHUB_DOWNLOAD_URL"
fi

echo ""

# ============================================
# Step 6: Publish appcast from this repo
# ============================================
echo "=== Step 6: Publishing Appcast ==="

if [ ! -f "$RELEASE_DIR/appcast/appcast.xml" ]; then
    echo "Appcast was not generated — skipping publish."
    echo "Sparkle clients will not see this release until an appcast is published."
elif [ -z "$GITHUB_DOWNLOAD_URL" ]; then
    echo "No GitHub download URL — skipping appcast publish."
else
    cp "$RELEASE_DIR/appcast/appcast.xml" "$REPO_APPCAST"

    # generate_appcast writes a local file:// or bare-filename URL for every
    # enclosure. Point each one at the release that carries the file — the DMG
    # and the deltas alike, for older items as well as this one. This used to
    # rewrite only the current DMG, which is why every delta in the feed and
    # every previous version's DMG pointed at a branch path that 404s.
    if ! "$SCRIPT_DIR/rewrite-appcast-urls.py" "$REPO_APPCAST" "$GITHUB_REPO"; then
        echo "ERROR: could not point every enclosure at a release asset."
        echo "Sparkle would ship 404s to installed clients."
        exit 1
    fi
    echo "Wrote $REPO_APPCAST (download URL: $GITHUB_DOWNLOAD_URL)"

    if ! grep -q "$GITHUB_DOWNLOAD_URL" "$REPO_APPCAST"; then
        echo "ERROR: appcast.xml does not reference the release DMG."
        echo "Inspect it before publishing — Sparkle updates would break."
        exit 1
    fi

    read -p "Commit and push appcast.xml to $APPCAST_BRANCH? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        cd "$PROJECT_DIR"
        git add appcast.xml
        if git diff --cached --quiet; then
            echo "appcast.xml unchanged — nothing to commit."
        else
            git commit -m "Publish appcast for v$VERSION"
            git push origin "$APPCAST_BRANCH"
            echo "Appcast pushed. Sparkle feed is live."
        fi
    else
        echo "Skipped. Push $REPO_APPCAST manually to make the update visible."
    fi
fi

echo ""

echo "=== Release Complete ==="
echo ""
echo "Files created:"
echo "  - DMG: $DMG_PATH"
if [ -f "$RELEASE_DIR/appcast/appcast.xml" ]; then
    echo "  - Appcast: $RELEASE_DIR/appcast/appcast.xml"
fi
if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
    echo "  - GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
fi
if [ -f "$REPO_APPCAST" ]; then
    echo "  - Appcast (repo): $REPO_APPCAST"
    echo "  - Feed URL: https://raw.githubusercontent.com/$GITHUB_REPO/$APPCAST_BRANCH/appcast.xml"
fi
