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
# Uses SCANNER_DEVICE when set (fast path). After a USB reconnect the SANE id
# suffix changes; refresh_device() re-runs -L only when a probe fails.
resolve_device() {
    if [ -n "${SCANNER_DEVICE:-}" ]; then
        echo "$SCANNER_DEVICE"
        return 0
    fi
    refresh_device
}

refresh_device() {
    local detected
    detected=$(scanimage -L 2>/dev/null | grep -oP "$SCANSNAP_DEVICE_RE" | head -1)
    if [ -z "$detected" ]; then
        echo "Error: no ScanSnap scanner found. Is it connected and powered on?" >&2
        return 1
    fi
    echo "$detected"
}

# Last scanimage error line, set by scan_batch for callers to surface in the UI.
SCAN_LAST_ERROR=""

# Printed by enhance_pages when no page orientation could be determined, so the
# GUI can offer a NAPS2 fallback. Kept as a stable, greppable sentinel line.
ORIENTATION_UNDETERMINED_MARKER="[scan] orientation-undetermined"

# Map capture failure codes to stderr messages for the GUI/CLI.
# resolve_source already prints specific errors for codes 4 and 5.
report_capture_failure() {
    local rc=$1
    case "$rc" in
        1) echo "Scanner busy — could not acquire the scanner lock" >&2 ;;
        2) echo "No document detected — feeder and card slot are both empty" >&2 ;;
        3)
            if [ -n "$SCAN_LAST_ERROR" ]; then
                echo "Scanner error: $SCAN_LAST_ERROR" >&2
            else
                echo "Scanner error — could not capture pages" >&2
            fi
            ;;
        4|5) ;;
        *) echo "Scan failed" >&2 ;;
    esac
}

# Echo the SANE source string for whichever input holds a document.
#   Top ADF feeder (sensor page-loaded)  -> "ADF Duplex"
#   Front/return slot (sensor card-loaded) -> "Card Duplex"
# Return codes: 0 with the source on stdout; 2 when neither is loaded (silent);
# 4 when the device cannot be queried; 5 when both inputs are loaded.
resolve_source() {
    local device=$1
    local options feeder front
    options=$(scanimage --device "$device" -A 2>&1) || true
    if echo "$options" | grep -qiE 'open of device .* failed|invalid argument'; then
        echo "Error: scanner disconnected or device ID changed — reconnect the USB cable" >&2
        return 4
    fi
    if [ -z "$options" ] || ! echo "$options" | grep -q 'page-loaded'; then
        echo "Error: scanner not available (busy or disconnected?)" >&2
        return 4
    fi
    feeder=$(echo "$options" | grep -oP '(?<=--page-loaded\[=\(yes\|no\)\] \[)\w+')
    front=$(echo "$options" | grep -oP '(?<=--card-loaded\[=\(yes\|no\)\] \[)\w+')

    if [ "$feeder" = "yes" ] && [ "$front" = "yes" ]; then
        echo "Error: documents loaded in both the feeder and the front slot - use only one." >&2
        return 5
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
    local source rs refreshed tried_refresh=0

    while true; do
        source=$(resolve_source "$device")
        rs=$?
        case "$rs" in
            0) break ;;
            2|5) return "$rs" ;;
            4)
                if [ "$tried_refresh" -eq 0 ] && refreshed=$(refresh_device 2>/dev/null); then
                    tried_refresh=1
                    device=$refreshed
                    continue
                fi
                return 4
                ;;
            *) return 4 ;;
        esac
    done

    echo "Scanning (duplex, color, A4) from $source..."
    scan_batch "$device" "$source" "$prefix" || return 3
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
# Returns scanimage's exit code so callers can tell I/O errors from an empty input.
scan_batch() {
    local device=$1 source=$2 prefix=$3
    local output rc
    output=$(scanimage --device "$device" \
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
        2>&1) || rc=$?
    rc=${rc:-0}
    SCAN_LAST_ERROR=$(printf '%s\n' "$output" \
        | grep -iE 'scanimage:.*(error|cannot|failed)' \
        | tail -1 \
        | sed 's/^scanimage:[[:space:]]*//')
    # Fujitsu batch mode scans until the feeder is empty; the final sane_start
    # after the last page often reports "out of documents" even though the batch
    # succeeded. Treat that as success when output files were written.
    if [ "$rc" -ne 0 ]; then
        shopt -s nullglob
        local pages=("${prefix}"-*.tiff)
        if [ ${#pages[@]} -gt 0 ] \
                && printf '%s\n' "$output" | grep -qiE 'out of documents|no documents'; then
            rc=0
            SCAN_LAST_ERROR=""
        fi
    fi
    if [ -n "$output" ]; then
        printf '%s\n' "$output" | grep -v "^$" || true
    fi
    return "$rc"
}

# Apply the chosen color treatment to the pages. COLOR_MODE selects:
#   color - keep every page in color (no conversion)
#   gray  - force every page to grayscale
#   auto  - convert near-monochrome pages to grayscale per page
apply_color_mode() {
    local tiffs=("$@")
    local mode="${COLOR_MODE:-color}"

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
# Only trust the result when tesseract's orientation confidence clears
# ROTATE_MIN_CONFIDENCE. On sparse pages (logos, decorative cards, calligraphy)
# OSD guesses with near-zero confidence and would otherwise flip the page the
# wrong way — that is what turned the "Thank You" tag upside down in testing.
# Empty output means "no trustworthy reading" so the document-level planner can
# borrow orientation from a sibling page instead.
_gated_page_rotation() {
    command -v tesseract >/dev/null 2>&1 || return 0
    local osd rotate confidence min="${ROTATE_MIN_CONFIDENCE:-2.0}"
    osd=$(tesseract "$1" stdout --psm 0 2>/dev/null) || return 0
    rotate=$(echo "$osd" | grep -i 'Rotate:' | grep -oE '[0-9]+' | head -1)
    confidence=$(echo "$osd" | grep -i 'Orientation confidence:' | grep -oE '[0-9.]+' | head -1)
    [ -n "$rotate" ] && [ -n "$confidence" ] || return 0
    if (( $(echo "$confidence < $min" | bc -l) )); then
        return 0
    fi
    echo "$rotate"
}

# Decide a rotation for every page and echo one value per line (blank = leave
# the page as-is). Pages tesseract can read keep their own orientation. Pages it
# cannot read borrow orientation from a confident page elsewhere in the same
# document. ScanSnap duplex captures alternate by 180 degrees per sheet side, so
# the borrowed value is offset by the page's parity (verified across the corpus:
# a card's blank logo side and its text side need opposite rotations). When no
# page in the document is readable, none are rotated.
_resolve_rotation_plan() {
    local tiffs=("$@")
    local -a own=()
    local i rot base=""

    for ((i = 0; i < ${#tiffs[@]}; i++)); do
        rot=$(_gated_page_rotation "${tiffs[$i]}")
        own+=("$rot")
        if [ -z "$base" ] && [ -n "$rot" ]; then
            base=$(( (rot + 180 * (i % 2)) % 360 ))
        fi
    done

    for ((i = 0; i < ${#tiffs[@]}; i++)); do
        if [ -n "${own[$i]}" ]; then
            echo "${own[$i]}"
        elif [ -n "$base" ]; then
            echo $(( (base + 180 * (i % 2)) % 360 ))
        else
            echo ""
        fi
    done
}

# Pixels to shave off scanner-bed grey before optional fringe removal.
_crop_shave_pixels() {
    if [ -n "${AUTO_CROP_SHAVE_PX:-}" ]; then
        echo "$AUTO_CROP_SHAVE_PX"
        return
    fi
    local shave_mm="${AUTO_CROP_SHAVE_MM:-1.5}"
    echo "scale=0; $RESOLUTION * $shave_mm / 25.4 + 0.5" | bc
}

# Trim uniform border down to the sheet edge, but never remove more than
# CROP_MAX_PCT per side. The driver (--swcrop) has usually already cropped to
# the paper, so this mainly cleans up the white that deskew adds at the corners;
# the per-side cap stops it from eating into a page that legitimately has wide
# uniform margins (a centered logo, a calligraphy sheet) down to the ink.
#
# NOTE: a tighter, artifact-free crop (e.g. removing the diagonal bed wedge seen
# on small angled cards) needs --swcrop disabled at capture so we can detect the
# sheet ourselves. That is a capture-level change, tracked as a future step.
_edge_crop() {
    local tiff=$1
    local fuzz="${AUTO_CROP_FUZZ:-15%}"
    local max_pct="${CROP_MAX_PCT:-6}"
    local W H box bw bh bx by

    W=$(magick "$tiff" -format '%w' info:)
    H=$(magick "$tiff" -format '%h' info:)
    box=$(magick "$tiff" -fuzz "$fuzz" -format "%@" info:) || return 0
    bw=${box%%x*}; box=${box#*x}
    bh=${box%%+*}; box=${box#*+}
    bx=${box%%+*}; by=${box#*+}
    [ -n "$bw" ] && [ -n "$bh" ] && [ -n "$bx" ] && [ -n "$by" ] || return 0

    local cap_w=$(( W * max_pct / 100 )) cap_h=$(( H * max_pct / 100 ))
    local left=$bx top=$by right=$(( W - bx - bw )) bottom=$(( H - by - bh ))
    if (( left > cap_w )); then left=$cap_w; fi
    if (( right > cap_w )); then right=$cap_w; fi
    if (( top > cap_h )); then top=$cap_h; fi
    if (( bottom > cap_h )); then bottom=$cap_h; fi

    local cw=$(( W - left - right )) ch=$(( H - top - bottom ))
    if (( cw <= 0 || ch <= 0 )); then return 0; fi
    if (( left == 0 && top == 0 && right == 0 && bottom == 0 )); then return 0; fi
    magick "$tiff" -crop "${cw}x${ch}+${left}+${top}" +repage "$tiff"
}

# Crop a page in place according to AUTO_CROP_MODE:
#   edge  - bounded trim to the sheet edge (default, card-safe)
#   shave - remove a fixed fringe only
#   trim  - unbounded content trim (legacy; over-crops low-contrast pages)
#   none  - trust the driver crop, do nothing
_apply_page_crop() {
    local tiff=$1
    local tmp="${tiff}.enhancing"
    local mode="${AUTO_CROP_MODE:-edge}"
    local shave_px fuzz

    [ "${AUTO_CROP:-true}" = "true" ] || return 0

    case "$mode" in
        none) return 0 ;;
        edge) _edge_crop "$tiff" ;;
        shave)
            shave_px=$(_crop_shave_pixels)
            magick "$tiff" -shave "${shave_px}x${shave_px}" +repage "$tmp"
            mv "$tmp" "$tiff"
            ;;
        trim)
            shave_px=$(_crop_shave_pixels)
            fuzz="${AUTO_CROP_FUZZ:-12%}"
            magick "$tiff" \
                -shave "${shave_px}x${shave_px}" \
                -bordercolor white -border 1 \
                -fuzz "$fuzz" -trim +repage -shave 1x1 \
                "$tmp"
            mv "$tmp" "$tiff"
            ;;
        *)
            echo "Unknown AUTO_CROP_MODE: $mode (expected none|edge|shave|trim)" >&2
            return 1
            ;;
    esac
}

# Straighten small scan skew, but only when the text skew agrees with the
# paper-edge skew. ImageMagick's -deskew reads the angle from dark marks on a
# light page, so artistic or sparse content (e.g. calligraphy written at a
# slight slant on a perfectly straight card) fools it into rotating a straight
# sheet — that was the doc-6 skew. We measure the angle two ways: from the
# content (-deskew) and from a thresholded paper-edge mask. When they disagree,
# the content is slanted relative to the sheet, so we trust the sheet and skip.
_maybe_deskew() {
    local tiff=$1
    [ "${AUTO_DESKEW:-true}" = "true" ] || return 0
    local tmp="${tiff}.deskew" text sheet
    text=$(magick "$tiff" -deskew 40% -format "%[deskew:angle]" info: 2>/dev/null)
    [ -n "$text" ] || return 0
    sheet=$(magick "$tiff" -colorspace Gray -threshold "${DESKEW_THRESHOLD:-82%}" \
        -negate -deskew 40% -format "%[deskew:angle]" info: 2>/dev/null)
    if [ -n "$sheet" ] && ! awk -v t="$text" -v s="$sheet" -v m="${DESKEW_AGREE_DEG:-0.8}" \
            'BEGIN { d = t - s; if (d < 0) d = -d; exit !(d <= m) }'; then
        return 0
    fi
    magick "$tiff" -deskew 40% -background white +repage "$tmp"
    mv "$tmp" "$tiff"
}

# Rotate (to the planner's value), deskew, and crop a single page in place.
# The rotation is decided per document by _resolve_rotation_plan and passed in;
# an empty value means leave the page's orientation untouched.
_enhance_page() {
    local tiff=$1
    local rotate=${2:-}
    local tmp="${tiff}.enhancing"

    if [ "${AUTO_ROTATE:-true}" = "true" ]; then
        case "$rotate" in
            90|180|270)
                magick "$tiff" -background white -rotate "$rotate" +repage "$tmp"
                mv "$tmp" "$tiff"
                ;;
        esac
    fi

    _maybe_deskew "$tiff"
    _apply_page_crop "$tiff"
}

# Pull the paper toward white and deepen the ink (levels + gamma). This is the
# 291f61a tone: a plain per-channel level stretch plus midtone gamma. An earlier
# saturation pull-back (-modulate) was tried to tame colored paper but it left
# the photo-heavy recipe cards looking washed out, so it was removed.
_tone_page() {
    local tiff=$1
    [ "${TONE:-true}" = true ] || return 0
    local black_pct="${TONE_BLACK_PCT:-6}"
    local white_pct="${TONE_WHITE_PCT:-90}"
    local gamma="${TONE_GAMMA:-1.2}"
    magick "$tiff" \
        -channel RGB -level "${black_pct}%,${white_pct}%" +channel \
        -gamma "$gamma" \
        "$tiff"
}

# Brightness / white-balance pass tuned against the Windows ScanSnap corpus.
tone_pages() {
    local tiffs=("$@")
    [ "${TONE:-true}" = true ] || return 0
    echo "Toning pages..."
    local tiff
    for tiff in "${tiffs[@]}"; do
        _tone_page "$tiff"
    done
}

# Enhance a list of pages, unless rotate, deskew, and crop are all disabled.
# Rotation is decided once for the whole document so unreadable pages can borrow
# orientation from readable siblings (see _resolve_rotation_plan).
enhance_pages() {
    local tiffs=("$@")
    if [ "${AUTO_CROP:-true}" != "true" ] \
            && [ "${AUTO_ROTATE:-true}" != "true" ] \
            && [ "${AUTO_DESKEW:-true}" != "true" ]; then
        return
    fi
    echo "Enhancing pages..."

    local -a rotations=()
    if [ "${AUTO_ROTATE:-true}" = "true" ]; then
        mapfile -t rotations < <(_resolve_rotation_plan "${tiffs[@]}")
    fi

    # Tell callers (the GUI) when no page could be oriented, so they can offer
    # to route the document to NAPS2 for a manual look instead.
    local determined=0 r
    for r in "${rotations[@]}"; do
        [ -n "$r" ] && { determined=1; break; }
    done
    if [ "${AUTO_ROTATE:-true}" = "true" ] && [ "$determined" -eq 0 ]; then
        echo "$ORIENTATION_UNDETERMINED_MARKER"
    fi

    local i
    for ((i = 0; i < ${#tiffs[@]}; i++)); do
        _enhance_page "${tiffs[$i]}" "${rotations[$i]:-}"
    done
}

# Combine TIFF pages into a single PDF with tuned JPEG compression.
build_pdf() {
    local outpdf=$1
    shift
    local quality="${JPEG_QUALITY:-75}"
    local sampling="${JPEG_SAMPLING:-4:2:0}"
    local density="${PDF_DENSITY:-300}"
    magick "$@" \
        -units PixelsPerInch -density "$density" \
        -compress JPEG -quality "$quality" -sampling-factor "$sampling" \
        "$outpdf"
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

# Save the captured pages as raw TIFFs (developer-only output).
#
# Used by the GUI's hidden "Raw Tiff" mode (`scan-gui --dev`) to build the
# tuning corpus: pages captured with `--raw` skip color/crop/enhance, so the
# files written here are straight scanner output. They drop directly into a
# corpus case's raw/ directory. Destination is RAW_TIFF_DIR (default
# ~/Documents/scanner-raw), one subfolder per document.
deliver_raw_tiff() {
    local name=$1
    shift
    local tiffs=("$@")
    local outdir="${RAW_TIFF_DIR:-$HOME/Documents/scanner-raw}/$name"
    mkdir -p "$outdir"

    local index=1 tiff
    for tiff in "${tiffs[@]}"; do
        cp "$tiff" "$(printf '%s/page-%04d.tiff' "$outdir" "$index")"
        index=$((index + 1))
    done

    echo "Saved ${#tiffs[@]} raw page(s) to $outdir"
    command -v xdg-open >/dev/null 2>&1 && \
        setsid xdg-open "$outdir" >/dev/null 2>&1 < /dev/null &
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
