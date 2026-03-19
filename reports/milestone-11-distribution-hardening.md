# Milestone 11: Distribution Hardening & Installation UX (v0.2.0)

**Date:** 2026-03-19
**Status:** Complete

---

## What Was Done

### Gatekeeper / Distribution Fix

Investigated app failing to open on another Mac (M4, Sequoia 15.7.3) when transferred as DMG via Telegram:
- **Root cause:** Telegram adds `com.apple.quarantine` extended attribute (`0081;...;Telegram;`). macOS Gatekeeper blocks unsigned apps with quarantine flag.
- **Verified:** DMG files are bit-for-bit identical (SHA256 match), only extended attributes differ.
- **Documented:** `xattr -cr` bypass in DMG README, System Settings → Privacy & Security → "Open Anyway" as alternative.

### Custom App Icon

Replaced system SF Symbol icon with custom robot icon (`robo-icon.png`):
- All macOS icon sizes generated (16–1024px) via `sips`
- Alpha channel analysis for precise padding control
- Final padding: 9% vertical, ~10% horizontal (aspect ratio preserved)
- Icon cache invalidation: `lsregister -kill -seed -r` + Dock restart

### Uninstaller (Script + In-App)

**`uninstall.sh`** — standalone terminal script:
- Prompts for confirmation
- Removes: app bundle, Application Support data, conda environment (~500MB), XDG config, preferences plist, SwiftData store
- Unregisters from LaunchServices

**Help → Uninstall CT Transcriber...** — in-app menu:
- Confirmation alert with Enter to proceed, Escape to cancel
- Spinner overlay while uninstalling
- Non-blocking: spawns background shell process that polls for app PID exit, then deletes everything
- No timing dependencies — shell waits for real process exit event

### Setup Script Hardening (`setup_env.sh`)

**ffmpeg install fix:**
- **Root cause:** `set -euo pipefail` + `conda install ffmpeg` failure killed entire setup script. Graceful fallback code never ran.
- **Fix:** Added `|| true` to make ffmpeg non-fatal + `--override-channels` to bypass Anaconda TOS requirement for defaults channel.

**Detailed logging:**
- Swift side: stderr now captured and logged via `AppLogger.debug` (was `FileHandle.nullDevice`)
- Shell side: replaced all `| tail -N` with `>&2 2>&1` — full output goes to stderr → log file
- Non-JSON stdout lines also logged

**Granular progress steps:**
- Split monolithic steps: `download_miniconda` / `install_miniconda` (was one step)
- Split pip: `install_torch` checkpoint between torch and faster-whisper
- Split CT2: `download_ct2` / `install_ct2` (was one step)
- Added download size hints ("~60 MB", "~400 MB", "~1.6 GB")
- Immediate `"prepare"` emit before any work begins

**Parallel installation:**
- torch + faster-whisper pip installs run in parallel
- ffmpeg conda install runs in parallel with pip deps
- Model HuggingFace download prefetches in background during CT2 install
- Roughly 2x faster total setup time

**Auto model download:**
- Default model (whisper-large-v3-turbo) downloaded and converted during setup
- `--download-model`, `--model-id`, `--model-quantization` arguments added
- Non-fatal: falls back to manual download from Settings if fails

### Setup UI Improvements (`EnvironmentSetupView`)

- Spinner always visible during setup (was disappearing between steps)
- Current step label persists until next step starts (was clearing on "done" events)
- Completed steps shown with green checkmarks, active step only next to spinner (no duplication)
- Initial "Starting environment setup..." message shown before shell script launches
- Step messages shown instead of raw step names (human-readable)
- `ModelManager.refreshStatuses()` called on setup sheet dismiss

### DYLD_LIBRARY_PATH Fix

- **Root cause:** `DYLD_LIBRARY_PATH` was set to conda env's `lib/`, causing conda's `libiconv.2.dylib` (missing `_iconv` symbol) to shadow the system one. PyAV's `libavformat` needs `_iconv` from system libiconv.
- **Fix:** Removed `DYLD_LIBRARY_PATH` override from `PythonEnvironment.runProcess()`, `runPythonWithStderr()`, and `TranscriptionService.transcribe()`. CTranslate2 wheel bundles its dylib with correct rpaths.

### Main-Thread Blocking Fixes

Comprehensive audit found and fixed:
- **`AppUninstaller.run()`** — file deletions moved to background shell process
- **`ModelManager.deleteModel()`** — `removeItem` moved to `Task.detached`
- **`ChatViewModel.attachFile()`** — `FileStorage.copyToStorage` moved to `Task.detached`, UI updates via `MainActor.run`

### SwiftData Store Location

Investigated moving SwiftData store to `~/Library/Application Support/CTTranscriber/ct-transcriber.store`:
- Custom `ModelConfiguration(url:)` causes `EXC_BREAKPOINT` crash on `modelContext.insert()`
- **Reverted** to default `~/Library/Application Support/default.store`
- Both uninstallers clean up `default.store*` files

### Version Bump

- Version advanced from 0.1.0 to 0.2.0 (`project.yml` + `project.pbxproj`)

---

## Files Created/Modified

- **Created:** `uninstall.sh` — standalone uninstall script
- **Created:** `CTTranscriber/Services/AppUninstaller.swift` — in-app uninstaller
- **Modified:** `CTTranscriberApp.swift` — uninstall menu item, alert, spinner overlay, keyboard shortcuts
- **Modified:** `CTTranscriber/Python/setup_env.sh` — parallel installs, granular steps, logging, model download, ffmpeg fix
- **Modified:** `CTTranscriber/Services/PythonEnvironment.swift` — stderr logging, removed DYLD_LIBRARY_PATH
- **Modified:** `CTTranscriber/Services/TranscriptionService.swift` — removed DYLD_LIBRARY_PATH
- **Modified:** `CTTranscriber/Views/EnvironmentSetupView.swift` — persistent spinner, step messages, initial message
- **Modified:** `CTTranscriber/Views/ContentView.swift` — refreshStatuses on setup dismiss
- **Modified:** `CTTranscriber/Views/SettingsView.swift` — pass modelManager to EnvironmentSettingsTab
- **Modified:** `CTTranscriber/Services/ModelManager.swift` — async deleteModel
- **Modified:** `CTTranscriber/ViewModels/ChatViewModel.swift` — async attachFile
- **Modified:** `Assets.xcassets/AppIcon.appiconset/` — custom robot icon
- **Modified:** `project.yml`, `project.pbxproj` — version 0.2.0
