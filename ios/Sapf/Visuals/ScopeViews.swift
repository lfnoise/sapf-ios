//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
    /// Whether dragging a finger drives mousex and mousey.
    var drivesPointer: Bool { true }

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

    private func updatePointer(_ touches: Set<UITouch>, event: UIEvent?, down: Bool) {
        guard drivesPointer || pointer != nil, let touch = touches.first else { return }
        // A second finger means a pinch, not pointing.
        let down = down && drivesPointer && (event?.touches(for: self)?.count ?? 1) == 1
        let p = touch.location(in: self)
        let x = Float(max(0, min(1, p.x / max(bounds.width, 1))))
        let y = Float(max(0, min(1, 1 - p.y / max(bounds.height, 1))))
        SapfEngine.shared.setPointerX(x, y: y, down: down)
        pointer = down ? p : nil
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { updatePointer(touches, event: event, down: true) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { updatePointer(touches, event: event, down: true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { updatePointer(touches, event: event, down: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { updatePointer(touches, event: event, down: false) }
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
