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

enum EditorTheme {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    static let text = UIColor.label
    static let background = UIColor.systemBackground

    static func color(for kind: TokenKind) -> UIColor {
        switch kind {
        case .comment: return comment
        case .string: return string
        case .number: return number
        case .builtIn: return builtIn
        case .userWord: return userWord
        case .word: return text
        case .symbol: return symbol
        case .key: return key
        case .assign, .assignTarget: return assign
        case .lambda, .lambdaArg: return lambda
        case .eachOp: return eachOp
        case .bracket: return bracket
        }
    }

    static let comment = dynamic(0x6E7781, 0x8B949E)
    static let string = dynamic(0xC41A16, 0xFF8170)
    static let number = dynamic(0x1C00CF, 0xD9C97C)
    static let builtIn = dynamic(0x0B7285, 0x67D4E8)
    static let userWord = dynamic(0x6F42C1, 0xD2A8FF)
    static let symbol = dynamic(0x9A6700, 0xF0B76B)
    static let key = dynamic(0x8250DF, 0xB4A0FF)
    static let assign = dynamic(0xCF222E, 0xFF7B9C)
    static let lambda = dynamic(0x116329, 0x7EE787)
    static let eachOp = dynamic(0xBC4C00, 0xFFA657)
    static let bracket = dynamic(0x57606A, 0x9DA7B3)
    static let evalFlash = UIColor.systemYellow.withAlphaComponent(0.35)

    static func font(size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    static func boldFont(size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Colors a text storage. Re-lexing the whole text is cheap; touching attributes is not,
/// so only the tokens that differ from the previous pass are restyled.
final class SyntaxHighlighter {
    private(set) var tokens: [Token] = []
    private var lexer = SapfLexer(builtIns: [], userWords: [])
    var fontSize: CGFloat = 15

    func setVocabulary(builtIns: Set<String>, userWords: Set<String>) {
        lexer.builtIns = builtIns
        lexer.userWords = userWords
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: EditorTheme.font(size: fontSize), .foregroundColor: EditorTheme.text]
    }

    /// Restyles everything. Use after loading text, changing the font or the vocabulary.
    func highlightAll(_ storage: NSTextStorage) {
        let newTokens = lexer.tokenize(storage.string as NSString)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        apply(newTokens[...], to: storage)
        storage.endEditing()
        tokens = newTokens
    }

    /// Restyles after an edit that replaced text at `editedRange` (in the new text), changing the length by `delta`.
    func highlightEdit(_ storage: NSTextStorage, editedRange: NSRange, delta: Int) {
        let newTokens = lexer.tokenize(storage.string as NSString)
        let old = tokens
        tokens = newTokens

        // Tokens wholly before the edit keep their positions; tokens wholly after it shift by delta.
        var prefix = 0
        while prefix < old.count && prefix < newTokens.count && old[prefix] == newTokens[prefix]
                && NSMaxRange(newTokens[prefix].range) < editedRange.location {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix && suffix < newTokens.count - prefix {
            let o = old[old.count - 1 - suffix]
            let t = newTokens[newTokens.count - 1 - suffix]
            guard o.kind == t.kind, o.range.length == t.range.length, o.range.location + delta == t.range.location,
                  t.range.location > NSMaxRange(editedRange) else { break }
            suffix += 1
        }

        let changed = newTokens[prefix..<(newTokens.count - suffix)]
        let start = prefix > 0 ? NSMaxRange(newTokens[prefix - 1].range) : 0
        let end = suffix > 0 ? newTokens[newTokens.count - suffix].range.location : storage.length
        guard end >= start else { highlightAll(storage); return }

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: start, length: end - start))
        apply(changed, to: storage)
        storage.endEditing()
    }

    private func apply(_ tokens: ArraySlice<Token>, to storage: NSTextStorage) {
        let bold = EditorTheme.boldFont(size: fontSize)
        for token in tokens where token.kind != .word {
            storage.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind), range: token.range)
            if token.kind == .assignTarget {
                storage.addAttribute(.font, value: bold, range: token.range)
            }
        }
    }

    /// The token containing a character offset, if any.
    func token(at offset: Int) -> Token? {
        var lo = 0, hi = tokens.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = tokens[mid].range
            if offset < r.location { hi = mid - 1 }
            else if offset >= NSMaxRange(r) { lo = mid + 1 }
            else { return tokens[mid] }
        }
        return nil
    }
}
