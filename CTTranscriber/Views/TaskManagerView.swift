import SwiftUI

struct TaskManagerView: View {
    @Bindable var taskManager: TaskManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        VStack(spacing: 0) {
            // Header — pinned at top
            HStack {
                Text("Background Tasks")
                    .font(sf.title2)
                    .fontWeight(.semibold)
                Spacer()
                if taskManager.tasks.contains(where: { $0.status == .completed }) {
                    Button("Clear Completed") {
                        taskManager.clearCompleted()
                    }
                    .controlSize(.small)
                }
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            // Content
            if taskManager.tasks.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 36 * CGFloat(fontScale)))
                        .foregroundStyle(.secondary)
                    Text("No Tasks")
                        .font(sf.headline)
                    Text("Background tasks like transcriptions and model downloads will appear here.")
                        .font(sf.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else {
                List {
                    ForEach(taskManager.tasks) { task in
                        TaskRow(task: task, taskManager: taskManager)
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
        .focusable()
        .focusEffectDisabled()
        .onExitCommand { dismiss() }
        .onKeyPress(.return) {
            dismiss()
            return .handled
        }
    }
}

// MARK: - Task Row

private struct TaskRow: View {
    let task: BackgroundTask
    let taskManager: TaskManager
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        VStack(alignment: .leading, spacing: 6) {
            // Primary line: icon + status prefix + filename
            HStack(alignment: .top) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(sf.title3)

                VStack(alignment: .leading, spacing: 2) {
                    // Status prefix + original filename
                    HStack(spacing: 4) {
                        Text(statusPrefix)
                            .font(sf.caption)
                            .foregroundStyle(statusColor)
                            .fontWeight(.medium)
                        Text(task.title)
                            .font(sf.headline)
                            .lineLimit(2)
                    }

                    // Conversation title
                    if let convoTitle = task.conversationTitle, !convoTitle.isEmpty {
                        Text("in \(convoTitle)")
                            .font(sf.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Task ID (small, subtle)
                    Text(task.id.uuidString.prefix(8).lowercased())
                        .font(sf.caption2)
                        .foregroundStyle(.tertiary)
                        .monospaced()
                }

                Spacer()
                actionButtons
            }

            if task.status == .running {
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                Text("\(Int(task.progress * 100))%")
                    .font(sf.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Text(task.createdAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(sf.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = task.errorMessage {
                Text(error)
                    .font(sf.caption)
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

    private var statusPrefix: String {
        switch task.status {
        case .pending: "Queued:"
        case .running: "Transcribing"
        case .completed: "Transcribed"
        case .failed: "Failed:"
        case .cancelled: "Cancelled:"
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

        case .failed, .cancelled, .completed:
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
