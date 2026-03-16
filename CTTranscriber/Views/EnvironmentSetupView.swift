import SwiftUI

/// Sheet shown when the Python environment needs setup.
struct EnvironmentSetupView: View {
    var settingsManager: SettingsManager
    @State private var isRunning = false
    @State private var isDone = false
    @State private var currentStep = ""
    @State private var steps: [(name: String, status: String)] = []
    @State private var errorMessage: String?
    @State private var setupTask: Task<Void, Never>?

    let reason: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Header
            Image(systemName: isDone ? "checkmark.circle.fill" : "waveform.badge.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(isDone ? .green : .accentColor)

            Text(isDone ? "Transcription Ready" : "Set Up Transcription")
                .font(.title2)
                .fontWeight(.semibold)

            if !isRunning && !isDone {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("This will download and configure the Python environment for audio transcription (~500 MB). No developer tools required.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Progress
            if isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(spacing: 6) {
                            Image(systemName: stepIcon(step.status))
                                .foregroundStyle(stepColor(step.status))
                                .frame(width: 16)
                            Text(step.name)
                                .font(.caption)
                                .foregroundStyle(step.status == "start" ? .primary : .secondary)
                        }
                    }

                    if !currentStep.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Error
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Buttons
            HStack(spacing: 12) {
                if isDone {
                    Button("Done") { onDismiss() }
                        .keyboardShortcut(.return)
                } else if isRunning {
                    Button("Cancel") { cancelSetup() }
                } else {
                    Button("Later") { onDismiss() }
                    Button("Set Up Transcription") { startSetup() }
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)

                    if errorMessage != nil {
                        Button("Retry") { startSetup() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func startSetup() {
        isRunning = true
        isDone = false
        errorMessage = nil
        steps = []
        currentStep = ""

        let settings = settingsManager.settings.transcription
        setupTask = Task {
            do {
                for try await step in PythonEnvironment.runSetup(settings: settings) {
                    await MainActor.run {
                        // Update or add step
                        if let idx = steps.firstIndex(where: { $0.name == step.step }) {
                            steps[idx] = (step.step, step.status)
                        } else {
                            steps.append((step.step, step.status))
                        }
                        currentStep = step.status == "start" ? step.message : ""
                    }
                }
                await MainActor.run {
                    isRunning = false
                    isDone = true
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelSetup() {
        setupTask?.cancel()
        setupTask = nil
        isRunning = false
        currentStep = ""
    }

    private func stepIcon(_ status: String) -> String {
        switch status {
        case "start": "circle.fill"
        case "done": "checkmark.circle.fill"
        case "error": "xmark.circle.fill"
        default: "circle"
        }
    }

    private func stepColor(_ status: String) -> Color {
        switch status {
        case "start": .accentColor
        case "done": .green
        case "error": .red
        default: .secondary
        }
    }
}
