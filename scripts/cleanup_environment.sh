#!/usr/bin/env bash

set -eou pipefail

# Cleanup script for NoChat4U build environment
# Safely cleans up only workflow-created resources without affecting development environment

# Generate a unique ID for this build (or use from environment if set)
BUILD_ID=${BUILD_ID:-$(date +%s)}
KEYCHAIN_PATH="$RUNNER_TEMP/nochat4u-signing-$BUILD_ID.keychain-db"
PROFILE_PATH="$RUNNER_TEMP/profile-$BUILD_ID.provisionprofile"

echo "🧹 Starting isolated environment cleanup..."

# Clean up build artifacts specific to this workflow
rm -rf DerivedData-$BUILD_ID || true
echo "✓ Removed workflow build artifacts"

# Clean up workflow-specific keychain (not touching login keychain)
if [ -f "$KEYCHAIN_PATH" ]; then
  security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
  security list-keychains -d user -s $(security list-keychains -d user | grep -v "$KEYCHAIN_PATH" | xargs)
  echo "✓ Removed workflow-specific keychain"
else
  echo "✓ No workflow keychain found to remove"
fi

# Clean up only the provisioning profile created by this workflow
if [ -f "$PROFILE_PATH" ]; then
  rm -f "$PROFILE_PATH" 2>/dev/null || true
  echo "✓ Removed workflow provisioning profile"
else
  echo "✓ No workflow provisioning profile found to remove"
fi

# Only remove the specific profile copied to the Library
PROFILE_UUID=$(grep -a -A 1 "UUID" "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile 2>/dev/null | grep -B 1 -a "nochat4u" | head -1 | awk -F"/" '{print $NF}' | cut -d '.' -f 1 || echo "")
if [ -n "$PROFILE_UUID" ]; then
  rm -f "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.provisionprofile" 2>/dev/null || true
  echo "✓ Removed workflow installed provisioning profile"
else
  echo "✓ No workflow provisioning profile found in Library"
fi

# Clean up git repositories created by this workflow
rm -rf homebrew-tap-$BUILD_ID || true
echo "✓ Removed workflow cloned repositories"

# Instead of killing all Xcode processes, only kill processes with specific workflow args
pkill -f "xcodebuild.*DerivedData-$BUILD_ID" 2>/dev/null || true
echo "✓ Terminated only workflow-specific processes"

# Remove certificates and profiles specific to this workflow
rm -f "$RUNNER_TEMP/certificate-$BUILD_ID.p12" 2>/dev/null || true
echo "✓ Removed workflow certificate files"

echo "✅ Workflow environment cleaned safely without affecting development environment" 