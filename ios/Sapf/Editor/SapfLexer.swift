//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Kinds of tokens, for coloring. Follows the rules in src/Parser.cpp.
enum TokenKind: Equatable {
    case comment        // ; to end of line
    case string         // "..."  ("" is an escaped quote)
    case number         // 1  -2.5  1e3  4c  24k  9/12  2pi  0xff
    case builtIn        // sinosc
    case userWord       // a word defined with help in the workspace
    case word           // any other word
    case symbol         // 'name  `name
    case key            // :name  .name  ,name
    case assign         // =
    case assignTarget   // the name after =
    case lambda         // \
    case lambdaArg      // the argument names after \
    case eachOp         // @  @@  @1  @01
    case bracket        // ( ) [ ] { } #[
}

struct Token: Equatable {
    var range: NSRange
    var kind: TokenKind
}

struct SapfLexer {
    var builtIns: Set<String>
    var userWords: Set<String>

    // Characters that end a word. Same as `nonnamechars` in Parser.cpp, plus whitespace.
    private static let nonName: Set<UInt16> = Set(";()[]{}.`,:\"\n".utf16)

    private static func isSpace(_ c: UInt16) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C || c == 0xA0
    }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isEndOfWord(_ c: UInt16) -> Bool { isSpace(c) || nonName.contains(c) }

    private static let semicolon = UInt16(UInt8(ascii: ";"))
    private static let quote = UInt16(UInt8(ascii: "\""))
    private static let newline = UInt16(UInt8(ascii: "\n"))
    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let at = UInt16(UInt8(ascii: "@"))
    private static let hash = UInt16(UInt8(ascii: "#"))
    private static let dot = UInt16(UInt8(ascii: "."))
    private static let openBracket = UInt16(UInt8(ascii: "["))
    private static let closeBracket = UInt16(UInt8(ascii: "]"))
    private static let openParen = UInt16(UInt8(ascii: "("))
    private static let closeParen = UInt16(UInt8(ascii: ")"))
    private static let brackets: Set<UInt16> = Set("()[]{}".utf16)
    private static let symbolPrefixes: Set<UInt16> = Set("'`".utf16)
    private static let keyPrefixes: Set<UInt16> = Set(":,".utf16)
    private static let numberStarts: Set<UInt16> = Set("0123456789+-.p".utf16)

    func tokenize(_ text: NSString) -> [Token] {
        let n = text.length
        var chars = [UInt16](repeating: 0, count: n)
        text.getCharacters(&chars, range: NSRange(location: 0, length: n))

        var tokens: [Token] = []
        tokens.reserveCapacity(n / 4)

        var pendingAssign = false   // just saw '='
        var multiAssign = false     // inside '= (a b c)' or '= [a b c]'
        var lambdaArgs = false      // between '\' and '['

        func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
            tokens.append(Token(range: NSRange(location: start, length: end - start), kind: kind))
        }
        func wordEnd(from start: Int) -> Int {
            var j = start
            while j < n && !Self.isEndOfWord(chars[j]) { j += 1 }
            return j
        }

        var i = 0
        while i < n {
            let c = chars[i]

            if Self.isSpace(c) {
                i += 1
                continue
            }

            if c == Self.semicolon {
                var j = i
                while j < n && chars[j] != Self.newline { j += 1 }
                add(i, j, .comment)
                i = j
                continue
            }

            if c == Self.quote {
                var j = i + 1
                while j < n {
                    if chars[j] == Self.quote {
                        if j + 1 < n && chars[j + 1] == Self.quote { j += 2; continue }
                        j += 1
                        break
                    }
                    j += 1
                }
                add(i, min(j, n), .string)
                i = j
                continue
            }

            if Self.brackets.contains(c) {
                add(i, i + 1, .bracket)
                if lambdaArgs && c == Self.openBracket { lambdaArgs = false }
                if pendingAssign && (c == Self.openParen || c == Self.openBracket) {
                    multiAssign = true
                    pendingAssign = false
                } else if multiAssign && (c == Self.closeParen || c == Self.closeBracket) {
                    multiAssign = false
                }
                i += 1
                continue
            }

            if c == Self.hash && i + 1 < n && chars[i + 1] == Self.openBracket {
                add(i, i + 2, .bracket)
                i += 2
                continue
            }

            if c == Self.backslash {
                add(i, i + 1, .lambda)
                lambdaArgs = true
                i += 1
                continue
            }

            if c == Self.at {
                var j = i + 1
                while j < n && chars[j] == Self.at { j += 1 }
                while j < n && Self.isDigit(chars[j]) { j += 1 }
                add(i, j, .eachOp)
                i = j
                continue
            }

            if Self.symbolPrefixes.contains(c) || Self.keyPrefixes.contains(c) {
                let j = wordEnd(from: i + 1)
                add(i, j, Self.symbolPrefixes.contains(c) ? .symbol : .key)
                i = j
                continue
            }

            if Self.numberStarts.contains(c) {
                // Numbers may contain '.', so scan with a looser terminator than words.
                var j = i
                while j < n && !Self.isSpace(chars[j]) && (chars[j] == Self.dot || !Self.nonName.contains(chars[j])) { j += 1 }
                if Self.isNumber(chars[i..<j]) {
                    add(i, j, .number)
                    i = j
                    continue
                }
                if c == Self.dot {
                    let k = wordEnd(from: i + 1)
                    add(i, k, .key)
                    i = k
                    continue
                }
            }

            var j = wordEnd(from: i)
            if j == i { j = i + 1 }
            let word = text.substring(with: NSRange(location: i, length: j - i))
            let kind: TokenKind
            if word == "=" {
                kind = .assign
                pendingAssign = true
            } else if pendingAssign || multiAssign {
                kind = .assignTarget
                pendingAssign = false
            } else if lambdaArgs {
                kind = .lambdaArg
            } else if builtIns.contains(word) {
                kind = .builtIn
            } else if userWords.contains(word) {
                kind = .userWord
            } else {
                kind = .word
            }
            add(i, j, kind)
            i = j
        }
        return tokens
    }

    /// Mirrors parseNumber / parseFloat / parseHexNumber in Parser.cpp.
    static func isNumber(_ s: ArraySlice<UInt16>) -> Bool {
        var i = s.startIndex
        let end = s.endIndex
        func peek(_ offset: Int = 0) -> UInt16? { i + offset < end ? s[i + offset] : nil }
        func isChar(_ c: UInt16?, _ ch: Unicode.Scalar) -> Bool { c == UInt16(ch.value) }

        if isChar(peek(), "0") && isChar(peek(1), "x") {
            i += 2
            let start = i
            while let c = peek(), (isDigit(c) || (c | 0x20) >= 0x61 && (c | 0x20) <= 0x66) { i += 1 }
            return i > start && i == end
        }

        if isChar(peek(), "+") || isChar(peek(), "-") { i += 1 }

        var digits = 0
        while let c = peek(), isDigit(c) { i += 1; digits += 1 }
        if isChar(peek(), ".") {
            i += 1
            while let c = peek(), isDigit(c) { i += 1; digits += 1 }
        }
        if digits > 0 && (isChar(peek(), "e") || isChar(peek(), "E")) {
            var k = 1
            if isChar(peek(k), "+") || isChar(peek(k), "-") { k += 1 }
            if let c = peek(k), isDigit(c) {
                i += k
                while let c = peek(), isDigit(c) { i += 1 }
            }
        }
        if isChar(peek(), "p") && isChar(peek(1), "i") {
            i += 2
            digits += 1
        }
        guard digits > 0 else { return false }

        if let c = peek(), "Mkhcmu".utf16.contains(c) { i += 1 }

        if isChar(peek(), "/") {
            i += 1
            var denomDigits = 0
            while let c = peek(), isDigit(c) || isChar(c, ".") { i += 1; denomDigits += 1 }
            if denomDigits == 0 { return false }
        }
        return i == end
    }
}
