# ix500-linux

One-button scanning workflow for [Fujitsu ScanSnap iX500](https://www.fujitsu.com/global/products/computing/peripheral/scanners/scansnap/ix500/) on Linux.

Press the scanner button → get a PDF. That's it.

## Features

- **One-button scanning** - press the hardware button, get a PDF
- **Duplex A4 color** - scans both sides automatically
- **Smart blank detection** - skips empty back pages (20% threshold)
- **Auto color/grayscale** - converts B&W pages to grayscale for smaller files
- **Three output modes** - upload to [Paperless-ngx](https://docs.paperless-ngx.com/) via API, write to a Paperless consume folder, or save locally with OCR
- **Clickable notifications** - open the result directly from the notification
- **Robust disconnect handling** - no crashes when scanner is unplugged

### Paperless-ngx API mode (recommended)
When `PAPERLESS_URL` and `PAPERLESS_TOKEN` are set, scans are uploaded directly to Paperless-ngx via its API. Paperless handles OCR, archiving, compression, and search.

### Paperless-ngx folder mode
When `PAPERLESS_CONSUME_DIR` is set, scans are written directly to the Paperless consume folder. Paperless picks them up from there.

### Local mode
Without Paperless configured, scans are processed locally with ocrmypdf (Dutch + English OCR, auto-rotate, deskew, cleanup) and saved to `~/Documents/scanner-inbox/`.

## Requirements

- **just** - task runner
- **sane-backends** (`scanimage`) - scanner driver
- **ImageMagick** (`magick`) - image processing and PDF creation
- **bc** - floating point math for color detection
- **libnotify** (`notify-send`), **xdg-utils** (`xdg-open`), **xdg-terminal-exec** - desktop notifications

Local mode only:
- **ocrmypdf** - OCR and PDF creation
- **tesseract** with `nld` and `eng` language data

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
1. Put documents in the feeder
2. Press the blue Scan button on the scanner
3. Wait for desktop notification "Scan Complete"
4. Click the notification to open the result

### Manual scanning
```bash
scan                  # Auto-named: scan-YYYY-MM-DD-HHMMSS.pdf
scan my-document      # Custom name: my-document.pdf
```

### Service management
```bash
just status    # Show service status
just logs      # Follow service logs
just restart   # Restart the service
just uninstall # Remove everything
```

## Configuration

Settings are stored in `~/.config/environment.d/scanner.conf` (managed by `just install`):

| Variable | Description |
|---|---|
| `SCANNER_DEVICE` | SANE device string (auto-detected if unset) |
| `COLOR_DETECT` | `true` (default) or `false` — auto-detect color vs grayscale per page |
| `PAPERLESS_URL` | Paperless-ngx base URL (API mode) |
| `PAPERLESS_TOKEN` | Paperless-ngx API token (API mode) |
| `PAPERLESS_CONSUME_DIR` | Path to Paperless consume folder (folder mode) |

### Scanner options (in `scan`)

| Option | Value | Purpose |
|--------|-------|---------|
| `--swskip` | 20% | Skip blank pages |
| `--swcrop` | yes | Auto-crop borders |
| `--swdespeck` | 2 | Remove small artifacts |
| `--overscan` | On | Better feed handling |
| `--prepick` | On | Pre-pick next page (faster) |
| `--buffermode` | On | Faster processing |

### OCR options (local mode only, in `scan`)

| Option | Value | Purpose |
|--------|-------|---------|
| `-l` | nld+eng | Languages (Dutch + English) |
| `--rotate-pages-threshold` | 2 | Aggressive rotation fix |
| `-O` | 3 | Maximum optimization |
| `--jpeg-quality` | 60 | Good compression |
| `--jbig2-lossy` | yes | Better text compression |

### Color detection
Pages with <10% color saturation are converted to grayscale automatically.

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
│  (SANE)     │     │ (PDF)        │     │ folder / OCR    │
└─────────────┘     └──────────────┘     └─────────────────┘
```

1. **Button poll service** checks scanner button every 100ms
2. **scanimage** captures duplex color TIFF pages
3. **ImageMagick** combines pages, detects color vs grayscale, creates PDF
4. Delivery: **Paperless API** upload, **Paperless folder** write, or local **ocrmypdf**
5. **Clickable notification** confirms completion

## Tested on

- **OS**: [Bluefin](https://projectbluefin.io/) (Fedora Silverblue based)
- **Scanner**: Fujitsu ScanSnap iX500
- **SANE**: sane-backends with fujitsu driver

Should work on any Linux with SANE support for the iX500.

## Credits

- [Rida Ayed's ix500 Linux guide](https://ridaayed.com/posts/setup_fujitsu_ix500_scanner_linux/) - scanner options and swskip threshold
- [foxey/scanbdScanSnapIntegration](https://github.com/foxey/scanbdScanSnapIntegration) - inspiration for button daemon
- [OCRmyPDF](https://ocrmypdf.readthedocs.io/) - excellent OCR tool

## License

MIT
