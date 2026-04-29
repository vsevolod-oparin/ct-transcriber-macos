import Foundation
@preconcurrency import SwiftData
import SwiftUI

/// Protocol for task management — enables mock injection for testing.
@MainActor
protocol TaskManagerProtocol: AnyObject {
    var tasks: [BackgroundTask] { get }
    var activeCount: Int { get }
    func createTask(kind: TaskKind, title: String, conversationTitle: String?, context: String?) -> BackgroundTask
    func deleteTask(_ task: BackgroundTask)
    func cancelTask(_ task: BackgroundTask)
    func clearCompleted()
}

/// Manages all long-running background tasks (transcriptions, downloads, env setup).
@Observable
@MainActor
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

    nonisolated deinit {
        AppLogger.debug("TaskManager deinit", category: "lifecycle")
    }

    // MARK: - Task CRUD

    func createTask(kind: TaskKind, title: String, conversationTitle: String? = nil, context: String? = nil) -> BackgroundTask {
        let task = BackgroundTask(kind: kind, title: title, conversationTitle: conversationTitle)
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

    func startTask(_ task: BackgroundTask, work: @escaping (BackgroundTask, @escaping @Sendable (Double) -> Void) async throws -> Void) {
        task.status = .running
        task.progress = 0
        task.errorMessage = nil
        task.updatedAt = Date()
        saveAndRefresh()

        let taskID = task.id
        activeTasks[taskID] = Task { [weak self] in
            guard let ref = self?.tasks.first(where: { $0.id == taskID && !$0.isDeleted && $0.modelContext != nil }) else { return }
            do {
                try await work(ref) { progress in
                    Task { @MainActor [weak self] in
                        guard let task = self?.tasks.first(where: { $0.id == taskID && !$0.isDeleted && $0.modelContext != nil }) else { return }
                        task.progress = progress
                        task.updatedAt = Date()
                        self?.saveAndRefresh()
                    }
                }

                if let t = self?.tasks.first(where: { $0.id == taskID && !$0.isDeleted && $0.modelContext != nil }) {
                    t.status = .completed
                    t.progress = 1.0
                    t.updatedAt = Date()
                }
                self?.activeTasks.removeValue(forKey: taskID)
                self?.saveAndRefresh()
            } catch is CancellationError {
                if let t = self?.tasks.first(where: { $0.id == taskID && !$0.isDeleted && $0.modelContext != nil }) {
                    t.status = .cancelled
                    t.updatedAt = Date()
                }
                self?.activeTasks.removeValue(forKey: taskID)
                self?.saveAndRefresh()
            } catch {
                if let t = self?.tasks.first(where: { $0.id == taskID && !$0.isDeleted && $0.modelContext != nil }) {
                    t.status = .failed
                    t.errorMessage = error.localizedDescription
                    t.updatedAt = Date()
                }
                self?.activeTasks.removeValue(forKey: taskID)
                self?.saveAndRefresh()
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

    func retryTask(_ task: BackgroundTask, work: @escaping (BackgroundTask, @escaping @Sendable (Double) -> Void) async throws -> Void) {
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
        do {
            tasks = try modelContext.fetch(descriptor)
        } catch {
            AppLogger.error("Failed to fetch tasks: \(error)", category: "tasks")
            tasks = []
        }
    }

    private func saveAndRefresh() {
        do {
            try modelContext.save()
        } catch {
            AppLogger.error("Failed to save task context: \(error)", category: "tasks")
        }
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
