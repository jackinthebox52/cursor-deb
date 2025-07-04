#!/bin/bash
# Cursor AppImage to DEB Converter
# This script downloads the latest Cursor IDE AppImage and converts it to a .deb package
# Usage: ./auto-convert.sh [-k] [-v] [-q] [-o output_dir] [-c config_file] [--version version_number]

set -euo pipefail

# Default configuration
declare -A CONFIG=(
    [KEEP_TEMP]=false
    [VERBOSE]=false
    [QUIET]=false
    [OUTPUT_DIR]=""
    [CONFIG_FILE]=""
    [SPECIFIC_VERSION]=""
    [USE_RSYNC]=true
)

# URLs and constants
readonly CURSOR_API_URL="https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/cursor-convert-$(date +%s).log"

# Colors for display
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
TEMP_DIR=""
ARCHITECTURE=""
CLEANUP_REGISTERED=false

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    if [[ "${CONFIG[QUIET]}" == "false" ]]; then
        case "$level" in
            "ERROR")
                echo -e "${RED}[ERROR]${NC} $message" >&2
                ;;
            "WARN")
                echo -e "${YELLOW}[WARNING]${NC} $message" >&2
                ;;
            "INFO")
                echo -e "${GREEN}[INFO]${NC} $message" >&2
                ;;
            "DEBUG")
                if [[ "${CONFIG[VERBOSE]}" == "true" ]]; then
                    echo -e "${BLUE}[DEBUG]${NC} $message" >&2
                fi
                ;;
        esac
    fi
}

# Cleanup function
cleanup() {
    local exit_code=$?
    
    if [[ -n "$TEMP_DIR" ]] && [[ -d "$TEMP_DIR" ]]; then
        if [[ "${CONFIG[KEEP_TEMP]}" == "false" ]]; then
            log "INFO" "Cleaning up temporary files..."
            rm -rf "$TEMP_DIR"
        else
            log "INFO" "Temporary files kept at: $TEMP_DIR"
        fi
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Script terminated with error (code: $exit_code)"
        echo -e "${RED}Check log file for details: $LOG_FILE${NC}"
    fi
    
    exit $exit_code
}

# Register cleanup function
register_cleanup() {
    if [[ "$CLEANUP_REGISTERED" == "false" ]]; then
        trap cleanup EXIT INT TERM
        CLEANUP_REGISTERED=true
    fi
}

# Help function
print_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

DESCRIPTION:
    Converts Cursor IDE AppImage to Debian/Ubuntu .deb package

OPTIONS:
    -k, --keep-temp        Keep temporary files after completion
    -v, --verbose          Verbose mode with additional details
    -q, --quiet            Quiet mode (suppress most messages)
    -o, --output DIR       Output directory for .deb package
    -c, --config FILE      Custom configuration file
    --version VERSION      Download specific version
    --no-rsync            Use 'cp' instead of 'rsync' for copying
    -h, --help            Display this help

EXAMPLES:
    $SCRIPT_NAME                        # Standard conversion
    $SCRIPT_NAME -v -k                  # Verbose mode, keep temp files
    $SCRIPT_NAME -o /tmp/packages       # Output to /tmp/packages
    $SCRIPT_NAME --version 0.42.0       # Specific version

FILES:
    Log: $LOG_FILE
EOF
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -k|--keep-temp)
                CONFIG[KEEP_TEMP]=true
                shift
                ;;
            -v|--verbose)
                CONFIG[VERBOSE]=true
                shift
                ;;
            -q|--quiet)
                CONFIG[QUIET]=true
                shift
                ;;
            -o|--output)
                CONFIG[OUTPUT_DIR]="$2"
                shift 2
                ;;
            -c|--config)
                CONFIG[CONFIG_FILE]="$2"
                shift 2
                ;;
            --version)
                CONFIG[SPECIFIC_VERSION]="$2"
                shift 2
                ;;
            --no-rsync)
                CONFIG[USE_RSYNC]=false
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

# Detect architecture
detect_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            ARCHITECTURE="amd64"
            ;;
        aarch64|arm64)
            ARCHITECTURE="arm64"
            ;;
        *)
            log "ERROR" "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
    log "DEBUG" "Detected architecture: $ARCHITECTURE"
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    local deps=("curl" "jq" "dpkg-deb")
    
    # Add rsync if needed
    if [[ "${CONFIG[USE_RSYNC]}" == "true" ]]; then
        deps+=("rsync")
    fi
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "ERROR" "Missing dependencies: ${missing_deps[*]}"
        case "${missing_deps[*]}" in
            *"dpkg-deb"*)
                log "INFO" "Install with: sudo apt-get install dpkg-dev"
                ;;
            *"rsync"*)
                log "INFO" "Install with: sudo apt-get install rsync"
                ;;
        esac
        exit 1
    fi
    
    log "DEBUG" "All dependencies satisfied"
}

# Load configuration file
load_config() {
    if [[ -n "${CONFIG[CONFIG_FILE]}" ]] && [[ -f "${CONFIG[CONFIG_FILE]}" ]]; then
        log "INFO" "Loading configuration from: ${CONFIG[CONFIG_FILE]}"
        source "${CONFIG[CONFIG_FILE]}"
    fi
}

# Setup directories
setup_directories() {
    local original_pwd=$(pwd)
    
    # Output directory
    if [[ -n "${CONFIG[OUTPUT_DIR]}" ]]; then
        mkdir -p "${CONFIG[OUTPUT_DIR]}"
        CONFIG[OUTPUT_DIR]=$(realpath "${CONFIG[OUTPUT_DIR]}")
    else
        CONFIG[OUTPUT_DIR]="$original_pwd"
    fi
    
    # Temporary directory
    TEMP_DIR=$(mktemp -d -t cursor-convert-XXXXXX)
    log "INFO" "Temporary directory created: $TEMP_DIR"
    
    # Subdirectories
    mkdir -p "$TEMP_DIR"/{download,extract,deb}
}

# Download version information
fetch_version_info() {
    log "INFO" "Fetching latest version information..."
    
    local api_response
    if ! api_response=$(curl -s --connect-timeout 30 --max-time 60 "$CURSOR_API_URL"); then
        log "ERROR" "Failed to contact Cursor API"
        log "DEBUG" "API URL: $CURSOR_API_URL"
        exit 1
    fi
    
    log "DEBUG" "API Response: $api_response"
    
    local download_url version
    download_url=$(echo "$api_response" | jq -r '.downloadUrl')
    version=$(echo "$api_response" | jq -r '.version')
    
    if [[ -z "$download_url" ]] || [[ "$download_url" == "null" ]]; then
        log "ERROR" "Failed to get download URL"
        log "DEBUG" "API response was: $api_response"
        exit 1
    fi
    
    # Validate URL format
    if [[ ! "$download_url" =~ ^https?:// ]]; then
        log "ERROR" "Invalid download URL format: $download_url"
        exit 1
    fi
    
    log "DEBUG" "Download URL: $download_url"
    log "DEBUG" "Version: $version"
    
    # Use specific version if provided
    if [[ -n "${CONFIG[SPECIFIC_VERSION]}" ]]; then
        version="${CONFIG[SPECIFIC_VERSION]}"
        log "INFO" "Using specified version: $version"
    fi
    
    echo "$download_url|$version"
}

# Download AppImage
download_appimage() {
    local download_url="$1"
    local version="$2"
    local appimage_path="$TEMP_DIR/download/Cursor-${version}-x86_64.AppImage"
    
    log "INFO" "Downloading Cursor IDE v${version}..."
    log "DEBUG" "Download URL: $download_url"
    log "DEBUG" "Target path: $appimage_path"
    
    # Validate URL before using it
    if [[ ! "$download_url" =~ ^https?:// ]]; then
        log "ERROR" "Invalid download URL: $download_url"
        exit 1
    fi
    
    # Use proper URL quoting and add more verbose error handling
    if ! curl -L --fail --progress-bar --connect-timeout 30 --max-time 1800 \
         -H "User-Agent: Mozilla/5.0 (Linux; x86_64) AppleWebKit/537.36" \
         -o "$appimage_path" "$download_url"; then
        local curl_exit_code=$?
        log "ERROR" "Download failed with curl exit code: $curl_exit_code"
        log "ERROR" "URL that failed: $download_url"
        
        # Provide specific error messages for common curl exit codes
        case $curl_exit_code in
            3) log "ERROR" "URL malformed or contains invalid characters" ;;
            6) log "ERROR" "Couldn't resolve host" ;;
            7) log "ERROR" "Couldn't connect to server" ;;
            22) log "ERROR" "HTTP error response (404, 403, etc.)" ;;
            28) log "ERROR" "Timeout reached" ;;
            *) log "ERROR" "Unknown curl error" ;;
        esac
        exit 1
    fi
    
    if [[ ! -f "$appimage_path" ]]; then
        log "ERROR" "AppImage file not found after download"
        exit 1
    fi
    
    # Verify file is not empty
    if [[ ! -s "$appimage_path" ]]; then
        log "ERROR" "Downloaded file is empty"
        exit 1
    fi
    
    chmod +x "$appimage_path"
    log "INFO" "Download completed successfully"
    echo "$appimage_path"
}

# Extract AppImage
extract_appimage() {
    local appimage_path="$1"
    local extract_dir="$TEMP_DIR/extract"
    
    log "INFO" "Extracting AppImage..."
    
    cd "$extract_dir"
    if ! "$appimage_path" --appimage-extract > /dev/null 2>&1; then
        log "ERROR" "Failed to extract AppImage"
        exit 1
    fi
    
    if [[ ! -d "squashfs-root" ]]; then
        log "ERROR" "squashfs-root directory not found after extraction"
        exit 1
    fi
    
    log "INFO" "Extraction completed successfully"
    echo "$extract_dir/squashfs-root"
}

# Copy files efficiently
copy_files() {
    local source="$1"
    local dest="$2"
    local description="$3"
    
    log "INFO" "Copying files: $description"
    
    if [[ "${CONFIG[USE_RSYNC]}" == "true" ]]; then
        rsync -a --info=progress2 "$source/" "$dest/"
    else
        cp -r "$source/"* "$dest/"
    fi
}

# Find application icon
find_app_icon() {
    local extract_root="$1"
    local icon_candidates=("code.png" "co.anysphere.cursor.png" "cursor.png")
    
    for icon in "${icon_candidates[@]}"; do
        if [[ -f "$extract_root/$icon" ]]; then
            echo "$extract_root/$icon"
            return 0
        fi
    done
    
    # General search for PNG icons
    local found_icon
    found_icon=$(find "$extract_root" -name "*.png" -type f | head -n 1)
    
    if [[ -n "$found_icon" ]]; then
        echo "$found_icon"
        return 0
    fi
    
    return 1
}

# Create .deb package structure
create_deb_structure() {
    local extract_root="$1"
    local version="$2"
    local deb_dir="$TEMP_DIR/deb"
    
    log "INFO" "Creating .deb package structure..."
    
    # Base directories
    mkdir -p "$deb_dir"/{DEBIAN,usr/{bin,share/{applications,icons/hicolor/512x512/apps}},opt/cursor}
    
    # Copy application files
    copy_files "$extract_root" "$deb_dir/opt/cursor" "application files"
    
    # Launch script
    cat > "$deb_dir/usr/bin/cursor" << 'EOF'
#!/bin/bash
exec /opt/cursor/AppRun --no-sandbox "$@"
EOF
    chmod +x "$deb_dir/usr/bin/cursor"
    
    # Copy icon
    if icon_path=$(find_app_icon "$extract_root"); then
        cp "$icon_path" "$deb_dir/usr/share/icons/hicolor/512x512/apps/cursor.png"
        log "DEBUG" "Icon copied from: $icon_path"
    else
        log "WARN" "No icon found. Desktop entry may not display correctly."
    fi
    
    # Desktop file
    cat > "$deb_dir/usr/share/applications/cursor.desktop" << EOF
[Desktop Entry]
Name=Cursor IDE
Comment=AI-first code editor
GenericName=Code Editor
Exec=/usr/bin/cursor %U
Terminal=false
Type=Application
Icon=cursor
Categories=Development;IDE;TextEditor;
StartupWMClass=Cursor
MimeType=text/plain;application/x-cursor-project;
Keywords=editor;development;ide;ai;code;
EOF
    
    # Control file
    local size=$(du -sk "$deb_dir/opt/cursor" | cut -f1)
    cat > "$deb_dir/DEBIAN/control" << EOF
Package: cursor-ide
Version: $version
Section: development
Priority: optional
Architecture: $ARCHITECTURE
Installed-Size: $size
Depends: libc6, libgtk-3-0, libxss1, libasound2, libdrm2, libxkbcommon0, libxcomposite1, libxdamage1, libxrandr2, libgbm1, libxft2, libxinerama1
Recommends: git, nodejs, npm
Maintainer: Cursor DEB Packager <cursor@auto-convert.local>
Homepage: https://cursor.com
Description: Cursor IDE - AI-first code editor
 Cursor is an AI-first code editor based on VSCode.
 It offers advanced AI-powered code assistance features
 for modern development workflows.
 .
 This package was automatically created from the official AppImage.
EOF
    
    # Maintenance scripts
    cat > "$deb_dir/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e
chmod +x /opt/cursor/AppRun
update-desktop-database -q || true
gtk-update-icon-cache -q /usr/share/icons/hicolor || true
EOF
    
    cat > "$deb_dir/DEBIAN/postrm" << 'EOF'
#!/bin/bash
set -e
case "$1" in
    remove|purge)
        update-desktop-database -q || true
        gtk-update-icon-cache -q /usr/share/icons/hicolor || true
        ;;
    purge)
        rm -rf /opt/cursor || true
        ;;
esac
EOF
    
    # Script permissions
    chmod 755 "$deb_dir/DEBIAN/postinst" "$deb_dir/DEBIAN/postrm"
    
    echo "$deb_dir"
}

# Build .deb package
build_deb_package() {
    local deb_dir="$1"
    local version="$2"
    local deb_name="cursor-ide_${version}_${ARCHITECTURE}.deb"
    local output_path="${CONFIG[OUTPUT_DIR]}/$deb_name"
    
    log "INFO" "Building .deb package..."
    
    # Save current directory
    local original_dir=$(pwd)
    
    # Change to the parent directory of deb_dir to use relative paths
    cd "$TEMP_DIR"
    
    log "DEBUG" "Working directory: $(pwd)"
    log "DEBUG" "Building package from: deb"
    log "DEBUG" "Output path: $output_path"
    
    # Simple approach with dpkg-deb
    if ! dpkg-deb --build deb "$output_path" >&2; then
        log "INFO" "Standard dpkg-deb failed, trying with fakeroot..."
        
        # Try with fakeroot
        if command -v fakeroot &> /dev/null; then
            if fakeroot dpkg-deb --build deb "$output_path"; then
                log "INFO" "Package built successfully with fakeroot"
                cd "$original_dir"
                log "INFO" "Package created successfully: $output_path"
                echo "$output_path"
                return 0
            fi
        fi
        
        # Try without compression
        log "INFO" "Trying without compression..."
        if dpkg-deb --build deb "$output_path"; then
            log "INFO" "Package built successfully without compression"
            cd "$original_dir"
            log "INFO" "Package created successfully: $output_path"
            echo "$output_path"
            return 0
        fi
        
        cd "$original_dir"
        log "ERROR" "Failed to build .deb package with all methods"
        exit 1
    fi
    
    # Return to original directory
    cd "$original_dir"
    
    log "INFO" "Package created successfully: $output_path"
    echo "$output_path"
}

# Validate created package
validate_package() {
    local package_path="$1"
    
    log "INFO" "Validating package..."
    
    # Check file existence
    if [[ ! -f "$package_path" ]]; then
        log "ERROR" "Package not found: $package_path"
        exit 1
    fi
    
    # Check integrity
    if ! dpkg-deb --info "$package_path" > /dev/null 2>&1; then
        log "ERROR" "Package is corrupted or invalid"
        exit 1
    fi
    
    # Display information
    local size=$(du -h "$package_path" | cut -f1)
    log "INFO" "Package validated successfully (size: $size)"
    
    if [[ "${CONFIG[VERBOSE]}" == "true" ]]; then
        log "INFO" "Package information:"
        dpkg-deb --info "$package_path"
    fi
}

# Main function
main() {
    local start_time=$(date +%s)
    
    log "INFO" "Starting Cursor AppImage to DEB converter"
    
    # Register cleanup
    register_cleanup
    
    # Parse arguments
    parse_arguments "$@"
    
    # Load configuration
    load_config
    
    # Preliminary checks
    detect_architecture
    check_dependencies
    
    # Setup directories
    setup_directories
    
    # Get version information
    local version_info download_url version
    version_info=$(fetch_version_info)
    IFS='|' read -r download_url version <<< "$version_info"
    
    # Download and extract
    local appimage_path extract_root
    appimage_path=$(download_appimage "$download_url" "$version")
    extract_root=$(extract_appimage "$appimage_path")
    
    # Create package
    local deb_dir package_path
    deb_dir=$(create_deb_structure "$extract_root" "$version")
    package_path=$(build_deb_package "$deb_dir" "$version")
    
    # Validate
    validate_package "$package_path"
    
    # Final statistics
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log "INFO" "Conversion completed successfully in ${duration}s"
    log "INFO" "Package available at: $package_path"
    log "INFO" "Install with: sudo dpkg -i $package_path"
    
    # Show log file details
    if [[ "${CONFIG[VERBOSE]}" == "true" ]]; then
        log "INFO" "Full log available at: $LOG_FILE"
    fi
}

# Entry point
main "$@"