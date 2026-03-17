import Foundation
import SwiftData
import SwiftUI

/// Protocol for task management — enables mock injection for testing.
protocol TaskManagerProtocol: AnyObject {
    var tasks: [BackgroundTask] { get }
    var activeCount: Int { get }
    func createTask(kind: TaskKind, title: String, context: String?) -> BackgroundTask
    func deleteTask(_ task: BackgroundTask)
    func cancelTask(_ task: BackgroundTask)
    func clearCompleted()
}

/// Manages all long-running background tasks (transcriptions, downloads, env setup).
@Observable
final class TaskManager: TaskManagerProtocol {
    private(set) var tasks: [BackgroundTask] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var modelContext: ModelContext

    /// Number of currently running tasks — used for toolbar badge.
    var activeCount: Int {
        tasks.filter { $0.status == .running }.count
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        refreshTasks()
        recoverFromCrash()
    }

    deinit {
        AppLogger.debug("TaskManager deinit", category: "lifecycle")
    }

    // MARK: - Task CRUD

    func createTask(kind: TaskKind, title: String, context: String? = nil) -> BackgroundTask {
        let task = BackgroundTask(kind: kind, title: title)
        task.contextJSON = context
        modelContext.insert(task)
        saveAndRefresh()
        return task
    }

    func deleteTask(_ task: BackgroundTask) {
        cancelTask(task)
        modelContext.delete(task)
        saveAndRefresh()
    }

    func clearCompleted() {
        let completed = tasks.filter { $0.status == .completed }
        for task in completed {
            modelContext.delete(task)
        }
        saveAndRefresh()
    }

    // MARK: - Task Lifecycle

    func startTask(_ task: BackgroundTask, work: @escaping (BackgroundTask, @escaping (Double) -> Void) async throws -> Void) {
        task.status = .running
        task.progress = 0
        task.errorMessage = nil
        task.updatedAt = Date()
        saveAndRefresh()

        activeTasks[task.id] = Task { [weak self] in
            do {
                try await work(task) { progress in
                    Task { @MainActor in
                        task.progress = progress
                        task.updatedAt = Date()
                        self?.saveAndRefresh()
                    }
                }

                await MainActor.run {
                    task.status = .completed
                    task.progress = 1.0
                    task.updatedAt = Date()
                    self?.activeTasks.removeValue(forKey: task.id)
                    self?.saveAndRefresh()
                }
            } catch is CancellationError {
                await MainActor.run {
                    task.status = .cancelled
                    task.updatedAt = Date()
                    self?.activeTasks.removeValue(forKey: task.id)
                    self?.saveAndRefresh()
                }
            } catch {
                await MainActor.run {
                    task.status = .failed
                    task.errorMessage = error.localizedDescription
                    task.updatedAt = Date()
                    self?.activeTasks.removeValue(forKey: task.id)
                    self?.saveAndRefresh()
                }
            }
        }
    }

    func cancelTask(_ task: BackgroundTask) {
        activeTasks[task.id]?.cancel()
        activeTasks.removeValue(forKey: task.id)
        if task.status == .running {
            task.status = .cancelled
            task.updatedAt = Date()
            saveAndRefresh()
        }
    }

    func retryTask(_ task: BackgroundTask, work: @escaping (BackgroundTask, @escaping (Double) -> Void) async throws -> Void) {
        task.status = .pending
        task.errorMessage = nil
        task.progress = 0
        task.updatedAt = Date()
        saveAndRefresh()
        startTask(task, work: work)
    }

    // MARK: - Private

    private func refreshTasks() {
        let descriptor = FetchDescriptor<BackgroundTask>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        tasks = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func saveAndRefresh() {
        try? modelContext.save()
        refreshTasks()
    }

    /// On launch, mark any previously-running tasks as failed (they didn't complete before quit/crash).
    private func recoverFromCrash() {
        var didChange = false
        for task in tasks where task.status == .running {
            task.status = .failed
            task.errorMessage = "App was closed during execution"
            task.updatedAt = Date()
            didChange = true
        }
        if didChange {
            saveAndRefresh()
        }
    }
}
