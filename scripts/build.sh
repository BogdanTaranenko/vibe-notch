#!/bin/bash
# Build Vibe Notch for release
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/ClaudeIsland.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# Signing style. A developer's Mac has an Xcode account that can fetch signing
# assets, so automatic stays the default there. A CI runner has only the
# Developer ID certificate imported into a temporary keychain and no account to
# ask, so it sets SIGNING_STYLE=manual and names the identity outright.
#
# Manual signing needs no provisioning profile here: the app is not sandboxed
# and its only entitlement is user-selected read-only, so nothing about it
# requires a profile to authorise.
SIGNING_STYLE="${SIGNING_STYLE:-automatic}"
SIGNING_TEAM="${SIGNING_TEAM:-36U788QB6S}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"

if [ "$SIGNING_STYLE" = "manual" ]; then
    SIGN_ARGS=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
        DEVELOPMENT_TEAM="$SIGNING_TEAM"
    )
else
    SIGN_ARGS=(CODE_SIGN_STYLE=Automatic)
fi

echo "=== Building Vibe Notch ==="
echo "Signing style: $SIGNING_STYLE"
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

# Release builds resolve strictly from the committed Package.resolved
# (-onlyUsePackageVersionsFromResolvedFile), so a release either uses exactly the
# reviewed dependency revisions or fails outright. Without it Xcode is free to
# re-resolve mid-archive and ship something nobody looked at.
# Build and archive — pipe to xcpretty when available, but capture the real
# xcodebuild exit code so a noisy-but-successful xcpretty doesn't fail the build.
echo "Archiving..."
set +e
xcodebuild archive \
    -scheme ClaudeIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    -onlyUsePackageVersionsFromResolvedFile \
    ENABLE_HARDENED_RUNTIME=YES \
    "${SIGN_ARGS[@]}" \
    2>&1 | xcpretty
ARCHIVE_EXIT=${PIPESTATUS[0]}
set -e

if [ "$ARCHIVE_EXIT" -ne 0 ]; then
    echo "ERROR: Archive failed. Re-running with full output..."
    xcodebuild archive \
        -scheme ClaudeIsland \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=macOS" \
        -onlyUsePackageVersionsFromResolvedFile \
        ENABLE_HARDENED_RUNTIME=YES \
        "${SIGN_ARGS[@]}"
    exit 1
fi

# The export has to agree with how the archive was signed, or xcodebuild goes
# looking for signing assets the runner has no account to fetch.
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>$SIGNING_STYLE</string>
    <key>teamID</key>
    <string>$SIGNING_TEAM</string>
</dict>
</plist>
EOF

# Export the archive
echo ""
echo "Exporting..."
set +e
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    2>&1 | xcpretty
EXPORT_EXIT=${PIPESTATUS[0]}
set -e

if [ "$EXPORT_EXIT" -ne 0 ]; then
    echo "ERROR: Export failed. Re-running with full output..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS"
    exit 1
fi

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/Vibe Notch.app"
echo ""
echo "Next: Run ./scripts/create-release.sh to notarize and create DMG"
