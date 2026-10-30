//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Accelerate
import UIKit

/// Something that redraws when new analysis is ready.
protocol AnalyzerDisplay: AnyObject {
    func analyzerDidUpdate(_ analyzer: AudioAnalyzer)
}

/// Once per display frame, grabs the most recent output of everything playing and analyzes it
/// for the waveform, spectrum and spectrogram views. Runs only while one of them is on screen.
final class AudioAnalyzer {
    static let shared = AudioAnalyzer()

    static let fftSize = 4096
    static let minDB: Float = -100
    static let minFrequency: Double = 20

    /// The latest output, oldest first. `fftSize` samples.
    private(set) var samples = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    /// Smoothed magnitude spectrum in dB re full scale sine, `fftSize / 2` bins.
    private(set) var spectrumDB = [Float](repeating: AudioAnalyzer.minDB, count: AudioAnalyzer.fftSize / 2)
    private(set) var playingCount = 0
    private(set) var peak: Float = 0
    /// The longest recent audio render as a fraction of the time it had, falling slowly from each peak.
    private(set) var renderLoad: Float = 0

    let spectrogram = SpectrogramBuffer(width: 600, height: 256)

    var sampleRate: Double { max(SapfEngine.shared.sampleRate, 1) }

    private var displays = NSHashTable<AnyObject>.weakObjects()
    private var displayLink: CADisplayLink?
    private var silentFrames = 0

    private let log2n = vDSP_Length(log2(Double(AudioAnalyzer.fftSize)))
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var windowed = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    private var real = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
    private var imag = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)

    private init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_DENORM))
    }

    func add(_ display: AnalyzerDisplay) {
        displays.add(display)
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func remove(_ display: AnalyzerDisplay) {
        displays.remove(display)
        if displays.count == 0 {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func tick() {
        playingCount = samples.withUnsafeMutableBufferPointer {
            SapfEngine.shared.copyOutputSamples($0.baseAddress!, count: $0.count)
        }

        // When nothing has played for a while, stop scrolling and drawing to save power.
        silentFrames = playingCount > 0 ? 0 : silentFrames + 1
        if silentFrames > 90 { return }

        var maxMag: Float = 0
        vDSP_maxmgv(samples, 1, &maxMag, vDSP_Length(samples.count))
        peak = maxMag
        renderLoad = max(SapfEngine.shared.takePeakAudioLoad(), renderLoad * 0.98)

        analyzeSpectrum()
        spectrogram.addColumn(spectrumDB: spectrumDB, sampleRate: sampleRate)

        for case let display as AnalyzerDisplay in displays.allObjects {
            display.analyzerDidUpdate(self)
        }
    }

    private func analyzeSpectrum() {
        let n = Self.fftSize
        let half = n / 2
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0 // packed Nyquist; not displayed
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // vDSP's real FFT is scaled by 2. With a Hann window (mean 0.5), a full scale sine
        // has a bin magnitude of 2 * n/2 * 0.5 = n/2, so scale by 2/n to make that 0 dB.
        var scale = 2 / Float(n)
        scale *= scale // magnitudes are squared
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))
        var floor: Float = 1e-12
        vDSP_vthr(magnitudes, 1, &floor, &magnitudes, 1, vDSP_Length(half))
        var one: Float = 1
        vDSP_vdbcon(magnitudes, 1, &one, &magnitudes, 1, vDSP_Length(half), 0) // power dB

        // Fast attack, slow release, so the display doesn't flicker.
        for i in 0..<half {
            let v = max(magnitudes[i], Self.minDB)
            let old = spectrumDB[i]
            spectrumDB[i] = v > old ? v : old + (v - old) * 0.25
        }
    }

    /// Maximum dB over the bins between two frequencies.
    func level(from f0: Double, to f1: Double) -> Float {
        let binHz = sampleRate / Double(Self.fftSize)
        let lo = max(1, min(Int(f0 / binHz), spectrumDB.count - 1))
        let hi = max(lo, min(Int(f1 / binHz), spectrumDB.count - 1))
        var m = Self.minDB
        for i in lo...hi { m = max(m, spectrumDB[i]) }
        return m
    }
}

/// A scrolling spectrogram image with log frequency on the vertical axis.
final class SpectrogramBuffer {
    let width: Int
    let height: Int
    /// RGBA pixels, `width` columns used as a ring buffer. Row 0 is the top (highest frequency).
    private(set) var pixels: [UInt32]
    /// The column that will be written next. The oldest column.
    private(set) var nextColumn = 0
    private let colors: [UInt32]
    private var rowBins: [(Int, Int)] = []
    private var rowBinsSampleRate: Double = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        colors = SpectrogramBuffer.makeColorTable()
        pixels = [UInt32](repeating: colors[0], count: width * height)
    }

    func addColumn(spectrumDB: [Float], sampleRate: Double) {
        if rowBinsSampleRate != sampleRate { computeRowBins(bins: spectrumDB.count, sampleRate: sampleRate) }
        let x = nextColumn
        for row in 0..<height {
            let (lo, hi) = rowBins[row]
            var m = AudioAnalyzer.minDB
            for i in lo...hi { m = max(m, spectrumDB[i]) }
            let t = (m - AudioAnalyzer.minDB) / -AudioAnalyzer.minDB
            let c = Int(max(0, min(1, t)) * Float(colors.count - 1))
            pixels[row * width + x] = colors[c]
        }
        nextColumn = (nextColumn + 1) % width
    }

    private func computeRowBins(bins: Int, sampleRate: Double) {
        let binHz = sampleRate / Double(AudioAnalyzer.fftSize)
        let fmax = min(sampleRate / 2, 22050)
        let fmin = AudioAnalyzer.minFrequency
        rowBins = (0..<height).map { row in
            let y = Double(height - 1 - row) // row 0 is the top
            let f0 = fmin * pow(fmax / fmin, y / Double(height))
            let f1 = fmin * pow(fmax / fmin, (y + 1) / Double(height))
            let lo = max(1, min(Int(f0 / binHz), bins - 1))
            let hi = max(lo, min(Int(f1 / binHz), bins - 1))
            return (lo, hi)
        }
        rowBinsSampleRate = sampleRate
    }

    /// The image, oldest column on the left.
    func makeImage() -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // Rotate the ring so the oldest column comes first.
        var ordered = [UInt32](repeating: 0, count: width * height)
        let split = nextColumn
        pixels.withUnsafeBufferPointer { src in
            ordered.withUnsafeMutableBufferPointer { dst in
                for row in 0..<height {
                    let s = src.baseAddress! + row * width
                    let d = dst.baseAddress! + row * width
                    (d).update(from: s + split, count: width - split)
                    (d + width - split).update(from: s, count: split)
                }
            }
        }
        let data = ordered.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Black through indigo, red and orange to pale yellow.
    private static func makeColorTable() -> [UInt32] {
        let stops: [(Float, Float, Float, Float)] = [
            (0.00, 0.00, 0.00, 0.02),
            (0.25, 0.20, 0.05, 0.45),
            (0.50, 0.70, 0.10, 0.45),
            (0.70, 0.95, 0.40, 0.10),
            (0.88, 1.00, 0.80, 0.25),
            (1.00, 1.00, 1.00, 0.85),
        ]
        return (0..<256).map { i in
            let t = Float(i) / 255
            var k = 0
            while k < stops.count - 2 && t > stops[k + 1].0 { k += 1 }
            let a = stops[k], b = stops[k + 1]
            let u = (t - a.0) / (b.0 - a.0)
            let r = a.1 + (b.1 - a.1) * u, g = a.2 + (b.2 - a.2) * u, bl = a.3 + (b.3 - a.3) * u
            // Bytes in memory order R G B A, which is big endian RGBA.
            let bytes: [UInt8] = [UInt8(r * 255), UInt8(g * 255), UInt8(bl * 255), 255]
            return bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        }
    }
}
