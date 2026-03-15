import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var modelManager: ModelManager

    private let languages: [(String, String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("de", "German"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // MARK: - Header
            Text("Vox Populi")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            // MARK: - Activation Mode
            VStack(alignment: .leading, spacing: 4) {
                Picker("Activation", selection: $appState.hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appState.hotkeyMode) { _ in appState.save() }

                Text("Right Option key")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // MARK: - Model Selection
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(ModelManager.whisperModels, id: \.name) { model in
                    HStack {
                        Text(model.displayName)
                            .font(.system(size: 12))

                        Spacer()

                        modelActionView(for: model)
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            // MARK: - Language
            Picker("Language", selection: $appState.selectedLanguage) {
                ForEach(languages, id: \.0) { code, label in
                    Text(label).tag(code)
                }
            }
            .onChange(of: appState.selectedLanguage) { _ in appState.save() }

            Divider()

            // MARK: - AI Cleanup
            VStack(alignment: .leading, spacing: 4) {
                Toggle("AI Cleanup", isOn: $appState.aiCleanupEnabled)
                    .onChange(of: appState.aiCleanupEnabled) { _ in appState.save() }

                Text("Use a local LLM to clean up transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // MARK: - Footer
            HStack {
                Text("v1.0.0")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Model Action

    @ViewBuilder
    private func modelActionView(for model: WhisperModelInfo) -> some View {
        if modelManager.isModelDownloaded(model.name) {
            if appState.selectedWhisperModel == model.name {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
            } else {
                Button("Select") {
                    appState.selectedWhisperModel = model.name
                    appState.save()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }
        } else if modelManager.isDownloading && modelManager.currentDownloadModel == model.name {
            HStack(spacing: 4) {
                ProgressView(value: modelManager.downloadProgress)
                    .frame(width: 60)
                Text("\(Int(modelManager.downloadProgress * 100))%")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        } else {
            Button("Download") {
                modelManager.downloadModel(name: model.name) { result in
                    if case .success = result {
                        DispatchQueue.main.async {
                            self.appState.selectedWhisperModel = model.name
                            self.appState.save()
                        }
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .disabled(modelManager.isDownloading)
        }
    }
}
