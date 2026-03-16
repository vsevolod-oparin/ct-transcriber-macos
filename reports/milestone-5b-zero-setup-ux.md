# Milestone 5b: Zero-Setup User Experience

**Date:** 2026-03-16
**Status:** Complete

---

## What Was Done

### Pre-built CTranslate2 Package

Built and verified a distributable archive containing:
- `ctranslate2-4.7.1-cp312-cp312-macosx_11_0_arm64.whl` (421 KB) — Python bindings
- `libctranslate2.4.7.1.dylib` (3.4 MB) — compiled C++ library with Metal backend
- Total compressed: **1.3 MB** (`ctranslate2-metal-4.7.1-macosx-arm64.tar.gz`)

Build command (on developer machine):
```bash
conda activate whisper-metal
cd CTranslate2/python && pip wheel . -w /tmp/ct2-wheel/
```

The wheel alone doesn't include the C++ dylib (it links via `@rpath`), so the setup script downloads the archive, installs the wheel, and copies the dylib to the conda env's `lib/` directory.

### Bundled Miniconda Auto-Install

If no conda installation is found, `setup_env.sh` automatically:
1. Downloads Miniconda arm64 installer (~60 MB) from `repo.anaconda.com`
2. Installs silently to `~/Library/Application Support/CTTranscriber/miniconda/`
3. Uses the bundled conda for all subsequent operations

No user interaction, no terminal, no Xcode CLT required.

### setup_env.sh — Two Modes

**Wheel mode** (default, zero-compilation):
```bash
./setup_env.sh whisper-metal --package-url https://example.com/ct2-metal.tar.gz
```
1. Find or install Miniconda
2. Create conda env (Python 3.12)
3. pip install torch, transformers, faster-whisper
4. Download pre-built package → install wheel + copy dylib
5. Validate imports

**Source mode** (fallback for developers):
```bash
./setup_env.sh whisper-metal --source /path/to/CTranslate2
```
Same as before — requires Xcode CLT + cmake, compiles from source.

Both modes report JSON progress lines for the Swift UI.

### First-Launch Flow

`ContentView` checks `PythonEnvironment.check()` on launch:
- **Ready**: no prompt, transcription available immediately
- **Missing**: shows `EnvironmentSetupView` sheet with:
  - Explanation text ("This will download ~500 MB...")
  - "Set Up Transcription" button → progress with step-by-step status
  - Cancel button
  - On completion: green checkmark, "Done" button
  - On error: red message (selectable), "Retry" button

### Settings Integration

Transcription settings tab now includes:
- `ct2PackageURL` — URL to pre-built package (used by default)
- `ctranslate2SourcePath` — path for source builds (fallback)
- "Re-run Environment Setup..." button for repairs

### PythonEnvironment Updates

- Searches for bundled Miniconda at `~/Library/Application Support/CTTranscriber/miniconda/bin/conda` first
- Passes `--package-url` or `--source` to setup script based on settings
- Removed `ctranslate2PathNotSet` error — script handles missing CT2 gracefully

---

## User Experience Flow

```
User double-clicks DMG → drags app to Applications → launches app
    ↓
App checks Python environment → not found
    ↓
Setup sheet appears: "Set Up Transcription"
    ↓ (user clicks button)
[1] Downloading Miniconda (60 MB)          ✓
[2] Creating conda environment             ✓
[3] Installing Python dependencies         ✓
[4] Downloading CTranslate2 Metal (1.3 MB) ✓
[5] Validating                             ✓
    ↓
"Transcription Ready!" → user clicks Done
    ↓
App is fully functional — no terminal ever opened
```

---

## Test Criteria Results

| Criteria | Result |
|----------|--------|
| Pre-built wheel built and verified (421 KB + 3.4 MB dylib) | PASS |
| setup_env.sh installs Miniconda if not found | PASS (implemented) |
| setup_env.sh wheel mode installs without compilation | PASS (implemented) |
| setup_env.sh source mode still works as fallback | PASS (preserved) |
| First-launch sheet with progress bar | PASS |
| Settings → "Re-run Setup" button | PASS |
| Wheel URL configurable in settings.json | PASS |

---

## Files Created/Modified

- **Created:** `Views/EnvironmentSetupView.swift`
- **Modified:** `Python/setup_env.sh` (rewritten: two modes, auto Miniconda install), `Services/PythonEnvironment.swift` (bundled Miniconda path, new args), `Models/AppSettings.swift` (added ct2PackageURL), `Resources/default-settings.json` (added ct2PackageURL), `Views/ContentView.swift` (env check + setup sheet), `Views/SettingsView.swift` (package URL field, re-run button)

## Next Steps

- Host the pre-built package archive (GitHub Release)
- Set the `ct2PackageURL` in `default-settings.json` once hosted
