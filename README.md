# scansnap-linux

One-button scanning workflow for [Fujitsu ScanSnap](https://www.pfu.ricoh.com/global/scanners/scansnap/) scanners on Linux. Should work with any ScanSnap the SANE `fujitsu` backend exposes as `fujitsu:ScanSnap …`; only tested with the iX1300 so far.

Press the scanner button → get a PDF. That's it.

## Features

- **One-button scanning** - press the hardware button, get a PDF
- **Desktop GUI** - pick pages, color, and destination, then scan
- **Button follows the GUI** - when the GUI is open the hardware button uses its current selection (and adds the next page in multi-page mode); when it's closed the button scans a single page to Paperless
- **Feeder or front slot** - automatically scans from whichever input has a document loaded
- **Multi-page documents** - keep scanning pages and combine them into one PDF
- **Duplex A4** - scans both sides automatically
- **Smart blank detection** - skips empty back pages (20% threshold)
- **Color / Grayscale / Auto** - keep color, force grayscale, or auto-detect per page
- **Two delivery modes** - upload to [Paperless-ngx](https://docs.paperless-ngx.com/) via API, or write the PDF to a folder
- **Send to NAPS2** - hand the finished PDF to the [NAPS2](https://www.naps2.com/) desktop app
- **Clickable notifications** - open the result directly from the notification
- **Robust disconnect handling** - no crashes when scanner is unplugged

### Desktop GUI
Run `just gui` (or launch **ScanSnap Scan** from your app menu). The window has three choices:

- **Pages** — *Scan single page* (one scan session) or *Scan multi page* (keep loading pages; each page is appended and everything is combined into one PDF).
- **Color** — *Color* (keep every page in color), *Grayscale* (force grayscale), or *Auto* (detect per page).
- **Send to** — *Send to Paperless* (uses the configured Paperless API or folder pipeline) or *Send to NAPS2* (opens the finished PDF in NAPS2 for review/editing).

Press **Scan** (on screen or the hardware button). In multi-page mode the Scan button becomes **Scan next page** and a **Finish** button appears after each page; the hardware button adds the next page too, so you can keep loading pages without touching the keyboard. Pages can come from either the feeder or the front slot, and you can switch between them between pages.

### Paperless-ngx API mode (recommended)
When `PAPERLESS_URL` and `PAPERLESS_TOKEN` are set, scans are uploaded directly to Paperless-ngx via its API. Paperless handles OCR, archiving, compression, and search.

### Folder mode
When `FOLDER_DIR` is set, the finished PDF is written to that folder. Point it at a Paperless consume folder, a synced directory, or anywhere else you like.

## Requirements

- **just** - task runner
- **sane-backends** (`scanimage`) - scanner driver
- **ImageMagick** (`magick`) - image processing and PDF creation
- **bc** - floating point math for color detection
- **tesseract** - page orientation detection (auto-rotate before PDF)
- **libnotify** (`notify-send`), **xdg-utils** (`xdg-open`), **xdg-terminal-exec** - desktop notifications

GUI only:
- **python3** with **PyGObject** and **GTK 4** - the desktop window
- **NAPS2** (`naps2`) - target for "Send to NAPS2"

Paperless API mode only:
- **curl** - API upload

Run `just check` to see which dependencies are installed.

## Installation

```bash
just install
```

The interactive installer detects the scanner, asks for mode and preferences, configures settings, installs files, and activates the service.

## Usage

### One-button scanning
1. Put documents in the feeder or the front slot
2. Press the blue Scan button on the scanner
3. With the GUI closed this scans a single page (auto color) to the configured destination; with the GUI open it uses the window's current selection
4. Wait for desktop notification "Scan Complete" (headless scans)
5. Click the notification to open the result

### GUI scanning
```bash
just gui       # Launch the scan window (or use the "ScanSnap Scan" app entry)
```
Pick pages, color, and destination, then press Scan.

### Manual scanning
```bash
scan                  # Auto-named: scan-YYYY-MM-DD-HHMMSS.pdf
scan my-document      # Custom name: my-document.pdf
```

### Service management
```bash
just gui       # Launch the scan GUI
just status    # Show service status
just logs      # Follow service logs
just restart   # Restart the service
just uninstall # Remove everything
```

## Configuration

Settings are stored in `~/.config/environment.d/scanner.conf` (managed by `just install`):

| Variable | Description |
|---|---|
| `SCANNER_DEVICE` | SANE device string (auto-detected if unset; matches `fujitsu:ScanSnap …`) |
| `PAPERLESS_URL` | Paperless-ngx base URL (API mode) |
| `PAPERLESS_TOKEN` | Paperless-ngx API token (API mode) |
| `FOLDER_DIR` | Output folder for the PDF (folder mode) |

Color treatment is not stored in config — it's chosen per scan in the GUI (Color / Grayscale / Auto). The headless hardware-button scan always uses Auto. `COLOR_MODE=color|gray|auto` can override it for the `scan`/`scan-doc` scripts.

### Scanner options (in `scan`)

| Option | Value | Purpose |
|--------|-------|---------|
| `--swskip` | 20% | Skip blank pages |
| `--swcrop` | yes | Auto-crop borders |
| `--swdespeck` | 2 | Remove small artifacts |
| `--overscan` | On | Better feed handling |
| `--prepick` | On | Pre-pick next page (faster) |
| `--buffermode` | On | Faster processing |

### Color mode
- **Color** — every page kept in color.
- **Grayscale** — every page converted to grayscale.
- **Auto** — pages with <10% color saturation are converted to grayscale automatically (smaller files).

## How it works

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Button     │────▶│ scan-button  │────▶│ scan script     │
│  pressed    │     │ -poll        │     │                 │
└─────────────┘     └──────────────┘     └─────────────────┘
                                                  │
                    ┌─────────────────────────────┘
                    ▼
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  scanimage  │────▶│ ImageMagick  │────▶│ Paperless API / │
│  (SANE)     │     │ (PDF)        │     │ folder          │
└─────────────┘     └──────────────┘     └─────────────────┘
```

1. **Button poll service** checks the scanner button every 100ms (forwards to the GUI when it's open)
2. **scanimage** captures duplex TIFF pages from the loaded input (feeder or front slot)
3. **ImageMagick** applies the color mode, deskews/crops, and combines pages into a PDF
4. Delivery: **Paperless API** upload, or **folder** write
5. **Clickable notification** confirms completion

## Tested on

- **OS**: Arch Linux
- **Scanner**: Fujitsu ScanSnap iX1300
- **SANE**: sane-backends with fujitsu driver

Other ScanSnap models that show up as `fujitsu:ScanSnap …` in `scanimage -L` should work, but have not been tested here.

## Credits

- [Rida Ayed's ix500 Linux guide](https://ridaayed.com/posts/setup_fujitsu_ix500_scanner_linux/) - scanner options and swskip threshold
- [foxey/scanbdScanSnapIntegration](https://github.com/foxey/scanbdScanSnapIntegration) - inspiration for button daemon

## License

MIT
