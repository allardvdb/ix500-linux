# scansnap-linux — one-button scanning for Fujitsu ScanSnap scanners

# List available recipes
default:
    @just --list

# Full interactive install (mode selection, scanner detection, config, activate)
install:
    #!/usr/bin/env bash
    set -e

    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'

    ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
    warn() { echo -e "  ${YELLOW}!${NC} $1"; }
    fail() { echo -e "  ${RED}✗${NC} $1"; }

    MISSING_SYSTEM=()

    check_cmd() {
        local cmd=$1 system_pkg=$2
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd found: $(command -v "$cmd")"
            return 0
        else
            fail "$cmd not found"
            [ -n "$system_pkg" ] && MISSING_SYSTEM+=("$system_pkg")
            return 1
        fi
    }

    echo "scansnap-linux installer"
    echo "========================"
    echo

    # --- Mode selection ---
    echo "Select delivery mode:"
    echo "  1) Paperless-ngx API  - Upload scans to Paperless via API (recommended)"
    echo "  2) Folder             - Write the scanned PDF to a folder"
    echo
    read -rp "Choice [1/2]: " MODE_CHOICE
    echo

    case "$MODE_CHOICE" in
        2) MODE=folder ;;
        *) MODE=paperless-api ;;
    esac

    # --- Dependency check ---
    echo "Checking dependencies..."
    DEPS_OK=true

    check_cmd scanimage "sane-backends" || DEPS_OK=false
    check_cmd magick "" || DEPS_OK=false
    check_cmd bc "bc" || DEPS_OK=false
    check_cmd tesseract "tesseract" || DEPS_OK=false

    if [ "$MODE" = "paperless-api" ]; then
        check_cmd curl "curl" || DEPS_OK=false
    fi

    # Notification dependencies
    check_cmd notify-send "libnotify" || DEPS_OK=false
    check_cmd xdg-open "xdg-utils" || DEPS_OK=false
    check_cmd xdg-terminal-exec "" || DEPS_OK=false

    # GUI dependencies (scan-gui)
    check_cmd python3 "python3" || DEPS_OK=false
    if python3 -c "import gi; gi.require_version('Gtk','4.0'); from gi.repository import Gtk" &>/dev/null; then
        ok "python GTK 4 bindings found"
    else
        fail "python GTK 4 bindings missing"
        MISSING_SYSTEM+=("python3-gobject" "gtk4")
        DEPS_OK=false
    fi
    check_cmd naps2 "naps2" || DEPS_OK=false

    echo

    if [ "$DEPS_OK" = false ]; then
        echo "Missing dependencies. Install them with:"
        [ ${#MISSING_SYSTEM[@]} -gt 0 ] && echo "  sudo dnf install ${MISSING_SYSTEM[*]}"
        echo
        read -rp "Continue anyway? [y/N]: " CONTINUE
        [ "$CONTINUE" != "y" ] && exit 1
        echo
    fi

    # --- Scanner detection ---
    echo "Detecting scanner..."
    DETECTED_DEVICE=$(scanimage -L 2>/dev/null | grep -oP "fujitsu:ScanSnap[^']+" | head -1 || true)

    if [ -n "$DETECTED_DEVICE" ]; then
        ok "Found: $DETECTED_DEVICE"
        read -rp "  Use this device? [Y/n]: " USE_DETECTED
        if [ "$USE_DETECTED" = "n" ] || [ "$USE_DETECTED" = "N" ]; then
            read -rp "  Device string: " SCANNER_DEVICE
        else
            SCANNER_DEVICE="$DETECTED_DEVICE"
        fi
    else
        warn "No scanner detected (is it connected?)"
        read -rp "  Enter device string manually, or leave blank to auto-detect at scan time: " SCANNER_DEVICE
    fi
    echo

    # Color treatment is chosen per scan in the GUI (Color / Grayscale / Auto);
    # the headless hardware-button scan always uses Auto.

    # --- Load existing settings for defaults ---
    ENV_DIR="$HOME/.config/environment.d"
    ENV_FILE="$ENV_DIR/scanner.conf"

    EXISTING_URL=""
    EXISTING_TOKEN=""
    EXISTING_FOLDER_DIR=""

    if [ -f "$ENV_FILE" ]; then
        EXISTING_URL=$(grep -oP '(?<=^PAPERLESS_URL=).+' "$ENV_FILE" 2>/dev/null || true)
        EXISTING_TOKEN=$(grep -oP '(?<=^PAPERLESS_TOKEN=).+' "$ENV_FILE" 2>/dev/null || true)
        EXISTING_FOLDER_DIR=$(grep -oP '(?<=^FOLDER_DIR=).+' "$ENV_FILE" 2>/dev/null || true)
        # Fall back to the pre-rebrand variable name for the folder path.
        [ -z "$EXISTING_FOLDER_DIR" ] && EXISTING_FOLDER_DIR=$(grep -oP '(?<=^PAPERLESS_CONSUME_DIR=).+' "$ENV_FILE" 2>/dev/null || true)
    fi

    # --- Mode-specific configuration ---
    PAPERLESS_URL=""
    PAPERLESS_TOKEN=""
    FOLDER_DIR=""

    if [ "$MODE" = "paperless-api" ]; then
        echo "Paperless-ngx API configuration:"

        if [ -n "$EXISTING_URL" ]; then
            read -rp "  URL [$EXISTING_URL]: " PAPERLESS_URL
            PAPERLESS_URL="${PAPERLESS_URL:-$EXISTING_URL}"
        else
            read -rp "  URL (e.g. https://paperless.example.com): " PAPERLESS_URL
        fi

        if [ -n "$EXISTING_TOKEN" ]; then
            read -rp "  API token [****${EXISTING_TOKEN: -4}]: " PAPERLESS_TOKEN
            PAPERLESS_TOKEN="${PAPERLESS_TOKEN:-$EXISTING_TOKEN}"
        else
            read -rp "  API token: " PAPERLESS_TOKEN
        fi

        if [ -z "$PAPERLESS_URL" ] || [ -z "$PAPERLESS_TOKEN" ]; then
            echo "Error: URL and token are required for Paperless API mode"
            exit 1
        fi

        # Test connection
        echo -n "  Testing connection... "
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 \
            -H "Authorization: Token $PAPERLESS_TOKEN" \
            "$PAPERLESS_URL/api/" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ]; then
            ok "connected"
        else
            warn "could not verify (HTTP $HTTP_CODE) - continuing anyway"
        fi
        echo

    elif [ "$MODE" = "folder" ]; then
        echo "Folder mode configuration:"

        if [ -n "$EXISTING_FOLDER_DIR" ]; then
            read -rp "  Output folder [$EXISTING_FOLDER_DIR]: " FOLDER_DIR
            FOLDER_DIR="${FOLDER_DIR:-$EXISTING_FOLDER_DIR}"
        else
            read -rp "  Output folder (e.g. /mnt/scans): " FOLDER_DIR
        fi

        if [ -z "$FOLDER_DIR" ]; then
            echo "Error: an output folder is required for folder mode"
            exit 1
        fi

        if [ ! -d "$FOLDER_DIR" ]; then
            warn "Directory $FOLDER_DIR does not exist (make sure it's available at scan time)"
        else
            ok "Directory exists"
        fi
        echo
    fi

    # --- Write config file ---
    mkdir -p "$ENV_DIR"
    {
        echo "# Scanner configuration for scansnap-linux"
        echo "SCANNER_DEVICE=$SCANNER_DEVICE"
        if [ "$MODE" = "paperless-api" ]; then
            echo "PAPERLESS_URL=$PAPERLESS_URL"
            echo "PAPERLESS_TOKEN=$PAPERLESS_TOKEN"
        elif [ "$MODE" = "folder" ]; then
            echo "FOLDER_DIR=$FOLDER_DIR"
        fi
    } > "$ENV_FILE"
    ok "Saved settings to $ENV_FILE"
    echo

    # --- Install files ---
    echo "Installing..."
    SCRIPT_DIR="{{justfile_directory()}}"

    mkdir -p "$HOME/.local/bin"
    cp "$SCRIPT_DIR/scan" "$SCRIPT_DIR/scan-button-poll" \
       "$SCRIPT_DIR/scan-lib.sh" "$SCRIPT_DIR/scan-doc" "$SCRIPT_DIR/scan-gui" \
       "$HOME/.local/bin/"
    chmod +x "$HOME/.local/bin/scan" "$HOME/.local/bin/scan-button-poll" \
             "$HOME/.local/bin/scan-doc" "$HOME/.local/bin/scan-gui"
    ok "Scripts installed to ~/.local/bin/"

    # Desktop launcher for the GUI (Exec points at the installed script)
    mkdir -p "$HOME/.local/share/applications"
    sed "s|^Exec=scan-gui|Exec=$HOME/.local/bin/scan-gui|" \
        "$SCRIPT_DIR/com.github.scansnaplinux.ScanGui.desktop" \
        > "$HOME/.local/share/applications/com.github.scansnaplinux.ScanGui.desktop"
    rm -f "$HOME/.local/share/applications/scan-gui.desktop"
    ok "GUI desktop launcher installed"

    mkdir -p "$HOME/.config/systemd/user"
    cp "$SCRIPT_DIR/scan-button.service" "$HOME/.config/systemd/user/"
    ok "Systemd service installed"

    echo
    echo "Installing udev rules (requires sudo)..."
    sudo cp "$SCRIPT_DIR/99-scansnap.rules" /etc/udev/rules.d/
    ok "Udev rules installed"

    # --- Activate ---
    echo
    echo "Activating..."

    # Load all env vars into current systemd session
    ENV_VARS=(SCANNER_DEVICE="$SCANNER_DEVICE")
    if [ "$MODE" = "paperless-api" ]; then
        ENV_VARS+=(PAPERLESS_URL="$PAPERLESS_URL" PAPERLESS_TOKEN="$PAPERLESS_TOKEN")
    elif [ "$MODE" = "folder" ]; then
        ENV_VARS+=(FOLDER_DIR="$FOLDER_DIR")
    fi
    systemctl --user set-environment "${ENV_VARS[@]}"

    systemctl --user daemon-reload
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    ok "Systemd and udev reloaded"

    systemctl --user restart scan-button.service 2>/dev/null && \
        ok "Service started" || \
        warn "Service not started (connect scanner to activate)"

    echo
    echo "Installation complete!"
    case "$MODE" in
        paperless-api) echo "Scans will be uploaded to Paperless at $PAPERLESS_URL" ;;
        folder)        echo "Scans will be saved to $FOLDER_DIR" ;;
    esac

# Check dependencies for all modes
check:
    #!/usr/bin/env bash
    set -e

    GREEN='\033[0;32m'
    RED='\033[0;31m'
    NC='\033[0m'

    ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
    fail() { echo -e "  ${RED}✗${NC} $1"; }
    ALL_OK=true

    check_cmd() {
        if command -v "$1" &>/dev/null; then
            ok "$1 found: $(command -v "$1")"
        else
            fail "$1 not found"
            ALL_OK=false
        fi
    }

    echo "Core dependencies:"
    check_cmd scanimage
    check_cmd magick
    check_cmd bc
    check_cmd tesseract

    echo
    echo "Notification dependencies:"
    check_cmd notify-send
    check_cmd xdg-open
    check_cmd xdg-terminal-exec

    echo
    echo "GUI dependencies:"
    check_cmd python3
    if python3 -c "import gi; gi.require_version('Gtk','4.0'); from gi.repository import Gtk" &>/dev/null; then
        ok "python GTK 4 bindings found"
    else
        fail "python GTK 4 bindings missing"
        ALL_OK=false
    fi
    check_cmd naps2

    echo
    echo "Paperless API mode:"
    check_cmd curl

    echo
    if [ "$ALL_OK" = true ]; then
        echo "All dependencies found."
    else
        echo "Some dependencies are missing (not all may be needed for your mode)."
    fi

# Copy latest scripts to ~/.local/bin and restart the button service.
# Use after code changes; does not touch config, udev, or dependencies.
reload:
    #!/usr/bin/env bash
    set -e
    SCRIPT_DIR="{{justfile_directory()}}"
    BIN="$HOME/.local/bin"

    mkdir -p "$BIN"
    cp "$SCRIPT_DIR/scan" "$SCRIPT_DIR/scan-button-poll" \
       "$SCRIPT_DIR/scan-lib.sh" "$SCRIPT_DIR/scan-doc" "$SCRIPT_DIR/scan-gui" \
       "$BIN/"
    chmod +x "$BIN/scan" "$BIN/scan-button-poll" "$BIN/scan-doc" "$BIN/scan-gui"
    echo "Scripts updated in $BIN"

    if [ -f "$SCRIPT_DIR/scan-button.service" ]; then
        mkdir -p "$HOME/.config/systemd/user"
        cp "$SCRIPT_DIR/scan-button.service" "$HOME/.config/systemd/user/"
        systemctl --user daemon-reload
        echo "systemd service updated"
    fi

    systemctl --user restart scan-button.service 2>/dev/null && \
        echo "scan-button.service restarted" || \
        echo "scan-button.service not running (connect scanner to activate)"

# Launch the scan GUI (pass --dev or --debug to reveal the Raw Tiff corpus output)
gui *args:
    ./scan-gui {{args}}

# Launch the scan GUI with developer options (Raw Tiff output)
gui-dev:
    SCAN_GUI_DEV=1 ./scan-gui --dev

# Show service status
status:
    systemctl --user status scan-button.service

# Follow service logs
logs:
    journalctl --user -u scan-button.service -f

# Restart the service
restart:
    systemctl --user restart scan-button.service

# Remove installed files, service, and udev rules
uninstall:
    #!/usr/bin/env bash
    set -e

    GREEN='\033[0;32m'
    NC='\033[0m'
    ok() { echo -e "  ${GREEN}✓${NC} $1"; }

    echo "Uninstalling scansnap-linux..."
    echo

    # Stop and disable service
    systemctl --user stop scan-button.service 2>/dev/null && ok "Service stopped" || true
    systemctl --user disable scan-button.service 2>/dev/null && ok "Service disabled" || true

    # Remove scripts
    rm -f "$HOME/.local/bin/scan" "$HOME/.local/bin/scan-button-poll" \
          "$HOME/.local/bin/scan-lib.sh" "$HOME/.local/bin/scan-doc" \
          "$HOME/.local/bin/scan-gui"
    ok "Scripts removed from ~/.local/bin/"

    # Remove GUI desktop launcher
    rm -f "$HOME/.local/share/applications/com.github.scansnaplinux.ScanGui.desktop"
    rm -f "$HOME/.local/share/applications/scan-gui.desktop"
    ok "GUI desktop launcher removed"

    # Remove service file
    rm -f "$HOME/.config/systemd/user/scan-button.service"
    ok "Systemd service removed"

    # Remove udev rules
    echo
    echo "Removing udev rules (requires sudo)..."
    sudo rm -f /etc/udev/rules.d/99-scansnap.rules /etc/udev/rules.d/99-scansnap-ix500.rules
    ok "Udev rules removed"

    # Reload
    systemctl --user daemon-reload
    sudo udevadm control --reload-rules
    ok "Systemd and udev reloaded"

    echo
    echo "Uninstalled. Config file ~/.config/environment.d/scanner.conf was kept (delete manually if desired)."
