import SwiftUI

struct TaskManagerView: View {
    @Bindable var taskManager: TaskManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Background Tasks")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if taskManager.tasks.contains(where: { $0.status == .completed }) {
                    Button("Clear Completed") {
                        taskManager.clearCompleted()
                    }
                    .controlSize(.small)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return)
            }
            .padding()

            Divider()

            if taskManager.tasks.isEmpty {
                ContentUnavailableView(
                    "No Tasks",
                    systemImage: "checklist",
                    description: Text("Background tasks like transcriptions and model downloads will appear here.")
                )
            } else {
                List {
                    ForEach(taskManager.tasks) { task in
                        TaskRow(task: task, taskManager: taskManager)
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - Task Row

private struct TaskRow: View {
    let task: BackgroundTask
    let taskManager: TaskManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                actionButtons
            }

            if task.status == .running {
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                Text("\(Int(task.progress * 100))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)

                Spacer()

                Text(task.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let error = task.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch task.kind {
        case .transcription: "waveform"
        case .modelDownload: "arrow.down.circle"
        case .pythonSetup: "terminal"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .running: .accentColor
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        case .pending: .secondary
        }
    }

    private var statusText: String {
        switch task.status {
        case .pending: "Pending"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .running: .accentColor
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        case .pending: .secondary
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch task.status {
        case .running:
            Button { taskManager.cancelTask(task) } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Cancel")

        case .failed, .cancelled:
            HStack(spacing: 8) {
                Button { taskManager.deleteTask(task) } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }

        case .completed:
            Button { taskManager.deleteTask(task) } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete")

        case .pending:
            EmptyView()
        }
    }
}
