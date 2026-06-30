# Scan pipeline knobs

Every tunable parameter in the scan → post-process → PDF path. All live-pipeline
knobs are environment variables read by `scan-lib.sh` (sourced by `scan`,
`scan-doc`, and the GUI).

Set them for one run:

```bash
TONE_GAMMA=1.1 scan
AUTO_CROP_MODE=none scan-doc capture /tmp/work --color color
```

Or export them in your shell / systemd unit / `just` recipe for a session.

---

## Quick reference (live pipeline)

| Knob | Default | Section |
|---|---|---|
| `SCAN_RESOLUTION` | `300` | [Capture](#capture) |
| `SCANNER_DEVICE` | *(auto)* | [Capture](#capture) |
| `SCAN_LOCK_TIMEOUT` | `120` | [Capture](#capture) |
| `COLOR_MODE` | `color` | [Color](#color) |
| `AUTO_ROTATE` | `true` | [Orientation](#orientation) |
| `ROTATE_MIN_CONFIDENCE` | `2.0` | [Orientation](#orientation) |
| `AUTO_DESKEW` | `true` | [Deskew](#deskew) |
| `DESKEW_THRESHOLD` | `82%` | [Deskew](#deskew) |
| `DESKEW_AGREE_DEG` | `0.8` | [Deskew](#deskew) |
| `AUTO_CROP` | `true` | [Crop](#crop) |
| `AUTO_CROP_MODE` | `edge` | [Crop](#crop) |
| `AUTO_CROP_FUZZ` | `15%` (`12%` in `trim` mode) | [Crop](#crop) |
| `CROP_MAX_PCT` | `6` | [Crop](#crop) |
| `AUTO_CROP_SHAVE_MM` | `1.5` | [Crop](#crop) |
| `AUTO_CROP_SHAVE_PX` | *(derived)* | [Crop](#crop) |
| `TONE` | `true` | [Tone](#tone) |
| `TONE_BLACK_PCT` | `6` | [Tone](#tone) |
| `TONE_WHITE_PCT` | `90` | [Tone](#tone) |
| `TONE_GAMMA` | `1.2` | [Tone](#tone) |
| `JPEG_QUALITY` | `75` | [PDF output](#pdf-output) |
| `JPEG_SAMPLING` | `4:2:0` | [PDF output](#pdf-output) |
| `PDF_DENSITY` | `300` | [PDF output](#pdf-output) |
| `RAW_TIFF_DIR` | `$HOME/Documents/scanner-raw` | [Delivery](#delivery) |
| `PAPERLESS_URL` / `PAPERLESS_TOKEN` | *(unset)* | [Delivery](#delivery) |
| `FOLDER_DIR` | *(unset)* | [Delivery](#delivery) |

---

## Capture

These affect the SANE `scanimage` call in `scan_batch`.

| Knob | Default | Effect |
|---|---|---|
| `SCAN_RESOLUTION` | `300` | DPI for capture and shave-pixel math. |
| `SCANNER_DEVICE` | *(auto-detect)* | Pin a specific SANE device string (e.g. after USB reconnect the suffix changes). Skips `scanimage -L` on every scan. |
| `SCAN_LOCK_TIMEOUT` | `120` | Seconds to wait for the scanner lock before failing with "Scanner busy". |

**Hardcoded SANE options** (not env vars today; edit `scan_batch` in
`scan-lib.sh` to change):

| Option | Value | Effect |
|---|---|---|
| `--mode` | `Color` | Always captures in color; grayscale is applied later if requested. |
| `--swskip` | `20` | Blank-page threshold (%). Skips near-empty duplex backs. |
| `--swcrop` | `yes` | Driver crops to the paper edge at capture. Most pages arrive pre-cropped. |
| `--swdespeck` | `2` | Light despeckle in the driver. |
| `--overscan` | `On` | Capture a little past the page edge. |
| `--page-width` / `--page-height` | A4 + 10 mm bleed | Scan area geometry. |

`--raw` on `scan-doc capture` skips all post-processing but still passes
`--swcrop=yes` to the driver. For corpus work, see `corpus/README.md`.

---

## Color

| Knob | Default | Effect |
|---|---|---|
| `COLOR_MODE` | `color` | `color` — keep RGB on every page. `gray` — force grayscale. `auto` — convert pages whose mean HSL saturation is below 10% to grayscale. |

Set via GUI radio buttons or `scan-doc capture … --color color|gray|auto`.

Windows ScanSnap always stores RGB; `color` tracks it most faithfully.
`auto`/`gray` are mainly file-size levers.

---

## Orientation

Applied in `enhance_pages` before deskew and crop. Uses Tesseract OSD
(`tesseract … --psm 0`).

| Knob | Default | Effect |
|---|---|---|
| `AUTO_ROTATE` | `true` | When `false`, skip rotation entirely. |
| `ROTATE_MIN_CONFIDENCE` | `2.0` | Minimum Tesseract orientation confidence to trust a per-page reading. Below this, the page is treated as "unreadable" and may borrow orientation from a sibling page. |

**Document-level planner** (not a knob): when one page has a confident OSD
reading, unreadable pages in the same document borrow its orientation, offset by
180° on alternating duplex sides. When *no* page is readable, nothing is
rotated and the GUI offers to send the document to NAPS2 instead (if that
wasn't already selected).

Disable with `AUTO_ROTATE=false` or `scan-doc capture … --raw`.

---

## Deskew

Straightens small physical scan skew via ImageMagick `-deskew 40%`.

| Knob | Default | Effect |
|---|---|---|
| `AUTO_DESKEW` | `true` | When `false`, skip deskew. |
| `DESKEW_THRESHOLD` | `82%` | Grayscale threshold for the paper-edge mask used to detect sheet skew separately from content skew. |
| `DESKEW_AGREE_DEG` | `0.8` | Max degrees text-skew and sheet-skew may disagree before deskew is skipped. Prevents rotating a straight card because calligraphy or decorative text is written at a slant. |

Disable with `AUTO_DESKEW=false` or `--raw`.

---

## Crop

Applied after rotate + deskew in `_apply_page_crop`. The driver (`--swcrop`)
has usually already cropped to the paper; this step mainly trims white added by
deskew and tightens margins slightly.

| Knob | Default | Effect |
|---|---|---|
| `AUTO_CROP` | `true` | Master switch. When `false`, no crop step runs. |
| `AUTO_CROP_MODE` | `edge` | See modes below. |
| `AUTO_CROP_FUZZ` | `15%` (`12%` in `trim`) | Color tolerance when finding the content bounding box. |
| `CROP_MAX_PCT` | `6` | **`edge` only.** Max percent of image width/height removable per side. Caps how much bounded trim can eat into wide uniform margins. |
| `AUTO_CROP_SHAVE_MM` | `1.5` | Millimetres shaved in `shave` / `trim` modes (converted to pixels from `SCAN_RESOLUTION`). |
| `AUTO_CROP_SHAVE_PX` | *(derived)* | Override the shave width in pixels directly (bypasses `AUTO_CROP_SHAVE_MM`). |

### `AUTO_CROP_MODE` values

| Mode | Behavior |
|---|---|
| `edge` | **(default)** Bounded trim to the sheet edge. Removes uniform white borders up to `CROP_MAX_PCT` per side. Safe for cards and calligraphy. |
| `none` | Trust the driver crop; do nothing. |
| `shave` | Remove a fixed `AUTO_CROP_SHAVE_MM` fringe from every side. |
| `trim` | Shave, then unbounded content trim. **Legacy / aggressive** — can over-crop low-contrast pages (cards, receipts) down to the ink. |

**Known limit:** a tilted card with a scanner-bed shadow along one edge cannot
be cropped tighter with an axis-aligned box without cutting content. The deeper
fix is `--swcrop=no` at capture plus Linux-side paper-edge detection (not
implemented yet).

Disable with `AUTO_CROP=false` or `--raw`.

---

## Tone

Applied in `tone_pages` after enhance (rotate / deskew / crop).

| Knob | Default | Effect |
|---|---|---|
| `TONE` | `true` | When `false`, skip the tone pass. |
| `TONE_BLACK_PCT` | `6` | Input black point (%). Deepens ink / dark areas. |
| `TONE_WHITE_PCT` | `90` | Input white point (%). Pulls paper toward white. |
| `TONE_GAMMA` | `1.2` | Midtone gamma on all RGB channels. Values > 1 lift brightness. |

Pipeline: `-level black%,white%` on RGB → `-gamma` on RGB.

Disable with `TONE=false` or `--raw`.

---

## PDF output

Applied in `build_pdf` at finalize time.

| Knob | Default | Effect |
|---|---|---|
| `JPEG_QUALITY` | `75` | JPEG quality inside the PDF. ~0.8 MB/color A4 page at 300 DPI; matches Windows file size. |
| `JPEG_SAMPLING` | `4:2:0` | Chroma subsampling (`4:4:4`, `4:2:2`, `4:2:0`, …). |
| `PDF_DENSITY` | `300` | DPI stamped into page geometry (should match capture resolution). |

---

## Delivery

Not image-processing knobs, but they control where the finished PDF goes.

| Knob | Default | Effect |
|---|---|---|
| `PAPERLESS_URL` | *(unset)* | Paperless-ngx base URL. With `PAPERLESS_TOKEN`, selects API upload mode. |
| `PAPERLESS_TOKEN` | *(unset)* | API token for Paperless-ngx. |
| `FOLDER_DIR` | *(unset)* | Write finished PDFs to this directory (Paperless consume folder, sync dir, etc.). Used when Paperless API is not configured. |
| `RAW_TIFF_DIR` | `$HOME/Documents/scanner-raw` | Destination for `scan-doc finalize … --target raw-tiff` (developer corpus output). |

Priority: Paperless API → folder → none.

---

## GUI / CLI options

These are not environment variables but select behavior at the call site.

### `scan-gui`

| Choice | Maps to |
|---|---|
| Pages: single / multi | One capture vs accumulate-then-finalize |
| Color: color / gray / auto | `COLOR_MODE` via `scan-doc --color` |
| Send to: Paperless / NAPS2 / Raw Tiff (`--dev`) | `scan-doc finalize --target` |

When orientation cannot be determined for any page, the GUI asks whether to
send to NAPS2 instead (skipped if NAPS2 or Raw Tiff is already selected).

### `scan-doc`

```
scan-doc capture  <workdir> [--color color|gray|auto] [--raw]
scan-doc finalize <workdir> --target paperless|naps2|raw-tiff [--name NAME]
```

`--raw` on capture: no color mode, enhance, or tone — pages stay as the
scanner wrote them.

### `scan` (one-button)

Uses the same `scan-lib.sh` defaults. Sets `COLOR_MODE` from its own logic
(default `color`).

---

## Tuning harness (`tune/postprocess`)

The corpus feedback loop (`tune/run`) sweeps parameters without touching the
live pipeline. It applies **crop → tone → color → PDF** only — no rotate or
deskew — so orientation differences don't mask crop/tone signal.

| Knob | Default | Live-pipeline equivalent |
|---|---|---|
| `SCAN_RES` | `300` | `SCAN_RESOLUTION` |
| `CROP_MODE` | `none` | `AUTO_CROP_MODE` (`none` / `shave` / `trim`; no `edge`) |
| `CROP_FUZZ` | `12%` | `AUTO_CROP_FUZZ` |
| `CROP_SHAVE_MM` | `1.5` | `AUTO_CROP_SHAVE_MM` |
| `TONE` | `true` | `TONE` |
| `TONE_BLACK_PCT` | `6` | `TONE_BLACK_PCT` |
| `TONE_WHITE_PCT` | `90` | `TONE_WHITE_PCT` |
| `TONE_GAMMA` | `1.2` | `TONE_GAMMA` |
| `COLOR` | `color` | `COLOR_MODE` |
| `COLOR_SAT_THRESHOLD` | `10` | Hardcoded `10` in `_detect_color_per_page` |
| `JPEG_QUALITY` | `75` | `JPEG_QUALITY` |
| `JPEG_SAMPLING` | `4:2:0` | `JPEG_SAMPLING` |
| `PDF_DENSITY` | `300` | `PDF_DENSITY` |

**Not in the harness** (live pipeline only): `AUTO_CROP_MODE=edge`,
`CROP_MAX_PCT`, rotation / `ROTATE_MIN_CONFIDENCE`, deskew / `DESKEW_*`.

Example sweep:

```bash
TONE_WHITE_PCT=92 JPEG_QUALITY=70 tune/run doc-1
```

See `tune/README.md` for metrics and the iteration workflow.

---

## Processing order (live pipeline)

```
scanimage capture
  → apply_color_mode        (COLOR_MODE)
  → enhance_pages           (AUTO_ROTATE, AUTO_DESKEW, AUTO_CROP*)
  → tone_pages              (TONE_*)
  → build_pdf at finalize   (JPEG_*, PDF_DENSITY)
```

`*` enhance order per page: rotate → deskew → crop.
