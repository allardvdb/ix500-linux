# ix500-linux

One-button scanning workflow for [Fujitsu ScanSnap iX500](https://www.fujitsu.com/global/products/computing/peripheral/scanners/scansnap/ix500/) on Linux.

Press the scanner button → get a PDF. That's it.

## Features

- **One-button scanning** - press the hardware button, get a PDF
- **Duplex A4 color** - scans both sides automatically
- **Smart blank detection** - skips empty back pages (20% threshold)
- **Auto color/grayscale** - converts B&W pages to grayscale for smaller files
- **Two output modes** - upload to [Paperless-ngx](https://docs.paperless-ngx.com/) or save locally with OCR
- **Clickable notifications** - open the result directly from the notification
- **Robust disconnect handling** - no crashes when scanner is unplugged

### Paperless-ngx mode (recommended)
When `PAPERLESS_URL` and `PAPERLESS_TOKEN` are set, scans are uploaded directly to Paperless-ngx via its API. Paperless handles OCR, archiving, compression, and search.

### Local mode
Without Paperless configured, scans are processed locally with ocrmypdf (Dutch + English OCR, auto-rotate, deskew, cleanup) and saved to `~/Documents/scanner-inbox/`.

## Requirements

### System packages
- `sane` / `sane-backends` - scanner driver (usually pre-installed)

### Homebrew packages

For both modes:
```bash
brew install imagemagick
```

For local mode (OCR):
```bash
brew install ocrmypdf tesseract tesseract-lang
```

## Installation

### Quick install
```bash
./install
```

The interactive installer checks dependencies, asks for Paperless or local mode, configures credentials, and activates the service.

### Manual installation

#### 1. Verify scanner is detected
```bash
scanimage -L
# Should show: device `fujitsu:ScanSnap iX500:XXXXX'
```

#### 2. Install scripts
```bash
cp scan scan-button-poll ~/.local/bin/
chmod +x ~/.local/bin/scan ~/.local/bin/scan-button-poll
```

#### 3. Configure Paperless (optional)
```bash
mkdir -p ~/.config/environment.d
cat > ~/.config/environment.d/paperless.conf <<EOF
PAPERLESS_URL=https://paperless.example.com
PAPERLESS_TOKEN=your-api-token
EOF
```

#### 4. Install systemd user service
```bash
cp scan-button.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable scan-button.service
```

#### 5. Install udev rule (for auto start on USB connect)
```bash
sudo cp 99-scansnap-ix500.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

#### 6. Start the service
```bash
systemctl --user start scan-button.service
```

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

### Check service status
```bash
systemctl --user status scan-button.service
journalctl --user -u scan-button.service -f
```

## Configuration

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
│  scanimage  │────▶│ ImageMagick  │────▶│ Paperless-ngx   │
│  (SANE)     │     │ (PDF)        │     │ or ocrmypdf     │
└─────────────┘     └──────────────┘     └─────────────────┘
```

1. **Button poll service** checks scanner button every 100ms
2. **scanimage** captures duplex color TIFF pages
3. **ImageMagick** combines pages, detects color vs grayscale, creates PDF
4. **Paperless-ngx** receives the upload (or **ocrmypdf** processes locally)
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

## Troubleshooting

### Tesseract language data not found (local mode)
Brew doesn't always link traineddata files automatically:
```bash
TESS_VERSION=$(brew list --versions tesseract | awk '{print $2}')
ln -sf "/home/linuxbrew/.linuxbrew/Cellar/tesseract/${TESS_VERSION}/share/tessdata/eng.traineddata" /home/linuxbrew/.linuxbrew/share/tessdata/
ln -sf "/home/linuxbrew/.linuxbrew/Cellar/tesseract/${TESS_VERSION}/share/tessdata/osd.traineddata" /home/linuxbrew/.linuxbrew/share/tessdata/
```

## License

MIT
