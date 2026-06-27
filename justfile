# ix500-linux — one-button scanning for ScanSnap iX500

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

    echo "ix500-linux installer"
    echo "====================="
    echo

    # --- Mode selection ---
    echo "Select scanning mode:"
    echo "  1) Paperless-ngx API     - Upload scans to Paperless via API (recommended)"
    echo "  2) Paperless-ngx folder  - Write scans to Paperless consume folder"
    echo "  3) Local                  - OCR locally, save to ~/Documents/scanner-inbox/"
    echo
    read -rp "Choice [1/2/3]: " MODE_CHOICE
    echo

    case "$MODE_CHOICE" in
        2) MODE=paperless-folder ;;
        3) MODE=local ;;
        *) MODE=paperless-api ;;
    esac

    # --- Dependency check ---
    echo "Checking dependencies..."
    DEPS_OK=true

    check_cmd scanimage "sane-backends" || DEPS_OK=false
    check_cmd magick "" || DEPS_OK=false
    check_cmd bc "bc" || DEPS_OK=false

    if [ "$MODE" = "local" ]; then
        check_cmd ocrmypdf "" || DEPS_OK=false
        check_cmd tesseract "" || DEPS_OK=false
        if command -v tesseract &>/dev/null; then
            if tesseract --list-langs 2>/dev/null | grep -q "^nld$"; then
                ok "tesseract language: nld"
            else
                fail "tesseract language: nld missing"
                DEPS_OK=false
            fi
        fi
    fi

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
    DETECTED_DEVICE=$(scanimage -L 2>/dev/null | grep -oP "fujitsu:ScanSnap iX1300:\d+" | head -1 || true)

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

    # --- Color detection preference ---
    echo "Auto color detection converts grayscale pages to reduce file size."
    read -rp "Enable auto color detection? [Y/n]: " COLOR_CHOICE

    if [ "$COLOR_CHOICE" = "n" ] || [ "$COLOR_CHOICE" = "N" ]; then
        COLOR_DETECT=false
    else
        COLOR_DETECT=true
    fi
    echo

    # --- Load existing settings for defaults ---
    ENV_DIR="$HOME/.config/environment.d"
    ENV_FILE="$ENV_DIR/scanner.conf"
    OLD_ENV_FILE="$ENV_DIR/paperless.conf"

    EXISTING_URL=""
    EXISTING_TOKEN=""
    EXISTING_CONSUME_DIR=""

    # Migrate from old paperless.conf if it exists
    if [ -f "$OLD_ENV_FILE" ]; then
        EXISTING_URL=$(grep -oP '(?<=^PAPERLESS_URL=).+' "$OLD_ENV_FILE" 2>/dev/null || true)
        EXISTING_TOKEN=$(grep -oP '(?<=^PAPERLESS_TOKEN=).+' "$OLD_ENV_FILE" 2>/dev/null || true)
    fi
    # Also check existing scanner.conf
    if [ -f "$ENV_FILE" ]; then
        [ -z "$EXISTING_URL" ] && EXISTING_URL=$(grep -oP '(?<=^PAPERLESS_URL=).+' "$ENV_FILE" 2>/dev/null || true)
        [ -z "$EXISTING_TOKEN" ] && EXISTING_TOKEN=$(grep -oP '(?<=^PAPERLESS_TOKEN=).+' "$ENV_FILE" 2>/dev/null || true)
        EXISTING_CONSUME_DIR=$(grep -oP '(?<=^PAPERLESS_CONSUME_DIR=).+' "$ENV_FILE" 2>/dev/null || true)
    fi

    # --- Mode-specific configuration ---
    PAPERLESS_URL=""
    PAPERLESS_TOKEN=""
    PAPERLESS_CONSUME_DIR=""

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

    elif [ "$MODE" = "paperless-folder" ]; then
        echo "Paperless-ngx consume folder configuration:"

        if [ -n "$EXISTING_CONSUME_DIR" ]; then
            read -rp "  Consume folder [$EXISTING_CONSUME_DIR]: " PAPERLESS_CONSUME_DIR
            PAPERLESS_CONSUME_DIR="${PAPERLESS_CONSUME_DIR:-$EXISTING_CONSUME_DIR}"
        else
            read -rp "  Consume folder (e.g. /mnt/paperless-consume): " PAPERLESS_CONSUME_DIR
        fi

        if [ -z "$PAPERLESS_CONSUME_DIR" ]; then
            echo "Error: Consume folder path is required for Paperless folder mode"
            exit 1
        fi

        if [ ! -d "$PAPERLESS_CONSUME_DIR" ]; then
            warn "Directory $PAPERLESS_CONSUME_DIR does not exist (make sure it's available at scan time)"
        else
            ok "Directory exists"
        fi
        echo
    fi

    # --- Write config file ---
    mkdir -p "$ENV_DIR"
    {
        echo "# Scanner configuration for ix500-linux"
        echo "SCANNER_DEVICE=$SCANNER_DEVICE"
        echo "COLOR_DETECT=$COLOR_DETECT"
        if [ "$MODE" = "paperless-api" ]; then
            echo "PAPERLESS_URL=$PAPERLESS_URL"
            echo "PAPERLESS_TOKEN=$PAPERLESS_TOKEN"
        elif [ "$MODE" = "paperless-folder" ]; then
            echo "PAPERLESS_CONSUME_DIR=$PAPERLESS_CONSUME_DIR"
        fi
    } > "$ENV_FILE"
    ok "Saved settings to $ENV_FILE"

    # Remove old paperless.conf if it exists
    if [ -f "$OLD_ENV_FILE" ]; then
        rm "$OLD_ENV_FILE"
        ok "Migrated from paperless.conf → scanner.conf"
    fi
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
        "$SCRIPT_DIR/scan-gui.desktop" > "$HOME/.local/share/applications/scan-gui.desktop"
    ok "GUI desktop launcher installed"

    mkdir -p "$HOME/.config/systemd/user"
    cp "$SCRIPT_DIR/scan-button.service" "$HOME/.config/systemd/user/"
    ok "Systemd service installed"

    echo
    echo "Installing udev rules (requires sudo)..."
    sudo cp "$SCRIPT_DIR/99-scansnap-ix500.rules" /etc/udev/rules.d/
    ok "Udev rules installed"

    # --- Activate ---
    echo
    echo "Activating..."

    # Load all env vars into current systemd session
    ENV_VARS=(SCANNER_DEVICE="$SCANNER_DEVICE" COLOR_DETECT="$COLOR_DETECT")
    if [ "$MODE" = "paperless-api" ]; then
        ENV_VARS+=(PAPERLESS_URL="$PAPERLESS_URL" PAPERLESS_TOKEN="$PAPERLESS_TOKEN")
    elif [ "$MODE" = "paperless-folder" ]; then
        ENV_VARS+=(PAPERLESS_CONSUME_DIR="$PAPERLESS_CONSUME_DIR")
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
        paperless-api)    echo "Scans will be uploaded to Paperless at $PAPERLESS_URL" ;;
        paperless-folder) echo "Scans will be saved to $PAPERLESS_CONSUME_DIR" ;;
        local)            echo "Scans will be saved to ~/Documents/scanner-inbox/" ;;
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
    echo "Local mode:"
    check_cmd ocrmypdf
    check_cmd tesseract
    if command -v tesseract &>/dev/null; then
        if tesseract --list-langs 2>/dev/null | grep -q "^nld$"; then
            ok "tesseract language: nld"
        else
            fail "tesseract language: nld missing"
            ALL_OK=false
        fi
    fi

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

# Launch the scan GUI
gui:
    ./scan-gui

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

    echo "Uninstalling ix500-linux..."
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
    rm -f "$HOME/.local/share/applications/scan-gui.desktop"
    ok "GUI desktop launcher removed"

    # Remove service file
    rm -f "$HOME/.config/systemd/user/scan-button.service"
    ok "Systemd service removed"

    # Remove udev rules
    echo
    echo "Removing udev rules (requires sudo)..."
    sudo rm -f /etc/udev/rules.d/99-scansnap-ix500.rules
    ok "Udev rules removed"

    # Reload
    systemctl --user daemon-reload
    sudo udevadm control --reload-rules
    ok "Systemd and udev reloaded"

    echo
    echo "Uninstalled. Config file ~/.config/environment.d/scanner.conf was kept (delete manually if desired)."
