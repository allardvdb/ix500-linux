# ix500-linux — one-button scanning for Fujitsu ScanSnap scanners

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

    # --- Load existing settings (if any) for use as defaults ---
    ENV_DIR="$HOME/.config/environment.d"
    ENV_FILE="$ENV_DIR/scanner.conf"
    OLD_ENV_FILE="$ENV_DIR/paperless.conf"

    read_var() {
        local var=$1 file=$2
        [ -f "$file" ] && grep -oP "(?<=^${var}=).+" "$file" 2>/dev/null || true
    }

    EXISTING_SCANNER_DEVICE=$(read_var SCANNER_DEVICE  "$ENV_FILE")
    EXISTING_COLOR_DETECT=$(read_var COLOR_DETECT      "$ENV_FILE")
    EXISTING_URL=$(read_var PAPERLESS_URL              "$ENV_FILE")
    EXISTING_TOKEN=$(read_var PAPERLESS_TOKEN          "$ENV_FILE")
    EXISTING_CONSUME_DIR=$(read_var PAPERLESS_CONSUME_DIR "$ENV_FILE")
    # Migration: older installs stored Paperless creds in paperless.conf
    if [ -f "$OLD_ENV_FILE" ]; then
        [ -z "$EXISTING_URL" ]   && EXISTING_URL=$(read_var PAPERLESS_URL  "$OLD_ENV_FILE")
        [ -z "$EXISTING_TOKEN" ] && EXISTING_TOKEN=$(read_var PAPERLESS_TOKEN "$OLD_ENV_FILE")
    fi

    # Derive existing mode from which vars are populated
    EXISTING_MODE=""
    if [ -n "$EXISTING_URL" ] && [ -n "$EXISTING_TOKEN" ]; then
        EXISTING_MODE=paperless-api
    elif [ -n "$EXISTING_CONSUME_DIR" ]; then
        EXISTING_MODE=paperless-folder
    elif [ -f "$ENV_FILE" ] || [ -f "$OLD_ENV_FILE" ]; then
        EXISTING_MODE=local
    fi

    QUICK_INSTALL=false
    if [ -n "$EXISTING_MODE" ]; then
        ok "Existing installation detected ($ENV_FILE)"
        case "$EXISTING_MODE" in
            paperless-api)    echo "    mode:    Paperless-ngx API ($EXISTING_URL)" ;;
            paperless-folder) echo "    mode:    Paperless-ngx folder ($EXISTING_CONSUME_DIR)" ;;
            local)            echo "    mode:    Local OCR" ;;
        esac
        [ -n "$EXISTING_SCANNER_DEVICE" ] && echo "    scanner: $EXISTING_SCANNER_DEVICE"
        [ -n "$EXISTING_COLOR_DETECT" ]   && echo "    color:   $EXISTING_COLOR_DETECT"
        echo
        read -rp "Keep current values? [Y/n]: " KEEP_CURRENT
        echo
        if [ "$KEEP_CURRENT" != "n" ] && [ "$KEEP_CURRENT" != "N" ]; then
            QUICK_INSTALL=true
            MODE="$EXISTING_MODE"
            SCANNER_DEVICE="$EXISTING_SCANNER_DEVICE"
            COLOR_DETECT="${EXISTING_COLOR_DETECT:-true}"
            PAPERLESS_URL="$EXISTING_URL"
            PAPERLESS_TOKEN="$EXISTING_TOKEN"
            PAPERLESS_CONSUME_DIR="$EXISTING_CONSUME_DIR"
        else
            echo "Reconfiguring — press Enter at any prompt to keep the current value."
            echo
        fi
    fi

    # --- Mode selection ---
    if [ "$QUICK_INSTALL" = "false" ]; then
        echo "Select scanning mode:"
        echo "  1) Paperless-ngx API     - Upload scans to Paperless via API (recommended)"
        echo "  2) Paperless-ngx folder  - Write scans to Paperless consume folder"
        echo "  3) Local                 - OCR locally, save to ~/Documents/scanner-inbox/"
        echo

        DEFAULT_MODE_NUM=1
        case "$EXISTING_MODE" in
            paperless-folder) DEFAULT_MODE_NUM=2 ;;
            local)            DEFAULT_MODE_NUM=3 ;;
        esac

        read -rp "Choice [1/2/3] (default: $DEFAULT_MODE_NUM): " MODE_CHOICE
        MODE_CHOICE="${MODE_CHOICE:-$DEFAULT_MODE_NUM}"
        echo

        case "$MODE_CHOICE" in
            2) MODE=paperless-folder ;;
            3) MODE=local ;;
            *) MODE=paperless-api ;;
        esac
    fi

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
    # Stop the polling service first — it holds a tight `scanimage -A` loop on
    # the USB device, which makes `scanimage -L` return nothing. Service will
    # be restarted at the end of install.
    systemctl --user stop scan-button.service 2>/dev/null || true

    if [ "$QUICK_INSTALL" = "false" ]; then
        echo "Detecting scanner..."
        mapfile -t DETECTED_DEVICES < <(scanimage -L 2>/dev/null | grep -oP "fujitsu:ScanSnap [^:]+:\d+" || true)

        SCANNER_DEVICE=""
        # If the previously-saved device is still present, keep it silently.
        if [ -n "$EXISTING_SCANNER_DEVICE" ]; then
            for dev in "${DETECTED_DEVICES[@]}"; do
                if [ "$dev" = "$EXISTING_SCANNER_DEVICE" ]; then
                    SCANNER_DEVICE="$dev"
                    ok "Using saved scanner: $SCANNER_DEVICE"
                    break
                fi
            done
            if [ -z "$SCANNER_DEVICE" ] && [ "${#DETECTED_DEVICES[@]}" -gt 0 ]; then
                warn "Saved scanner ($EXISTING_SCANNER_DEVICE) not detected — re-prompting."
            fi
        fi

        if [ -z "$SCANNER_DEVICE" ]; then
            if [ "${#DETECTED_DEVICES[@]}" -eq 1 ]; then
                ok "Found: ${DETECTED_DEVICES[0]}"
                read -rp "  Use this device? [Y/n]: " USE_DETECTED
                if [ "$USE_DETECTED" = "n" ] || [ "$USE_DETECTED" = "N" ]; then
                    read -rp "  Device string: " SCANNER_DEVICE
                else
                    SCANNER_DEVICE="${DETECTED_DEVICES[0]}"
                fi
            elif [ "${#DETECTED_DEVICES[@]}" -gt 1 ]; then
                ok "Found ${#DETECTED_DEVICES[@]} ScanSnap devices:"
                DEFAULT_DEV_IDX=1
                for i in "${!DETECTED_DEVICES[@]}"; do
                    marker=""
                    if [ "${DETECTED_DEVICES[$i]}" = "$EXISTING_SCANNER_DEVICE" ]; then
                        marker=" (current)"
                        DEFAULT_DEV_IDX=$((i + 1))
                    fi
                    echo "    $((i + 1))) ${DETECTED_DEVICES[$i]}$marker"
                done
                read -rp "  Choose device [1-${#DETECTED_DEVICES[@]}] (default: $DEFAULT_DEV_IDX): " CHOICE
                CHOICE="${CHOICE:-$DEFAULT_DEV_IDX}"
                IDX=$((CHOICE - 1))
                if [ "$IDX" -lt 0 ] || [ "$IDX" -ge "${#DETECTED_DEVICES[@]}" ]; then
                    fail "Invalid choice"
                    exit 1
                fi
                SCANNER_DEVICE="${DETECTED_DEVICES[$IDX]}"
            else
                warn "No ScanSnap detected"
                # Distinguish between "USB not plugged in" and "USB visible but SANE can't talk to it"
                if lsusb 2>/dev/null | grep -qi "ScanSnap\|04c5:"; then
                    warn "USB device is present but SANE can't reach it."
                    warn "The scanner may be wedged — try power-cycling it (unplug/replug USB),"
                    warn "then re-run 'just install'."
                else
                    warn "Is it connected and powered on?"
                fi
                if [ -n "$EXISTING_SCANNER_DEVICE" ]; then
                    read -rp "  Device string [$EXISTING_SCANNER_DEVICE]: " SCANNER_DEVICE
                    SCANNER_DEVICE="${SCANNER_DEVICE:-$EXISTING_SCANNER_DEVICE}"
                else
                    read -rp "  Enter device string manually, or leave blank to auto-detect at scan time: " SCANNER_DEVICE
                fi
            fi
        fi
        echo
    fi

    # --- Color detection preference ---
    if [ "$QUICK_INSTALL" = "false" ]; then
        echo "Auto color detection converts grayscale pages to reduce file size."
        if [ "$EXISTING_COLOR_DETECT" = "false" ]; then
            COLOR_PROMPT="y/N"
            COLOR_DEFAULT=false
        else
            COLOR_PROMPT="Y/n"
            COLOR_DEFAULT=true
        fi
        read -rp "Enable auto color detection? [$COLOR_PROMPT]: " COLOR_CHOICE

        if [ -z "$COLOR_CHOICE" ]; then
            COLOR_DETECT=$COLOR_DEFAULT
        elif [ "$COLOR_CHOICE" = "n" ] || [ "$COLOR_CHOICE" = "N" ]; then
            COLOR_DETECT=false
        else
            COLOR_DETECT=true
        fi
        echo
    fi

    # --- Mode-specific configuration (uses EXISTING_* defaults loaded above) ---
    # Quick-install already populated PAPERLESS_* from EXISTING_*; reset only when reconfiguring.
    if [ "$QUICK_INSTALL" = "false" ]; then
        PAPERLESS_URL=""
        PAPERLESS_TOKEN=""
        PAPERLESS_CONSUME_DIR=""
    fi

    if [ "$MODE" = "paperless-api" ] && [ "$QUICK_INSTALL" = "false" ]; then
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

    elif [ "$MODE" = "paperless-folder" ] && [ "$QUICK_INSTALL" = "false" ]; then
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
    cp "$SCRIPT_DIR/scan" "$SCRIPT_DIR/scan-button-poll" "$HOME/.local/bin/"
    chmod +x "$HOME/.local/bin/scan" "$HOME/.local/bin/scan-button-poll"
    ok "Scripts installed to ~/.local/bin/"

    mkdir -p "$HOME/.config/systemd/user"
    cp "$SCRIPT_DIR/scan-button.service" "$HOME/.config/systemd/user/"
    ok "Systemd service installed"

    echo
    echo "Installing udev rules (requires sudo)..."
    RULES_DEST=/etc/udev/rules.d/99-scansnap.rules
    sed "s/__USERNAME__/$USER/g" "$SCRIPT_DIR/99-scansnap.rules" | sudo tee "$RULES_DEST" >/dev/null
    ok "Udev rules installed to $RULES_DEST (username: $USER)"

    # Clean up rules file from older install that used a model-specific name
    if [ -f /etc/udev/rules.d/99-scansnap-ix500.rules ]; then
        sudo rm /etc/udev/rules.d/99-scansnap-ix500.rules
        ok "Removed old 99-scansnap-ix500.rules"
    fi

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
    rm -f "$HOME/.local/bin/scan" "$HOME/.local/bin/scan-button-poll"
    ok "Scripts removed from ~/.local/bin/"

    # Remove service file
    rm -f "$HOME/.config/systemd/user/scan-button.service"
    ok "Systemd service removed"

    # Remove udev rules (includes older model-specific filename for upgrades)
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
