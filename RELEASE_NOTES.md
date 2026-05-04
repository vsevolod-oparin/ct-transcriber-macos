# CT Transcriber 0.5.5 Release Notes

## Bug Fixes

- **Fixed Whisper model downloads not persisting across app restarts** — the most critical fix in this release. Models would show as "Ready" after downloading, but appear as "Not downloaded" after quitting and reopening the app.

## What Changed

### Model Download Persistence

The root cause was multiple interacting bugs:

1. **Dual ModelManager instances** — the Settings window created a separate throwaway `ModelManager` instead of sharing the app's instance. When Settings closed, the download's background task was cancelled, leaving incomplete model files on disk. Fixed by making `ModelManager` a singleton (`ModelManager.shared`).

2. **Download to Caches directory** — `MWModelManager`'s default cache directory is `~/Library/Caches/`, which macOS can purge at any time. If the directory wasn't set before a download started, models could land in a temporary location. Fixed by eagerly initializing the cache directory before any download can begin.

3. **Validation mismatch** — the startup scan checked for `preprocessor_config.json` (which some models don't include) but ignored `config.json` and vocabulary files (which are required). This meant even successfully downloaded models could fail the scan on next launch. Fixed to match the download validation exactly.

### Other Fixes

- Fixed cancelled downloads overwriting status back to "Ready"
- Added diagnostic logging for model download paths and incomplete model detection

## Full Changelog (0.5.4 → 0.5.5)

### Bug Fixes
- Fixed Whisper model downloads not persisting across app restarts
- Fixed `isValidModel` validation not matching `MWModelManager`'s requirements
- Fixed Settings window using a separate `ModelManager` instance whose downloads were cancelled on window close
- Fixed download potentially writing to `~/Library/Caches/` instead of Application Support
- Fixed cancelled downloads incorrectly marking models as "Ready"

### Architecture
- `ModelManager` is now a singleton (`ModelManager.shared`) — one instance for the entire app lifecycle
- `ModelManager` is eagerly initialized in `CTTranscriberApp.init()` to prevent race conditions
- `ContentView` simplified — no longer passes `ModelManager` as a binding
- Added diagnostic logging for model download path, success/failure, and incomplete model detection
