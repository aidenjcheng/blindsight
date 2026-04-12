import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                apiSection
                safetySection
                voiceSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let engine = appState.navigationEngine {
                            engine.geminiService.configure(apiKey: appState.geminiAPIKey)
                            engine.speechService.configure(speechRate: Float(appState.voiceSpeed))
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(BNTheme.textPrimary)
                }
            }
        }
    }

    // MARK: - API

    private var apiSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Gemini API Key", systemImage: "key.fill")
                    .font(BNTheme.Font.caption)
                    .foregroundColor(BNTheme.textSecondary)

                SecureField("Enter your API key", text: $appState.geminiAPIKey)
                    .textContentType(.password)
                    .font(BNTheme.Font.mono)
                    .foregroundColor(BNTheme.textPrimary)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: BNTheme.Radius.sm, style: .continuous)
                            .fill(Color(.tertiarySystemGroupedBackground))
                    )
            }
            .padding(.vertical, 4)
        } header: {
            sectionHeader("API Configuration", icon: "server.rack")
        } footer: {
            Text("Get your API key from Google AI Studio. The key is stored locally on this device.")
        }
    }

    // MARK: - Safety

    private var safetySection: some View {
        Section {
            sliderRow(
                label: "Danger distance",
                value: $appState.dangerDistance,
                range: 0.2...1.0,
                step: 0.1,
                format: "%.1f m",
                tint: BNTheme.danger,
                icon: "exclamationmark.octagon.fill"
            )

            sliderRow(
                label: "Warning distance",
                value: $appState.warningDistance,
                range: 0.5...2.0,
                step: 0.1,
                format: "%.1f m",
                tint: BNTheme.warning,
                icon: "exclamationmark.triangle.fill"
            )
        } header: {
            sectionHeader("Safety Thresholds", icon: "shield.checkered")
        } footer: {
            Text("Danger triggers an urgent stop alert. Warning gives a gentle caution.")
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section {
            sliderRow(
                label: "Speech speed",
                value: $appState.voiceSpeed,
                range: 0.3...0.7,
                step: 0.05,
                displayValue: speedLabel,
                tint: BNTheme.brandPrimary,
                icon: "waveform"
            )
        } header: {
            sectionHeader("Voice", icon: "speaker.wave.3.fill")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Label("Version", systemImage: "info.circle")
                    .font(BNTheme.Font.bodyRegular)
                    .foregroundColor(BNTheme.textPrimary)
                Spacer()
                Text("1.0.0")
                    .font(BNTheme.Font.mono)
                    .foregroundColor(BNTheme.textSecondary)
            }
        } header: {
            sectionHeader("About", icon: "heart.fill")
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(BNTheme.brandPrimary)
            Text(title)
                .foregroundColor(BNTheme.textSecondary)
        }
    }

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String? = nil,
        displayValue: String? = nil,
        tint: Color,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(label, systemImage: icon)
                    .font(BNTheme.Font.bodyRegular)
                    .foregroundColor(BNTheme.textPrimary)
                Spacer()
                if let displayValue {
                    Text(displayValue)
                        .font(BNTheme.Font.mono)
                        .foregroundColor(BNTheme.textSecondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: displayValue)
                } else if let format {
                    Text(String(format: format, value.wrappedValue))
                        .font(BNTheme.Font.mono)
                        .foregroundColor(BNTheme.textSecondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: value.wrappedValue)
                }
            }
            Slider(value: value, in: range, step: step)
                .tint(tint)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(displayValue ?? String(format: format ?? "%.1f", value.wrappedValue))")
    }

    private var speedLabel: String {
        if appState.voiceSpeed < 0.4 { return "Slow" }
        if appState.voiceSpeed < 0.55 { return "Normal" }
        return "Fast"
    }
}
