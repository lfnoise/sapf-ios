//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UIKit

/// The help for every function, styled so names stand out from their descriptions and wrapped lines
/// are indented under their entry. Colours match the editor's.
enum FunctionList {
    struct Entry: Equatable {
        var name: String
        var mask: String?
        var effect: String?
        var description: String
    }

    /// Splits a help line like "name @mask (a b --> c) description". Returns nil for headings and
    /// the legend, which start with whitespace or end their first word with a colon.
    static func entry(_ line: Substring) -> Entry? {
        guard let first = line.first, !first.isWhitespace, !line.hasSuffix(":"),
              let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[..<space])
        guard !name.hasSuffix(":"), !name.hasPrefix("***") else { return nil }

        var rest = line[line.index(after: space)...].drop { $0 == " " }
        var mask: String?
        if rest.hasPrefix("@") {
            let end = rest.firstIndex(of: " ") ?? rest.endIndex
            mask = String(rest[rest.index(after: rest.startIndex)..<end])
            rest = rest[end...].drop { $0 == " " }
        }
        var effect: String?
        if rest.hasPrefix("(") {
            // The stack effect ends at the parenthesis after its arrow; its items can have their own.
            let arrow = rest.range(of: "-->")?.upperBound ?? rest.startIndex
            if let close = rest[arrow...].firstIndex(of: ")") {
                effect = String(rest[...close])
                rest = rest[rest.index(after: close)...].drop { $0 == " " }
            }
        }
        return Entry(name: name, mask: mask, effect: effect, description: String(rest))
    }

    /// The whole list, styled: names bold in the editor's built-in colour, masks and stack effects in
    /// mono, and each entry's wrapped lines indented under its name.
    static func attributedText(from text: String) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let mono = UIFont.monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular)
        let bold = UIFont.boldSystemFont(ofSize: body.pointSize)
        let indent = body.pointSize * 1.5

        func paragraph(headIndent: CGFloat, firstLine: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 3) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = firstLine
            style.headIndent = headIndent
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            return style
        }
        let entryStyle = paragraph(headIndent: indent)

        let s = NSMutableAttributedString()
        func add(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            s.append(NSAttributedString(string: string, attributes: attributes))
        }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "BUILT IN FUNCTIONS" || trimmed == "USER DEFINED FUNCTIONS" {
                add(trimmed.capitalized + "\n", [.font: UIFont.preferredFont(forTextStyle: .title2).bold,
                                                .foregroundColor: UIColor.label,
                                                .paragraphStyle: paragraph(headIndent: 0, before: s.length > 0 ? 24 : 0, after: 8)])
            } else if trimmed.hasPrefix("***") {
                add(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "* ")) + "\n",
                    [.font: UIFont.preferredFont(forTextStyle: .headline), .foregroundColor: UIColor.secondaryLabel,
                     .paragraphStyle: paragraph(headIndent: 0, before: 16, after: 6)])
            } else if let e = entry(line) {
                let style: [NSAttributedString.Key: Any] = [.paragraphStyle: entryStyle]
                add(e.name, style.merging([.font: bold, .foregroundColor: EditorTheme.builtIn]) { $1 })
                if let mask = e.mask { add("  @" + mask, style.merging([.font: mono, .foregroundColor: EditorTheme.eachOp]) { $1 }) }
                if let effect = e.effect { add("  " + effect, style.merging([.font: mono, .foregroundColor: UIColor.secondaryLabel]) { $1 }) }
                add((e.description.isEmpty ? "" : "  " + e.description) + "\n",
                    style.merging([.font: body, .foregroundColor: UIColor.label]) { $1 })
            } else {
                add(trimmed + "\n", [.font: body, .foregroundColor: UIColor.secondaryLabel,
                                      .paragraphStyle: paragraph(headIndent: indent, firstLine: line.first == " " ? indent / 2 : 0)])
            }
        }
        return s
    }

}

private extension UIFont {
    var bold: UIFont {
        fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}
