#!/usr/bin/env bash

set -eou pipefail

# Update Sparkle appcast.xml with new release information
#
# Usage: update_appcast.sh <app_name> <version>
#
# Required environment variables:
# SPARKLE_ED_PRIVATE_KEY - Sparkle EdDSA private key for signing the update
# BUILD_ID - Unique build identifier (for path to Sparkle binary)
# GITHUB_REPOSITORY - Full repository name (owner/repo)

# Get application info
APP_NAME="$1"
VERSION="$2"  # This is the tag name with the 'v' prefix (e.g., v1.0.0)
VERSION_NO_V="${VERSION#v}"  # Version without the 'v' prefix (e.g., 1.0.0)

ZIP_NAME="$APP_NAME-$VERSION.zip"

# Get system and dependency information
DATE="$(date +'%a, %d %b %Y %H:%M:%S %z')"

# Extract minimum system version from the project file
MINIMUM_SYSTEM_VERSION=$(grep -m 1 "MACOSX_DEPLOYMENT_TARGET" "NoChat4U.xcodeproj/project.pbxproj" | awk -F ' = ' '{print $2}' | tr -d '[:space:];')
if [ -z "$MINIMUM_SYSTEM_VERSION" ]; then
    # Fallback to default if extraction fails
    echo "Warning: Could not extract MACOSX_DEPLOYMENT_TARGET, using default value"
    MINIMUM_SYSTEM_VERSION="10.15"
fi

echo "Using minimum system version: $MINIMUM_SYSTEM_VERSION"

# Find Sparkle binary path dynamically
DERIVED_DATA_PATH="DerivedData-${BUILD_ID:-}"
SPARKLE_BIN_PATH="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin"

# If Sparkle binary path doesn't exist, try alternative paths
if [ ! -d "$SPARKLE_BIN_PATH" ]; then
    echo "Warning: Sparkle binary not found at $SPARKLE_BIN_PATH, searching for alternatives..."
    SPARKLE_BIN_PATH=$(find DerivedData* -type d -path "*/artifacts/sparkle/Sparkle/bin" 2>/dev/null | head -n 1)
    
    if [ -z "$SPARKLE_BIN_PATH" ]; then
        echo "Error: Could not find Sparkle binary path"
        exit 1
    fi
    
    echo "Found Sparkle binary at: $SPARKLE_BIN_PATH"
fi

# Check if the ZIP file exists in workspace root (moved there by previous step)
ZIP_PATH="./$ZIP_NAME"
if [ ! -f "$ZIP_PATH" ]; then
    echo "Error: ZIP file not found at $ZIP_PATH"
    echo "Files in directory:"
    ls -la .
    exit 1
fi

echo "Found ZIP file at: $ZIP_PATH"

# Sign the update with Sparkle
echo "Signing update with Sparkle..."
SIGNATURE_DATA_AND_LENGTH=$(echo "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN_PATH/sign_update" --ed-key-file - "$ZIP_PATH")

# Create appcast item
echo "Creating appcast item for version $VERSION_NO_V..."
cat > "ITEM.txt" << EOF
    <item>
      <title>Version $VERSION_NO_V</title>
      <pubDate>$DATE</pubDate>
      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$GITHUB_REPOSITORY/releases/tag/$VERSION</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/$GITHUB_REPOSITORY/releases/download/$VERSION/$ZIP_NAME"
        sparkle:version="$VERSION_NO_V"
        sparkle:shortVersionString="$VERSION_NO_V"
        $SIGNATURE_DATA_AND_LENGTH
        type="application/octet-stream"/>
    </item>
EOF

# Update appcast.xml
echo "Updating appcast.xml..."
sed -i '' -e "/<\/language>/r ITEM.txt" appcast.xml

# Clean up
rm ITEM.txt

# Commit and push the updated appcast.xml
echo "Committing changes to appcast.xml..."

# Configure git
git config user.name "GitHub Actions Bot"
git config user.email "actions@github.com"

# Fetch and checkout main branch
echo "Checking out main branch..."
git fetch origin main
git checkout main

# Add, commit and push the changes
git add appcast.xml
git commit -m "Update appcast.xml for $VERSION [skip ci]"
git push origin main

echo "✅ Appcast.xml updated and changes committed successfully for version $VERSION"