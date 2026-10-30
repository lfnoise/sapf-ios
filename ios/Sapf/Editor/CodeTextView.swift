//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UIKit

protocol CodeTextViewActions: AnyObject {
    func codeTextView(_ view: CodeTextView, evaluate code: String)
    func codeTextViewStop(_ view: CodeTextView)
    func codeTextViewDidChangeText(_ view: CodeTextView)
    func codeTextViewDidEndEditing(_ view: CodeTextView)
}

/// The sapf source editor: syntax coloring, tap a word for help, and evaluation commands.
final class CodeTextView: UITextView, UITextViewDelegate, NSTextStorageDelegate, UIGestureRecognizerDelegate {
    weak var actions: CodeTextViewActions?
    let highlighter = SyntaxHighlighter()
    private let tooltip = HelpTooltipView()
    private var pendingEdit: (range: NSRange, delta: Int)?
    private var tooltipToken: Token?
    private var vocabularySize = 0
    private let storage = NSTextStorage()
    var showsHelpOnTap = true

    /// Blocks and bracket pairs, kept in step with the highlighter's tokens.
    private(set) var structure = CodeStructure()
    private var runButtons: [UIButton] = []
    private let blockBar = UIView()
    private static let gutterWidth: CGFloat = 30

    var fontSize: CGFloat = 15 {
        didSet {
            guard fontSize != oldValue else { return }
            highlighter.fontSize = fontSize
            rehighlight()
        }
    }

    init() {
        // TextKit 1, for the glyph geometry used to place the tooltip.
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        delegate = self
        textStorage.delegate = self
        backgroundColor = EditorTheme.background
        autocapitalizationType = .none
        autocorrectionType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        keyboardType = .asciiCapable
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        textContainerInset = UIEdgeInsets(top: 12, left: Self.gutterWidth + 4, bottom: 40, right: 8)
        typingAttributes = highlighter.baseAttributes
        inputAccessoryView = makeAccessoryBar()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)

        blockBar.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.55)
        blockBar.layer.cornerRadius = 1.5
        blockBar.isUserInteractionEnabled = false
        addSubview(blockBar)

        NotificationCenter.default.addObserver(self, selector: #selector(vocabularyMayHaveChanged),
                                               name: .sapfVocabularyChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Text

    func setText(_ newText: String) {
        tooltip.hide()
        text = newText
        selectedRange = NSRange(location: 0, length: 0)
        rehighlight()
        setContentOffset(CGPoint(x: 0, y: -adjustedContentInset.top), animated: false)
    }

    func rehighlight() {
        let builtIns = SapfEngine.shared.builtInWords
        let userWords = SapfEngine.shared.userWords
        vocabularySize = builtIns.count + userWords.count
        highlighter.setVocabulary(builtIns: builtIns, userWords: userWords)
        highlighter.highlightAll(textStorage)
        typingAttributes = highlighter.baseAttributes
        updateStructure()
    }

    private func updateStructure() {
        structure = CodeStructure(text: textStorage.string as NSString, tokens: highlighter.tokens)
        setNeedsLayout()
    }

    @objc private func vocabularyMayHaveChanged() {
        // Words are only ever added, so the count tells whether anything is new.
        let size = SapfEngine.shared.builtInWords.count + SapfEngine.shared.userWords.count
        if size != vocabularySize { rehighlight() }
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) {
            pendingEdit = (editedRange, delta)
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        tooltip.hide()
        // Restyling while composing marked text (e.g. dead keys) would cancel the composition.
        if markedTextRange == nil, let edit = pendingEdit {
            highlighter.highlightEdit(textStorage, editedRange: edit.range, delta: edit.delta)
            pendingEdit = nil
            updateStructure()
        }
        typingAttributes = highlighter.baseAttributes
        actions?.codeTextViewDidChangeText(self)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Keep the indentation of the current line on return.
        guard text == "\n" else { return true }
        let ns = self.text as NSString
        let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
        var indentEnd = lineStart
        while indentEnd < range.location, let c = Unicode.Scalar(ns.character(at: indentEnd)), c == " " || c == "\t" {
            indentEnd += 1
        }
        guard indentEnd > lineStart else { return true }
        let indent = ns.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))
        replace(range, with: "\n" + indent)
        return false
    }

    private func replace(_ range: NSRange, with string: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        replace(textRange, withText: string)
    }

    // MARK: Evaluation

    /// The selection if there is one, otherwise the block around the cursor (or its line).
    func codeToEvaluate(wholeBlock: Bool) -> NSRange {
        let sel = selectedRange
        if sel.length > 0 { return sel }
        if !wholeBlock { return (text as NSString).lineRange(for: sel) }
        return structure.block(at: sel.location)?.range ?? (text as NSString).lineRange(for: sel)
    }

    /// Runs the block whose code starts at a location (from a gutter button).
    private func evaluateBlock(codeStart: Int) {
        guard let block = structure.blocks.first(where: { $0.codeStart == codeStart }) else { return }
        tooltip.hide()
        flash(block.range)
        actions?.codeTextView(self, evaluate: (text as NSString).substring(with: block.range))
    }

    private func selectBlock(codeStart: Int) {
        guard let block = structure.blocks.first(where: { $0.codeStart == codeStart }) else { return }
        if !isFirstResponder { becomeFirstResponder() }
        selectedRange = structure.trimmed(block.range)
    }

    /// Selects the next larger enclosing expression: inside the brackets, the brackets, then the block.
    @objc func expandSelection() {
        guard let range = structure.expand(selectedRange) else { return }
        if !isFirstResponder { becomeFirstResponder() }
        selectedRange = range
    }

    func evaluate(wholeBlock: Bool = true) {
        let range = codeToEvaluate(wholeBlock: wholeBlock)
        let code = (text as NSString).substring(with: range)
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        flash(range)
        actions?.codeTextView(self, evaluate: code)
    }

    private func flash(_ range: NSRange) {
        textStorage.addAttribute(.backgroundColor, value: EditorTheme.evalFlash, range: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let all = NSRange(location: 0, length: self.textStorage.length)
            self.textStorage.removeAttribute(.backgroundColor, range: all)
        }
    }

    // MARK: Help tooltips

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if !isEditable, let position = closestPosition(to: point) {
            // Reading: there's no caret, but a tap still picks the block that Run evaluates.
            // Set it after the text view's own tap handling, which clears the selection.
            DispatchQueue.main.async {
                self.selectedTextRange = self.textRange(from: position, to: position)
                self.setNeedsLayout()
            }
        }
        guard showsHelpOnTap, !(tooltip.isShowing && tooltip.frame.contains(point)),
              case let (token, rect)? = wordToken(at: point) else {
            tooltip.hide()
            tooltipToken = nil
            return
        }
        if tooltipToken == token && tooltip.isShowing {
            // Tapping the same word again dismisses its help.
            tooltip.hide()
            tooltipToken = nil
            return
        }

        var word = (text as NSString).substring(with: token.range)
        if token.kind == .symbol || token.kind == .key {
            word.removeFirst()
        }
        tooltipToken = token

        if let help = SapfEngine.shared.help(forWord: word) {
            let detail = help.builtIn ? nil : "user defined"
            showTooltip(HelpTooltipView.attributedHelp(name: help.name, mask: help.mask, help: help.help,
                                                        detail: detail, fontSize: fontSize), at: rect)
            return
        }

        // Not a function with help. If it's a variable, show its value.
        tooltip.hide()
        SapfEngine.shared.describeWord(word) { [weak self] description in
            guard let self, let description, self.tooltipToken == token else { return }
            self.showTooltip(HelpTooltipView.attributedHelp(name: word, mask: nil, help: description,
                                                             detail: "value", fontSize: self.fontSize), at: rect)
        }
    }

    private func showTooltip(_ text: NSAttributedString, at rect: CGRect) {
        let visible = bounds.inset(by: adjustedContentInset)
        tooltip.show(text, pointingAt: rect, in: self, visible: visible)
    }

    /// The word under a point, and its rect in this view's coordinates.
    private func wordToken(at point: CGPoint) -> (Token, CGRect)? {
        let containerPoint = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: containerPoint, in: textContainer,
                                                 fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < textStorage.length, let token = highlighter.token(at: index) else { return nil }
        switch token.kind {
        case .builtIn, .userWord, .word, .symbol, .key, .assignTarget: break
        default: return nil
        }

        let glyphs = layoutManager.glyphRange(forCharacterRange: token.range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect = rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
        // characterIndex(for:) returns the nearest character even past the end of a line.
        guard rect.insetBy(dx: -6, dy: -4).contains(point) else { return nil }
        return (token, rect)
    }

    // MARK: Brackets

    /// Double tapping a bracket selects through its match.
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let containerPoint = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: containerPoint, in: textContainer,
                                                 fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard let token = highlighter.token(at: index), token.kind == .bracket,
              let pair = structure.pair(withBracketAt: token.range.location) else { return }
        // Let the text view do its own double tap word selection first, then replace it.
        DispatchQueue.main.async { self.selectedRange = pair }
    }

    // MARK: Gutter

    func textViewDidChangeSelection(_ textView: UITextView) {
        setNeedsLayout()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        actions?.codeTextViewDidEndEditing(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutGutter()
    }

    /// Puts a run button beside the first line of each visible block, and a bar beside the block
    /// that Run would evaluate.
    private func layoutGutter() {
        let lm = layoutManager
        let visible = CGRect(x: 0, y: contentOffset.y - textContainerInset.top - 40,
                             width: bounds.width, height: bounds.height + 80)
        let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: textContainer)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        var used = 0
        for block in structure.blocks {
            guard let start = block.codeStart else { continue }
            if start < chars.location { continue }
            if start > NSMaxRange(chars) { break }
            let glyph = lm.glyphIndexForCharacter(at: start)
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let button = runButton(used)
            button.tag = start
            let size: CGFloat = 28
            button.frame = CGRect(x: 2, y: line.midY + textContainerInset.top - size / 2, width: size, height: size)
            button.isHidden = false
            used += 1
        }
        for i in used..<runButtons.count { runButtons[i].isHidden = true }

        if selectedRange.length == 0, let block = structure.block(at: selectedRange.location), block.codeStart != nil {
            let range = structure.trimmed(block.range)
            let blockGlyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
            blockBar.frame = CGRect(x: Self.gutterWidth, y: rect.minY + textContainerInset.top + 2,
                                    width: 3, height: max(rect.height - 4, 4))
            blockBar.isHidden = false
        } else {
            blockBar.isHidden = true
        }
    }

    private func runButton(_ index: Int) -> UIButton {
        if index < runButtons.count { return runButtons[index] }
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "play.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.baseForegroundColor = .systemGreen
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self, unowned button] _ in
            self?.evaluateBlock(codeStart: button.tag)
        }, for: .primaryActionTriggered)
        // Long press for more.
        button.menu = UIMenu(children: [
            UIAction(title: "Run Block", image: UIImage(systemName: "play.fill")) { [weak self, unowned button] _ in
                self?.evaluateBlock(codeStart: button.tag)
            },
            UIAction(title: "Select Block", image: UIImage(systemName: "selection.pin.in.out")) { [weak self, unowned button] _ in
                self?.selectBlock(codeStart: button.tag)
            },
            UIAction(title: "Copy Block", image: UIImage(systemName: "doc.on.doc")) { [weak self, unowned button] _ in
                guard let self, let block = self.structure.blocks.first(where: { $0.codeStart == button.tag }) else { return }
                UIPasteboard.general.string = (self.text as NSString).substring(with: self.structure.trimmed(block.range))
            },
        ])
        button.accessibilityLabel = "Run block"
        button.accessibilityHint = "Touch and hold for more options."
        addSubview(button)
        runButtons.append(button)
        return button
    }

    // MARK: Keyboard

    override var keyCommands: [UIKeyCommand]? {
        let run = UIKeyCommand(title: "Evaluate", action: #selector(evaluateBlockCommand), input: "\r", modifierFlags: .command)
        let line = UIKeyCommand(title: "Evaluate Line", action: #selector(evaluateLineCommand), input: "\r", modifierFlags: .shift)
        let stop = UIKeyCommand(title: "Stop", action: #selector(stopCommand), input: ".", modifierFlags: .command)
        let expand = UIKeyCommand(title: "Expand Selection", action: #selector(expandSelection), input: "b", modifierFlags: .command)
        let bigger = UIKeyCommand(title: "Bigger", action: #selector(biggerCommand), input: "+", modifierFlags: .command)
        let bigger2 = UIKeyCommand(title: "Bigger", action: #selector(biggerCommand), input: "=", modifierFlags: .command)
        let smaller = UIKeyCommand(title: "Smaller", action: #selector(smallerCommand), input: "-", modifierFlags: .command)
        for c in [run, line, stop] { c.wantsPriorityOverSystemBehavior = true }
        bigger2.attributes = .hidden
        return [run, line, stop, expand, bigger, bigger2, smaller]
    }

    @objc private func evaluateBlockCommand() { evaluate(wholeBlock: true) }
    @objc private func evaluateLineCommand() { evaluate(wholeBlock: false) }
    @objc private func stopCommand() { actions?.codeTextViewStop(self) }
    @objc private func biggerCommand() { fontSize = min(fontSize + 1, 32) }
    @objc private func smallerCommand() { fontSize = max(fontSize - 1, 9) }

    private func makeAccessoryBar() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        bar.allowsSelfSizing = true

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        func button(_ title: String?, image: String? = nil, tint: UIColor? = nil, label: String? = nil, action: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.gray()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11)
            if let title {
                config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: EditorTheme.font(size: 17)]))
            }
            if let image { config.image = UIImage(systemName: image) }
            if let tint { config.baseForegroundColor = tint }
            let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            b.accessibilityLabel = label ?? title
            return b
        }

        stack.addArrangedSubview(button(nil, image: "play.fill", tint: .systemGreen, label: "Evaluate") { [weak self] in self?.evaluate() })
        stack.addArrangedSubview(button(nil, image: "stop.fill", tint: .systemRed, label: "Stop") { [weak self] in
            guard let self else { return }
            self.actions?.codeTextViewStop(self)
        })
        stack.addArrangedSubview(button(nil, image: "selection.pin.in.out", tint: .systemBlue, label: "Expand Selection") { [weak self] in
            self?.expandSelection()
        })
        for key in ["[", "]", "(", ")", "{", "}", "\\", "@", "'", "`", "=", ":", ";", "\"", "#", ",", "."] {
            stack.addArrangedSubview(button(key) { [weak self] in self?.insertText(key) })
        }
        stack.addArrangedSubview(button(nil, image: "keyboard.chevron.compact.down", label: "Hide keyboard") { [weak self] in
            self?.resignFirstResponder()
        })

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 36),
        ])
        return bar
    }
}

extension Notification.Name {
    /// Posted when evaluation may have defined new words.
    static let sapfVocabularyChanged = Notification.Name("sapfVocabularyChanged")
}
