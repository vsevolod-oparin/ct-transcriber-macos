# Milestone 8: Background Task Manager

**Date:** 2026-03-17
**Status:** Complete

---

## What Was Done

### BackgroundTask Model (SwiftData)

`BackgroundTask` persisted in SwiftData:
- `id`, `kind` (transcription/modelDownload/pythonSetup), `title`, `status`, `progress`, `errorMessage`
- `createdAt`, `updatedAt` timestamps
- `contextJSON` for retry context
- Status enum: pending, running, completed, failed, cancelled

### TaskManager Service (`@Observable`)

- `tasks` array fetched from SwiftData, sorted by creation date
- `activeCount` — number of running tasks (drives toolbar badge)
- `createTask(kind:title:context:)` — creates and persists a new task
- `startTask(_:work:)` — runs async work with progress callback, manages status transitions
- `cancelTask(_:)` — cancels the Swift Task, updates status
- `retryTask(_:work:)` — resets and re-starts a failed/cancelled task
- `deleteTask(_:)` — removes from SwiftData
- `clearCompleted()` — batch delete completed tasks
- **Crash recovery**: on init, any tasks with `.running` status are marked `.failed` with "App was closed during execution"

### Task Manager UI

Toolbar button (list.bullet.rectangle icon) with red badge showing active task count:
- Opens a sheet with all background tasks
- Each task row shows: icon (by kind), title, status with color, progress bar (when running), timestamps, error message (when failed)
- Actions: cancel (running), delete (completed/failed/cancelled)
- "Clear Completed" button when applicable
- "Done" button to close

### Integration with Transcription

When a transcription starts:
1. Placeholder message (`⏳ Queued: filename.mp3`) created immediately after the audio attachment — always paired
2. `BackgroundTask` created with kind `.transcription`
3. Progress updates reflected on both the chat bubble and the background task
4. On completion/cancel/failure, task status updated accordingly
5. Task persists in SwiftData — visible in task manager even after conversation switch

### Transcription Queue

- Multiple audio attachments are queued sequentially (not parallel by default)
- Configurable `maxParallelTranscriptions` in Settings → Transcription (default 1, range 1–4)
- When a transcription finishes, the next queued one starts automatically
- Each queued transcription shows a placeholder in the chat immediately, updated when processing begins

### Wiring

- `TaskManager` created in `ContentView.task {}` with shared `ModelContext`
- Injected into `ChatViewModel` as `taskManager`
- `BackgroundTask.self` registered in model container
- Toolbar button in main navigation

---

## Files Created/Modified

- **Created:** `Models/BackgroundTask.swift`, `Services/TaskManager.swift`, `Views/TaskManagerView.swift`
- **Modified:** `Views/ContentView.swift` (TaskManager creation, toolbar button, sheet), `ViewModels/ChatViewModel.swift` (taskManager property, transcription queue with configurable parallelism, placeholder messages paired with audio), `Models/AppSettings.swift` (maxParallelTranscriptions), `Resources/default-settings.json` (maxParallelTranscriptions), `Views/SettingsView.swift` (parallel limit stepper), `App/CTTranscriberApp.swift` (BackgroundTask in model container)
