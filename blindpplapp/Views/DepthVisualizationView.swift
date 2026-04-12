import SwiftUI
import UIKit

struct DepthVisualizationView: View {
    let depthMap: (depthGrid: [[Float]], gridWidth: Int, gridHeight: Int, closestObstacle: (x: Int, y: Int, distance: Float)?)?

    var body: some View {
        VStack(spacing: 0) {
            if let depthMap = depthMap {
                ZStack(alignment: .bottom) {
                    DepthHeatmapView(
                        depthGrid: depthMap.depthGrid,
                        width: depthMap.gridWidth,
                        height: depthMap.gridHeight,
                        closestObstacle: depthMap.closestObstacle
                    )

                    HStack {
                        Label(
                            "\(depthMap.gridWidth)\u{00D7}\(depthMap.gridHeight)",
                            systemImage: "grid"
                        )
                        .font(BNTheme.Font.captionSmall)

                        Spacer()

                        if let closest = depthMap.closestObstacle {
                            Label(
                                String(format: "%.2fm", closest.distance),
                                systemImage: "ruler"
                            )
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(closest.distance < 0.8 ? BNTheme.danger : .white)
                            .contentTransition(.numericText())
                            .animation(.linear(duration: 0.2), value: closest.distance)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.5))
                    .foregroundColor(.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous))
                .glassCard(cornerRadius: BNTheme.Radius.md)

                HStack(spacing: 4) {
                    Text("Far")
                        .font(BNTheme.Font.captionSmall)
                        .foregroundColor(BNTheme.textTertiary)
                    LinearGradient(
                        colors: [
                            Color(red: 0.1, green: 0.1, blue: 0.3),
                            Color(red: 0.0, green: 0.4, blue: 0.8),
                            Color(red: 0.0, green: 0.8, blue: 0.6),
                            Color(red: 1.0, green: 0.9, blue: 0.0),
                            Color(red: 1.0, green: 0.3, blue: 0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 6)
                    .clipShape(Capsule())
                    Text("Near")
                        .font(BNTheme.Font.captionSmall)
                        .foregroundColor(BNTheme.textTertiary)
                }
                .padding(.horizontal, BNTheme.Spacing.xs)
                .padding(.top, BNTheme.Spacing.sm)
            } else {
                VStack(spacing: BNTheme.Spacing.sm) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(BNTheme.textTertiary)
                    Text("No depth data")
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
}

// MARK: - Heatmap renderer

struct DepthHeatmapView: View {
    let depthGrid: [[Float]]
    let width: Int
    let height: Int
    let closestObstacle: (x: Int, y: Int, distance: Float)?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                GeometryReader { geometry in
                    let imageSize = fitSize(
                        imageWidth: CGFloat(width),
                        imageHeight: CGFloat(height),
                        in: geometry.size
                    )
                    let xOffset = (geometry.size.width - imageSize.width) / 2
                    let yOffset = (geometry.size.height - imageSize.height) / 2

                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: imageSize.width, height: imageSize.height)
                            .position(
                                x: geometry.size.width / 2,
                                y: geometry.size.height / 2
                            )

                        if let closest = closestObstacle {
                            let nx = CGFloat(closest.x) / CGFloat(width)
                            let ny = CGFloat(closest.y) / CGFloat(height)

                            Circle()
                                .stroke(Color.white, lineWidth: 2.5)
                                .frame(width: 16, height: 16)
                                .background(
                                    Circle()
                                        .fill(closest.distance < 0.4 ? BNTheme.danger : BNTheme.warning)
                                )
                                .position(
                                    x: xOffset + imageSize.width * nx,
                                    y: yOffset + imageSize.height * ny
                                )
                        }
                    }
                }
                .aspectRatio(CGFloat(width) / CGFloat(height), contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .aspectRatio(CGFloat(width > 0 ? width : 3) / CGFloat(height > 0 ? height : 4), contentMode: .fit)
                    .overlay(ProgressView().scaleEffect(0.8))
            }
        }
        .onAppear { generateHeatmap() }
        .onChange(of: depthGrid) { _ in generateHeatmap() }
    }

    private func fitSize(imageWidth: CGFloat, imageHeight: CGFloat, in containerSize: CGSize) -> CGSize {
        let widthRatio = containerSize.width / imageWidth
        let heightRatio = containerSize.height / imageHeight
        let scale = min(widthRatio, heightRatio)
        return CGSize(width: imageWidth * scale, height: imageHeight * scale)
    }

    private func generateHeatmap() {
        guard !depthGrid.isEmpty, width > 0, height > 0 else { return }

        let renderScale = 2
        let renderWidth = width * renderScale
        let renderHeight = height * renderScale
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: renderWidth,
            height: renderHeight,
            bitsPerComponent: 8,
            bytesPerRow: renderWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return
        }

        var minDepth: Float = .greatestFiniteMagnitude
        var maxDepth: Float = 0.0
        for row in depthGrid {
            for value in row where value > 0 {
                minDepth = min(minDepth, value)
                maxDepth = max(maxDepth, value)
            }
        }
        if minDepth >= maxDepth { minDepth = 0 }
        let range = max(maxDepth - minDepth, 0.001)

        for y in 0..<renderHeight {
            for x in 0..<renderWidth {
                let srcX = x / renderScale
                let srcY = y / renderScale

                guard srcY < depthGrid.count, srcX < depthGrid[srcY].count else { continue }

                let depth = depthGrid[srcY][srcX]
                let normalized: Float
                if depth <= 0 {
                    normalized = 0
                } else {
                    normalized = (depth - minDepth) / range
                }

                let color = depthToColor(normalized)
                context.setFillColor(color)
                context.fill(CGRect(x: x, y: renderHeight - 1 - y, width: 1, height: 1))
            }
        }

        if let cgImage = context.makeImage() {
            image = UIImage(cgImage: cgImage)
        }
    }

    private func depthToColor(_ normalized: Float) -> CGColor {
        let t = CGFloat(max(0, min(1, normalized)))

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0

        if t < 0.25 {
            let localT = t / 0.25
            red = 0.1 * (1 - localT)
            green = 0.1 * (1 - localT) + 0.1 * localT
            blue = 0.3 + 0.5 * localT
        } else if t < 0.5 {
            let localT = (t - 0.25) / 0.25
            red = 0
            green = 0.1 + 0.7 * localT
            blue = 0.8 - 0.2 * localT
        } else if t < 0.75 {
            let localT = (t - 0.5) / 0.25
            red = localT
            green = 0.8 + 0.15 * localT
            blue = 0.6 * (1 - localT)
        } else {
            let localT = (t - 0.75) / 0.25
            red = 1.0
            green = 0.95 * (1 - localT * 0.7)
            blue = 0
        }

        return CGColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

#Preview {
    DepthVisualizationView(depthMap: nil)
        .environmentObject(AppState())
        .padding()
}
