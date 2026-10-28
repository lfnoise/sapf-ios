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

import UIKit

/// A small bubble that points at a word and shows its help. It's a plain subview of the
/// text view rather than a presented popover, so it never takes focus from the editor.
final class HelpTooltipView: UIView {
    private let label = UILabel()
    private let arrow = CAShapeLayer()
    private let bubble = UIView()
    private static let arrowSize: CGFloat = 7
    private static let margin: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear

        bubble.backgroundColor = .secondarySystemBackground
        bubble.layer.cornerRadius = 10
        bubble.layer.borderWidth = 1 / UIScreen.main.scale
        bubble.layer.borderColor = UIColor.separator.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(bubble)

        arrow.fillColor = UIColor.secondarySystemBackground.cgColor
        layer.addSublayer(arrow)

        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        bubble.addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        arrow.fillColor = UIColor.secondarySystemBackground.resolvedColor(with: traitCollection).cgColor
        bubble.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    /// Builds the tooltip text: the word, its automapping mask, then the help.
    static func attributedHelp(name: String, mask: String?, help: String, detail: String?, fontSize: CGFloat) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let mono = EditorTheme.font(size: fontSize)
        s.append(NSAttributedString(string: name, attributes: [
            .font: EditorTheme.boldFont(size: fontSize + 1),
            .foregroundColor: EditorTheme.builtIn,
        ]))
        if let mask {
            s.append(NSAttributedString(string: "  @" + mask, attributes: [
                .font: mono, .foregroundColor: EditorTheme.eachOp,
            ]))
        }
        if let detail {
            s.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .caption1), .foregroundColor: UIColor.secondaryLabel,
            ]))
        }
        s.append(NSAttributedString(string: "\n"))

        // Help usually starts with a stack effect like "(in freq --> out)". Show it in mono.
        var body = help
        if body.hasPrefix("("), let close = body.range(of: ")") {
            let effect = String(body[body.startIndex..<close.upperBound])
            body = String(body[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            s.append(NSAttributedString(string: effect + (body.isEmpty ? "" : "\n"), attributes: [
                .font: mono, .foregroundColor: UIColor.label,
            ]))
        }
        if !body.isEmpty {
            s.append(NSAttributedString(string: body, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .callout), .foregroundColor: UIColor.label,
            ]))
        }
        return s
    }

    /// Shows the tooltip pointing at `target`, a rect in `container`'s coordinates. `visible` is the part
    /// of the container currently on screen (for a scroll view, its bounds).
    func show(_ text: NSAttributedString, pointingAt target: CGRect, in container: UIView, visible: CGRect) {
        label.attributedText = text
        accessibilityLabel = text.string

        let maxWidth = min(visible.width - 2 * Self.margin, 460)
        let padding = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let textSize = label.sizeThatFits(CGSize(width: maxWidth - padding.left - padding.right, height: .greatestFiniteMagnitude))
        let bubbleSize = CGSize(width: ceil(textSize.width) + padding.left + padding.right,
                                height: ceil(textSize.height) + padding.top + padding.bottom)

        // Prefer above the word, unless there's no room.
        let a = Self.arrowSize
        let roomAbove = target.minY - visible.minY
        let above = roomAbove >= bubbleSize.height + a + Self.margin

        var x = target.midX - bubbleSize.width / 2
        x = max(visible.minX + Self.margin, min(x, visible.maxX - Self.margin - bubbleSize.width))
        let y = above ? target.minY - a - bubbleSize.height : target.maxY + a

        frame = CGRect(x: x, y: above ? y : y - a, width: bubbleSize.width, height: bubbleSize.height + a)
        bubble.frame = CGRect(x: 0, y: above ? 0 : a, width: bubbleSize.width, height: bubbleSize.height)
        label.frame = bubble.bounds.inset(by: padding)

        let tipX = min(max(target.midX - x, 14), bubbleSize.width - 14)
        let path = UIBezierPath()
        if above {
            path.move(to: CGPoint(x: tipX - a, y: bubbleSize.height - 0.5))
            path.addLine(to: CGPoint(x: tipX, y: bubbleSize.height + a))
            path.addLine(to: CGPoint(x: tipX + a, y: bubbleSize.height - 0.5))
        } else {
            path.move(to: CGPoint(x: tipX - a, y: a + 0.5))
            path.addLine(to: CGPoint(x: tipX, y: 0))
            path.addLine(to: CGPoint(x: tipX + a, y: a + 0.5))
        }
        path.close()
        arrow.path = path.cgPath

        if superview !== container {
            container.addSubview(self)
        }
        container.bringSubviewToFront(self)

        alpha = 0
        transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.12) {
            self.alpha = 1
            self.transform = .identity
        }
        UIAccessibility.post(notification: .announcement, argument: text.string)
    }

    func hide() {
        guard superview != nil else { return }
        UIView.animate(withDuration: 0.1, animations: { self.alpha = 0 }) { _ in
            if self.alpha == 0 { self.removeFromSuperview() }
        }
    }

    var isShowing: Bool { superview != nil && alpha > 0 }
}
