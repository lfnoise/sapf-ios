//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

/// Holds interpreter output. Text is appended straight into whichever console view is showing,
/// rather than through SwiftUI state, because the output can get long.
final class ConsoleBuffer {
    private(set) var text = NSMutableAttributedString()
    /// Changes whenever text is removed, so views know they can't just append.
    private(set) var generation = 0
    private let maxLength = 300_000
    var fontSize: CGFloat = 13
    fileprivate var onChange: (() -> Void)?

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: EditorTheme.font(size: fontSize), .foregroundColor: UIColor.label]
    }
    private var errorAttributes: [NSAttributedString.Key: Any] {
        [.font: EditorTheme.font(size: fontSize), .foregroundColor: UIColor.systemRed]
    }
    private var inputAttributes: [NSAttributedString.Key: Any] {
        [.font: EditorTheme.font(size: fontSize), .foregroundColor: UIColor.secondaryLabel]
    }

    func append(_ output: String) {
        // Color lines that report errors.
        var rest = Substring(output)
        while !rest.isEmpty {
            let lineEnd = rest.firstIndex(of: "\n").map { rest.index(after: $0) } ?? rest.endIndex
            let line = rest[..<lineEnd]
            let isError = line.hasPrefix("error") || line.hasPrefix("\nerror") || line.contains("exception in real time")
            text.append(NSAttributedString(string: String(line), attributes: isError ? errorAttributes : attributes))
            rest = rest[lineEnd...]
        }
        trim()
        onChange?()
    }

    /// Echoes code that was evaluated, like the terminal prompt does.
    func echo(_ code: String) {
        var shown = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if shown.count > 400 { shown = String(shown.prefix(400)) + " ..." }
        shown = shown.replacingOccurrences(of: "\n", with: "\n       ")
        if text.length > 0 && !text.string.hasSuffix("\n") { text.append(NSAttributedString(string: "\n", attributes: attributes)) }
        text.append(NSAttributedString(string: "sapf> " + shown + "\n", attributes: inputAttributes))
        trim()
        onChange?()
    }

    func clear() {
        text = NSMutableAttributedString()
        generation += 1
        onChange?()
    }

    private func trim() {
        if text.length > maxLength {
            text.deleteCharacters(in: NSRange(location: 0, length: text.length - maxLength * 3 / 4))
            generation += 1
        }
    }
}

struct ConsoleView: UIViewRepresentable {
    let buffer: ConsoleBuffer

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .secondarySystemBackground
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        view.alwaysBounceVertical = true
        view.accessibilityLabel = "Console"
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(buffer: buffer) }

    final class Coordinator {
        let buffer: ConsoleBuffer
        weak var view: UITextView?
        private var shownGeneration = -1
        private var shownLength = 0
        init(buffer: ConsoleBuffer) { self.buffer = buffer }

        func attach(_ view: UITextView) {
            self.view = view
            buffer.onChange = { [weak self] in self?.refresh() }
            refresh()
        }

        private func refresh() {
            guard let view else { return }
            let atBottom = view.contentOffset.y >= view.contentSize.height - view.bounds.height - 40
            if shownGeneration == buffer.generation && shownLength <= buffer.text.length {
                let new = NSRange(location: shownLength, length: buffer.text.length - shownLength)
                view.textStorage.append(buffer.text.attributedSubstring(from: new))
            } else {
                view.attributedText = buffer.text
                shownGeneration = buffer.generation
            }
            shownLength = buffer.text.length
            if atBottom || view.contentSize.height <= view.bounds.height {
                view.layoutIfNeeded()
                let end = NSRange(location: max(buffer.text.length - 1, 0), length: buffer.text.length > 0 ? 1 : 0)
                view.scrollRangeToVisible(end)
            }
        }
    }
}
