# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

One-button scanning workflow for Fujitsu ScanSnap scanners on Linux. Press the hardware button, get a PDF. Supports three delivery modes: upload to Paperless-ngx via API, write to a Paperless consume folder, or local OCR via ocrmypdf. Pure bash scripts orchestrated by a `justfile`.

The project name is a historical artifact — it started as iX500-specific, but now auto-detects any ScanSnap model supported by the SANE `fujitsu` backend. Scanner detection matches `fujitsu:ScanSnap [^:]+:\d+` across `scanimage -L` output, and the udev rule matches USB vendor `04c5` + product string containing "ScanSnap".

## Architecture

The system has four components forming a hardware-to-PDF pipeline:

1. **`99-scansnap.rules`** — Udev rule template that auto-starts the systemd user service when any ScanSnap (USB vendor `04c5`, product string matching `*ScanSnap*`) is plugged in, and stops it on disconnect. Contains a `__USERNAME__` placeholder that `just install` substitutes with the invoking user — do not install this file by hand.
2. **`scan-button.service`** — Systemd user service that runs the polling script; restarts on failure with 5s delay
3. **`scan-button-poll`** — Bash script polling the scanner button every 0.1s via `scanimage -A`; triggers `scan` on press with 3s debounce; sends clickable desktop notifications (open Paperless/file on success, view logs on failure)
4. **`scan`** — Bash script that drives the actual scanning: duplex TIFF capture at 300 DPI with bleed margin → optional per-page color/grayscale detection (10% saturation threshold) → ImageMagick PDF creation → delivery via API upload, consume folder, or local OCR

### Three modes

Determined automatically by environment variables:

- **Paperless API mode** (`PAPERLESS_URL` + `PAPERLESS_TOKEN` set): Creates PDF with ImageMagick, uploads to Paperless-ngx via `POST /api/documents/post_document/`. Paperless handles OCR, archiving, etc.
- **Paperless folder mode** (`PAPERLESS_CONSUME_DIR` set): Creates PDF with ImageMagick, writes directly to the Paperless consume folder. Paperless picks it up from there.
- **Local mode** (none of the above set): Runs `ocrmypdf` with Dutch+English OCR, saves to `~/Documents/scanner-inbox/`

### Configuration

All scanner settings are stored in `~/.config/environment.d/scanner.conf` so they're available to both the shell and systemd user services.

Environment variables:
- `SCANNER_DEVICE` — SANE device string (detected at install time, falls back to auto-detect if unset)
- `COLOR_DETECT` — `true` (default) or `false`; whether to auto-detect color vs grayscale per page
- `PAPERLESS_URL` — Paperless-ngx base URL (API mode)
- `PAPERLESS_TOKEN` — Paperless-ngx API token (API mode)
- `PAPERLESS_CONSUME_DIR` — Path to Paperless consume folder (folder mode)

## Usage

All operations are run via `just`:

| Command | Description |
|---|---|
| `just` | List available recipes |
| `just install` | Full interactive install (mode selection, scanner detection, config, activate) |
| `just check` | Check dependencies for all modes |
| `just status` | Show service status |
| `just logs` | Follow service logs |
| `just restart` | Restart the service |
| `just uninstall` | Remove installed files, service, and udev rules |

## Installation

```bash
just install
```

The interactive installer detects the scanner, asks for mode and preferences, configures settings, installs files, and activates the service. If upgrading from an older install with `paperless.conf`, the installer migrates settings automatically.

## Dependencies

**Build/install:**
- **just** — task runner (`just install`, `just check`, etc.)

**Both modes:**
- **SANE** (`scanimage`) — scanner driver interface
- **ImageMagick** (`magick`) — image manipulation and color analysis
- **bc** — floating point comparison for color detection
- **notify-send**, **xdg-open**, **xdg-terminal-exec** — desktop notifications

**Local mode only:**
- **ocrmypdf** — OCR and PDF creation
- **Tesseract** with `nld` and `eng` trained data

**Paperless API mode only:**
- **curl** — API upload

## Key Parameters

| Parameter | Value | Location |
|---|---|---|
| Scan resolution | 300 DPI | `scan` |
| Bleed margin | 10 mm | `scan` |
| Blank page skip threshold | 20% | `scan` (`--swskip`) |
| Color detection | `COLOR_DETECT` env var (default: true) | `scanner.conf` / `scan` |
| Grayscale conversion threshold | 10% saturation | `scan` |
| Button poll interval | 0.1s | `scan-button-poll` |
| Debounce period | 3s | `scan-button-poll` |
| OCR languages | `nld+eng` | `scan` (local mode only) |
| JPEG quality | 60 | `scan` (local mode only) |

## Conventions

- The `scan` script uses `WORKDIR` (not `TMPDIR`) for its temp directory to avoid shadowing the standard env var.
- Color/grayscale detection runs in both Paperless and local modes when enabled — it reduces upload/file size.
- When `COLOR_DETECT=false`, all pages are converted to grayscale (no ImageMagick analysis).
- All dependencies are in `/usr/bin`; no Homebrew paths needed in the service file.
- `scan-button-poll` resolves the `scan` script path relative to its own location via `BASH_SOURCE`.
- Scanner detection in both `scan` and `scan-button-poll` uses the regex `fujitsu:ScanSnap [^:]+:\d+` so any ScanSnap model is matched; the installer lists all detected devices and asks the user to pick when more than one is present.
- `scan` probes `scanimage -A` per run and only passes options the specific scanner exposes (via a `has_opt` helper). The iX500 has `--overscan`/`--prepick` but the S1500 does not — setting those on an S1500 produces a "readonly option" warning. Keep this probe in place when adding new scan options.
- On failure, `scan-button-poll`'s "View Logs" notification action opens a terminal wrapped in `sh -c '…; read -rp "Press Enter…"'` — without the trailing `read`, the terminal exits before the user can see anything.

## Platform

Developed on Bluefin (Fedora Silverblue). Git commits are signed with a FIDO security key.
