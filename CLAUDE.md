# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

One-button scanning workflow for the Fujitsu ScanSnap iX500 on Linux. Press the hardware button, get a PDF. Supports two modes: upload to Paperless-ngx (which handles OCR) or local OCR via ocrmypdf. Pure bash — no build system, no package manager, no tests.

## Architecture

The system has four components forming a hardware-to-PDF pipeline:

1. **`99-scansnap-ix500.rules`** — Udev rule that auto-starts the systemd user service when the scanner (USB `04c5:132b`) is plugged in
2. **`scan-button.service`** — Systemd user service that runs the polling script; restarts on failure with 5s delay
3. **`scan-button-poll`** — Bash script polling the scanner button every 0.1s via `scanimage -A`; triggers `scan` on press with 3s debounce; sends clickable desktop notifications (open Paperless/file on success, view logs on failure)
4. **`scan`** — Bash script that drives the actual scanning: duplex TIFF capture at 300 DPI → per-page color/grayscale detection (10% saturation threshold) → ImageMagick PDF creation → upload to Paperless or local OCR

### Two modes

Determined automatically by environment variables:

- **Paperless mode** (`PAPERLESS_URL` + `PAPERLESS_TOKEN` set): Creates PDF with ImageMagick, uploads to Paperless-ngx via `POST /api/documents/post_document/`. Paperless handles OCR, archiving, etc.
- **Local mode** (env vars not set): Runs `ocrmypdf` with Dutch+English OCR, saves to `~/Documents/scanner-inbox/`

### Configuration

Paperless credentials are stored in `~/.config/environment.d/paperless.conf` so they're available to both the shell and systemd user services.

## Installation

Run the interactive installer:

```bash
./install
```

It checks dependencies, asks for Paperless or local mode, configures credentials, installs files, and activates the service.

## Dependencies

**Both modes:**
- **SANE** (`scanimage`) — scanner driver interface
- **ImageMagick** (`magick`) — image manipulation and color analysis
- **bc** — floating point comparison for color detection
- **notify-send**, **xdg-open**, **xdg-terminal-exec** — desktop notifications

**Local mode only:**
- **ocrmypdf** — OCR and PDF creation
- **Tesseract** with `nld` and `eng` trained data

**Paperless mode only:**
- **curl** — API upload

## Key Parameters

| Parameter | Value | Location |
|---|---|---|
| Scan resolution | 300 DPI | `scan` |
| Blank page skip threshold | 20% | `scan` (`--swskip`) |
| Grayscale conversion threshold | 10% saturation | `scan` |
| Button poll interval | 0.1s | `scan-button-poll` |
| Debounce period | 3s | `scan-button-poll` |
| OCR languages | `nld+eng` | `scan` (local mode only) |
| JPEG quality | 60 | `scan` (local mode only) |

## Conventions

- The `scan` script uses `WORKDIR` (not `TMPDIR`) for its temp directory to avoid shadowing the standard env var.
- Color/grayscale detection runs in both modes — it reduces upload size for Paperless too.
- All dependencies are in `/usr/bin`; no Homebrew paths needed in the service file.

## Platform

Developed on Bluefin (Fedora Silverblue). Git commits are signed with a FIDO security key.
