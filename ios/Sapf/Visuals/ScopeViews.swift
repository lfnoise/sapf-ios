//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This program is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    This program is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with this program.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI
import UIKit

enum ScopeTheme {
    static let background = UIColor(white: 0.07, alpha: 1)
    static let grid = UIColor(white: 1, alpha: 0.09)
    static let gridLabel = UIColor(white: 1, alpha: 0.45)
    static let trace = UIColor(red: 0.35, green: 0.95, blue: 0.75, alpha: 1)
    static let fill = UIColor(red: 0.35, green: 0.95, blue: 0.75, alpha: 0.18)
    static let pointer = UIColor.systemYellow
    static let labelFont = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
}

/// Common behavior: redraws on analyzer updates while visible, and lets you drag a finger
/// across it to drive the mousex / mousey unit generators.
class ScopeBaseView: UIView, AnalyzerDisplay {
    private var pointer: CGPoint?
    var title: String { "" }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ScopeTheme.background
        isOpaque = true
        contentMode = .redraw
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityHint = "Drag to control mousex and mousey."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { AudioAnalyzer.shared.add(self) } else { AudioAnalyzer.shared.remove(self) }
    }

    func analyzerDidUpdate(_ analyzer: AudioAnalyzer) {
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawScope(in: ctx, analyzer: AudioAnalyzer.shared)
        drawTitle()
        if let p = pointer {
            ctx.setStrokeColor(ScopeTheme.pointer.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: p.x, y: 0)); ctx.addLine(to: CGPoint(x: p.x, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: p.y)); ctx.addLine(to: CGPoint(x: bounds.width, y: p.y))
            ctx.strokePath()
            ctx.setFillColor(ScopeTheme.pointer.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        }
    }

    func drawScope(in ctx: CGContext, analyzer: AudioAnalyzer) {}

    private func drawTitle() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: ScopeTheme.gridLabel,
        ]
        (title as NSString).draw(at: CGPoint(x: 8, y: 6), withAttributes: attrs)
    }

    func drawLabel(_ text: String, at point: CGPoint, alignRight: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: ScopeTheme.labelFont, .foregroundColor: ScopeTheme.gridLabel]
        let size = (text as NSString).size(withAttributes: attrs)
        let x = alignRight ? point.x - size.width : point.x
        (text as NSString).draw(at: CGPoint(x: x, y: point.y), withAttributes: attrs)
    }

    // MARK: Pointer

    private func updatePointer(_ touches: Set<UITouch>, down: Bool) {
        guard let touch = touches.first else { return }
        let p = touch.location(in: self)
        let x = Float(max(0, min(1, p.x / max(bounds.width, 1))))
        let y = Float(max(0, min(1, 1 - p.y / max(bounds.height, 1))))
        SapfEngine.shared.setPointerX(x, y: y, down: down)
        pointer = down ? p : nil
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { updatePointer(touches, down: true) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { updatePointer(touches, down: true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { updatePointer(touches, down: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { updatePointer(touches, down: false) }
}

/// An oscilloscope. Triggers on a rising zero crossing so periodic sounds stand still.
final class WaveformView: ScopeBaseView {
    override var title: String { "Waveform" }
    /// Samples across the width of the view.
    var span = 2048

    override func drawScope(in ctx: CGContext, analyzer: AudioAnalyzer) {
        let w = bounds.width, h = bounds.height
        let mid = h / 2

        ctx.setStrokeColor(ScopeTheme.grid.cgColor)
        ctx.setLineWidth(1)
        for f in [0.25, 0.5, 0.75] as [CGFloat] {
            ctx.move(to: CGPoint(x: 0, y: h * f)); ctx.addLine(to: CGPoint(x: w, y: h * f))
        }
        ctx.strokePath()

        let samples = analyzer.samples
        let span = min(self.span, samples.count / 2)
        // Search back from the newest possible start for a rising zero crossing.
        var start = samples.count - span
        var i = start
        while i > samples.count - 2 * span {
            if samples[i - 1] <= 0 && samples[i] > 0 { start = i; break }
            i -= 1
        }

        // Scale up quiet sounds a bit, but never clip loud ones.
        let gain = CGFloat(analyzer.peak > 1 ? 1 / analyzer.peak : 1) * (mid - 4)
        let path = CGMutablePath()
        let columns = max(Int(w * contentScaleFactor), 2)
        let samplesPerColumn = Double(span) / Double(columns)
        for c in 0..<columns {
            // Min and max over each pixel column, so dense waveforms still render correctly.
            let a = start + Int(Double(c) * samplesPerColumn)
            let b = max(a + 1, start + Int(Double(c + 1) * samplesPerColumn))
            var lo = samples[a], hi = samples[a]
            for k in a..<min(b, samples.count) { lo = min(lo, samples[k]); hi = max(hi, samples[k]) }
            let x = CGFloat(c) / contentScaleFactor
            let y0 = mid - CGFloat(hi) * gain, y1 = mid - CGFloat(lo) * gain
            if c == 0 { path.move(to: CGPoint(x: x, y: y0)) } else { path.addLine(to: CGPoint(x: x, y: y0)) }
            if y1 - y0 > 1 { path.addLine(to: CGPoint(x: x, y: y1)) }
        }
        ctx.addPath(path)
        ctx.setStrokeColor(ScopeTheme.trace.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        let ms = Double(span) / analyzer.sampleRate * 1000
        drawLabel(String(format: "%.0f ms", ms), at: CGPoint(x: w - 6, y: 6), alignRight: true)
        if analyzer.playingCount > 0 {
            let peakDB = 20 * log10(max(Double(analyzer.peak), 1e-6))
            drawLabel(String(format: "%d playing   peak %.1f dB", analyzer.playingCount, peakDB), at: CGPoint(x: 8, y: h - 18))
        }
    }
}

/// Log frequency magnitude spectrum.
final class SpectrumView: ScopeBaseView {
    override var title: String { "Spectrum" }

    override func drawScope(in ctx: CGContext, analyzer: AudioAnalyzer) {
        let w = bounds.width, h = bounds.height
        let fmin = AudioAnalyzer.minFrequency
        let fmax = min(analyzer.sampleRate / 2, 22050)
        let minDB = CGFloat(AudioAnalyzer.minDB)
        func xFor(_ f: Double) -> CGFloat { CGFloat(log(f / fmin) / log(fmax / fmin)) * w }
        func yFor(_ db: CGFloat) -> CGFloat { (db / minDB) * (h - 2) + 1 }

        ctx.setStrokeColor(ScopeTheme.grid.cgColor)
        ctx.setLineWidth(1)
        for db in stride(from: -20, to: Int(minDB), by: -20) {
            let y = yFor(CGFloat(db))
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y))
        }
        let decades: [Double] = [50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        for f in decades where f < fmax {
            let x = xFor(f)
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h))
        }
        ctx.strokePath()
        for f in [100.0, 1000, 10000] where f < fmax {
            drawLabel(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))", at: CGPoint(x: xFor(f) + 3, y: h - 14))
        }
        for db in stride(from: -20, to: Int(minDB), by: -40) {
            drawLabel("\(db)", at: CGPoint(x: w - 4, y: yFor(CGFloat(db)) + 1), alignRight: true)
        }

        let columns = max(Int(w), 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: h))
        for c in 0...columns {
            let f0 = fmin * pow(fmax / fmin, Double(c) / Double(columns))
            let f1 = fmin * pow(fmax / fmin, Double(c + 1) / Double(columns))
            let db = CGFloat(analyzer.level(from: f0, to: f1))
            path.addLine(to: CGPoint(x: CGFloat(c) * w / CGFloat(columns), y: yFor(db)))
        }
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(ScopeTheme.fill.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(ScopeTheme.trace.cgColor)
        ctx.setLineWidth(1.25)
        ctx.strokePath()
    }
}

/// Scrolling spectrogram (sonogram): time left to right, log frequency bottom to top.
final class SpectrogramView: ScopeBaseView {
    override var title: String { "Spectrogram" }

    override func drawScope(in ctx: CGContext, analyzer: AudioAnalyzer) {
        let w = bounds.width, h = bounds.height
        if let image = analyzer.spectrogram.makeImage() {
            ctx.saveGState()
            ctx.interpolationQuality = .medium
            // CGContext draws images bottom up in UIKit's flipped coordinates, so flip back.
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
        }

        let fmin = AudioAnalyzer.minFrequency
        let fmax = min(analyzer.sampleRate / 2, 22050)
        for f in [100.0, 1000, 10000] where f < fmax {
            let y = h - CGFloat(log(f / fmin) / log(fmax / fmin)) * h
            ctx.setStrokeColor(ScopeTheme.grid.cgColor)
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y))
            ctx.strokePath()
            drawLabel(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))", at: CGPoint(x: w - 4, y: y + 1), alignRight: true)
        }
    }
}

// MARK: - SwiftUI wrappers

enum ScopeKind: String, CaseIterable, Identifiable {
    case waveform = "Waveform"
    case spectrum = "Spectrum"
    case spectrogram = "Spectrogram"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .waveform: return "waveform.path"
        case .spectrum: return "chart.bar.xaxis"
        case .spectrogram: return "square.stack.3d.down.forward"
        }
    }
}

struct ScopeView: UIViewRepresentable {
    let kind: ScopeKind

    func makeUIView(context: Context) -> ScopeBaseView {
        let view: ScopeBaseView
        switch kind {
        case .waveform: view = WaveformView()
        case .spectrum: view = SpectrumView()
        case .spectrogram: view = SpectrogramView()
        }
        view.accessibilityLabel = kind.rawValue
        return view
    }

    func updateUIView(_ uiView: ScopeBaseView, context: Context) {}
}
