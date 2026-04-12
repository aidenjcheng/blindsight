import SwiftUI

struct NavigationActiveView: View {
    @EnvironmentObject var appState: AppState
    @State private var showDebugVisualization = false
    @State private var appearAnimated = false

    var body: some View {
        ZStack {
            BNTheme.pageBg
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, BNTheme.Spacing.lg)
                    .padding(.top, BNTheme.Spacing.sm)

                Spacer()

                centralStatus
                    .padding(.horizontal, BNTheme.Spacing.lg)

                Spacer()

                bottomActions
                    .padding(.horizontal, BNTheme.Spacing.lg)
                    .padding(.bottom, BNTheme.Spacing.xl)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showDebugVisualization)
        .onTapGesture(count: 3) {
            appState.stopNavigation()
        }
        .accessibilityAction(.escape) {
            appState.stopNavigation()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                appearAnimated = true
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack(spacing: BNTheme.Spacing.sm) {
            HStack(spacing: BNTheme.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(phaseColor.opacity(0.12))
                        .frame(width: 36, height: 36)

                    Image(systemName: phaseIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(phaseColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(phaseLabel)
                        .font(BNTheme.Font.captionSmall)
                        .foregroundColor(BNTheme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .contentTransition(.numericText())
                        .animation(.default, value: phaseLabel)

                    Text(appState.session.destination)
                        .font(BNTheme.Font.bodyMedium)
                        .foregroundColor(BNTheme.textPrimary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(.default, value: appState.session.destination)
                }

                Spacer()

                if let dist = appState.session.estimatedDistanceToGoal {
                    Text(String(format: "%.1f m", dist))
                        .font(BNTheme.Font.mono)
                        .foregroundColor(BNTheme.textSecondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: dist)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassInset(cornerRadius: BNTheme.Radius.full)
                }
            }

            if appState.session.isFinalDestinationVisible {
                HStack(spacing: 8) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Destination in sight!")
                        .font(BNTheme.Font.caption)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .foregroundColor(BNTheme.success)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: BNTheme.Radius.sm, style: .continuous)
                        .fill(BNTheme.success.opacity(0.08))
                )
                .glassInset(cornerRadius: BNTheme.Radius.sm)
            }
        }
        .padding(BNTheme.Spacing.md)
        .glassCard(cornerRadius: BNTheme.Radius.lg)
        .opacity(appearAnimated ? 1 : 0)
        .offset(y: appearAnimated ? 0 : -12)
    }

    // MARK: - Central Status

    private var centralStatus: some View {
        VStack(spacing: BNTheme.Spacing.md) {
            if let alertText = safetyAlertText {
                safetyAlertCard(alertText)
            }

            if appState.isVoiceCommandProcessing {
                voiceProcessingCard
            } else if appState.isVoiceCommandListening {
                voiceListeningHint
            }

            if let goal = appState.session.currentSecondaryGoal?.descriptor {
                goalCard(goal)
            }

            Text(appState.session.statusMessage)
                .font(BNTheme.Font.bodyRegular)
                .foregroundColor(BNTheme.textTertiary)
                .multilineTextAlignment(.center)
                .contentTransition(.numericText())
                .animation(.default, value: appState.session.statusMessage)
                .padding(.horizontal, BNTheme.Spacing.sm)
        }
        .opacity(appearAnimated ? 1 : 0)
    }

    private func safetyAlertCard(_ alertText: String) -> some View {
        let alertColor = alertIsUrgent ? BNTheme.danger : BNTheme.warning
        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(alertColor)
            Text(alertText)
                .font(BNTheme.Font.bodyMedium)
                .foregroundColor(BNTheme.textPrimary)
                .contentTransition(.numericText())
                .animation(.default, value: alertText)
        }
        .padding(.horizontal, BNTheme.Spacing.lg)
        .padding(.vertical, BNTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
                .fill(alertColor.opacity(0.1))
        )
        .glassCard(cornerRadius: BNTheme.Radius.md)
        .overlay(
            RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
                .stroke(alertColor.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityLabel("Safety alert: \(alertText)")
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }

    private var voiceProcessingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(BNTheme.brandAccent)
                .scaleEffect(0.9)
            VStack(alignment: .leading, spacing: 3) {
                Text("Processing voice command...")
                    .font(BNTheme.Font.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(BNTheme.textPrimary)
                if !appState.lastVoiceCommand.isEmpty {
                    Text("\"\(appState.lastVoiceCommand)\"")
                        .font(BNTheme.Font.captionSmall)
                        .foregroundColor(BNTheme.textTertiary)
                        .contentTransition(.numericText())
                        .animation(.default, value: appState.lastVoiceCommand)
                }
            }
        }
        .padding(.horizontal, BNTheme.Spacing.md)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: BNTheme.Radius.md)
        .accessibilityLabel("Processing voice command: \(appState.lastVoiceCommand)")
    }

    private var voiceListeningHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .font(.system(size: 11))
                .foregroundColor(BNTheme.brandAccent)
            Text("Say \"\(BNConstants.voiceCommandWakeWord)\" to ask a question")
                .font(BNTheme.Font.captionSmall)
                .foregroundColor(BNTheme.textTertiary)
        }
    }

    private func goalCard(_ goal: String) -> some View {
        VStack(spacing: BNTheme.Spacing.sm) {
            Text("HEADING TOWARD")
                .font(BNTheme.Font.captionSmall)
                .foregroundColor(BNTheme.textTertiary)
                .tracking(1.2)

            Text(goal)
                .font(BNTheme.Font.sectionTitle)
                .foregroundColor(BNTheme.textPrimary)
                .multilineTextAlignment(.center)
                .contentTransition(.numericText())
                .animation(.default, value: goal)
        }
        .padding(.vertical, BNTheme.Spacing.lg)
        .padding(.horizontal, BNTheme.Spacing.md)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: BNTheme.Radius.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Currently heading toward \(goal)")
    }

    // MARK: - Bottom Actions

    private var bottomActions: some View {
        VStack(spacing: BNTheme.Spacing.sm) {
            Button(action: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showDebugVisualization.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: showDebugVisualization ? "eye.slash" : "eye")
                        .font(.system(size: 13, weight: .medium))
                    Text(showDebugVisualization ? "Hide Debug View" : "Show Debug View")
                        .font(BNTheme.Font.caption)
                }
                .foregroundColor(BNTheme.textSecondary)
                .padding(.horizontal, BNTheme.Spacing.md)
                .padding(.vertical, BNTheme.Spacing.sm)
                .glassInset(cornerRadius: BNTheme.Radius.full)
            }
            .accessibilityLabel("Toggle debug visualization")

            if showDebugVisualization {
                HStack(alignment: .top, spacing: BNTheme.Spacing.sm) {
                    CameraDebugView()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipped()
                    DepthVisualizationView(depthMap: appState.debugDepthMap)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipped()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if appState.session.phase == .arrived {
                AccessibleButton(
                    title: "Done",
                    systemImage: "checkmark.circle.fill",
                    style: .primary,
                    action: {
                        appState.session.phase = .idle
                        appState.session.statusMessage = "Ready"
                    }
                )
            } else {
                AccessibleButton(
                    title: "Stop Navigation",
                    systemImage: "stop.fill",
                    style: .destructive,
                    action: { appState.stopNavigation() }
                )
                .accessibilityHint("Stops navigation and returns to the home screen")
            }
        }
    }

    // MARK: - Computed

    private var phaseIcon: String {
        switch appState.session.phase {
        case .idle: return "circle"
        case .listening: return "mic.fill"
        case .planning: return "brain"
        case .navigating: return "location.fill"
        case .arrived: return "checkmark.circle.fill"
        }
    }

    private var phaseColor: Color {
        switch appState.session.phase {
        case .idle: return BNTheme.textTertiary
        case .listening: return BNTheme.brandAccent
        case .planning: return BNTheme.warning
        case .navigating: return BNTheme.brandPrimary
        case .arrived: return BNTheme.success
        }
    }

    private var phaseLabel: String {
        switch appState.session.phase {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .planning: return "Planning"
        case .navigating: return "Navigating"
        case .arrived: return "Arrived"
        }
    }

    private var safetyAlertText: String? {
        switch appState.session.safetyAlert {
        case .clear:
            return nil
        case .caution(_, let dist):
            return "Caution: object \(String(format: "%.1f", dist))m ahead"
        case .danger(_, let dist):
            return "DANGER: obstacle \(String(format: "%.1f", dist))m ahead!"
        case .groundUnsafe:
            return "Ground ahead may not be safe"
        }
    }

    private var alertIsUrgent: Bool {
        if case .danger = appState.session.safetyAlert { return true }
        return false
    }
}
