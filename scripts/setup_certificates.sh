#!/usr/bin/env bash

set -eou pipefail

# Setup code signing certificates for macOS app - isolated from development environment
#
# Required environment variables:
# BUILD_CERTIFICATE_BASE64 - Base64 encoded certificate
# P12_PASSWORD - Certificate password
# BUILD_PROVISION_PROFILE_BASE64 - Base64 encoded provisioning profile
# KEYCHAIN_PASSWORD - Password for the temporary keychain

# Generate a unique ID for this build (or use from environment if set)
BUILD_ID=${BUILD_ID:-$(date +%s)}
export BUILD_ID

# Configure isolated paths
TEMP_DIR="${RUNNER_TEMP:-/tmp}"
KEYCHAIN_PATH="$TEMP_DIR/nochat4u-signing-$BUILD_ID.keychain-db"
CERTIFICATE_PATH="$TEMP_DIR/certificate-$BUILD_ID.p12"
PROFILE_PATH="$TEMP_DIR/profile-$BUILD_ID.provisionprofile"
PROFILE_DEST="$HOME/Library/MobileDevice/Provisioning Profiles/"

echo "🔐 Setting up isolated code signing environment..."

# Decode certificate and provisioning profile
echo "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$CERTIFICATE_PATH"
echo -n "$BUILD_PROVISION_PROFILE_BASE64" | base64 --decode > "$PROFILE_PATH"

# Setup keychain (isolated from the user's login keychain)
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# No need to set as default, just add to search list
security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | xargs)
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# Import certificate with appropriate access rights
security import "$CERTIFICATE_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$P12_PASSWORD" \
  -T "/usr/bin/codesign" \
  -T "$(xcrun --find notarytool)"

security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# Install provisioning profile with uniquely identifiable name
mkdir -p "$PROFILE_DEST"
UUID=$(grep -a -A 1 "UUID" "$PROFILE_PATH" | tail -1 | awk -F'>' '{print $2}' | awk -F'<' '{print $1}')
cp "$PROFILE_PATH" "$PROFILE_DEST/$UUID.provisionprofile"

echo "✅ Isolated code signing setup complete. Use cleanup_environment.sh to safely remove." 