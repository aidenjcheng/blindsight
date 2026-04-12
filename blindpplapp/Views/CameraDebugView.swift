import SwiftUI

struct CameraDebugView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let frame = appState.debugCameraFrame {
                let displaySize = orientedDisplaySize(for: frame)
                ZStack(alignment: .bottom) {
                    GeometryReader { geometry in
                        let baseFillSize = fillSize(
                            imageWidth: displaySize.width,
                            imageHeight: displaySize.height,
                            in: geometry.size
                        )
                        let imageSize = CGSize(
                            width: baseFillSize.width * cameraZoomScale,
                            height: baseFillSize.height * cameraZoomScale
                        )
                        let xOffset = (geometry.size.width - imageSize.width) / 2
                        let yOffset = (geometry.size.height - imageSize.height) / 2

                        ZStack {
                            Image(uiImage: frame)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: imageSize.width, height: imageSize.height)
                                .position(
                                    x: geometry.size.width / 2,
                                    y: geometry.size.height / 2
                                )

                            ForEach(
                                Array(goalDetections.enumerated()),
                                id: \.offset
                            ) { _, detection in
                                BoundingBoxView(
                                    detection: detection,
                                    imageSize: imageSize,
                                    imageOffset: CGPoint(x: xOffset, y: yOffset),
                                    isGoalMatch: true
                                )
                            }
                        }
                    }
                    .aspectRatio(
                        debugPanelAspectRatio,
                        contentMode: .fit
                    )
                    .clipped()

                    HStack {
                        Label(
                            goalDetections.isEmpty ? "No match" : "Tracking",
                            systemImage: goalDetections.isEmpty ? "viewfinder" : "viewfinder.circle.fill"
                        )
                        .font(BNTheme.Font.captionSmall)

                        Spacer()

                        if let goal = appState.session.currentSecondaryGoal?.descriptor {
                            Text(goal)
                                .font(BNTheme.Font.captionSmall)
                                .lineLimit(1)
                                .contentTransition(.numericText())
                                .animation(.default, value: goal)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.5))
                    .foregroundColor(.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous))
                .glassCard(cornerRadius: BNTheme.Radius.md)
            } else {
                VStack(spacing: BNTheme.Spacing.sm) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(BNTheme.textTertiary)
                    Text("No camera feed")
                        .font(BNTheme.Font.captionSmall)
                        .foregroundColor(BNTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .glassCard(cornerRadius: BNTheme.Radius.md)
            }
        }
        .padding(.horizontal, BNTheme.Spacing.xs)
    }

    private var goalDetections: [YOLOEService.Detection] {
        guard let goal = appState.session.currentSecondaryGoal?.descriptor else {
            return []
        }
        let goalWords = Set(goal.lowercased().split(separator: " ").map(String.init))
        return appState.debugDetections.filter { detection in
            let labelWords = Set(detection.label.lowercased().split(separator: " ").map(String.init))
            return !goalWords.intersection(labelWords).isEmpty
        }
    }

    private func fillSize(imageWidth: CGFloat, imageHeight: CGFloat, in containerSize: CGSize) -> CGSize {
        let widthRatio = containerSize.width / imageWidth
        let heightRatio = containerSize.height / imageHeight
        let scale = max(widthRatio, heightRatio)
        return CGSize(width: imageWidth * scale, height: imageHeight * scale)
    }

    private func orientedDisplaySize(for image: UIImage) -> CGSize {
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: image.size.height, height: image.size.width)
        default:
            return image.size
        }
    }

    private var debugPanelAspectRatio: CGFloat {
        if let depthMap = appState.debugDepthMap, depthMap.gridWidth > 0, depthMap.gridHeight > 0 {
            return CGFloat(depthMap.gridWidth) / CGFloat(depthMap.gridHeight)
        }
        return 3.0 / 4.0
    }

    private var cameraZoomScale: CGFloat { 2.0 }
}

// MARK: - Bounding box overlay

struct BoundingBoxView: View {
    let detection: YOLOEService.Detection
    let imageSize: CGSize
    let imageOffset: CGPoint
    let isGoalMatch: Bool

    var body: some View {
        let box = detection.boundingBox
        let x = imageOffset.x + box.minX * imageSize.width
        let y = imageOffset.y + (1 - box.maxY) * imageSize.height
        let w = box.width * imageSize.width
        let h = box.height * imageSize.height

        let boxColor: Color = isGoalMatch ? BNTheme.success : .yellow

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(boxColor, lineWidth: isGoalMatch ? 2.5 : 1.5)
                .frame(width: w, height: h)

            Text("\(detection.label) \(String(format: "%.0f%%", detection.confidence * 100))")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(boxColor.opacity(0.85))
                )
                .offset(y: -16)
        }
        .position(x: x + w / 2, y: y + h / 2)
    }
}
