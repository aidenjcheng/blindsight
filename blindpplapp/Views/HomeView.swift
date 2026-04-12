import Combine
import SwiftUI
import os

struct HomeView: View {
 @EnvironmentObject var appState: AppState
 @State private var manualDestination = ""
 @State private var showManualInput = false
 @State private var isListening = false
 @State private var recognizedText = ""
 @State private var permissionsGranted = false
 @State private var permissionError: String?
 @State private var isRequestingPermissions = false
 @State private var transcriptionCancellable: AnyCancellable?
 @State private var liveTextCancellable: AnyCancellable?
 @State private var appearAnimated = false
 @State private var showNavigationView = false
 @State private var waveformMonitor = AudioWaveformMonitor.shared

 var body: some View {
  ZStack {
   BNTheme.pageBg
    .ignoresSafeArea()

   VStack(spacing: 0) {
    Spacer()

    heroSection
     .padding(.bottom, BNTheme.Spacing.xxl)

    actionSection
     .padding(.horizontal, BNTheme.Spacing.lg)

    Spacer()

    if let error = permissionError {
     errorBanner(error)
    }

    bottomBar
   }
  }
  .onAppear {
   bootstrapIfNeeded()
   Task { await requestPermissions() }
   withAnimation(.easeOut(duration: 0.3)) {
    appearAnimated = true
   }
  }
  .sheet(isPresented: $appState.isSettingsPresented) {
   SettingsView()
  }
  .alert("Enter Destination", isPresented: $showManualInput) {
   TextField("e.g. bathroom, exit, elevator", text: $manualDestination)
   Button("Go") {
    if !manualDestination.trimmingCharacters(in: .whitespaces).isEmpty {
     withAnimation(.easeInOut(duration: 0.3)) {
      showNavigationView = true
     }
    }
   }
   Button("Cancel", role: .cancel) {
    manualDestination = ""
   }
  } message: {
   Text("Type where you want to go")
  }
  .fullScreenCover(isPresented: $showNavigationView) {
   NavigationWithSpatialAudioView(
    destinationName: manualDestination,
    onDismiss: {
     showNavigationView = false
    })
  }
 }

 // MARK: - Hero

 private var heroSection: some View {
  VStack(spacing: BNTheme.Spacing.sm) {
   Text("BlindNav")
    .font(BNTheme.Font.heroTitle)
    .foregroundColor(BNTheme.textPrimary)

   Text("Indoor Navigation Assistant")
    .font(BNTheme.Font.heroSubtitle)
    .foregroundColor(BNTheme.textSecondary)
  }
  .opacity(appearAnimated ? 1 : 0)
  .offset(y: appearAnimated ? 0 : 12)
 }

 // MARK: - Action

 private var actionSection: some View {
  VStack(spacing: BNTheme.Spacing.md) {
   if isListening {
    listeningCard
   } else {
    idleCard
   }
  }
  .opacity(appearAnimated ? 1 : 0)
  .offset(y: appearAnimated ? 0 : 16)
 }

 private var listeningCard: some View {
  VStack(spacing: BNTheme.Spacing.lg) {
   AudioWaveformView(
    barLevels: waveformMonitor.barLevels,
    barColor: BNTheme.textPrimary,
    maxHeight: 64,
    barWidth: 6,
    spacing: 5
   )

   Text(
    recognizedText.isEmpty
     ? "Listening... say where you want to go"
     : recognizedText
   )
   .font(BNTheme.Font.bodyMedium)
   .multilineTextAlignment(.center)
   .foregroundColor(recognizedText.isEmpty ? BNTheme.textTertiary : BNTheme.textPrimary)
   .contentTransition(.numericText())
   .animation(.default, value: recognizedText)
   .frame(minHeight: 50)

   VStack(spacing: BNTheme.Spacing.sm) {
    AccessibleButton(
     title: "Tap to Stop",
     systemImage: "record.circle",
     style: .destructive,
     action: { submitTranscription() }
    )
    .accessibilityLabel("Tap to stop listening and submit destination")

    AccessibleButton(
     title: "Cancel",
     systemImage: "xmark",
     style: .secondary,
     action: { stopListening() }
    )
   }
  }
  .padding(BNTheme.Spacing.lg)
  .glassCard()
  .accessibilityElement(children: .combine)
  .accessibilityLabel("Listening for your destination. \(recognizedText)")
  .transition(.scale(scale: 0.95).combined(with: .opacity))
 }

 private var idleCard: some View {
  VStack(spacing: BNTheme.Spacing.md) {
   AccessibleButton(
    title: "Tap to Start",
    systemImage: "mic.fill",
    style: .destructive,
    action: {
     if permissionsGranted {
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      appState.navigationEngine?.speechService.speak("Where do you want to go?", priority: .urgent)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
       withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
        startListening()
       }
      }
     } else {
      Task { await requestPermissions() }
     }
    }
   )
   .accessibilityHint("Activates voice input so you can say your destination")

   Button {
    showManualInput = true
   } label: {
    HStack(spacing: 6) {
     Image(systemName: "keyboard")
      .font(.system(size: 13, weight: .medium))
     Text("Or type your destination")
      .font(BNTheme.Font.caption)
    }
    .foregroundColor(BNTheme.textTertiary)
   }
   .accessibilityLabel("Type destination manually")
  }
  .transition(.scale(scale: 0.95).combined(with: .opacity))
 }

 // MARK: - Error

 private func errorBanner(_ error: String) -> some View {
  HStack(spacing: BNTheme.Spacing.sm) {
   Image(systemName: "exclamationmark.circle.fill")
    .foregroundColor(BNTheme.danger)
   Text(error)
    .font(BNTheme.Font.caption)
    .foregroundColor(BNTheme.textPrimary)
  }
  .padding(.horizontal, BNTheme.Spacing.md)
  .padding(.vertical, BNTheme.Spacing.sm)
  .glassInset()
  .padding(.horizontal, BNTheme.Spacing.lg)
  .padding(.bottom, BNTheme.Spacing.sm)
 }

 // MARK: - Bottom

 private var bottomBar: some View {
  HStack {
   Spacer()

   Button {
    appState.isSettingsPresented = true
   } label: {
    Image(systemName: "gearshape.fill")
     .font(.system(size: 18, weight: .medium))
     .foregroundColor(BNTheme.textSecondary)
     .frame(width: 48, height: 48)
     .background(
      Circle()
       .fill(.ultraThinMaterial)
       .overlay(
        Circle()
         .stroke(.white.opacity(0.5), lineWidth: 0.5)
       )
     )
   }
   .accessibilityLabel("Settings")
  }
  .padding(.horizontal, BNTheme.Spacing.lg)
  .padding(.bottom, BNTheme.Spacing.md)
 }

 // MARK: - Actions

 private func bootstrapIfNeeded() {
  guard appState.navigationEngine == nil else { return }
  let engine = NavigationEngine(appState: appState)
  engine.bootstrap()
  appState.navigationEngine = engine
  BNLog.app.info("NavigationEngine bootstrapped from HomeView")
 }

 private func requestPermissions() async {
  guard !isRequestingPermissions else { return }
  isRequestingPermissions = true
  defer { isRequestingPermissions = false }

  let cameraOK = await CameraService.requestPermission()
  let speechOK = await SpeechService.requestPermissions()

  if cameraOK && speechOK {
   permissionsGranted = true
  } else {
   var missing: [String] = []
   if !cameraOK { missing.append("camera") }
   if !speechOK { missing.append("microphone/speech") }
   permissionError = "Please grant \(missing.joined(separator: " and ")) access in Settings."
  }
 }

 private func startListening() {
  guard let engine = appState.navigationEngine else { return }
  isListening = true
  appState.session.phase = .listening
  recognizedText = ""

  transcriptionCancellable?.cancel()

  waveformMonitor.start()
  engine.speechService.startListening()

  liveTextCancellable = engine.speechService.$recognizedText
   .receive(on: DispatchQueue.main)
   .sink { text in
    self.recognizedText = text
   }

  transcriptionCancellable = engine.speechService.transcriptionPublisher
   .receive(on: DispatchQueue.main)
   .sink { text in
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    self.recognizedText = text
    self.isListening = false
    self.transcriptionCancellable = nil
    self.liveTextCancellable = nil
    if !text.isEmpty {
     self.manualDestination = text
     withAnimation(.easeInOut(duration: 0.3)) {
      self.showNavigationView = true
     }
    }
   }
 }

 private func stopListening() {
  transcriptionCancellable?.cancel()
  transcriptionCancellable = nil
  liveTextCancellable?.cancel()
  liveTextCancellable = nil
  appState.navigationEngine?.speechService.stopListening(isManual: true)
  waveformMonitor.stop()
  withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
   isListening = false
  }
  appState.session.phase = .idle
  recognizedText = ""
 }

 private func submitTranscription() {
  guard let engine = appState.navigationEngine else { return }
  let currentText = engine.speechService.recognizedText

  UINotificationFeedbackGenerator().notificationOccurred(.success)

  transcriptionCancellable?.cancel()
  transcriptionCancellable = nil
  liveTextCancellable?.cancel()
  liveTextCancellable = nil

  engine.speechService.stopListening(isManual: true)
  waveformMonitor.stop()
  isListening = false
  appState.session.phase = .idle

  if !currentText.trimmingCharacters(in: .whitespaces).isEmpty {
   BNLog.speech.info("Starting navigation to: '\(currentText)'")
   manualDestination = currentText
   withAnimation(.easeInOut(duration: 0.3)) {
    showNavigationView = true
   }
  }

  recognizedText = ""
 }
}
