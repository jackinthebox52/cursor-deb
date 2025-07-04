#!/bin/bash
# Cursor AppImage to DEB Converter
# This script downloads the latest Cursor IDE AppImage and converts it to a .deb package
# Usage: ./convert-cursor-to-deb.sh [-k]

set -e

# Default settings
KEEP_TEMP=false
CURSOR_API_URL="https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable"

# Function to print usage
print_usage() {
    echo "Usage: $0 [-k]"
    echo "  -k            Keep temporary files after completion (useful for debugging)"
    echo "  -h            Display this help message"
}

# Parse command line options
while getopts "kh" opt; do
  case ${opt} in
    k )
      KEEP_TEMP=true
      ;;
    h )
      print_usage
      exit 0
      ;;
    \? )
      echo "Invalid option: $OPTARG" 1>&2
      print_usage
      exit 1
      ;;
  esac
done

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Check for required tools
for cmd in curl jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required but not installed. Please install it."
        exit 1
    fi
done

# Ensure dpkg-deb is available (part of dpkg-dev package)
if ! command -v dpkg-deb &> /dev/null; then
    echo "Error: dpkg-deb is required but not installed."
    echo "Install it with: sudo apt-get install dpkg-dev"
    exit 1
fi

# Save current working directory
ORIGINAL_PWD=$(pwd)

# Create temp directory in current working directory
TEMP_DIR="$ORIGINAL_PWD/cursor_temp_$(date +%s)"
DOWNLOAD_DIR="$TEMP_DIR/download"
EXTRACT_DIR="$TEMP_DIR/extract"
DEB_DIR="$TEMP_DIR/deb"
mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$DEB_DIR"

echo "Temporary directory created at $TEMP_DIR"

# Download the latest Cursor AppImage
echo "Fetching latest Cursor version information..."
API_RESPONSE=$(curl -s "$CURSOR_API_URL")
DOWNLOAD_URL=$(echo "$API_RESPONSE" | jq -r '.downloadUrl')
VERSION=$(echo "$API_RESPONSE" | jq -r '.version')

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    echo "Error: Failed to get download URL from API"
    exit 1
fi

APPIMAGE_PATH="$DOWNLOAD_DIR/Cursor-${VERSION}-x86_64.AppImage"

echo "Downloading Cursor IDE v${VERSION}..."
curl -L -o "$APPIMAGE_PATH" "$DOWNLOAD_URL"

if [ ! -f "$APPIMAGE_PATH" ]; then
    echo "Error: Failed to download AppImage"
    exit 1
fi

# Make the AppImage executable
chmod +x "$APPIMAGE_PATH"

echo "Successfully downloaded Cursor v${VERSION}"

# Extract AppImage by running it with --appimage-extract
echo "Extracting AppImage..."
cd "$EXTRACT_DIR"
"$APPIMAGE_PATH" --appimage-extract

# Verify extraction
if [ ! -d "squashfs-root" ]; then
    echo "Error: Failed to extract AppImage. squashfs-root directory not found."
    exit 1
fi

# Create directory structure for .deb package
mkdir -p "$DEB_DIR/DEBIAN"
mkdir -p "$DEB_DIR/usr/bin"
mkdir -p "$DEB_DIR/usr/share/applications"
mkdir -p "$DEB_DIR/usr/share/icons/hicolor/512x512/apps"
mkdir -p "$DEB_DIR/opt/cursor"

# Copy application files
echo "Setting up .deb structure..."
cp -r "$EXTRACT_DIR/squashfs-root/"* "$DEB_DIR/opt/cursor/"

# Create launcher script
cat > "$DEB_DIR/usr/bin/cursor" << EOF
#!/bin/bash
/opt/cursor/AppRun --no-sandbox "\$@"
EOF
chmod +x "$DEB_DIR/usr/bin/cursor"

# Copy icon
echo "Setting up application icon..."
if [ -f "$EXTRACT_DIR/squashfs-root/code.png" ]; then
    cp "$EXTRACT_DIR/squashfs-root/code.png" "$DEB_DIR/usr/share/icons/hicolor/512x512/apps/cursor.png"
elif [ -f "$EXTRACT_DIR/squashfs-root/co.anysphere.cursor.png" ]; then
    cp "$EXTRACT_DIR/squashfs-root/co.anysphere.cursor.png" "$DEB_DIR/usr/share/icons/hicolor/256x256/apps/cursor.png"
else
    # Try to find an icon in the squashfs-root directory
    # Using a safer method that avoids broken pipe errors
    ICON_PATH=""
    while IFS= read -r line; do
        if [ -z "$ICON_PATH" ] && [ -f "$line" ]; then
            ICON_PATH="$line"
            break
        fi
    done < <(find "$EXTRACT_DIR/squashfs-root" -name "*.png" 2>/dev/null || true)
    
    if [ -n "$ICON_PATH" ]; then
        cp "$ICON_PATH" "$DEB_DIR/usr/share/icons/hicolor/512x512/apps/cursor.png"
    else
        echo "Warning: No icon found. Desktop entry may not display correctly."
    fi
fi

# Create desktop file
cat > "$DEB_DIR/usr/share/applications/cursor.desktop" << EOF
[Desktop Entry]
Name=Cursor IDE
Comment=AI-first code editor
Exec=/usr/bin/cursor %U
Terminal=false
Type=Application
Icon=cursor
Categories=Development;IDE;
StartupWMClass=Cursor
EOF

# Create control file
SIZE=$(du -sk "$DEB_DIR/opt/cursor" | cut -f1)
cat > "$DEB_DIR/DEBIAN/control" << EOF
Package: cursor-ide
Version: $VERSION
Section: development
Priority: optional
Architecture: amd64
Installed-Size: $SIZE
Maintainer: Cursor DEB Packager <github@cursor-deb.pkg>
Description: Cursor IDE
 Cursor is an AI-first code editor based on VSCode.
 This package was automatically created from the official AppImage.
 Website: https://cursor.com
EOF

# Create postinst and postrm scripts
cat > "$DEB_DIR/DEBIAN/postinst" << EOF
#!/bin/bash
set -e
chmod +x /opt/cursor/AppRun
update-desktop-database -q || true
EOF

cat > "$DEB_DIR/DEBIAN/postrm" << EOF
#!/bin/bash
set -e
if [ "\$1" = "purge" ]; then
    rm -rf /opt/cursor
fi
update-desktop-database -q || true
EOF

# Make scripts executable
chmod 755 "$DEB_DIR/DEBIAN/postinst" "$DEB_DIR/DEBIAN/postrm"

# Build the .deb package
echo "Building .deb package..."
DEB_NAME="cursor-ide_${VERSION}_amd64.deb"
dpkg-deb --build "$DEB_DIR" "$ORIGINAL_PWD/$DEB_NAME"

# Return to original directory
cd "$ORIGINAL_PWD"

# Cleanup or keep temporary files based on flag
if [ "$KEEP_TEMP" = true ]; then
    echo "Temporary directory kept at: $TEMP_DIR"
else
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
fi

echo "Done! Package created: $ORIGINAL_PWD/$DEB_NAME"
echo "You can install it using: sudo dpkg -i $DEB_NAME"