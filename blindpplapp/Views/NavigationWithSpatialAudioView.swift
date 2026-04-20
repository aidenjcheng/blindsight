import SwiftUI

struct NavigationWithSpatialAudioView: View {
 @EnvironmentObject var appState: AppState
 @StateObject var navigationEngine = SpatialAudioTestEngine()
 @State var showDebugDrawer = false
 @State var appearAnimated = false

 var destinationName: String = "Destination"
 var onDismiss: (() -> Void)? = nil

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

   if showDebugDrawer {
    debugDrawerOverlay
     .ignoresSafeArea()
   }
  }
  .animation(.easeInOut(duration: 0.3), value: showDebugDrawer)
  .onAppear {
   withAnimation(.easeOut(duration: 0.4)) {
    appearAnimated = true
   }

   let apiKey =
    appState.geminiAPIKey.isEmpty ? BNConstants.hardcodedGeminiAPIKey : appState.geminiAPIKey
   navigationEngine.configure(apiKey: apiKey)

   navigationEngine.startNavigation(destination: destinationName)
  }
  .onDisappear {
   navigationEngine.stop()
  }
 }

 private var topBar: some View {
  VStack(spacing: BNTheme.Spacing.sm) {
   HStack(spacing: BNTheme.Spacing.sm) {
    ZStack {
     Circle()
      .fill(currentPhaseColor.opacity(0.12))
      .frame(width: 36, height: 36)

     Image(systemName: currentPhaseIcon)
      .font(.system(size: 14, weight: .semibold))
      .foregroundColor(currentPhaseColor)
    }

    VStack(alignment: .leading, spacing: 2) {
     Text(currentPhaseLabel)
      .font(BNTheme.Font.captionSmall)
      .foregroundColor(BNTheme.textTertiary)
      .textCase(.uppercase)
      .tracking(0.8)
      .contentTransition(.numericText())
      .animation(.default, value: currentPhaseLabel)

     Text(destinationName)
      .font(BNTheme.Font.bodyMedium)
      .foregroundColor(BNTheme.textPrimary)
      .lineLimit(1)
      .contentTransition(.numericText())
      .animation(.default, value: destinationName)
    }

    Spacer()

    if isGuidingPhase {
     Text(navigationEngine.subgoalDistanceText)
      .font(BNTheme.Font.mono)
      .foregroundColor(navigationEngine.subgoalDistanceColor)
      .contentTransition(.numericText())
      .animation(.default, value: navigationEngine.subgoalDistanceText)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .glassInset(cornerRadius: BNTheme.Radius.full)
    }
   }
  }
  .padding(BNTheme.Spacing.md)
  .glassCard(cornerRadius: BNTheme.Radius.lg)
  .opacity(appearAnimated ? 1 : 0)
  .offset(y: appearAnimated ? 0 : -12)
 }

 private var centralStatus: some View {
  VStack(spacing: BNTheme.Spacing.md) {
   hopStateCard

   meshScanCard

   yoloStatusCard

   if !navigationEngine.hopStatusText.isEmpty {
    Text(navigationEngine.hopStatusText)
     .font(BNTheme.Font.bodyRegular)
     .foregroundColor(BNTheme.textTertiary)
     .multilineTextAlignment(.center)
     .contentTransition(.numericText())
     .animation(.default, value: navigationEngine.hopStatusText)
     .padding(.horizontal, BNTheme.Spacing.sm)
   }
  }
  .opacity(appearAnimated ? 1 : 0)
 }

 private var hopStateCard: some View {
  VStack(spacing: BNTheme.Spacing.sm) {
   if isAcquiringPhase {
    Text("ACQUIRING TARGET")
     .font(BNTheme.Font.captionSmall)
     .foregroundColor(BNTheme.warning)
     .tracking(1.2)

    Text(navigationEngine.hopTargetDescriptor)
     .font(BNTheme.Font.sectionTitle)
     .foregroundColor(BNTheme.textPrimary)
     .multilineTextAlignment(.center)
     .contentTransition(.numericText())
     .animation(.default, value: navigationEngine.hopTargetDescriptor)

    HStack(spacing: 6) {
     ProgressView()
      .tint(BNTheme.warning)
      .scaleEffect(0.8)
     Text("Scanning for target...")
      .font(BNTheme.Font.caption)
      .foregroundColor(BNTheme.textSecondary)
    }
   } else if isGuidingPhase {
    Text("APPROACHING SUBGOAL")
     .font(BNTheme.Font.captionSmall)
     .foregroundColor(BNTheme.brandPrimary)
     .tracking(1.2)

    Text(navigationEngine.hopTargetDescriptor)
     .font(BNTheme.Font.sectionTitle)
     .foregroundColor(BNTheme.textPrimary)
     .multilineTextAlignment(.center)
     .contentTransition(.numericText())
     .animation(.default, value: navigationEngine.hopTargetDescriptor)

    HStack(spacing: 12) {
     Image(systemName: "location.fill")
      .font(.system(size: 13, weight: .semibold))
      .foregroundColor(BNTheme.brandPrimary)
     Text(navigationEngine.subgoalDistanceText)
      .font(BNTheme.Font.bodyMedium)
      .foregroundColor(navigationEngine.subgoalDistanceColor)
      .contentTransition(.numericText())
      .animation(.default, value: navigationEngine.subgoalDistanceText)
    }
   } else {
    Text("READY")
     .font(BNTheme.Font.captionSmall)
     .foregroundColor(BNTheme.textTertiary)
     .tracking(1.2)

    Text("Waiting for destination")
     .font(BNTheme.Font.bodyMedium)
     .foregroundColor(BNTheme.textSecondary)
   }
  }
  .padding(.vertical, BNTheme.Spacing.lg)
  .padding(.horizontal, BNTheme.Spacing.md)
  .frame(maxWidth: .infinity)
  .glassCard(cornerRadius: BNTheme.Radius.lg)
  .accessibilityElement(children: .combine)
 }

 private var meshScanCard: some View {
  HStack(spacing: BNTheme.Spacing.sm) {
   VStack(alignment: .leading, spacing: 4) {
    Text("Mesh Scan")
     .font(BNTheme.Font.captionSmall)
     .foregroundColor(BNTheme.textTertiary)
     .tracking(0.8)

    HStack(spacing: 8) {
     Text("\(navigationEngine.meshAnchorCount) anchors")
      .font(BNTheme.Font.caption)
      .foregroundColor(BNTheme.textPrimary)
      .contentTransition(.numericText())
      .animation(.default, value: navigationEngine.meshAnchorCount)

     Spacer()

     Text(navigationEngine.totalVertexCount)
      .font(BNTheme.Font.caption)
      .foregroundColor(BNTheme.textSecondary)
      .contentTransition(.numericText())
      .animation(.default, value: navigationEngine.totalVertexCount)
    }
   }
   Spacer()
   Image(systemName: navigationEngine.meshAnchorCount > 0 ? "checkmark.circle.fill" : "circle")
    .font(.system(size: 16, weight: .semibold))
    .foregroundColor(navigationEngine.meshAnchorCount > 0 ? BNTheme.success : BNTheme.textTertiary)
    .animation(.default, value: navigationEngine.meshAnchorCount > 0)
  }
  .padding(BNTheme.Spacing.md)
  .frame(maxWidth: .infinity, alignment: .leading)
  .glassCard(cornerRadius: BNTheme.Radius.md)
 }

 private var yoloStatusCard: some View {
  HStack(spacing: BNTheme.Spacing.sm) {
   VStack(alignment: .leading, spacing: 4) {
    Text("Detection")
     .font(BNTheme.Font.captionSmall)
     .foregroundColor(BNTheme.textTertiary)
     .tracking(0.8)

    Text(navigationEngine.yoloStatusText)
     .font(BNTheme.Font.caption)
     .foregroundColor(navigationEngine.yoloStatusColor)
     .contentTransition(.numericText())
     .animation(.default, value: navigationEngine.yoloStatusText)
   }
   Spacer()
   Circle()
    .fill(navigationEngine.yoloStatusColor)
    .frame(width: 10, height: 10)
    .animation(.default, value: navigationEngine.yoloStatusColor)
  }
  .padding(BNTheme.Spacing.md)
  .frame(maxWidth: .infinity, alignment: .leading)
  .glassCard(cornerRadius: BNTheme.Radius.md)
 }

 private var debugDrawerOverlay: some View {
  ZStack(alignment: .bottom) {
   Color.black.opacity(0.3)
    .onTapGesture {
     withAnimation(.easeInOut(duration: 0.3)) {
      showDebugDrawer = false
     }
    }

   VStack(spacing: 0) {
    HStack {
     Text("Debug View")
      .font(BNTheme.Font.bodyMedium)
      .foregroundColor(BNTheme.textPrimary)
     Spacer()
     Button(action: {
      withAnimation(.easeInOut(duration: 0.3)) {
       showDebugDrawer = false
      }
     }) {
      Image(systemName: "xmark")
       .font(.system(size: 14, weight: .semibold))
       .foregroundColor(BNTheme.textSecondary)
     }
    }
    .padding(BNTheme.Spacing.md)

    SpatialAudioTestView(
     testEngine: navigationEngine, hopTargetLabel: navigationEngine.hopTargetDescriptor,
     manageLifecycle: false
    )
    .frame(maxHeight: .infinity)
   }
   .background(BNTheme.pageBg)
   .glassCard(cornerRadius: BNTheme.Radius.lg)
   .padding(BNTheme.Spacing.md)
   .transition(.move(edge: .bottom).combined(with: .opacity))
  }
 }

 private var bottomActions: some View {
  VStack(spacing: BNTheme.Spacing.sm) {
   Button(action: {
    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
     showDebugDrawer.toggle()
    }
   }) {
    HStack(spacing: 6) {
     Image(systemName: showDebugDrawer ? "eye.slash" : "eye")
      .font(.system(size: 13, weight: .medium))
     Text(showDebugDrawer ? "Hide Debug View" : "Show Debug View")
      .font(BNTheme.Font.caption)
    }
    .foregroundColor(BNTheme.textSecondary)
    .padding(.horizontal, BNTheme.Spacing.md)
    .padding(.vertical, BNTheme.Spacing.sm)
    .glassInset(cornerRadius: BNTheme.Radius.full)
   }
   .accessibilityLabel("Toggle debug view")

   AccessibleButton(
    title: "Stop Navigation",
    systemImage: "stop.fill",
    style: .destructive,
    action: {
     navigationEngine.stop()
     onDismiss?()
    }
   )
   .accessibilityHint("Stops spatial audio navigation")
  }
 }

 private var isAcquiringPhase: Bool {
  navigationEngine.hopStatusText.lowercased().contains("acquiring")
 }

 private var isGuidingPhase: Bool {
  navigationEngine.hopStatusText.lowercased().contains("approaching")
   || navigationEngine.hopStatusText.lowercased().contains("guiding")
 }

 private var currentPhaseIcon: String {
  if isAcquiringPhase {
   return "target"
  } else if isGuidingPhase {
   return "location.fill"
  } else {
   return "circle"
  }
 }

 private var currentPhaseColor: Color {
  if isAcquiringPhase {
   return BNTheme.warning
  } else if isGuidingPhase {
   return BNTheme.brandPrimary
  } else {
   return BNTheme.textTertiary
  }
 }

 private var currentPhaseLabel: String {
  if isAcquiringPhase {
   return "Acquiring"
  } else if isGuidingPhase {
   return "Guiding"
  } else {
   return "Idle"
  }
 }
}
