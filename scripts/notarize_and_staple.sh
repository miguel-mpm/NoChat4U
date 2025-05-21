#!/usr/bin/env bash

set -eou pipefail

# Notarize and staple macOS application
#
# Usage: notarize_and_staple.sh <app_name> <version>
#
# Required environment variables:
# APPLE_ID - Apple ID for notarization
# APPLE_PASSWORD - App-specific password for Apple ID
# APPLE_TEAM_ID - Developer Team ID
# XCODE_BUILD_PATH - Path to the build directory

# Get application info
APP_NAME="$1"
VERSION="$2"
APP_PATH="$XCODE_BUILD_PATH/$APP_NAME.app"
ZIP_PATH="$XCODE_BUILD_PATH/$APP_NAME-$VERSION.zip"

# Package app for notarization
echo "📦 Packaging application for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Submit for notarization and capture output
echo "📤 Submitting to Apple notarization service (timeout: 5 minutes)..."
NOTARIZATION_OUTPUT=$(xcrun notarytool submit \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait \
  --progress \
  --timeout 5m \
  "$ZIP_PATH" 2>&1)

# Display output for logs
echo "$NOTARIZATION_OUTPUT"

# Check if process completed and was accepted
if ! echo "$NOTARIZATION_OUTPUT" | grep -q "Processing complete"; then
  echo "❌ Notarization process did not complete!"
  exit 1
fi

if ! echo "$NOTARIZATION_OUTPUT" | grep -q "status: Accepted"; then
  echo "❌ Notarization was rejected!"
  exit 1
fi

# Staple the notarization ticket to the app
echo "🔖 Notarization successful, stapling ticket to app..."
xcrun stapler staple "$APP_PATH"

# Create final zip package
echo "📦 Creating final package..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "✅ App notarized and packaged successfully at: $ZIP_PATH"