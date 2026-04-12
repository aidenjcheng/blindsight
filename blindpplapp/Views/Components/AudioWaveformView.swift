import SwiftUI

struct AudioWaveformView: View {
    var barLevels: [Float]
    var barColor: Color = BNTheme.brandPrimary
    var maxHeight: CGFloat = 64
    var barWidth: CGFloat = 5
    var spacing: CGFloat = 4
    var minBarFraction: CGFloat = 0.12

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(barLevels.indices, id: \.self) { index in
                let level = CGFloat(barLevels[index])
                let height = max(maxHeight * level, maxHeight * minBarFraction)

                Capsule()
                    .fill(barColor)
                    .frame(width: barWidth, height: height)
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.08), value: barLevels.map { Int($0 * 1000) })
        .accessibilityHidden(true)
    }
}
