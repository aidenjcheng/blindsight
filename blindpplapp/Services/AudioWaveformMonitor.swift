import Foundation
import AVFoundation
import Accelerate

@MainActor
@Observable
final class AudioWaveformMonitor {

    static let shared = AudioWaveformMonitor()

    private static let fftSize = 8192
    private static let sampleBins = 200
    private static let barCount = 13

    private(set) var barLevels = [Float](repeating: 0, count: barCount)
    private(set) var isActive = false

    private var fftSetup: OpaquePointer?
    private var rawMagnitudes = [Float](repeating: 0, count: sampleBins)

    private init() {}

    func start() {
        guard !isActive else { return }
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, UInt(Self.fftSize), .FORWARD)
        isActive = true
    }

    func stop() {
        isActive = false
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
            fftSetup = nil
        }
        barLevels = [Float](repeating: 0, count: Self.barCount)
        rawMagnitudes = [Float](repeating: 0, count: Self.sampleBins)
    }

    nonisolated func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let floatData = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        let padded: [Float]
        if floatData.count >= Self.fftSize {
            padded = Array(floatData.prefix(Self.fftSize))
        } else {
            padded = floatData + [Float](repeating: 0, count: Self.fftSize - floatData.count)
        }

        let magnitudes = performFFT(data: padded)
        let bars = reduceToBars(magnitudes)

        Task { @MainActor in
            guard self.isActive else { return }
            self.rawMagnitudes = magnitudes
            self.barLevels = bars
        }
    }

    private nonisolated func performFFT(data: [Float]) -> [Float] {
        let bufferSize = Self.fftSize
        let sampleBins = Self.sampleBins

        var realIn = data
        var imagIn = [Float](repeating: 0, count: bufferSize)
        var realOut = [Float](repeating: 0, count: bufferSize)
        var imagOut = [Float](repeating: 0, count: bufferSize)
        var magnitudes = [Float](repeating: 0, count: sampleBins)

        realIn.withUnsafeMutableBufferPointer { realInPtr in
            imagIn.withUnsafeMutableBufferPointer { imagInPtr in
                realOut.withUnsafeMutableBufferPointer { realOutPtr in
                    imagOut.withUnsafeMutableBufferPointer { imagOutPtr in
                        guard let setup = vDSP_DFT_zop_CreateSetup(nil, UInt(bufferSize), .FORWARD) else { return }
                        defer { vDSP_DFT_DestroySetup(setup) }

                        vDSP_DFT_Execute(
                            setup,
                            realInPtr.baseAddress!,
                            imagInPtr.baseAddress!,
                            realOutPtr.baseAddress!,
                            imagOutPtr.baseAddress!
                        )

                        var complex = DSPSplitComplex(
                            realp: realOutPtr.baseAddress!,
                            imagp: imagOutPtr.baseAddress!
                        )

                        vDSP_zvabs(&complex, 1, &magnitudes, 1, UInt(sampleBins))
                    }
                }
            }
        }

        let limit: Float = 80
        return magnitudes.map { min($0, limit) / limit }
    }

    private nonisolated func reduceToBars(_ magnitudes: [Float]) -> [Float] {
        let barCount = Self.barCount
        let halfBars = barCount / 2 + 1
        let usableBins = min(magnitudes.count, 80)
        let binsPerBar = max(usableBins / halfBars, 1)

        var halfLevels = [Float](repeating: 0, count: halfBars)
        for i in 0..<halfBars {
            let start = i * binsPerBar
            let end = min(start + binsPerBar, usableBins)
            guard start < end else { continue }
            let slice = magnitudes[start..<end]
            halfLevels[i] = slice.reduce(0, +) / Float(slice.count)
        }

        var bars = [Float](repeating: 0, count: barCount)
        let center = barCount / 2
        bars[center] = halfLevels[0]
        for i in 1..<halfBars {
            let left = center - i
            let right = center + i
            if left >= 0 { bars[left] = halfLevels[i] }
            if right < barCount { bars[right] = halfLevels[i] }
        }

        let minHeight: Float = 0.08
        return bars.map { max($0, minHeight) }
    }
}
