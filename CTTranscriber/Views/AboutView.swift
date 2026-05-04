import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fontScale) private var fontScale

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        let s = CGFloat(fontScale)
        VStack(spacing: 16 * s) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64 * s))
                .foregroundStyle(Color.accentColor)

            Text("CT Transcriber")
                .font(sf.title)
                .fontWeight(.bold)

            Text("Version \(version) (\(build))")
                .font(sf.caption)
                .foregroundStyle(.secondary)

            Text("Audio & video transcription powered by CTranslate2 Metal backend on Apple Silicon.")
                .font(sf.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300 * s)

            Text("by Vsevolod Oparin")
                .font(sf.body)
                .foregroundStyle(.secondary)

            Divider()

            VStack(spacing: 4 * s) {
                Text("CTranslate2 Metal Backend")
                    .font(sf.caption)
                    .fontWeight(.medium)
                Text("faster-whisper · Whisper Models")
                    .font(sf.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                if let url = URL(string: "https://github.com/vsevolod-oparin/ct-transcriber-macos") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("GitHub Repository")
                }
                .font(sf.caption)
            }
            .buttonStyle(.link)

            Button("OK") { dismiss() }
                .keyboardShortcut(.return)
        }
        .padding(24 * s)
        .fixedSize(horizontal: false, vertical: true)
        .focusable()
        .focusEffectDisabled()
        .onExitCommand { dismiss() }
        .onKeyPress(.return) {
            dismiss()
            return .handled
        }
    }
}
