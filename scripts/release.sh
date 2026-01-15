#!/bin/bash
set -euo pipefail

# HomeKit Menu Release Script
# Usage: ./release.sh <version> [--local] [--skip-notarize]
#
# Options:
#   --local          Build only, don't push to GitHub or update appcast
#   --skip-notarize  Skip Apple notarization step
#
# Prerequisites:
# - Xcode command line tools
# - GitHub CLI (gh) authenticated
# - Sparkle installed: brew install --cask sparkle
# - create-dmg installed: brew install create-dmg

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
APP_NAME="HomeKit Menu"
BUNDLE_ID="com.danielraffel.HomeKitMenu"
PROJECT_DIR="$HOME/Code/HomeKitMenu"
RELEASES_DIR="$HOME/Code/homekitmenu-releases"
GITHUB_REPO="danielraffel/homekitmenu-releases"
APPCAST_URL="https://www.generouscorp.com/homekitmenu-releases/appcast/release.xml"

# Sparkle tools
SPARKLE_SIGN="/opt/homebrew/Caskroom/sparkle/2.8.1/bin/sign_update"
SPARKLE_KEY_FILE="$HOME/.sparkle_private_key"

# Load environment variables from .env if it exists
ENV_FILE="$RELEASES_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Use APP_CERT if set, otherwise fall back to default
DEVELOPER_ID_APP="${APP_CERT:-Developer ID Application: Daniel Raffel (95CX6P84C4)}"

# Parse arguments
VERSION=""
SKIP_NOTARIZE=false
LOCAL_ONLY=false

for arg in "$@"; do
    case $arg in
        --skip-notarize)
            SKIP_NOTARIZE=true
            ;;
        --local)
            LOCAL_ONLY=true
            ;;
        *)
            if [[ -z "$VERSION" && "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                VERSION="$arg"
            elif [[ -z "$VERSION" && ! "$arg" =~ ^-- ]]; then
                VERSION="$arg"
            fi
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo -e "${RED}Error: Version required${NC}"
    echo "Usage: $0 <version> [--local] [--skip-notarize]"
    echo ""
    echo "Options:"
    echo "  --local          Build only, don't push to GitHub or update appcast"
    echo "  --skip-notarize  Skip Apple notarization step"
    echo ""
    echo "Examples:"
    echo "  $0 1.0.0              # Full release with notarization"
    echo "  $0 1.0.0 --local      # Local build only"
    echo "  $0 1.0.0 --skip-notarize  # Release without notarization"
    exit 1
fi

# Validate version format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}Error: Invalid version format. Use semantic versioning (e.g., 1.0.0)${NC}"
    exit 1
fi

# Calculate build number
IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD_NUMBER=$((MAJOR * 10000 + MINOR * 100 + PATCH))

# Display mode
MODE="Release"
[[ "$LOCAL_ONLY" == true ]] && MODE="Local Build"
[[ "$SKIP_NOTARIZE" == true ]] && MODE="$MODE (skip notarize)"

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  HomeKit Menu v$VERSION (Build $BUILD_NUMBER)${NC}"
echo -e "${BLUE}  Mode: $MODE${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# Check prerequisites
echo -e "\n${YELLOW}Checking prerequisites...${NC}"

if [[ "$LOCAL_ONLY" == false ]]; then
    if ! command -v gh &> /dev/null; then
        echo -e "${RED}Error: GitHub CLI not found. Install: brew install gh${NC}"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        echo -e "${RED}Error: Not authenticated with GitHub. Run: gh auth login${NC}"
        exit 1
    fi
fi

if ! command -v create-dmg &> /dev/null; then
    echo -e "${RED}Error: create-dmg not found. Install: brew install create-dmg${NC}"
    exit 1
fi

if [[ ! -f "$SPARKLE_SIGN" ]]; then
    echo -e "${RED}Error: Sparkle not found. Install: brew install --cask sparkle${NC}"
    exit 1
fi

if [[ ! -f "$SPARKLE_KEY_FILE" ]]; then
    echo -e "${YELLOW}Warning: Sparkle private key not found at $SPARKLE_KEY_FILE${NC}"
    echo "Export with: /opt/homebrew/Caskroom/sparkle/2.8.1/bin/generate_keys -x ~/.sparkle_private_key"
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"

# Create output directory
OUTPUT_DIR="$RELEASES_DIR/releases/v$VERSION"
mkdir -p "$OUTPUT_DIR"

# Build the app
echo -e "\n${YELLOW}Building HomeKit Menu...${NC}"
cd "$PROJECT_DIR"

# Update version in project (Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PROJECT_DIR/HomeKitMenu/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PROJECT_DIR/HomeKitMenu/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PROJECT_DIR/HomeKitMenu/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$PROJECT_DIR/HomeKitMenu/Info.plist"

# Build for Mac Catalyst
xcodebuild -scheme "HomeKitMenu" \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -configuration Release \
    clean build \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    | grep -E "^(Build|error:|warning:|\*\*)" || true

# Find the built app
BUILD_DIR=$(xcodebuild -scheme "HomeKitMenu" -destination 'platform=macOS,variant=Mac Catalyst' -configuration Release -showBuildSettings 2>/dev/null | grep -m 1 'BUILT_PRODUCTS_DIR' | awk '{print $3}')
APP_PATH="$BUILD_DIR/HomeKitMenu.app"

if [[ ! -d "$APP_PATH" ]]; then
    # Try alternative path
    APP_PATH="$HOME/Library/Developer/Xcode/DerivedData/HomeKitMenu-*/Build/Products/Release-maccatalyst/HomeKitMenu.app"
    APP_PATH=$(ls -d $APP_PATH 2>/dev/null | head -1)
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo -e "${RED}Error: Built app not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Build complete: $APP_PATH${NC}"

# Remove development provisioning profile (not valid for Developer ID distribution)
echo -e "\n${YELLOW}Preparing app for Developer ID distribution...${NC}"
rm -f "$APP_PATH/Contents/embedded.provisionprofile"
echo -e "${GREEN}✓ Removed development provisioning profile${NC}"

# Sign the app with entitlements
echo -e "\n${YELLOW}Signing app with Developer ID...${NC}"
ENTITLEMENTS_FILE="$PROJECT_DIR/HomeKitMenu/HomeKitMenu.entitlements"

if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
    echo -e "${RED}Error: Entitlements file not found at $ENTITLEMENTS_FILE${NC}"
    exit 1
fi

codesign --force --deep \
    --sign "$DEVELOPER_ID_APP" \
    --entitlements "$ENTITLEMENTS_FILE" \
    --timestamp --options runtime \
    "$APP_PATH"
echo -e "${GREEN}✓ App signed with entitlements${NC}"

# Create DMG
echo -e "\n${YELLOW}Creating DMG...${NC}"
DMG_PATH="$OUTPUT_DIR/HomeKitMenu-$VERSION.dmg"

# Remove old DMG if exists
rm -f "$DMG_PATH"

# create-dmg (sindresorhus version) - simpler API
create-dmg "$APP_PATH" "$OUTPUT_DIR" --overwrite --dmg-title="HomeKit Menu" 2>&1 || true

# Rename to our versioned name
CREATED_DMG=$(ls "$OUTPUT_DIR"/*.dmg 2>/dev/null | head -1)
if [[ -n "$CREATED_DMG" && "$CREATED_DMG" != "$DMG_PATH" ]]; then
    mv "$CREATED_DMG" "$DMG_PATH"
fi

if [[ ! -f "$DMG_PATH" ]]; then
    echo -e "${RED}Error: DMG creation failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ DMG created: $DMG_PATH${NC}"

# Sign DMG
echo -e "\n${YELLOW}Signing DMG...${NC}"
codesign --force --sign "$DEVELOPER_ID_APP" --timestamp "$DMG_PATH"
echo -e "${GREEN}✓ DMG signed${NC}"

# Notarize (optional)
if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo -e "\n${YELLOW}Notarizing DMG...${NC}"
    echo "This may take several minutes..."

    if [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_SPECIFIC_PASSWORD:-}" ]]; then
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_SPECIFIC_PASSWORD" \
            --wait

        xcrun stapler staple "$DMG_PATH"
        echo -e "${GREEN}✓ Notarization complete${NC}"
    else
        echo -e "${YELLOW}Skipping notarization (credentials not set in .env)${NC}"
        echo "Add APPLE_ID, TEAM_ID, and APP_SPECIFIC_PASSWORD to $ENV_FILE"
    fi
else
    echo -e "${YELLOW}Skipping notarization (--skip-notarize)${NC}"
fi

# Sign for Sparkle
echo -e "\n${YELLOW}Generating Sparkle signature...${NC}"
if [[ -f "$SPARKLE_KEY_FILE" ]]; then
    SPARKLE_SIG=$("$SPARKLE_SIGN" "$DMG_PATH" --ed-key-file "$SPARKLE_KEY_FILE" 2>/dev/null | grep 'edSignature=' | cut -d'"' -f2)
    echo -e "${GREEN}✓ Sparkle signature: $SPARKLE_SIG${NC}"
else
    SPARKLE_SIG="SIGNATURE_PLACEHOLDER"
    echo -e "${YELLOW}Warning: Using placeholder signature (no key file)${NC}"
fi

# Get file size
DMG_SIZE=$(stat -f%z "$DMG_PATH")

# Local build ends here
if [[ "$LOCAL_ONLY" == true ]]; then
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Local build v$VERSION complete!${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "📦 DMG: $DMG_PATH"
    echo "📏 Size: $DMG_SIZE bytes"
    echo "🔐 Sparkle signature: $SPARKLE_SIG"
    echo ""
    echo -e "${YELLOW}To install locally:${NC}"
    echo "  open \"$DMG_PATH\""
    echo ""
    echo -e "${YELLOW}To do a full release:${NC}"
    echo "  $0 $VERSION"
    exit 0
fi

# Generate release notes
RELEASE_NOTES="## HomeKit Menu v$VERSION

### What's New
- Bug fixes and improvements

### Installation
1. Download the DMG file
2. Open it and drag HomeKit Menu to Applications
3. Launch from Applications folder

### Requirements
- macOS 14.0 or later
"

# Create GitHub release
echo -e "\n${YELLOW}Creating GitHub release...${NC}"
cd "$RELEASES_DIR"

gh release create "v$VERSION" \
    --repo "$GITHUB_REPO" \
    --title "HomeKit Menu v$VERSION" \
    --notes "$RELEASE_NOTES" \
    "$DMG_PATH"

echo -e "${GREEN}✓ GitHub release created${NC}"

# Update appcast
echo -e "\n${YELLOW}Updating appcast...${NC}"
APPCAST_FILE="$RELEASES_DIR/appcast/release.xml"
PUB_DATE=$(date -R)
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/HomeKitMenu-$VERSION.dmg"

# Insert new item before </channel> using Python (handles multiline reliably)
python3 << PYEOF
import sys

new_item = '''        <item>
            <title>HomeKit Menu v$VERSION (build $BUILD_NUMBER)</title>
            <sparkle:releaseNotesLink>https://github.com/$GITHUB_REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
            <pubDate>$PUB_DATE</pubDate>
            <enclosure
                url="$DOWNLOAD_URL"
                sparkle:version="$BUILD_NUMBER"
                sparkle:shortVersionString="$VERSION"
                length="$DMG_SIZE"
                type="application/octet-stream"
                sparkle:edSignature="$SPARKLE_SIG"
            />
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        </item>'''

with open("$APPCAST_FILE", "r") as f:
    content = f.read()

content = content.replace("    </channel>", new_item + "\n    </channel>")

with open("$APPCAST_FILE", "w") as f:
    f.write(content)
PYEOF

echo -e "${GREEN}✓ Appcast updated${NC}"

# Commit and push appcast
echo -e "\n${YELLOW}Pushing appcast update...${NC}"
cd "$RELEASES_DIR"
git add -A
git commit -m "Release v$VERSION" || true
git push

echo -e "${GREEN}✓ Appcast pushed${NC}"

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ Release v$VERSION complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "📦 DMG: $DMG_PATH"
echo "🔗 Release: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "📡 Appcast: $APPCAST_URL"
echo ""
echo -e "${YELLOW}Test the update:${NC}"
echo "1. Install an older version"
echo "2. Click 'Check for Updates' in the menu bar"
