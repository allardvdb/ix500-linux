#!/bin/bash
# scan-lib.sh - Shared scanning routines for Fujitsu ScanSnap scanners.
#
# Sourced by `scan` (one-button workflow) and `scan-doc` (GUI workflow).
# Each function does one focused thing: find the scanner, capture a batch,
# clean up pages, build a PDF, or deliver the result. Callers wire them
# together; this file holds no top-level logic.

# Page geometry and capture quality (shared by every scan).
BLEED_MM=10
PAGE_WIDTH_MM=$((210 + BLEED_MM))
PAGE_HEIGHT_MM=$((297 + BLEED_MM))
RESOLUTION="${SCAN_RESOLUTION:-300}"

# Serialize access to the SANE device. The button poller and scan scripts share
# this lock so scanimage calls never fight each other.
SCAN_LOCK="/run/user/$(id -u)/scansnap.lock"

# Run a command with exclusive scanner access. Waits up to SCAN_LOCK_TIMEOUT
# seconds (default 120) before giving up. Uses a scoped file descriptor so
# shell functions work and the lock fd is not left open after the command.
with_scan_lock() {
    local timeout=${SCAN_LOCK_TIMEOUT:-120}
    mkdir -p "$(dirname "$SCAN_LOCK")"
    touch "$SCAN_LOCK" 2>/dev/null || true
    { flock -w "$timeout" 200 || return 1; "$@"; } 200>"$SCAN_LOCK"
}

# SANE device pattern matching any Fujitsu ScanSnap model (iX500, iX1300,
# iX1600, S1500, ...). Used by every script that looks the scanner up.
SCANSNAP_DEVICE_RE="fujitsu:ScanSnap[^']+"

# Echo the SANE device string, or exit 1 if no scanner is found.
resolve_device() {
    local device
    if [ -n "$SCANNER_DEVICE" ]; then
        device="$SCANNER_DEVICE"
    else
        device=$(scanimage -L 2>/dev/null | grep -oP "$SCANSNAP_DEVICE_RE" | head -1)
    fi
    if [ -z "$device" ]; then
        echo "Error: no ScanSnap scanner found. Is it connected and powered on?" >&2
        return 1
    fi
    echo "$device"
}

# Echo the SANE source string for whichever input holds a document.
#   Top ADF feeder (sensor page-loaded)  -> "ADF Duplex"
#   Front/return slot (sensor card-loaded) -> "Card Duplex"
# Return codes: 0 with the source on stdout; 1 when both inputs are loaded
# (an error is printed); 2 when neither is loaded (silent, so callers can
# emit their own "feeder empty" message).
resolve_source() {
    local device=$1
    local options feeder front
    options=$(scanimage --device "$device" -A 2>&1) || true
    if [ -z "$options" ] || ! echo "$options" | grep -q 'page-loaded'; then
        echo "Error: scanner not available (busy or disconnected?)" >&2
        return 1
    fi
    feeder=$(echo "$options" | grep -oP '(?<=--page-loaded\[=\(yes\|no\)\] \[)\w+')
    front=$(echo "$options" | grep -oP '(?<=--card-loaded\[=\(yes\|no\)\] \[)\w+')

    if [ "$feeder" = "yes" ] && [ "$front" = "yes" ]; then
        echo "Error: documents loaded in both the feeder and the front slot - use only one." >&2
        return 1
    elif [ "$feeder" = "yes" ]; then
        echo "ADF Duplex"
    elif [ "$front" = "yes" ]; then
        echo "Card Duplex"
    else
        return 2
    fi
}

# Detect which input holds a document and capture one batch into "<prefix>-NNNN.tiff"
# files. Holds the scan lock for the whole SANE session.
scan_pages() {
    local device=$1 prefix=$2
    local source
    source=$(resolve_source "$device") || return $?
    echo "Scanning (duplex, color, A4) from $source..."
    scan_batch "$device" "$source" "$prefix"
}

# Echo which delivery mode the environment selects:
#   paperless  - upload to Paperless-ngx (PAPERLESS_URL + PAPERLESS_TOKEN)
#   folder     - write the PDF to a folder (FOLDER_DIR)
#   none       - nothing configured
delivery_mode() {
    if [ -n "$PAPERLESS_URL" ] && [ -n "$PAPERLESS_TOKEN" ]; then
        echo paperless
    elif [ -n "$FOLDER_DIR" ]; then
        echo folder
    else
        echo none
    fi
}

# Capture one duplex batch into "<prefix>-NNNN.tiff" files from the given
# SANE source ("ADF Duplex" for the feeder, "Card Duplex" for the front slot).
scan_batch() {
    local device=$1 source=$2 prefix=$3
    scanimage --device "$device" \
        --format=tiff \
        --resolution "$RESOLUTION" \
        --mode Color \
        --source "$source" \
        --page-width "$PAGE_WIDTH_MM" \
        --page-height "$PAGE_HEIGHT_MM" \
        --swskip 20 \
        --swcrop=yes \
        --swdespeck 2 \
        --overscan On \
        --prepick On \
        --buffermode On \
        --batch="${prefix}-%04d.tiff" \
        --batch-count=-1 \
        2>&1 | grep -v "^$" || true
}

# Apply the chosen color treatment to the pages. COLOR_MODE selects:
#   color - keep every page in color (no conversion)
#   gray  - force every page to grayscale
#   auto  - convert near-monochrome pages to grayscale per page (default)
apply_color_mode() {
    local tiffs=("$@")
    local mode="${COLOR_MODE:-auto}"

    case "$mode" in
        color)
            echo "Color mode: keeping pages in color."
            ;;
        gray)
            echo "Color mode: converting all pages to grayscale..."
            local tiff
            for tiff in "${tiffs[@]}"; do
                magick "$tiff" -colorspace Gray "$tiff"
            done
            ;;
        *)
            _detect_color_per_page "${tiffs[@]}"
            ;;
    esac
}

# Auto mode: grayscale any page whose color saturation is below threshold.
_detect_color_per_page() {
    local tiffs=("$@")
    echo "Detecting color..."
    local color_pages=0 gray_pages=0 tiff saturation
    for tiff in "${tiffs[@]}"; do
        saturation=$(magick "$tiff" -colorspace HSL -channel G -separate +channel \
            -format "%[fx:mean*100]" info: 2>/dev/null || echo "0")
        if (( $(echo "$saturation < 10" | bc -l) )); then
            magick "$tiff" -colorspace Gray "$tiff"
            gray_pages=$((gray_pages + 1))
        else
            color_pages=$((color_pages + 1))
        fi
    done

    if [ "$gray_pages" -gt 0 ] && [ "$color_pages" -gt 0 ]; then
        echo "Mixed: $color_pages color, $gray_pages grayscale"
    elif [ "$gray_pages" -gt 0 ]; then
        echo "Converted to grayscale"
    else
        echo "Color detected"
    fi
}

# Detect the upright orientation of a page via tesseract (0/90/180/270).
# Used for every delivery mode, not just Paperless or folder.
_page_rotation() {
    command -v tesseract >/dev/null 2>&1 || return 0
    tesseract "$1" stdout --psm 0 2>/dev/null \
        | grep -i 'Rotate:' \
        | grep -oE '[0-9]+' \
        | head -1
}

# Pixels to shave off scanner-bed grey before white-border trimming.
_crop_shave_pixels() {
    if [ -n "${AUTO_CROP_SHAVE_PX:-}" ]; then
        echo "$AUTO_CROP_SHAVE_PX"
        return
    fi
    local shave_mm="${AUTO_CROP_SHAVE_MM:-1.5}"
    echo "scale=0; $RESOLUTION * $shave_mm / 25.4 + 0.5" | bc
}

# Auto-rotate, deskew, and crop a single page in place.
_enhance_page() {
    local tiff=$1
    local tmp="${tiff}.enhancing"
    local fuzz="${AUTO_CROP_FUZZ:-10%}"
    local shave_px
    shave_px=$(_crop_shave_pixels)

    if [ "${AUTO_ROTATE:-true}" = "true" ]; then
        local rotate
        local -a rotate_args=()
        rotate=$(_page_rotation "$tiff")
        case "$rotate" in
            90|180|270) rotate_args+=(-rotate "$rotate") ;;
        esac
        rotate_args+=(-deskew 40% -background white)
        magick "$tiff" "${rotate_args[@]}" "$tmp"
        mv "$tmp" "$tiff"
    elif [ "${AUTO_DESKEW:-true}" = "true" ]; then
        magick "$tiff" -deskew 40% -background white "$tmp"
        mv "$tmp" "$tiff"
    fi

    if [ "${AUTO_CROP:-true}" = "true" ]; then
        magick "$tiff" \
            -shave "${shave_px}x${shave_px}" \
            -bordercolor white -border 1 \
            -fuzz "$fuzz" -trim +repage -shave 1x1 \
            "$tmp"
        mv "$tmp" "$tiff"
    fi
}

# Enhance a list of pages, unless rotate, deskew, and crop are all disabled.
enhance_pages() {
    local tiffs=("$@")
    if [ "${AUTO_CROP:-true}" != "true" ] \
            && [ "${AUTO_ROTATE:-true}" != "true" ] \
            && [ "${AUTO_DESKEW:-true}" != "true" ]; then
        return
    fi
    echo "Enhancing pages..."
    local tiff
    for tiff in "${tiffs[@]}"; do
        _enhance_page "$tiff"
    done
}

# Combine TIFF pages into a single PDF.
build_pdf() {
    local outpdf=$1
    shift
    magick "$@" "$outpdf"
}

# Deliver processed pages via the configured mode: upload to Paperless-ngx
# or write the PDF to a folder.
deliver_document() {
    local name=$1
    shift
    local tiffs=("$@")
    local pagecount=${#tiffs[@]}
    local mode
    mode=$(delivery_mode)

    case "$mode" in
        paperless) _deliver_paperless_api "$name" "$pagecount" "${tiffs[@]}" ;;
        folder)    _deliver_folder "$name" "$pagecount" "${tiffs[@]}" ;;
        none)
            echo "Error: no delivery configured. Set PAPERLESS_URL+PAPERLESS_TOKEN or FOLDER_DIR." >&2
            return 1
            ;;
    esac
}

_deliver_paperless_api() {
    local name=$1 pagecount=$2
    shift 2
    local workdir pdf response http_code filesize
    workdir=$(mktemp -d)
    pdf="$workdir/$name.pdf"

    echo "Creating PDF..."
    build_pdf "$pdf" "$@"

    echo "Uploading to Paperless..."
    response=$(curl -sk -w "\n%{http_code}" \
        -H "Authorization: Token $PAPERLESS_TOKEN" \
        -F "document=@$pdf" \
        -F "created=$(date '+%Y-%m-%d')" \
        "$PAPERLESS_URL/api/documents/post_document/")

    http_code=$(echo "$response" | tail -1)
    if [ "$http_code" -eq 200 ]; then
        filesize=$(ls -lh "$pdf" | awk '{print $5}')
        echo "Done: $name.pdf ($pagecount pages, $filesize) uploaded to Paperless"
        rm -rf "$workdir"
    else
        echo "Upload failed (HTTP $http_code)" >&2
        local body
        body=$(echo "$response" | sed '$d')
        [ -n "$body" ] && echo "$body" >&2
        rm -rf "$workdir"
        return 1
    fi
}

_deliver_folder() {
    local name=$1 pagecount=$2
    shift 2
    mkdir -p "$FOLDER_DIR"
    local outfile="$FOLDER_DIR/$name.pdf"

    echo "Creating PDF..."
    build_pdf "$outfile" "$@"

    local filesize
    filesize=$(ls -lh "$outfile" | awk '{print $5}')
    echo "Done: $outfile ($pagecount pages, $filesize)"
}

# Build a PDF and hand it to the NAPS2 desktop app for review/editing.
# The PDF is kept in ~/Documents/scanner-inbox/ so NAPS2 has a stable file.
deliver_naps2() {
    local name=$1
    shift
    local tiffs=("$@")
    local pagecount=${#tiffs[@]}
    local outdir="$HOME/Documents/scanner-inbox"
    local pdf="$outdir/$name.pdf"
    mkdir -p "$outdir"

    echo "Creating PDF..."
    build_pdf "$pdf" "${tiffs[@]}"

    local filesize
    filesize=$(ls -lh "$pdf" | awk '{print $5}')
    echo "Opening in NAPS2: $pdf ($pagecount pages, $filesize)"
    setsid naps2 "$pdf" >/dev/null 2>&1 < /dev/null &
}
