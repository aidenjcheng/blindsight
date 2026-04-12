import SwiftUI
import PhotosUI

struct YOLOETestView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedItem: PhotosPickerItem?
    @State private var testImage: UIImage?
    @State private var detections: [YOLOEService.Detection] = []
    @State private var isRunning = false
    @State private var hasRun = false
    @State private var inferenceTimeMs: Double = 0

    var body: some View {
        NavigationStack {
            ZStack {
                BNTheme.pageBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: BNTheme.Spacing.md) {
                        modelStatusBadge
                        imageSection
                        if hasRun { resultsSection }
                    }
                    .padding(.horizontal, BNTheme.Spacing.lg)
                    .padding(.vertical, BNTheme.Spacing.md)
                }
            }
            .navigationTitle("YOLOE Test")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Model status

    private var modelStatusBadge: some View {
        let loaded = appState.navigationEngine?.yoloeService.isModelLoaded == true
        return HStack(spacing: 8) {
            Circle()
                .fill(loaded ? BNTheme.success : BNTheme.danger)
                .frame(width: 8, height: 8)
            Text(loaded ? "YOLOE model loaded" : "YOLOE model not loaded")
                .font(BNTheme.Font.caption)
                .foregroundColor(loaded ? BNTheme.success : BNTheme.danger)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: BNTheme.Radius.sm)
    }

    // MARK: - Image section

    private var imageSection: some View {
        VStack(spacing: BNTheme.Spacing.sm) {
            if let testImage {
                let displaySize = orientedDisplaySize(for: testImage)
                ZStack(alignment: .bottom) {
                    GeometryReader { geo in
                        let imgSize = fitSize(
                            imageWidth: displaySize.width,
                            imageHeight: displaySize.height,
                            in: geo.size
                        )
                        let xOff = (geo.size.width - imgSize.width) / 2
                        let yOff = (geo.size.height - imgSize.height) / 2

                        ZStack {
                            Image(uiImage: testImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: imgSize.width, height: imgSize.height)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)

                            ForEach(Array(detections.enumerated()), id: \.offset) { _, det in
                                TestBoundingBox(
                                    detection: det,
                                    imageSize: imgSize,
                                    imageOffset: CGPoint(x: xOff, y: yOff),
                                    prompt: "door"
                                )
                            }
                        }
                    }
                    .aspectRatio(displaySize.width / displaySize.height, contentMode: .fit)
                }
                .clipShape(RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous))
                .glassCard(cornerRadius: BNTheme.Radius.md)
            } else {
                VStack(spacing: BNTheme.Spacing.sm) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundColor(BNTheme.textTertiary)
                    Text("Pick an image to test YOLOE")
                        .font(BNTheme.Font.caption)
                        .foregroundColor(BNTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .glassCard(cornerRadius: BNTheme.Radius.md)
            }

            HStack(spacing: BNTheme.Spacing.sm) {
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Choose Image")
                            .font(BNTheme.Font.bodyMedium)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
                            .fill(BNTheme.brandPrimary)
                    )
                }
                .onChange(of: selectedItem) { _, newValue in
                    loadImage(from: newValue)
                }

                if testImage != nil {
                    Button {
                        runDetection()
                    } label: {
                        HStack(spacing: 8) {
                            if isRunning {
                                ProgressView().tint(.white).scaleEffect(0.8)
                            } else {
                                Image(systemName: "sparkle.magnifyingglass")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            Text("Detect")
                                .font(BNTheme.Font.bodyMedium)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundColor(.white)
                        .background(
                            RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
                                .fill(isRunning ? BNTheme.textTertiary : BNTheme.success)
                        )
                    }
                    .disabled(isRunning)
                }
            }
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: BNTheme.Spacing.sm) {
            HStack {
                Text("Results")
                    .font(BNTheme.Font.sectionTitle)
                    .foregroundColor(BNTheme.textPrimary)
                Spacer()
                Text(String(format: "%.0f ms", inferenceTimeMs))
                    .font(BNTheme.Font.mono)
                    .foregroundColor(BNTheme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassInset(cornerRadius: BNTheme.Radius.full)
            }

            if detections.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(BNTheme.warning)
                    Text("No detections. The model may need re-exporting with set_classes().")
                        .font(BNTheme.Font.caption)
                        .foregroundColor(BNTheme.textSecondary)
                }
                .padding(BNTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: BNTheme.Radius.sm)
            } else {
                let doorMatches = detections.filter {
                    $0.label.lowercased().contains("door")
                }

                if !doorMatches.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(BNTheme.success)
                        Text("Found \(doorMatches.count) door detection(s)")
                            .font(BNTheme.Font.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(BNTheme.success)
                    }
                    .padding(BNTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BNTheme.successSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: BNTheme.Radius.sm, style: .continuous))
                }

                ForEach(Array(detections.enumerated()), id: \.offset) { _, det in
                    HStack {
                        Text(det.label)
                            .font(BNTheme.Font.bodyMedium)
                            .foregroundColor(
                                det.label.lowercased().contains("door")
                                    ? BNTheme.success : BNTheme.textPrimary
                            )
                        Spacer()
                        Text(String(format: "%.1f%%", det.confidence * 100))
                            .font(BNTheme.Font.mono)
                            .foregroundColor(BNTheme.textTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassCard(cornerRadius: BNTheme.Radius.sm)
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadImage(from item: PhotosPickerItem?) {
        guard let item else { return }
        detections = []
        hasRun = false
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                testImage = img
            }
        }
    }

    private func runDetection() {
        guard let image = testImage,
              let yoloe = appState.navigationEngine?.yoloeService,
              yoloe.isModelLoaded else { return }

        isRunning = true
        let start = CFAbsoluteTimeGetCurrent()

        Task {
            let results = await yoloe.detect(in: image)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            detections = results.sorted { $0.confidence > $1.confidence }
            inferenceTimeMs = elapsed
            hasRun = true
            isRunning = false
        }
    }

    private func fitSize(imageWidth: CGFloat, imageHeight: CGFloat, in containerSize: CGSize) -> CGSize {
        let scale = min(containerSize.width / imageWidth, containerSize.height / imageHeight)
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
}

// MARK: - Bounding box for test view

private struct TestBoundingBox: View {
    let detection: YOLOEService.Detection
    let imageSize: CGSize
    let imageOffset: CGPoint
    let prompt: String

    var body: some View {
        let box = detection.boundingBox
        let x = imageOffset.x + box.minX * imageSize.width
        let y = imageOffset.y + (1 - box.maxY) * imageSize.height
        let w = box.width * imageSize.width
        let h = box.height * imageSize.height

        let matched = detection.label.lowercased().contains(prompt.lowercased())
        let color: Color = matched ? BNTheme.success : .yellow

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(color, lineWidth: matched ? 2.5 : 1.5)
                .frame(width: w, height: h)

            Text("\(detection.label) \(String(format: "%.0f%%", detection.confidence * 100))")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.85)))
                .offset(y: -16)
        }
        .position(x: x + w / 2, y: y + h / 2)
    }
}
