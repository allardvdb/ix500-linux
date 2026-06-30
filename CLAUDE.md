# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

One-button scanning workflow for Fujitsu ScanSnap scanners on Linux. Press the hardware button, get a PDF. Should work with any ScanSnap the SANE `fujitsu` backend exposes as `fujitsu:ScanSnap …`; only tested with the iX1300 so far. Supports two delivery modes: upload to Paperless-ngx via API, or write the PDF to a folder. Pure bash scripts plus a small GTK4 GUI, orchestrated by a `justfile`.

## Architecture

The system has two entry points — the hardware button and a desktop GUI — built on a shared scanning library.

1. **`99-scansnap.rules`** — Udev rule that auto-starts the systemd user service when any PFU/Fujitsu ScanSnap (USB vendor `04c5`) is plugged in
2. **`scan-button.service`** — Systemd user service that runs the polling script; restarts on failure with 5s delay
3. **`scan-button-poll`** — Bash script polling the scanner button every 0.1s via `scanimage -A`; on press it forwards to the GUI when one is running (SIGUSR1, with D-Bus / `scan-gui --scan` fallbacks) and otherwise runs `scan` headlessly; 3s debounce; sends clickable desktop notifications for headless scans
4. **`scan-lib.sh`** — Sourced bash library holding all reusable routines: `with_scan_lock`, `resolve_device`, `resolve_source`, `scan_pages`, `scan_batch`, `delivery_mode`, `apply_color_mode`, `enhance_pages`, `build_pdf`, `deliver_document`, `deliver_naps2`. Contains no top-level logic — callers wire the functions together.
5. **`scan`** — Thin one-button entry point. Sources `scan-lib.sh`, captures one duplex batch, processes pages, delivers via the configured mode. Used by the button poller for headless scans (single page, auto color).
6. **`scan-doc`** — CLI used by the GUI to build a document across one or more batches. `scan-doc capture <workdir> [--color color|gray|auto] [--raw]` scans and processes one batch into a working directory (pages named `batch-NN-page-NNNN.tiff` so order is preserved); `scan-doc finalize <workdir> --target paperless|naps2|raw-tiff` combines every captured page into one PDF, delivers it, and removes the working directory. `--raw` capture leaves pages exactly as the scanner produced them (no color detection, crop, deskew, or rotate); the `raw-tiff` target copies those TIFFs out unchanged for the tuning corpus.
7. **`scan-gui`** — PyGObject/GTK4 desktop app, registered as a single instance (`com.github.scansnaplinux.ScanGui`). Three radio sections (Pages: single/multi; Color: color/grayscale/auto; Send to: Paperless/NAPS2) plus a Scan button. It only drives the flow: it calls `scan-doc capture`, shows in-window next-page controls between pages in multi-page mode, then calls `scan-doc finalize`. A scan is triggered by the on-screen button or by SIGUSR1 / the `scan` D-Bus action / `scan-gui --scan` (how the hardware button reaches a running window), routed through an idle/busy/awaiting-next state so either button starts a scan or adds the next page. Scanning runs on a worker thread to keep the UI responsive.

### Scanner access locking

`with_scan_lock` serializes every `scanimage` call (button polling and captures) through `flock` on `/run/user/$(id -u)/scansnap.lock`, so the poller and a GUI scan never fight over the single-client SANE device. The poller polls more slowly (0.5s) while the GUI is open and reports `busy` instead of `error` when it can't grab the lock.

### Input auto-detection

`resolve_source` reads the hardware paper sensors once via `scanimage -A` and chooses the input that holds a document: the top ADF feeder (sensor `page-loaded`) maps to source `ADF Duplex`, and the front/return slot (sensor `card-loaded`) maps to source `Card Duplex`. If both inputs are loaded it errors; if neither is loaded the caller emits the usual "feeder empty" message. Both `scan` and `scan-doc capture` resolve the source before each capture, so multi-page documents can mix feeder and front-slot pages.

### Color modes

`apply_color_mode` honours `COLOR_MODE` (default `auto`):
- `color` — keep every page in color (no conversion)
- `gray` — convert every page to grayscale
- `auto` — per-page detection; pages under 10% saturation become grayscale

The GUI's Color section sets this per capture via `scan-doc capture --color`; the headless `scan` path uses the `auto` default.

### GUI workflow

- **Single page**: one `capture` → `finalize`.
- **Multi page**: `capture`, then in-window next-page controls (the Scan button becomes "Scan next page" and a "Finish" button appears) appending pages into the same working directory, then a single `finalize` combining them into one PDF. Because the controls live in the window (not a modal dialog), a hardware button press forwarded as SIGUSR1 adds the next page just like clicking "Scan next page". Color and Send-to can be changed between pages; Pages cannot.
- **Send to Paperless**: `finalize --target paperless`, which reuses the same configured delivery (API or folder) as the hardware button.
- **Send to NAPS2**: `finalize --target naps2`, which builds the PDF into `~/Documents/scanner-inbox/` and opens it in the NAPS2 desktop app (`naps2 <pdf>`).

### Developer mode (`--dev`)

Launching the GUI with `scan-gui --dev` (or `just gui --dev`) reveals an extra "Raw Tiff" option in the Send-to section. Selecting it captures with `--raw` and finalizes with `--target raw-tiff`, saving the untouched scanner TIFFs to `RAW_TIFF_DIR` (default `~/Documents/scanner-raw/<name>/page-NNNN.tiff`). This is the input side of the post-processing tuning loop: drop these files into a corpus case's `raw/` directory and compare candidate output against the Windows ScanSnap reference PDF. The option is hidden in normal use. Dev mode is single-instance-sticky: once a window is launched with `--dev`, hardware-button scans forwarded as `scan-gui --scan` keep the option visible.

### Two delivery modes

Determined automatically by environment variables (`delivery_mode`):

- **Paperless API mode** (`PAPERLESS_URL` + `PAPERLESS_TOKEN` set): Creates PDF with ImageMagick, uploads to Paperless-ngx via `POST /api/documents/post_document/`.
- **Folder mode** (`FOLDER_DIR` set): Creates PDF with ImageMagick and writes it to that folder (e.g. a Paperless consume folder, a synced directory, ...).
- If neither is configured, `deliver_document` errors out.

### Configuration

All scanner settings are stored in `~/.config/environment.d/scanner.conf` so they're available to both the shell and systemd user services.

Environment variables:
- `SCANNER_DEVICE` — SANE device string (detected at install time, falls back to auto-detect of any `fujitsu:ScanSnap …` if unset)
- `PAPERLESS_URL` — Paperless-ngx base URL (API mode)
- `PAPERLESS_TOKEN` — Paperless-ngx API token (API mode)
- `FOLDER_DIR` — Output folder for the PDF (folder mode)

Color treatment is not persisted in config — it's a per-scan GUI choice (`COLOR_MODE` can still override the scripts).

## Usage

All operations are run via `just`:

| Command | Description |
|---|---|
| `just` | List available recipes |
| `just install` | Full interactive install (mode selection, scanner detection, config, activate) |
| `just reload` | Copy the latest scripts/service into place and restart the button service (no config/udev/deps) |
| `just gui` | Launch the scan GUI (`scan-gui`) |
| `just check` | Check dependencies |
| `just status` | Show service status |
| `just logs` | Follow service logs |
| `just restart` | Restart the service |
| `just uninstall` | Remove installed files, service, and udev rules |

## Installation

```bash
just install
```

The interactive installer detects the scanner, asks for the delivery mode and its settings, configures the environment, installs files, and activates the service. After editing scripts, use `just reload` to redeploy without re-running the full install.

## Dependencies

**Build/install:**
- **just** — task runner (`just install`, `just check`, etc.)

**Core:**
- **SANE** (`scanimage`) — scanner driver interface
- **ImageMagick** (`magick`) — image manipulation and color analysis
- **bc** — floating point comparison for color detection
- **tesseract** — page orientation detection (auto-rotate; not used for OCR)
- **notify-send**, **xdg-open**, **xdg-terminal-exec** — desktop notifications

**GUI (`scan-gui`):**
- **python3** with **PyGObject** and **GTK 4** — the desktop window
- **NAPS2** (`naps2`) — receives the final PDF in "Send to NAPS2" mode

**Paperless API mode only:**
- **curl** — API upload

## Key Parameters

| Parameter | Value | Location |
|---|---|---|
| Raw corpus output dir | `RAW_TIFF_DIR` (default `~/Documents/scanner-raw`) | `scan-lib.sh` (`--dev` only) |
| Scan resolution | 300 DPI | `scan-lib.sh` |
| Bleed margin | 10 mm | `scan-lib.sh` |
| Blank page skip threshold | 20% | `scan-lib.sh` (`--swskip`) |
| Color mode | `COLOR_MODE` (default: auto) | GUI / `scan-doc --color` |
| Grayscale conversion threshold | 10% saturation | `scan-lib.sh` |
| Auto-rotate | tesseract OSD (`--psm 0`) | `scan-lib.sh` (`AUTO_ROTATE`) |
| Button poll interval | 0.1s (0.5s while GUI is open) | `scan-button-poll` |
| Debounce period | 3s | `scan-button-poll` |
| Scanner lock | `/run/user/$UID/scansnap.lock` | `scan-lib.sh` |

## Conventions

- Shared scanning logic lives only in `scan-lib.sh`; `scan` and `scan-doc` are thin orchestrators that source it. Add new scanning behavior as a focused function in the library rather than inline in an entry point.
- The GUI (`scan-gui`) never scans directly — it shells out to `scan-doc` so all capture/processing/delivery logic stays in one place.
- The `scan` script uses `WORKDIR` (not `TMPDIR`) for its temp directory to avoid shadowing the standard env var.
- Every `scanimage` call goes through `with_scan_lock` so the poller and the GUI never access the device at the same time.
- Scanner detection matches `fujitsu:ScanSnap …` (shared `SCANSNAP_DEVICE_RE` in `scan-lib.sh`); other models should work but only the iX1300 has been tested.
- All dependencies are in `/usr/bin`; no Homebrew paths needed in the service file.
- `scan-button-poll` resolves the `scan` script path relative to its own location via `BASH_SOURCE`.

## Platform

Developed on Arch Linux. Git commits are signed with a FIDO security key.
