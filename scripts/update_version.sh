#!/usr/bin/env bash

set -eou pipefail

# Update version information in Info.plist
#
# Usage: update_version.sh <version>
#
# This script replaces #VERSION# placeholders in Info.plist with the specified version

VERSION="$1"

# Remove 'v' prefix if present
VERSION="${VERSION#v}"

echo "Updating version placeholders to $VERSION..."

# Replace version placeholders in Info.plist
sed -i '' "s/#VERSION#/$VERSION/g" "NoChat4U/Info.plist"

echo "✅ Version updated successfully to $VERSION in Info.plist" 