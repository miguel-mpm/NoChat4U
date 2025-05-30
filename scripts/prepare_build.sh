#!/usr/bin/env bash

set -eou pipefail

# Prepare build by injecting version and GitHub token
#
# Usage: prepare_build.sh <version> <github_token>
#
# This script replaces build-time placeholders in the source code:
# - #VERSION# -> actual version number
# - GITHUB_TOKEN_PLACEHOLDER -> actual GitHub token

VERSION="$1"
GITHUB_TOKEN="$2"

# Remove 'v' prefix from version if present
VERSION="${VERSION#v}"

echo "🔧 Preparing build with version $VERSION..."

# Define source directories to process
SOURCE_DIRS=("NoChat4U" ".")

echo "📋 Finding and replacing placeholders..."

# Find and replace version placeholders
echo "📝 Replacing version placeholders with $VERSION..."
for dir in "${SOURCE_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        find "$dir" -type f \( -name "*.swift" -o -name "*.plist" -o -name "*.xml" -o -name "*.md" \) \
            -not -path "*/DerivedData*" \
            -not -path "*/.git*" \
            -exec grep -l "#VERSION#" {} \; 2>/dev/null | while read -r file; do
            echo "  📝 Updating version in: $file"
            sed -i '' "s/#VERSION#/$VERSION/g" "$file"
        done
    fi
done

# Find and replace GitHub token placeholders
echo "🔐 Injecting GitHub token..."
for dir in "${SOURCE_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        find "$dir" -type f \( -name "*.swift" -o -name "*.plist" -o -name "*.xml" -o -name "*.md" \) \
            -not -path "*/DerivedData*" \
            -not -path "*/.git*" \
            -exec grep -l "GITHUB_TOKEN_PLACEHOLDER" {} \; 2>/dev/null | while read -r file; do
            echo "  🔐 Updating token in: $file"
            # Use a different delimiter to avoid issues with token content
            sed -i '' "s|GITHUB_TOKEN_PLACEHOLDER|$GITHUB_TOKEN|g" "$file"
        done
    fi
done

echo "🔍 Validating all placeholders were replaced..."

# Check if any placeholders still exist
VALIDATION_FAILED=false

for dir in "${SOURCE_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        # Check for remaining version placeholders
        if find "$dir" -type f \( -name "*.swift" -o -name "*.plist" -o -name "*.xml" -o -name "*.md" \) \
            -not -path "*/DerivedData*" \
            -not -path "*/.git*" \
            -exec grep -l "#VERSION#" {} \; 2>/dev/null | grep -q .; then
            echo "❌ Version placeholders still found in:"
            find "$dir" -type f \( -name "*.swift" -o -name "*.plist" -o -name "*.xml" -o -name "*.md" \) \
                -not -path "*/DerivedData*" \
                -not -path "*/.git*" \
                -exec grep -l "#VERSION#" {} \; 2>/dev/null | sed 's/^/    /'
            VALIDATION_FAILED=true
        fi
        
        # Check for remaining token placeholders
        if find "$dir" -type f \( -name "*.swift" -o -name "*.plist" -o -name "*.xml" -o -name "*.md" \) \
            -not -path "*/DerivedData*" \
            -not -path "*/.git*" \
            -exec grep -l "GITHUB_TOKEN_PLACEHOLDER" {} \; 2>/dev/null | grep -q .; then
            echo "❌ Token placeholders still found in:"
            find "$dir" -type f \( -name "*.swift" -o -name "*.plist" -o -name "*.xml" -o -name "*.md" \) \
                -not -path "*/DerivedData*" \
                -not -path "*/.git*" \
                -exec grep -l "GITHUB_TOKEN_PLACEHOLDER" {} \; 2>/dev/null | sed 's/^/    /'
            VALIDATION_FAILED=true
        fi
    fi
done

if [ "$VALIDATION_FAILED" = true ]; then
    echo "💥 Validation failed - some placeholders were not replaced"
    exit 1
fi

echo "✅ Build preparation completed successfully!"
echo "📊 Summary:"
echo "  - Version: $VERSION"
echo "  - Token: [REDACTED]" 