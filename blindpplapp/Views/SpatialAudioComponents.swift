import SwiftUI
import UIKit

struct SpatialAudioHeader: View {
 let dismiss: DismissAction

 var body: some View {
  HStack {
   Button {
    dismiss()
   } label: {
    Image(systemName: "xmark.circle.fill")
     .font(.system(size: 28))
     .foregroundColor(BNTheme.textSecondary)
   }

   Spacer()

   Text("Spatial Audio Test")
    .font(BNTheme.Font.sectionTitle)
    .foregroundColor(BNTheme.textPrimary)

   Spacer()

   Color.clear.frame(width: 28, height: 28)
  }
  .padding(.top, BNTheme.Spacing.lg)
 }
}

struct SpatialAudioMeshViewerHeader: View {
 @ObservedObject var testEngine: SpatialAudioTestEngine
 let dismiss: DismissAction

 var body: some View {
  HStack {
   Button {
    testEngine.resumeScanning()
   } label: {
    HStack(spacing: 6) {
     Image(systemName: "arrow.left")
     Text("Scan Again")
    }
    .font(BNTheme.Font.bodyMedium)
    .foregroundColor(BNTheme.brandPrimary)
   }

   Spacer()

   Text("3D Mesh")
    .font(BNTheme.Font.sectionTitle)
    .foregroundColor(BNTheme.textPrimary)

   Spacer()

   Button {
    dismiss()
   } label: {
    Image(systemName: "xmark.circle.fill")
     .font(.system(size: 28))
     .foregroundColor(BNTheme.textSecondary)
   }
  }
  .padding(.horizontal, BNTheme.Spacing.lg)
  .padding(.top, BNTheme.Spacing.lg)
  .padding(.bottom, BNTheme.Spacing.sm)
 }
}

struct SpatialAudioMeshViewerLegend: View {
 @ObservedObject var testEngine: SpatialAudioTestEngine

 var body: some View {
  VStack(spacing: BNTheme.Spacing.xs) {
   Text("\(testEngine.meshViewerStats)")
    .font(BNTheme.Font.captionSmall)
    .foregroundColor(BNTheme.textTertiary)
    .contentTransition(.numericText())
    .animation(.easeOut(duration: 0.25), value: testEngine.meshViewerStats)

   HStack(spacing: BNTheme.Spacing.md) {
    SpatialAudioLegendDot(color: .systemBlue, label: "Wall")
    SpatialAudioLegendDot(color: .systemGreen, label: "Floor")
    SpatialAudioLegendDot(color: .systemOrange, label: "Path")
    SpatialAudioLegendDot(color: .systemPurple, label: "Door")
    SpatialAudioLegendDot(color: .systemGray, label: "Other")
   }

   Text(
    "Yellow = scan end • Orange dots + red tubes = phone path • Pink = correct subgoal • Cyan = mirrored subgoal"
   )
   .font(BNTheme.Font.captionSmall)
   .foregroundColor(BNTheme.textTertiary)
  }
  .padding(.vertical, BNTheme.Spacing.sm)
  .padding(.horizontal, BNTheme.Spacing.lg)
  .background(.ultraThinMaterial)
 }
}

struct SpatialAudioLegendDot: View {
 let color: UIColor
 let label: String

 var body: some View {
  HStack(spacing: 4) {
   Circle().fill(Color(color)).frame(width: 8, height: 8)
   Text(label).font(BNTheme.Font.captionSmall).foregroundColor(BNTheme.textSecondary)
  }
 }
}

struct SpatialAudioStatusSection: View {
 @ObservedObject var testEngine: SpatialAudioTestEngine

 var body: some View {
  VStack(spacing: BNTheme.Spacing.sm) {
   SpatialAudioStatusRow(
    "ARKit", value: testEngine.arStatus,
    color: testEngine.arStatus == "Running" ? BNTheme.success : BNTheme.warning)
   SpatialAudioStatusRow(
    "LiDAR Mesh", value: testEngine.meshStatus,
    color: testEngine.meshAnchorCount > 0 ? BNTheme.success : BNTheme.textTertiary)
   SpatialAudioStatusRow(
    "YOLO", value: testEngine.yoloStatusText, color: testEngine.yoloStatusColor)
   SpatialAudioStatusRow(
    "Hop Mode", value: testEngine.hopStatusText, color: testEngine.hopStatusColor)
   SpatialAudioStatusRow("Target", value: testEngine.hopTargetDescriptor)
   SpatialAudioStatusRow(
    "Subgoal Distance", value: testEngine.subgoalDistanceText,
    color: testEngine.subgoalDistanceColor)
   SpatialAudioStatusRow(
    "Orientation", value: testEngine.orientationStatusText, color: BNTheme.warning)
   SpatialAudioStatusRow("Mesh Anchors", value: "\(testEngine.meshAnchorCount)")
   SpatialAudioStatusRow("Mesh Vertices", value: testEngine.totalVertexCount)
   SpatialAudioStatusRow(
    "Head Tracking", value: testEngine.headTrackingStatus,
    color: testEngine.headTrackingStatus.contains("AirPods")
     ? BNTheme.success : BNTheme.textTertiary)
   SpatialAudioStatusRow(
    "Audio Engine", value: testEngine.audioStatus,
    color: testEngine.audioStatus == "Running" ? BNTheme.success : BNTheme.danger)
   SpatialAudioStatusRow(
    "Closest Obstacle", value: testEngine.closestObstacleText,
    color: testEngine.closestDistance < 1.0
     ? BNTheme.danger : (testEngine.closestDistance < 2.0 ? BNTheme.warning : BNTheme.textPrimary))
  }
  .padding(BNTheme.Spacing.md)
  .glassCard()
 }
}

struct SpatialAudioStatusRow: View {
 let label: String
 let value: String
 let color: Color

 init(_ label: String, value: String, color: Color = BNTheme.textPrimary) {
  self.label = label
  self.value = value
  self.color = color
 }

 var body: some View {
  HStack {
   Text(label)
    .font(BNTheme.Font.caption)
    .foregroundColor(BNTheme.textSecondary)
   Spacer()
   Text(value)
    .font(BNTheme.Font.mono)
    .foregroundColor(color)
    .contentTransition(.numericText())
    .animation(.easeOut(duration: 0.25), value: value)
  }
 }
}

struct SpatialAudioObstacleList: View {
 @ObservedObject var testEngine: SpatialAudioTestEngine

 var body: some View {
  VStack(alignment: .leading, spacing: BNTheme.Spacing.xs) {
   Text("Nearby Obstacles")
    .font(BNTheme.Font.bodyMedium)
    .foregroundColor(BNTheme.textPrimary)

   if testEngine.nearbyObstacles.isEmpty {
    Text("Scan your surroundings by looking around slowly...")
     .font(BNTheme.Font.caption)
     .foregroundColor(BNTheme.textTertiary)
     .frame(maxWidth: .infinity, alignment: .center)
     .padding(.vertical, BNTheme.Spacing.md)
   } else {
    ForEach(testEngine.nearbyObstacles.prefix(6), id: \.id) { obstacle in
     SpatialAudioObstacleRow(obstacle: obstacle)
    }
   }
  }
  .padding(BNTheme.Spacing.md)
  .glassCard()
 }
}

struct SpatialAudioObstacleRow: View {
 let obstacle: ObstacleDisplayInfo

 var body: some View {
  HStack(spacing: BNTheme.Spacing.sm) {
   Circle()
    .fill(
     obstacle.distance < 1.0
      ? BNTheme.danger : (obstacle.distance < 2.0 ? BNTheme.warning : BNTheme.success)
    )
    .frame(width: 8, height: 8)

   Text(obstacle.directionLabel)
    .font(BNTheme.Font.caption)
    .foregroundColor(BNTheme.textSecondary)
    .frame(width: 60, alignment: .leading)

   Text(String(format: "%.2fm", obstacle.distance))
    .font(BNTheme.Font.mono)
    .foregroundColor(BNTheme.textPrimary)
    .contentTransition(.numericText())
    .animation(.easeOut(duration: 0.25), value: obstacle.distance)

   Spacer()

   SpatialAudioObstacleBar(distance: obstacle.distance)
  }
 }
}

struct SpatialAudioObstacleBar: View {
 let distance: Float

 var body: some View {
  let maxWidth: CGFloat = 80
  let normalized = CGFloat(min(distance, 4.0) / 4.0)
  let barWidth = maxWidth * (1.0 - normalized)
  let color = distance < 1.0 ? BNTheme.danger : (distance < 2.0 ? BNTheme.warning : BNTheme.success)

  return RoundedRectangle(cornerRadius: 3)
   .fill(color.opacity(0.6))
   .frame(width: max(4, barWidth), height: 10)
   .frame(width: maxWidth, alignment: .leading)
 }
}

struct SpatialAudioAcquireOverlay: View {
 @ObservedObject var testEngine: SpatialAudioTestEngine

 var body: some View {
  VStack(alignment: .leading, spacing: BNTheme.Spacing.xs) {
   Text("Acquire Debug")
    .font(BNTheme.Font.caption)
    .foregroundColor(BNTheme.textSecondary)

   if let image = testEngine.acquireOverlayImage {
    Image(uiImage: image)
     .resizable()
     .aspectRatio(contentMode: .fit)
     .clipShape(RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous))
     .overlay(
      RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
       .stroke(BNTheme.textTertiary.opacity(0.35), lineWidth: 1)
     )
   } else {
    RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
     .fill(.ultraThinMaterial)
     .frame(height: 180)
     .overlay(
      Text("Waiting for detection...")
       .font(BNTheme.Font.caption)
       .foregroundColor(BNTheme.textTertiary)
     )
   }
  }
  .padding(BNTheme.Spacing.sm)
  .glassCard(cornerRadius: BNTheme.Radius.md)
 }
}

struct SpatialAudioControls: View {
 @ObservedObject var testEngine: SpatialAudioTestEngine
 @Binding var hopTargetLabel: String

 var body: some View {
  VStack(spacing: BNTheme.Spacing.sm) {
   HStack(spacing: BNTheme.Spacing.sm) {
    Button {
     testEngine.isAudioEnabled.toggle()
    } label: {
     HStack(spacing: 8) {
      Image(systemName: testEngine.isAudioEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill")
      Text(testEngine.isAudioEnabled ? "Audio On" : "Audio Off")
     }
     .font(BNTheme.Font.bodyMedium)
     .foregroundColor(.white)
     .frame(maxWidth: .infinity)
     .padding(.vertical, 14)
     .background(
      RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
       .fill(testEngine.isAudioEnabled ? BNTheme.brandPrimary : BNTheme.textTertiary)
     )
    }

    Button {
     testEngine.endScanAndShowMesh()
    } label: {
     HStack(spacing: 8) {
      Image(systemName: "cube.fill")
      Text("End Scan")
     }
     .font(BNTheme.Font.bodyMedium)
     .foregroundColor(.white)
     .frame(maxWidth: .infinity)
     .padding(.vertical, 14)
     .background(
      RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
       .fill(testEngine.meshAnchorCount > 0 ? BNTheme.success : BNTheme.textTertiary)
     )
    }
    .disabled(testEngine.meshAnchorCount == 0)
   }

   HStack(spacing: BNTheme.Spacing.sm) {
    TextField("object label", text: $hopTargetLabel)
     .textInputAutocapitalization(.never)
     .autocorrectionDisabled(true)
     .font(BNTheme.Font.bodyMedium)
     .padding(.horizontal, 12)
     .padding(.vertical, 10)
     .background(
      RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
       .fill(.ultraThinMaterial)
     )

    Button {
     let cleaned = hopTargetLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
     testEngine.startHopMode(descriptor: cleaned.isEmpty ? "chair" : cleaned)
    } label: {
     HStack(spacing: 8) {
      Image(systemName: "scope")
      Text("Acquire")
     }
     .font(BNTheme.Font.bodyMedium)
     .foregroundColor(.white)
     .padding(.horizontal, 14)
     .padding(.vertical, 12)
     .background(
      RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
       .fill(BNTheme.brandPrimary)
     )
    }

    Button {
     testEngine.cancelHopMode()
    } label: {
     HStack(spacing: 8) {
      Image(systemName: "xmark")
      Text("Stop")
     }
     .font(BNTheme.Font.bodyMedium)
     .foregroundColor(.white)
     .padding(.horizontal, 14)
     .padding(.vertical, 12)
     .background(
      RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
       .fill(BNTheme.textTertiary)
     )
    }
   }

   VStack(alignment: .leading, spacing: BNTheme.Spacing.sm) {
    SpatialAudioSliderRow(
     title: "Distance scale", value: $testEngine.distanceCalibration, range: 0.25...3.0,
     format: "%.2f×")
    SpatialAudioSliderRow(
     title: "Max beep range", value: $testEngine.beepMaxRangeMeters, range: 0.5...12.0,
     format: "%.1f m")
    SpatialAudioSliderRow(
     title: "Min distance to beep", value: $testEngine.beepMinDistanceMeters, range: 0...2.0,
     format: "%.2f m")
    SpatialAudioSliderRow(
     title: "Subgoal reached radius", value: $testEngine.subgoalReachRadiusMeters,
     range: 0.25...2.0, format: "%.2f m")
   }

   Text(
    "Uses YOLO stream pipeline. Hop gating locks one 3D subgoal and suppresses new YOLO hops until reached."
   )
   .font(BNTheme.Font.captionSmall)
   .foregroundColor(BNTheme.textTertiary)
   .multilineTextAlignment(.center)
  }
  .padding(.bottom, BNTheme.Spacing.lg)
 }
}

struct SpatialAudioSliderRow: View {
 let title: String
 @Binding var value: Float
 let range: ClosedRange<Float>
 let format: String

 var body: some View {
  VStack(alignment: .leading, spacing: 4) {
   HStack {
    Text(title)
     .font(BNTheme.Font.caption)
     .foregroundColor(BNTheme.textSecondary)
    Spacer()
    Text(String(format: format, value))
     .font(BNTheme.Font.mono)
     .foregroundColor(BNTheme.textPrimary)
     .contentTransition(.numericText())
     .animation(.easeOut(duration: 0.25), value: value)
   }
   Slider(value: $value, in: range)
    .tint(BNTheme.brandPrimary)
  }
 }
}
