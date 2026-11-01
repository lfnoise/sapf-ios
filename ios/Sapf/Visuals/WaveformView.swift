//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Accelerate
import UIKit

/// Samples taken from the top of the stack.
struct Plot {
    var channels: [[Float]]
    var frameCount: Int
    /// Signals are at the sample rate; otherwise each frame is one item of a list of numbers.
    var isSignal: Bool
    var truncated: Bool
    var sampleRate: Double
    /// The smallest and largest values in all channels, for scaling.
    var range: ClosedRange<Float>

    init(_ plot: SapfPlot) {
        channels = plot.channels.map { data in
            data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        frameCount = plot.frameCount
        isSignal = plot.isSignal
        truncated = plot.truncated
        sampleRate = plot.sampleRate
        var lo = Float.infinity, hi = -Float.infinity
        for c in channels {
            var cmin: Float = 0, cmax: Float = 0
            vDSP_minv(c, 1, &cmin, vDSP_Length(c.count))
            vDSP_maxv(c, 1, &cmax, vDSP_Length(c.count))
            lo = min(lo, cmin); hi = max(hi, cmax)
        }
        range = lo.isFinite && hi.isFinite ? lo...hi : -1...1
    }

    /// A short description, e.g. "2 channels, 1.50 s".
    var summary: String {
        let channelText = channels.count == 1 ? "" : "\(channels.count) channels, "
        if isSignal {
            let seconds = WaveformView.durationText(Double(frameCount) / sampleRate)
            return channelText + (truncated ? "first \(seconds) of a longer signal" : seconds)
        }
        return "\(frameCount) values" + (truncated ? " (truncated)" : "")
    }
}

/// What the waveform views show and how far they're zoomed. Shared, so that every waveform view
/// on screen stays in step.
final class WaveformState {
    static let shared = WaveformState()
    static let didChange = Notification.Name("WaveformStateDidChange")

    enum Source { case output, plot }

    private(set) var source: Source = .output
    private(set) var plot: Plot?

    /// Output: frames across the view, newest at the right edge.
    var outputSpan: Double {
        didSet {
            UserDefaults.standard.set(outputSpan, forKey: "waveformSpan")
            changed()
        }
    }
    static let defaultOutputSpan: Double = 2048
    static let minOutputSpan: Double = 128
    /// Limited by the output history kept by the engine, and to 30 seconds.
    static var maxOutputSpan: Double {
        let history = Double(SapfEngine.outputEnvelopeCapacity * SapfEngine.outputEnvelopeBlockSize)
        return min(history, 30 * max(SapfEngine.shared.sampleRate, 1))
    }

    /// Plot: the first visible frame and the number of frames across the view.
    private(set) var plotStart: Double = 0
    private(set) var plotSpan: Double = 1
    static let minPlotSpan: Double = 8

    private init() {
        outputSpan = UserDefaults.standard.object(forKey: "waveformSpan") as? Double ?? Self.defaultOutputSpan
    }

    func show(_ plot: Plot) {
        self.plot = plot
        source = .plot
        fitPlot()
    }

    /// Discards the plot and goes back to the output.
    func clearPlot() {
        guard plot != nil else { return }
        plot = nil
        source = .output
        changed()
    }

    func setSource(_ source: Source) {
        guard source != self.source, source == .output || plot != nil else { return }
        self.source = source
        changed()
    }

    /// From the first frame to the last.
    private var plotExtent: Double { Double(max((plot?.frameCount ?? 2) - 1, 1)) }

    func fitPlot() {
        plotStart = 0
        plotSpan = plotExtent
        changed()
    }

    /// Sets the visible part of the plot, kept within the plot.
    func setPlotWindow(start: Double, span: Double) {
        let total = plotExtent
        plotSpan = min(max(span, min(Self.minPlotSpan, total)), total)
        plotStart = min(max(start, 0), total - plotSpan)
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// An oscilloscope of the live output, or a plot of the top of the stack.
///
/// Output: pinch to zoom from milliseconds to 30 seconds; short spans trigger on a rising zero
/// crossing so periodic sounds stand still, long ones show the amplitude envelope. Dragging one
/// finger drives mousex and mousey. Plot: pinch to zoom around your fingers and drag to scroll.
/// Double tap returns to the default zoom, or fits the whole plot.
final class WaveformView: ScopeBaseView, UIGestureRecognizerDelegate {
    private var state: WaveformState { .shared }
    private let sourcePicker = UISegmentedControl(items: ["Output", "Plot"])
    private let closeButton = UIButton(type: .system)
    private let scopeElement: UIAccessibilityElement
    private let pan = UIPanGestureRecognizer()
    private var gestureStart: (start: Double, span: Double, anchor: Double)?

    private var envelopeMin: [Float] = []
    private var envelopeMax: [Float] = []

    override var title: String { state.source == .output ? "Waveform" : "Plot" }
    override var drivesPointer: Bool { state.source == .output }

    override init(frame: CGRect) {
        scopeElement = UIAccessibilityElement(accessibilityContainer: NSObject())
        super.init(frame: frame)

        // The picker is a subview, so this view is a container rather than one element.
        isAccessibilityElement = false
        scopeElement.accessibilityContainer = self
        scopeElement.accessibilityLabel = "Waveform"
        scopeElement.accessibilityTraits = .allowsDirectInteraction
        scopeElement.accessibilityHint = "Pinch to zoom. Double tap to reset."

        sourcePicker.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 11, weight: .medium)], for: .normal)
        sourcePicker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.state.setSource(self.sourcePicker.selectedSegmentIndex == 0 ? .output : .plot)
        }, for: .valueChanged)
        addSubview(sourcePicker)

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)), for: .normal)
        closeButton.tintColor = UIColor(white: 1, alpha: 0.45)
        closeButton.accessibilityLabel = "Close Plot"
        closeButton.addAction(UIAction { [weak self] _ in self?.state.clearPlot() }, for: .touchUpInside)
        addSubview(closeButton)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)
        isMultipleTouchEnabled = true

        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: WaveformState.didChange, object: nil)
        stateChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var accessibilityLabel: String? {
        get { scopeElement.accessibilityLabel }
        set { scopeElement.accessibilityLabel = newValue }
    }

    override var accessibilityElements: [Any]? {
        get { sourcePicker.isHidden ? [scopeElement] : [scopeElement, sourcePicker, closeButton] }
        set {}
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = sourcePicker.sizeThatFits(CGSize(width: 140, height: 22))
        sourcePicker.frame = CGRect(x: (bounds.width - size.width) / 2, y: 3, width: size.width, height: 22)
        closeButton.frame = CGRect(x: sourcePicker.frame.maxX + 2, y: 0, width: 28, height: 28)
        scopeElement.accessibilityFrameInContainerSpace = bounds
    }

    @objc private func stateChanged() {
        sourcePicker.isHidden = state.plot == nil
        closeButton.isHidden = sourcePicker.isHidden
        sourcePicker.selectedSegmentIndex = state.source == .output ? 0 : 1
        pan.isEnabled = state.source == .plot
        setNeedsDisplay()
    }

    // MARK: Gestures

    /// Leaves touches on the picker and close button to them, so they respond without waiting
    /// for the double tap to fail.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other == pan
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        let w = max(bounds.width, 1)
        switch state.source {
        case .output:
            if pinch.state == .began { gestureStart = (0, state.outputSpan, 0) }
            guard let g = gestureStart, pinch.scale > 0 else { return }
            state.outputSpan = min(max(g.span / Double(pinch.scale), WaveformState.minOutputSpan), WaveformState.maxOutputSpan)
        case .plot:
            let x = Double(pinch.location(in: self).x / w)
            if pinch.state == .began {
                gestureStart = (state.plotStart, state.plotSpan, state.plotStart + x * state.plotSpan)
            }
            guard let g = gestureStart, pinch.scale > 0 else { return }
            // Keep the frame under the fingers where it is.
            let span = g.span / Double(pinch.scale)
            state.setPlotWindow(start: g.anchor - x * span, span: span)
        }
        if pinch.state == .ended || pinch.state == .cancelled { gestureStart = nil }
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard state.source == .plot else { return }
        if pan.state == .began { gestureStart = (state.plotStart, state.plotSpan, 0) }
        guard let g = gestureStart, pan.numberOfTouches <= 1 else { return }
        let dx = Double(pan.translation(in: self).x / max(bounds.width, 1))
        state.setPlotWindow(start: g.start - dx * state.plotSpan, span: state.plotSpan)
        if pan.state == .ended || pan.state == .cancelled { gestureStart = nil }
    }

    @objc private func handleDoubleTap() {
        switch state.source {
        case .output: state.outputSpan = WaveformState.defaultOutputSpan
        case .plot: state.fitPlot()
        }
    }

    // MARK: Drawing

    override func drawScope(in ctx: CGContext, analyzer: AudioAnalyzer) {
        let w = bounds.width, h = bounds.height
        ctx.setStrokeColor(ScopeTheme.grid.cgColor)
        ctx.setLineWidth(1)
        for f in [0.25, 0.5, 0.75] as [CGFloat] {
            ctx.move(to: CGPoint(x: 0, y: h * f)); ctx.addLine(to: CGPoint(x: w, y: h * f))
        }
        ctx.strokePath()

        switch state.source {
        case .output: drawOutput(in: ctx, analyzer: analyzer)
        case .plot: drawPlot(in: ctx)
        }
    }

    private var columnCount: Int { max(Int(bounds.width * contentScaleFactor), 2) }

    /// Strokes one trace through per-column minimums and maximums, mapping values with `y`.
    private func drawColumns(_ ranges: [(lo: Float, hi: Float)], color: UIColor, in ctx: CGContext, y: (Float) -> CGFloat) {
        guard !ranges.isEmpty else { return }
        let path = CGMutablePath()
        let dx = bounds.width / CGFloat(max(ranges.count - 1, 1))
        for (c, r) in ranges.enumerated() {
            let x = CGFloat(c) * dx
            let y0 = y(r.hi), y1 = y(r.lo)
            if c == 0 { path.move(to: CGPoint(x: x, y: y0)) } else { path.addLine(to: CGPoint(x: x, y: y0)) }
            if y1 - y0 > 1 { path.addLine(to: CGPoint(x: x, y: y1)) }
        }
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// Minimum and maximum of `samples[start ..< start + span]` for each pixel column.
    private func columnRanges(_ samples: UnsafeBufferPointer<Float>, start: Double, span: Double) -> [(lo: Float, hi: Float)] {
        let columns = columnCount
        let perColumn = span / Double(columns)
        var ranges: [(lo: Float, hi: Float)] = []
        ranges.reserveCapacity(columns)
        for c in 0..<columns {
            let a = min(max(Int(start + Double(c) * perColumn), 0), samples.count - 1)
            let b = min(max(a + 1, Int(start + Double(c + 1) * perColumn)), samples.count)
            var lo: Float = 0, hi: Float = 0
            vDSP_minv(samples.baseAddress! + a, 1, &lo, vDSP_Length(b - a))
            vDSP_maxv(samples.baseAddress! + a, 1, &hi, vDSP_Length(b - a))
            ranges.append((lo, hi))
        }
        return ranges
    }

    private func drawOutput(in ctx: CGContext, analyzer: AudioAnalyzer) {
        let w = bounds.width, h = bounds.height
        let mid = h / 2
        let span = state.outputSpan
        var ranges: [(lo: Float, hi: Float)]

        let history = analyzer.history
        if span * 2 <= Double(history.count) {
            // Search back from the newest possible start for a rising zero crossing.
            let n = Int(span)
            var start = history.count - n
            var i = start
            while i > history.count - 2 * n {
                if history[i - 1] <= 0 && history[i] > 0 { start = i; break }
                i -= 1
            }
            ranges = history.withUnsafeBufferPointer { columnRanges($0, start: Double(start), span: span) }
        } else if span <= Double(history.count) {
            ranges = history.withUnsafeBufferPointer { columnRanges($0, start: Double(history.count) - span, span: span) }
        } else {
            // Longer than the sample history: use the engine's block minimums and maximums.
            let blocks = min(Int(span) / SapfEngine.outputEnvelopeBlockSize, SapfEngine.outputEnvelopeCapacity)
            if envelopeMin.count != blocks {
                envelopeMin = [Float](repeating: 0, count: blocks)
                envelopeMax = [Float](repeating: 0, count: blocks)
            }
            _ = SapfEngine.shared.copyOutputEnvelopeMin(&envelopeMin, max: &envelopeMax, count: blocks)
            let columns = columnCount
            let perColumn = Double(blocks) / Double(columns)
            ranges = (0..<columns).map { c in
                let a = min(Int(Double(c) * perColumn), blocks - 1)
                let b = min(max(a + 1, Int(Double(c + 1) * perColumn)), blocks)
                var lo: Float = 0, hi: Float = 0
                envelopeMin.withUnsafeBufferPointer { vDSP_minv($0.baseAddress! + a, 1, &lo, vDSP_Length(b - a)) }
                envelopeMax.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + a, 1, &hi, vDSP_Length(b - a)) }
                return (lo, hi)
            }
        }

        // Never clip loud sounds.
        let peak = ranges.reduce(Float(0)) { max($0, abs($1.lo), abs($1.hi)) }
        let gain = CGFloat(peak > 1 ? 1 / peak : 1) * (mid - 4)
        drawColumns(ranges, color: ScopeTheme.trace, in: ctx) { mid - CGFloat($0) * gain }

        drawLabel(Self.durationText(span / analyzer.sampleRate), at: CGPoint(x: w - 6, y: 6), alignRight: true)
        if analyzer.playingCount > 0 {
            let peakDB = 20 * log10(max(Double(analyzer.peak), 1e-6))
            var status = String(format: "%d playing   peak %.1f dB", analyzer.playingCount, peakDB)
            status += String(format: "   load %.0f%% (max %.0f%%)", analyzer.renderLoad * 100, analyzer.maxRenderLoad * 100)
            drawLabel(status, at: CGPoint(x: 8, y: h - 32))
            // Counted since launch: a dropout is a gap in the output's timeline, a late render one
            // that took longer than its buffer lasts.
            let engine = SapfEngine.shared
            drawLabel("dropouts \(engine.audioDropouts)   late \(engine.lateAudioRenders)", at: CGPoint(x: 8, y: h - 18))
        }
    }

    private static let channelColors: [UIColor] = [
        ScopeTheme.trace, .systemOrange, .systemPink, .systemYellow, .systemCyan, .systemPurple, .systemGreen, .systemRed,
    ]

    private func drawPlot(in ctx: CGContext) {
        guard let plot = state.plot else { return }
        let w = bounds.width, h = bounds.height
        let top: CGFloat = 30, bottom = h - 22

        // Scale to the whole plot's range so it doesn't jump around while zooming.
        var lo = plot.range.lowerBound, hi = plot.range.upperBound
        if hi - lo < 1e-9 { lo -= 1; hi += 1 }
        let pad = (hi - lo) * 0.05
        lo -= pad; hi += pad
        let y = { (v: Float) -> CGFloat in bottom - CGFloat((v - lo) / (hi - lo)) * (bottom - top) }

        if lo < 0 && hi > 0 {
            ctx.setStrokeColor(ScopeTheme.gridLabel.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: 0, y: y(0))); ctx.addLine(to: CGPoint(x: w, y: y(0)))
            ctx.strokePath()
        }

        let start = state.plotStart, span = state.plotSpan
        for (i, channel) in plot.channels.enumerated() {
            let color = Self.channelColors[i % Self.channelColors.count]
            if span <= Double(columnCount) {
                // Zoomed in: a line through the points.
                let first = max(Int(start.rounded(.down)), 0)
                let last = min(Int((start + span).rounded(.up)), channel.count - 1)
                guard first <= last else { continue }
                let path = CGMutablePath()
                for k in first...last {
                    let p = CGPoint(x: CGFloat((Double(k) - start) / span) * w, y: y(channel[k]))
                    if k == first { path.move(to: p) } else { path.addLine(to: p) }
                }
                ctx.addPath(path)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokePath()
            } else {
                let ranges = channel.withUnsafeBufferPointer { columnRanges($0, start: start, span: span) }
                drawColumns(ranges, color: color, in: ctx, y: y)
            }
        }

        drawLabel(Self.valueText(hi - pad), at: CGPoint(x: w - 6, y: top - 2), alignRight: true)
        drawLabel(Self.valueText(lo + pad), at: CGPoint(x: w - 6, y: bottom - 12), alignRight: true)
        let position = { (frame: Double) -> String in
            plot.isSignal ? Self.durationText(frame / plot.sampleRate) : String(Int(frame))
        }
        drawLabel(position(start), at: CGPoint(x: 8, y: h - 16))
        drawLabel(position(start + span), at: CGPoint(x: w - 6, y: h - 16), alignRight: true)
        drawLabel(plot.summary, at: CGPoint(x: w / 2 - 40, y: h - 16))
    }

    static func durationText(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        return String(format: seconds < 10 ? "%.2f s" : "%.1f s", seconds)
    }

    private static func valueText(_ v: Float) -> String {
        abs(v) >= 1000 || (abs(v) < 0.01 && v != 0) ? String(format: "%.3g", v) : String(format: "%.3f", v)
    }
}
