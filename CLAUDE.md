# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

One-button scanning workflow for the Fujitsu ScanSnap iX500 on Linux. Press the hardware button, get a searchable, optimized PDF with OCR. Pure bash — no build system, no package manager, no tests.

## Architecture

The system has four components forming a hardware-to-PDF pipeline:

1. **`99-scansnap-ix500.rules`** — Udev rule that auto-starts the systemd user service when the scanner (USB `04c5:132b`) is plugged in
2. **`scan-button.service`** — Systemd user service that runs the polling script; restarts on failure with 5s delay
3. **`scan-button-poll`** — Bash script polling the scanner button every 0.5s via `scanimage -A`; triggers `scan` on press with 3s debounce; sends desktop notifications via `notify-send`
4. **`scan`** — Bash script that drives the actual scanning: duplex TIFF capture at 300 DPI → per-page color/grayscale detection (10% saturation threshold) → ImageMagick combine → ocrmypdf with Dutch+English OCR → PDF/A-2b output to `~/Documents/scanner-inbox/`

## Installation

```bash
cp scan scan-button-poll ~/.local/bin/
cp scan-button.service ~/.config/systemd/user/
sudo cp 99-scansnap-ix500.rules /etc/udev/rules.d/
systemctl --user daemon-reload
sudo udevadm control --reload-rules
```

## Dependencies

- **SANE** (`scanimage`) — scanner driver interface
- **ImageMagick** (`magick`) — image manipulation and color analysis
- **ocrmypdf** — OCR and PDF creation
- **Tesseract** with `nld` and `eng` trained data (installed via Homebrew on this system; `TESSDATA_PREFIX` set in service file)

## Key Parameters

| Parameter | Value | Location |
|---|---|---|
| Scan resolution | 300 DPI | `scan` |
| Blank page skip threshold | 20% | `scan` (`--swskip`) |
| Grayscale conversion threshold | 10% saturation | `scan` |
| Button poll interval | 0.5s | `scan-button-poll` |
| Debounce period | 3s | `scan-button-poll` |
| OCR languages | `nld+eng` | `scan` |
| JPEG quality | 60 | `scan` |
| Output directory | `~/Documents/scanner-inbox/` | `scan` |

## Platform

Developed on Bluefin (Fedora Silverblue). Tesseract paths in the service file reference `/home/linuxbrew/.linuxbrew/`.
