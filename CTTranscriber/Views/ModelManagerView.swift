import SwiftUI

struct ModelManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var modelManager: ModelManager

    private var models: [WhisperModelConfig] {
        modelManager.settingsManager.settings.transcription.models
    }

    private var selectedModelID: String {
        modelManager.settingsManager.settings.transcription.selectedModelID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Whisper Models")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return)
            }
            .padding()

            Divider()

            List {
                ForEach(models) { model in
                    ModelRow(
                        model: model,
                        status: modelManager.modelStatuses[model.id] ?? .notDownloaded,
                        isSelected: selectedModelID == model.id,
                        onDownload: { modelManager.downloadModel(model) },
                        onCancel: { modelManager.cancelDownload(model.id) },
                        onDelete: { modelManager.deleteModel(model) },
                        onSelect: { modelManager.settingsManager.settings.transcription.selectedModelID = model.id }
                    )
                }
            }
        }
        .frame(width: 500, height: 350)
        .onAppear { modelManager.refreshStatuses() }
    }
}

// MARK: - Model Row

private struct ModelRow: View {
    let model: WhisperModelConfig
    let status: ModelManager.ModelStatus
    let isSelected: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .onTapGesture {
                    if case .ready = status {
                        onSelect()
                    }
                }

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.headline)

                HStack(spacing: 8) {
                    Text(model.sizeEstimate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.quantization)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                statusText
            }

            Spacer()

            // Action buttons
            actionButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusText: some View {
        switch status {
        case .notDownloaded:
            Text("Not downloaded")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .downloading(let step):
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(step)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .ready(_, let sizeMB):
            Text("Ready (\(sizeMB) MB)")
                .font(.caption2)
                .foregroundStyle(.green)
        case .error(let msg):
            Text(msg)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .notDownloaded, .error:
            Button("Download") { onDownload() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .downloading:
            Button("Cancel") { onCancel() }
                .controlSize(.small)
        case .ready:
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete model")
        }
    }
}
