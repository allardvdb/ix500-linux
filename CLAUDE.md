# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

One-button scanning workflow for the Fujitsu ScanSnap iX500 on Linux. Press the hardware button, get a PDF. Supports three delivery modes: upload to Paperless-ngx via API, write to a Paperless consume folder, or local OCR via ocrmypdf. Pure bash scripts orchestrated by a `justfile`.

## Architecture

The system has two entry points — the hardware button and a desktop GUI — built on a shared scanning library.

1. **`99-scansnap-ix500.rules`** — Udev rule that auto-starts the systemd user service when the scanner (USB `04c5:132b`) is plugged in
2. **`scan-button.service`** — Systemd user service that runs the polling script; restarts on failure with 5s delay
3. **`scan-button-poll`** — Bash script polling the scanner button every 0.1s via `scanimage -A`; triggers `scan` on press with 3s debounce; sends clickable desktop notifications (open Paperless/file on success, view logs on failure)
4. **`scan-lib.sh`** — Sourced bash library holding all reusable routines: `resolve_device`, `scan_batch`, `apply_color_detection`, `enhance_pages`, `build_pdf`, `deliver_paperless`, `deliver_naps2`. Contains no top-level logic — callers wire the functions together.
5. **`scan`** — Thin one-button entry point. Sources `scan-lib.sh`, captures one duplex batch, processes pages, delivers to Paperless/local. Used by the button poller.
6. **`scan-doc`** — CLI used by the GUI to build a document across one or more batches. `scan-doc capture <workdir>` scans and processes one batch into a working directory (pages named `batch-NN-page-NNNN.tiff` so order is preserved); `scan-doc finalize <workdir> --target paperless|naps2` combines every captured page into one PDF, delivers it, and removes the working directory.
7. **`scan-gui`** — PyGObject/GTK4 desktop app. Two radio sections (Pages: single/multi; Send to: Paperless/NAPS2) plus a Scan button. It only drives the flow: it calls `scan-doc capture`, asks "scan more?" between batches in multi-page mode, then calls `scan-doc finalize`. Scanning runs on a worker thread to keep the UI responsive.

### GUI workflow

- **Single page**: one `capture` → `finalize`.
- **Multi page**: `capture`, then an AlertDialog loop ("Scan more pages" / "Finish") appending batches into the same working directory, then a single `finalize` combining them into one PDF.
- **Send to Paperless**: `finalize --target paperless`, which reuses the same API/folder/local delivery as the hardware button.
- **Send to NAPS2**: `finalize --target naps2`, which builds the PDF into `~/Documents/scanner-inbox/` and opens it in the NAPS2 desktop app (`naps2 <pdf>`).

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
| `just gui` | Launch the scan GUI (`scan-gui`) |
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

**GUI (`scan-gui`):**
- **python3** with **PyGObject** and **GTK 4** — the desktop window
- **NAPS2** (`naps2`) — receives the final PDF in "Send to NAPS2" mode

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

- Shared scanning logic lives only in `scan-lib.sh`; `scan` and `scan-doc` are thin orchestrators that source it. Add new scanning behavior as a focused function in the library rather than inline in an entry point.
- The GUI (`scan-gui`) never scans directly — it shells out to `scan-doc` so all capture/processing/delivery logic stays in one place.
- The `scan` script uses `WORKDIR` (not `TMPDIR`) for its temp directory to avoid shadowing the standard env var.
- Color/grayscale detection runs in both Paperless and local modes when enabled — it reduces upload/file size.
- When `COLOR_DETECT=false`, all pages are converted to grayscale (no ImageMagick analysis).
- All dependencies are in `/usr/bin`; no Homebrew paths needed in the service file.
- `scan-button-poll` resolves the `scan` script path relative to its own location via `BASH_SOURCE`.

## Platform

Developed on Bluefin (Fedora Silverblue). Git commits are signed with a FIDO security key.
