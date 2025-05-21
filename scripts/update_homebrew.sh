#!/usr/bin/env bash

set -eou pipefail

# Update Homebrew tap with the new release
#
# Usage: update_homebrew.sh <version> <tag_name> <zip_sha>
#
# Required environment variables:
# GITHUB_REPOSITORY: Full repository name (owner/repo)
# GITHUB_REPOSITORY_OWNER: Repository owner
# APP_NAME: Application name
# BUILD_ID: Unique build identifier

# Validate arguments
if [[ $# -ne 3 ]]; then
    echo "Error: Invalid number of arguments"
    echo "Usage: $0 <version> <tag_name> <zip_sha>"
    exit 1
fi

VERSION="$1"
TAG_NAME="$2"
ZIP_SHA="$3"
ZIP_NAME="$APP_NAME-$TAG_NAME.zip"
BUILD_ID=${BUILD_ID:-$(date +%s)}
TAP_DIR="homebrew-tap-$BUILD_ID"

echo "Updating Homebrew tap for version $VERSION ($TAG_NAME)..."

# Navigate to homebrew-tap directory (with the unique name)
if [ -d "$TAP_DIR" ]; then
    cd "$TAP_DIR"
else
    # Fallback to standard name if unique directory not found
    cd homebrew-tap || { echo "Error: Homebrew tap directory not found"; exit 1; }
fi

# Create/update the cask formula file
echo "Creating Homebrew cask formula..."
cat > "Casks/nochat4u.rb" << EOF
cask "nochat4u" do
  desc "NoChat4U Application"
  homepage "https://github.com/$GITHUB_REPOSITORY"
  url "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG_NAME/$ZIP_NAME"
  sha256 "$ZIP_SHA"
  version "$VERSION"

  app "$APP_NAME.app"

  uninstall quit: "com.someone.NoChat4U"
end
EOF

# Commit and push changes
echo "Committing and pushing changes..."
git config user.name "GitHub Actions Bot"
git config user.email "actions@github.com"
git add "Casks/nochat4u.rb"
git commit -m "Update $APP_NAME to $TAG_NAME"
git push

echo "Homebrew tap updated successfully" 